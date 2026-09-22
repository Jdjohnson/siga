import AppKit
import CoreAudio
import ServiceManagement
import OSLog

let systemAudio = AudioObjectID(kAudioObjectSystemObject)
func address(_ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}
struct AudioFailure: Error, CustomStringConvertible {
    let description: String, status: OSStatus?
    init(_ operation: String, _ status: OSStatus? = nil) {
        description = operation + (status.map { " (\($0))" } ?? "")
        self.status = status
    }
}
func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw AudioFailure(operation, status) }
}
func readNumber(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
    var a = address(selector), value: UInt32 = 0, size: UInt32 = 4
    try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value), "Read audio state")
    guard size == 4 else { throw AudioFailure("Invalid audio state size") }
    return value
}
// A client that has gone away answers kAudioHardwareBadObjectError. Only that status means
// "not there any more"; every other error is a real failure.
func ignoringGone<T>(_ read: () throws -> T) throws -> T? {
    do { return try read() }
    catch let failure as AudioFailure where failure.status == kAudioHardwareBadObjectError { return nil }
}
// Every client is read on every tick, so an error is seen whatever the order of the list.
func anyActive<Client>(_ clients: [Client], _ isActive: (Client) throws -> Bool) throws -> Bool {
    var active = false
    for client in clients where try ignoringGone({ try isActive(client) }) == true { active = true }
    return active
}
func audioClients() throws -> [AudioObjectID] {
    var a = address(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(systemAudio, &a, 0, nil, &size), "Size audio clients")
    var all = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    try check(AudioObjectGetPropertyData(systemAudio, &a, 0, nil, &size, &all), "List audio clients")
    return Array(all.prefix(Int(size) / 4))
}
// nil: the client went away, or its path cannot be read. Ownership is never guessed.
func executable(of client: AudioObjectID) throws -> String? {
    guard let pid = try ignoringGone({ try readNumber(client, kAudioProcessPropertyPID) }) else { return nil }
    var buffer = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid_t(bitPattern: pid), &buffer, 4096) > 0 ? String(cString: buffer) : nil
}
func isInput(_ client: AudioObjectID) throws -> Bool { try readNumber(client, kAudioProcessPropertyIsRunningInput) != 0 }

// The release uses fade B: smoothstep down in 400 ms and up in 850 ms.
struct Fade {
    let from: Float32, to: Float32, began: TimeInterval, duration: TimeInterval
    // A new target mid-fade starts a new segment from the current gain. Its length scales with
    // the distance left, so reversing after a quick tap neither snaps nor drags.
    init(from: Float32, to: Float32, fullSpan: Float32, now: TimeInterval) {
        self.from = from; self.to = to; began = now
        let full: TimeInterval = to < from ? 0.40 : 0.85
        duration = max(0.15, full * min(1, TimeInterval(abs(to - from) / max(fullSpan, 0.0001))))
    }
    // The last step returns the target itself, so restore verification compares exact values.
    func gain(at now: TimeInterval) -> (value: Float32, finished: Bool) {
        let p = from == to ? 1 : Float32(min(1, max(0, (now - began) / duration)))
        return (p >= 1 ? to : from + (to - from) * (p * p * (3 - 2 * p)), p >= 1)
    }
}

struct SavedVolume {
    struct Control { let element: UInt32; let startingValue: Float32 }
    let device: AudioDeviceID
    let uid: CFString
    let controls: [Control]

    static func scalar(_ element: UInt32) -> AudioObjectPropertyAddress {
        address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
    }
    static func writable(_ device: AudioDeviceID, _ element: UInt32) throws -> Bool {
        var a = scalar(element), value = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &a) else { return false }
        try check(AudioObjectIsPropertySettable(device, &a, &value), "Check output volume control")
        return value.boolValue
    }
    static func level(_ device: AudioDeviceID, _ element: UInt32) throws -> Float32 {
        var a = scalar(element), value: Float32 = 0, size: UInt32 = 4
        try check(AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value), "Read output channel \(element)")
        guard size == 4, value.isFinite, (0...1).contains(value) else {
            throw AudioFailure("Invalid output volume")
        }
        return value
    }
    static func capture() throws -> SavedVolume {
        let device = try readNumber(systemAudio, kAudioHardwarePropertyDefaultOutputDevice)
        guard device != 0 else { throw AudioFailure("No output device") }
        var a = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &a, 0, nil, &size, &uid), "Read output identity")
        guard let uid else { throw AudioFailure("No output identity") }
        let identity = uid.takeRetainedValue()
        // Support a writable main control or verified stereo channel controls.
        let elements: [UInt32] = try writable(device, 0) ? [0] : [1, 2]
        let controls = try elements.map { element -> Control in
            guard try (element == 0 || writable(device, element)) else { throw AudioFailure("Output volume is unsupported") }
            return Control(element: element, startingValue: try level(device, element))
        }
        return SavedVolume(device: device, uid: identity, controls: controls)
    }
    func resolve() throws -> AudioDeviceID {
        var a = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var identity = Unmanaged.passUnretained(uid)
        var device: AudioDeviceID = 0, size: UInt32 = 4
        try check(AudioObjectGetPropertyData(systemAudio, &a,
            UInt32(MemoryLayout<Unmanaged<CFString>>.size), &identity, &size, &device), "Find saved output")
        guard size == 4, device != 0 else { throw AudioFailure("Saved output is unavailable") }
        return device
    }
    func write(_ gain: Float32, to device: AudioDeviceID) throws {
        var failure: AudioFailure?
        for control in controls {
            var a = Self.scalar(control.element), value = control.startingValue * gain
            let result = AudioObjectSetPropertyData(device, &a, 0, nil, 4, &value)
            if result != noErr { failure = AudioFailure("Write output channel \(control.element)", result) }
        }
        if let failure { throw failure }
    }
    func isRestored(on device: AudioDeviceID) throws -> Bool {
        var restored = true
        for control in controls {
            // The baseline was itself read from hardware; allow only float roundoff.
            if abs(try Self.level(device, control.element) - control.startingValue) > 0.0001 { restored = false }
        }
        return restored
    }
}

struct AudioStatus: Equatable {
    let title: String, detail: String?, lowered: Bool, enabled: Bool, restorable: Bool
    var skipped = false
}

// All mutable audio state and Core Audio operations belong to this queue.
final class Ducking {
    let queue = DispatchQueue(label: "io.mostlyserious.siga.audio", qos: .userInitiated)
    let display: (AudioStatus) -> Void
    var enabled = true, awake = true, quitting = false
    // roots: real bundle paths of the chosen apps that are running, each ending in a slash.
    // clients: the audio clients whose executables live inside them; this is what gets polled.
    var roots: [String] = [], clients: [AudioObjectID] = []
    var poll: DispatchSourceTimer?, ramp: DispatchSourceTimer?, watcher: DispatchSourceTimer?
    var listeners: [AudioObjectPropertySelector] = []
    var saved: SavedVolume?
    var gain: Float32 = 1, target: Float32 = 1
    var duckGain: Float32
    var segment: Fade?
    var inputActive = false, suppressed = false, skipped = false, restoring = false
    var fault: String?
    var lastDisplay: AudioStatus?
    var restorations: [(Bool) -> Void] = []
    var operational: Bool { enabled && awake && !quitting }
    // Core Audio calls this on its own thread with addresses valid only during the call: copy what
    // changed, then decide on the audio queue. The same proc and client data go to Add and Remove,
    // so a removal matches its registration (a stored Swift closure is re-bridged on every call).
    static let listener: AudioObjectPropertyListenerProc = { _, count, changes, context in
        guard let context else { return noErr }
        let ducking = Unmanaged<Ducking>.fromOpaque(context).takeUnretainedValue()
        let selectors = (0..<Int(count)).map { changes[$0].mSelector }
        ducking.queue.async { ducking.lifecycleChanged(selectors) }
        return noErr
    }
    // The app holds this object for the life of the process, so an unretained pointer is stable.
    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    func lifecycleChanged(_ selectors: [AudioObjectPropertySelector]) {
        guard !quitting else { return }
        let restarted = selectors.contains(kAudioHardwarePropertyServiceRestarted)
        // A Core Audio reset drops client listeners; register again before deciding anything else.
        if restarted { removeListeners(); listen() }
        // A saved level still matters while paused or disabled; only its restore proceeds then.
        guard operational || saved != nil else { return }
        if restarted {
            reconfigure()
        } else {
            if selectors.contains(kAudioHardwarePropertyDefaultOutputDevice) { outputChanged() }
            if selectors.contains(kAudioHardwarePropertyProcessObjectList) { bind() }
        }
    }
    init(percent: Int, display: @escaping (AudioStatus) -> Void) {
        duckGain = Float32(min(100, max(0, percent))) / 100
        self.display = display
    }
    func setPercent(_ percent: Int) {
        duckGain = Float32(min(100, max(0, percent))) / 100
        readInput()
    }
    func show() {
        let title: String
        if fault != nil { title = saved == nil ? "Audio error" : "Couldn’t restore volume" }
        else if restoring { title = "Restoring volume" }
        else if !enabled { title = "Disabled" }
        else if !awake { title = "Sleeping" }
        else if suppressed && inputActive { title = skipped ? "Volume was already off, so Sigá left it alone" : "Restored · waiting for dictation to stop" }
        else if saved != nil { title = target == 1 ? "Restoring volume" : (ramp == nil ? "Volume lowered · \(Int((duckGain * 100).rounded()))%" : "Lowering volume") }
        else if clients.isEmpty { title = "Waiting for your dictation app" }
        else { title = "Ready" }
        let status = AudioStatus(title: title, detail: fault, lowered: saved != nil && gain < 1,
                                 enabled: enabled, restorable: saved != nil, skipped: skipped && inputActive)
        guard status != lastDisplay else { return }
        lastDisplay = status
        DispatchQueue.main.async { self.display(status) }
    }
    func stopPolling() { poll?.cancel(); poll = nil }
    func stopRamp() { ramp?.cancel(); ramp = nil }
    func removeListeners() {
        for selector in listeners {
            var a = address(selector)
            AudioObjectRemovePropertyListener(systemAudio, &a, Self.listener, context)
        }
        listeners.removeAll()
    }
    func reconfigure() {
        stopPolling()
        // Every lifecycle retry starts clean; a restore that fails again sets the fault back.
        // Listeners stay registered so the saved output can still recover its level later.
        clients = []; inputActive = false; fault = nil
        restore { success in
            if success && self.operational { self.start() }
        }
    }
    func listen() {
        guard listeners.isEmpty else { return }
        do {
            for selector in [kAudioHardwarePropertyProcessObjectList,
                             kAudioHardwarePropertyDefaultOutputDevice,
                             kAudioHardwarePropertyServiceRestarted] {
                var a = address(selector)
                try check(AudioObjectAddPropertyListener(systemAudio, &a, Self.listener, context), "Observe audio lifecycle")
                listeners.append(selector)
            }
        } catch { removeListeners(); fail(error) }
    }
    func start() {
        guard operational, fault == nil, !restoring else { show(); return }
        listen(); bind()
    }
    func setRoots(_ next: [String]) {
        guard next != roots else { return }
        roots = next
        // A chosen app launching or quitting is also the moment to retry after a fault.
        if fault == nil { bind() } else { reconfigure() }
    }
    // Called wherever the answer can change, never per poll tick. It only replaces the client list,
    // so a helper appearing or vanishing mid-dictation changes nothing the user can hear. The read
    // that follows ends the session when the last dictating app was just switched off or quit.
    func bind() {
        guard operational, fault == nil else { return }
        // Clients can change while a restore is in flight; look again once that restore has settled,
        // before any other completion reads a client that may have gone away.
        if restoring { restorations.insert({ success in if success { self.bind() } }, at: 0); return }
        do {
            clients = roots.isEmpty ? [] : try audioClients().filter { client in
                guard let path = try executable(of: client) else { return false }
                return roots.contains(where: path.hasPrefix)
            }
            // No chosen app is an audio client: no timer runs at all.
            if clients.isEmpty { stopPolling() } else { startPolling() }
            readInput()
        } catch { fail(error) }
    }
    func startPolling() {
        guard operational, fault == nil, !restoring, !clients.isEmpty, poll == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.readInput() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
        poll = timer
        timer.activate()
    }
    func readInput() {
        guard operational, fault == nil else { return }
        do {
            inputActive = try anyActive(clients, isInput)
            if !inputActive { suppressed = false; skipped = false }
            guard !restoring else { return }
            let lowering = inputActive && !suppressed && duckGain < 1
            let next: Float32 = lowering ? duckGain : 1
            if lowering && saved == nil {
                let captured = try SavedVolume.capture()
                // Already silent (another app muted the Mac): nothing to lower and nothing of Sigá's
                // to restore. The skip holds until dictation stops, whatever the volume does meanwhile.
                if captured.controls.allSatisfy({ $0.startingValue == 0 }) { suppressed = true; skipped = true }
                else { saved = captured; gain = 1 }
            }
            if saved != nil && next != target { fade(to: next) }
            show()
        } catch { fail(error) }
    }
    // "Use another app…" watches every audio client while its sheet is open. It only reads: each tick
    // reports the executables that have the microphone. A tick that cannot be read reports nothing.
    func watchAll(_ report: (([String]) -> Void)?) {
        watcher?.cancel(); watcher = nil
        guard let report else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler {
            var active: [String] = []
            do {
                for client in try audioClients() where try ignoringGone({ try isInput(client) }) == true {
                    if let path = try executable(of: client) { active.append(path) }
                }
            } catch { return }
            DispatchQueue.main.async { report(active) }
        }
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
        watcher = timer
        timer.activate()
    }
    func fade(to next: Float32) {
        target = next
        segment = Fade(from: gain, to: next, fullSpan: 1 - duckGain, now: ProcessInfo.processInfo.systemUptime)
        guard ramp == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self, let saved = self.saved, let segment = self.segment, !self.restoring else { return }
            let (gain, finished) = segment.gain(at: ProcessInfo.processInfo.systemUptime)
            self.gain = gain
            do {
                try saved.write(gain, to: saved.device)
                if finished {
                    if self.target == 1 {
                        self.restore(alreadyWrittenTo: saved.device) { _ in }
                    } else { self.stopRamp(); self.show() }
                }
            } catch { self.fail(error) }
        }
        timer.schedule(deadline: .now() + .nanoseconds(16_666_667),
                       repeating: .nanoseconds(16_666_667), leeway: .milliseconds(2))
        ramp = timer
        timer.activate()
    }
    func outputChanged() {
        guard let saved else {
            // Nothing needs restoring; a new output is the moment to try watching again.
            if fault != nil { fault = nil; start(); startPolling(); show() }
            return
        }
        if fault != nil {
            // The saved output is back: retry the pending restore, then resume only if still allowed.
            guard (try? saved.resolve()) != nil else { return }
            fault = nil
            restore { success in
                if success && self.operational { self.start(); self.startPolling() }
            }
            return
        }
        do {
            if try readNumber(systemAudio, kAudioHardwarePropertyDefaultOutputDevice) != saved.device {
                restore { success in if success { self.readInput() } }
            }
        } catch { fail(error) }
    }
    func fail(_ error: Error) {
        fault = String(describing: error)
        stopPolling()
        restore { _ in }
    }
    func restore(alreadyWrittenTo: AudioDeviceID? = nil, _ completion: @escaping (Bool) -> Void) {
        stopRamp(); target = 1
        restorations.append(completion)
        guard !restoring else { return }
        guard let saved else { finishRestore(true); return }
        restoring = true
        do {
            // Re-resolve the saved UID, never write old levels to the new default output.
            let device = try saved.resolve()
            // Skip only an endpoint write that succeeded for this same saved output.
            if device != alreadyWrittenTo {
                // Attempt every channel; a failed channel must not prevent restoring the others.
                try saved.write(1, to: device)
            }
            verifyRestore(saved, device: device, remaining: 10)
        } catch {
            fault = "Restore failed: \(error)"
            finishRestore(false)
        }
        show()
    }
    func verifyRestore(_ saved: SavedVolume, device: AudioDeviceID, remaining: Int) {
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
            do {
                // A reset/output change during readback must not validate a reused ID.
                guard try saved.resolve() == device else { throw AudioFailure("Saved output changed during restore") }
                if try saved.isRestored(on: device) { self.finishRestore(true) }
                else if remaining > 1 { self.verifyRestore(saved, device: device, remaining: remaining - 1) }
                else { throw AudioFailure("Saved volume did not restore") }
            } catch {
                self.fault = "Restore failed: \(error)"
                self.finishRestore(false)
            }
        }
    }
    func finishRestore(_ success: Bool) {
        if success { saved = nil; gain = 1 } else { stopPolling() }
        restoring = false
        let completions = restorations
        restorations.removeAll()
        for completion in completions { completion(success) }
        show()
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        reconfigure()
    }
    func manualRestore() {
        suppressed = true; fault = nil
        stopPolling()
        restore { success in
            if success { self.start(); self.startPolling() }
        }
    }
    func setAwake(_ value: Bool) { awake = value; reconfigure() }
    // One restoration attempt; the completion carries advice only when it failed.
    func terminate(_ completion: @escaping (String?) -> Void) {
        quitting = true
        stopPolling(); removeListeners()
        restore { success in
            guard !success else { completion(nil); return }
            let level = self.saved?.controls.first.map { Int(($0.startingValue * 100).rounded()) }
            completion(level.map { "Set it back to about \($0)% with your Mac’s volume controls." }
                       ?? "Use your Mac’s volume controls to set it back.")
        }
    }
}

// Two copies of Sigá would each save and restore the other's lowered volume. The lock lasts as
// long as the process, and anything but a clean acquire means this copy never touches audio.
enum EngineLock { case acquired, heldByAnother, unavailable }
func takeEngineLock() -> EngineLock {
    guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return .unavailable }
    let path = support.appendingPathComponent("io.mostlyserious.siga.lock").path
    if open(path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK, 0o600) >= 0 { return .acquired }
    return errno == EWOULDBLOCK ? .heldByAnother : .unavailable
}
// Where a running app really lives, ending in a slash so one app's folder is never a prefix of another's.
func bundleRoot(_ url: URL) -> String? {
    guard let real = realpath(url.path, nil) else { return nil }
    defer { free(real) }
    return String(cString: real) + "/"
}
func bundleID(at root: String) -> String? { Bundle(path: root)?.bundleIdentifier }

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    var status: NSStatusItem!
    var runningApps: NSKeyValueObservation?
    var info: NSMenuItem!
    var enableItem: NSMenuItem!
    let appsMenu = NSMenu()
    var loginItem: NSMenuItem!
    var welcome: Welcome?
    var audioStarted = false, restorable = false, poweringOff = false, terminating = false
    var startupError: String?
    var startupRequestedEnabled: Bool?
    private let startupLog = Logger(subsystem: "io.mostlyserious.siga", category: "startup")
    // Bundle ids only. During first-run setup the choice is a draft, saved when Sigá starts.
    lazy var chosen = UserDefaults.standard.object(forKey: "dictationApps") as? [String] ?? []
    var session = Session.none
    var discovery: Discovery?
    // A setup finished before apps could be chosen shows the choose screen once, keeping its volume.
    var setupComplete: Bool {
        UserDefaults.standard.bool(forKey: "hasFinishedSetup") && UserDefaults.standard.object(forKey: "dictationApps") != nil
    }
    var volumePercent: Int {
        let stored = UserDefaults.standard.object(forKey: "volumePercent") as? Int ?? 30
        return min(100, max(0, stored))
    }
    lazy var audio = Ducking(percent: volumePercent) { [weak self] state in
        guard let self else { return }
        self.info.title = state.title; self.info.toolTip = state.detail
        self.enableItem.state = state.enabled ? .on : .off
        self.restorable = state.restorable
        self.status.button?.toolTip = "Sigá · \(state.title)" + (state.detail.map { "\n\($0)" } ?? "")
        self.status.button?.appearsDisabled = state.lowered
        let before = self.session
        self.session.observe(lowered: state.lowered, skipped: state.skipped)
        if self.session != before { self.refreshSetup() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "pdf"), let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 14); image.isTemplate = true
            status.button?.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        info = NSMenuItem(title: "Waiting for your dictation app", action: nil, keyEquivalent: "")
        menu.addItem(info)
        enableItem = add("Enabled", #selector(toggleEnabled), to: menu)
        enableItem.state = .on
        add("Restore volume", #selector(restoreManually), to: menu)
        menu.addItem(.separator())
        let apps = NSMenuItem(title: "Dictation apps", action: nil, keyEquivalent: "")
        apps.submenu = appsMenu; menu.addItem(apps)
        add("Settings…", #selector(showSettings), to: menu)
        loginItem = add("Launch at login", #selector(toggleLogin), to: menu)
        add("Quit Sigá", #selector(quit), to: menu)
        status.menu = menu
        // An accessory app shows no menu bar, yet ⌘Q and ⌘W still dispatch through the main menu.
        let main = NSMenu(), application = NSMenu(), file = NSMenu(title: "File")
        application.addItem(withTitle: "Quit Sigá", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for submenu in [application, file] { let item = NSMenuItem(); item.submenu = submenu; main.addItem(item) }
        NSApp.mainMenu = main
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        notifications.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        notifications.addObserver(self, selector: #selector(powerOff), name: NSWorkspace.willPowerOffNotification, object: nil)
        // Background dictation apps do not send workspace launch/quit notifications.
        runningApps = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in self?.updateRoots() }
        if setupComplete { startAudioIfNeeded() }
        else {
            info.title = "Finish setting up Sigá"
            info.target = self; info.action = #selector(showSettings)
            enableItem.state = .off
            showSettings()
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(restoreManually) ? restorable : true
    }
    func startAudioIfNeeded() {
        guard setupComplete, !audioStarted else { return }
        audioStarted = true
        info.target = nil; info.action = nil
        let roots = runningRoots(), percent = volumePercent
        audio.queue.async {
            self.audio.setPercent(percent)
            self.audio.roots = roots
            self.audio.start()
            self.audio.show()
        }
    }
    func saveVolume(_ percent: Int) {
        let percent = min(100, max(0, percent))
        guard percent != volumePercent else { return }
        UserDefaults.standard.set(percent, forKey: "volumePercent")
        if audioStarted { audio.queue.async { self.audio.setPercent(percent) } }
    }
    @objc func showSettings() {
        if welcome == nil {
            welcome = Welcome(percent: volumePercent, firstRun: !setupComplete,
                onRefresh: { [weak self] in self?.refreshSetup() },
                onAction: { [weak self] action in self?.setupAction(action) },
                onVolume: { [weak self] percent in self?.saveVolume(percent) },
                onFinish: { [weak self] percent in self?.finishSetup(percent) }, onClose: { [weak self] in
                    // Closing leaves incomplete setup incomplete. No audio begins here.
                    self?.endDiscovery()
                    DispatchQueue.main.async { self?.welcome = nil }
                })
        }
        welcome?.present()
    }
    func finishSetup(_ percent: Int) {
        if setupComplete { saveVolume(percent); welcome?.close(); return }
        guard let controller = welcome else { return }
        controller.setFinishing(true)
        // Recheck at Start, without changing volume. Closing cancels completion.
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak controller] in
            let supported = (try? SavedVolume.capture()) != nil
            DispatchQueue.main.async {
                guard let self, let controller, self.welcome === controller,
                      controller.window?.isVisible == true else { return }
                controller.setFinishing(false)
                guard supported else {
                    controller.showAttention(); return
                }
                self.saveVolume(percent)
                UserDefaults.standard.set(self.chosen, forKey: "dictationApps")
                UserDefaults.standard.set(true, forKey: "hasFinishedSetup")
                self.session = .none
                self.startAudioIfNeeded()
                self.refreshSetup()
                controller.showComplete()
            }
        }
    }
    func startupState() -> StartupState {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .off
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    func dictationApps() -> [DictationApp] {
        dictationRows(chosen: chosen) { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }
    func refreshSetup() {
        guard let welcome else { return }
        reconcileStartupError()
        let sheet = discovery.map { AnotherAppSheet($0.phase, app: candidate()) }
        welcome.update(SetupSnapshot(apps: dictationApps(), startup: startupState(), startupError: startupError,
                                     session: session, anotherApp: sheet))
    }
    func setupAction(_ action: SetupAction) {
        switch action {
        case .choose(let id, let on): choose(id, on)
        case .useAnotherApp: useAnotherApp()
        case .tryAgain: discovery?.tryAgain(); refreshSetup()
        case .addApp:
            // Add is the only thing that saves; it exists only after a full start and stop was heard.
            if case .heard = discovery?.phase, let app = candidate() { choose(app.id, true) }
            endDiscovery()
        case .cancelAnotherApp: endDiscovery()
        case .soundSettings:
            if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!),
               let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
                NSWorkspace.shared.open(settings)
            }
        case .login(let enabled): setLogin(enabled)
        case .openLoginItems: SMAppService.openSystemSettingsLoginItems()
        }
    }
    func choose(_ id: String, _ on: Bool) {
        chosen.removeAll { $0 == id }
        if on { chosen.append(id) }
        if setupComplete { UserDefaults.standard.set(chosen, forKey: "dictationApps"); updateRoots() }
        refreshSetup()
    }
    @objc func toggleApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        choose(id, sender.state != .on)
    }
    // Only a chosen app that is running is ever watched, and by where it really is on disk.
    func runningRoots() -> [String] {
        var roots: [String] = []
        for id in chosen {
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == id && !app.isTerminated {
                if let root = app.bundleURL.flatMap(bundleRoot) { roots.append(root) }
            }
        }
        return roots
    }
    func updateRoots() {
        guard audioStarted else { return }
        let roots = runningRoots()
        audio.queue.async { self.audio.setRoots(roots) }
    }
    // Use another app…: watch every microphone user, read-only, until the sheet closes.
    @objc func useAnotherApp() {
        showSettings()
        discovery = Discovery(); refreshSetup()
        audio.queue.async {
            self.audio.watchAll { [weak self] executables in
                guard let self, let before = self.discovery else { return }
                self.discovery!.tick(active: executables.compactMap(owningApp).filter { bundleID(at: $0) != nil })
                if self.discovery!.phase != before.phase { self.refreshSetup() }
            }
        }
    }
    func candidate() -> DictationApp? {
        switch discovery?.phase {
        case .hearing(let root), .heard(let root): return bundleID(at: root).map { dictationApp(id: $0, path: root) }
        default: return nil
        }
    }
    func endDiscovery() {
        guard discovery != nil else { return }
        discovery = nil
        audio.queue.async { self.audio.watchAll(nil) }
        refreshSetup()
    }
    @discardableResult func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item)
        return item
    }
    func notice(_ message: String, _ detail: String) {
        let alert = NSAlert(); alert.messageText = message; alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    func loginState() -> NSControl.StateValue {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .mixed
        default: return .off
        }
    }
    // Any interaction after a power-off notice means that logout or shutdown was cancelled.
    func menuWillOpen(_ menu: NSMenu) {
        poweringOff = false; loginItem.state = loginState()
        appsMenu.removeAllItems()
        for app in dictationApps() {
            let item = add(app.name, #selector(toggleApp), to: appsMenu)
            item.representedObject = app.id; item.state = app.chosen ? .on : .off
            if app.chosen { item.toolTip = app.note.map { $0 + sigaHandlesIt } }
        }
        if !appsMenu.items.isEmpty { appsMenu.addItem(.separator()) }
        add("Use another app…", #selector(useAnotherApp), to: appsMenu)
    }
    func applicationDidBecomeActive(_ notification: Notification) { poweringOff = false }
    func reconcileStartupError() {
        guard startupError != nil else { startupRequestedEnabled = nil; return }
        let current = SMAppService.mainApp.status
        if (startupRequestedEnabled == true && current == .enabled) ||
           (startupRequestedEnabled == false && current == .notRegistered) {
            startupError = nil
            startupRequestedEnabled = nil
        }
    }
    @objc func toggleLogin() { setLogin(SMAppService.mainApp.status != .enabled) }
    func setLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        let previousStatus = service.status
        startupError = nil
        startupRequestedEnabled = nil
        do {
            switch (enabled, previousStatus) {
            case (true, .enabled), (false, .notRegistered), (false, .notFound): break
            case (true, .requiresApproval): SMAppService.openSystemSettingsLoginItems()
            // A failed status lookup does not rule out an explicit registration
            // attempt. The framework can return the actual reason it failed.
            case (true, _):
                startupRequestedEnabled = true
                try service.register()
            case (false, _):
                startupRequestedEnabled = false
                try service.unregister()
            }
        } catch {
            let failure = error as NSError
            startupLog.error("Launch at login failed: state=\(previousStatus.rawValue) domain=\(failure.domain, privacy: .public) code=\(failure.code)")
            startupError = "Couldn’t update Login Items. Try again."
        }
        reconcileStartupError()
        loginItem.state = loginState()
        refreshSetup()
        // First-run setup shows the note under its checkbox; otherwise say it once here.
        if startupError != nil, welcome == nil || setupComplete {
            notice("Couldn’t update launch at login.", "Try again from the Sigá menu.")
        }
    }
    @objc func toggleEnabled() {
        guard audioStarted else { showSettings(); return }
        audio.queue.async { self.audio.setEnabled(!self.audio.enabled) }
    }
    @objc func restoreManually() {
        guard audioStarted else { return }
        audio.queue.async { self.audio.manualRestore() }
    }
    @objc func sleep() {
        guard audioStarted else { return }
        audio.queue.async { self.audio.setAwake(false) }
    }
    @objc func wake() {
        refreshSetup()
        guard audioStarted else { return }
        let roots = runningRoots()
        audio.queue.async { self.audio.roots = roots; self.audio.setAwake(true) }
    }
    @objc func powerOff() { poweringOff = true }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard audioStarted, !terminating else { return .terminateNow }
        terminating = true
        // One bounded restoration attempt, then Sigá always finishes quitting.
        let done = DispatchSemaphore(value: 0)
        var advice: String?
        audio.queue.async { self.audio.terminate { note in advice = note; done.signal() } }
        let finished = done.wait(timeout: .now() + .seconds(3)) == .success
        let note = finished ? advice : "Sigá couldn’t confirm the restore in time. Check your Mac’s volume controls."
        // A timeout with nothing lowered is not a failed restore, so it passes silently.
        if let note, !poweringOff, finished || restorable { notice("Sigá couldn’t restore your volume.", note) }
        return .terminateNow
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let engineLock = takeEngineLock()
if engineLock != .acquired {
    app.finishLaunching()
    let alert = NSAlert()
    alert.messageText = engineLock == .heldByAnother ? "Sigá is already running." : "Sigá couldn’t start."
    app.activate(ignoringOtherApps: true); alert.runModal()
    exit(0)
}
let delegate = App()
app.delegate = delegate
app.run()
