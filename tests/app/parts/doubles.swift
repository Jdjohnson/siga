// Foundation-only doubles for the Sigá `App` delegate harness.
//
// Nothing in this file touches AppKit, CoreAudio, ServiceManagement or OSLog. Types that
// main.swift reaches through those frameworks are re-declared here with the exact member
// surface the App class uses, so the App class text can be compiled verbatim. Types that
// Foundation already exports (UserDefaults, DispatchQueue, DispatchSemaphore) are shadowed
// by same-named declarations in this module; Swift resolves the local declaration first.
//
// Every double is deterministic: no threads, no timers, no real waiting. "Background" work
// is queued and only runs when the test drains a queue or when a semaphore wait pumps the
// non-main queues (which is what a blocked main thread would allow in the real app).
import Foundation

// MARK: - Harness bookkeeping (globals first: this file is compiled in script mode)
var passed = 0, failed = 0
var failures: [String] = []
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { passed += 1; print("PASS \(name)") } else { failed += 1; failures.append(name); print("FAIL \(name)") }
}
func observe(_ text: String) { print("OBSERVE \(text)") }
enum HarnessError: Error { case captureFailed, registerFailed, unregisterFailed }

// MARK: - Dispatch doubles (shadow Dispatch.DispatchQueue / Dispatch.DispatchSemaphore)
final class FakeQueue {
    static var background: [FakeQueue] = []
    let label: String, isMain: Bool
    var pending: [() -> Void] = []
    var executed = 0
    init(label: String, isMain: Bool = false) {
        self.label = label; self.isMain = isMain
        if !isMain { FakeQueue.background.append(self) }
    }
    func async(_ work: @escaping () -> Void) { pending.append(work) }
    func drain() { while !pending.isEmpty { pending.removeFirst()(); executed += 1 } }
    // What a blocked main thread would let happen: every other queue keeps running.
    static func runBackgroundUntilIdle() {
        var again = true
        while again {
            again = false
            for queue in background where !queue.pending.isEmpty { queue.drain(); again = true }
        }
    }
}
enum DispatchQueue {
    enum Quality { case userInitiated }
    static let main = FakeQueue(label: "main", isMain: true)
    static let worker = FakeQueue(label: "global.userInitiated")
    static func global(qos: Quality) -> FakeQueue { worker }
}
final class DispatchSemaphore {
    struct Wait { let requestedSeconds: Double; let result: DispatchTimeoutResult }
    static var waits: [Wait] = []
    static var created = 0
    private var count: Int
    init(value: Int) { count = value; DispatchSemaphore.created += 1 }
    func signal() { count += 1 }
    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        let requested = Double(timeout.uptimeNanoseconds &- DispatchTime.now().uptimeNanoseconds) / 1e9
        FakeQueue.runBackgroundUntilIdle()
        let result: DispatchTimeoutResult = count > 0 ? .success : .timedOut
        if result == .success { count -= 1 }
        DispatchSemaphore.waits.append(Wait(requestedSeconds: requested, result: result))
        return result
    }
}

// MARK: - Preferences (shadows Foundation.UserDefaults; nothing is written to disk)
final class UserDefaults {
    static var standard = UserDefaults()
    var values: [String: Any] = [:]
    var writes: [(key: String, value: Any?)] = []
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value; writes.append((key, value)) }
}

// MARK: - OSLog double
struct LogMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let value: String
    init(stringLiteral value: String) { self.value = value }
    init(stringInterpolation: StringInterpolation) { value = stringInterpolation.value }
    struct StringInterpolation: StringInterpolationProtocol {
        enum Privacy { case `public`, `private` }
        var value = ""
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ text: String) { value += text }
        mutating func appendInterpolation<T>(_ item: T) { value += String(describing: item) }
        mutating func appendInterpolation(_ item: String, privacy: Privacy) { value += item }
    }
}
struct Logger {
    static var messages: [String] = []
    init(subsystem: String, category: String) {}
    func error(_ message: LogMessage) { Logger.messages.append(message.value) }
}

// MARK: - AppKit doubles
protocol NSApplicationDelegate: AnyObject {}
protocol NSMenuDelegate: AnyObject {}
protocol NSMenuItemValidation: AnyObject {}
enum NSControl { enum StateValue: Equatable { case on, off, mixed } }
final class NSImage {
    var size = NSSize(width: 0, height: 0), isTemplate = false
    init?(contentsOf url: URL) { return nil }
}
final class NSMenuItem: NSObject {   // an NSObject so an action can take its sender
    var title: String, action: Selector?, keyEquivalent: String
    weak var target: AnyObject?
    var state = NSControl.StateValue.off
    var toolTip: String?
    var representedObject: Any?
    var submenu: NSMenu?
    let isSeparatorItem: Bool
    init(title: String, action: Selector?, keyEquivalent: String, separator: Bool = false) {
        self.title = title; self.action = action; self.keyEquivalent = keyEquivalent; isSeparatorItem = separator
    }
    convenience override init() { self.init(title: "", action: nil, keyEquivalent: "") }
    static func separator() -> NSMenuItem { NSMenuItem(title: "", action: nil, keyEquivalent: "", separator: true) }
}
final class NSMenu {
    let title: String
    weak var delegate: NSMenuDelegate?
    var items: [NSMenuItem] = []
    init(title: String = "") { self.title = title }
    func addItem(_ item: NSMenuItem) { items.append(item) }
    func removeAllItems() { items = [] }
    @discardableResult func addItem(withTitle title: String, action: Selector?, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent); items.append(item); return item
    }
}
final class NSStatusBarButton { var image: NSImage?; var toolTip: String?; var appearsDisabled = false }
final class NSStatusItem {
    static let variableLength: CGFloat = -1
    var button: NSStatusBarButton? = NSStatusBarButton()
    var menu: NSMenu?
}
final class NSStatusBar {
    static let system = NSStatusBar()
    var created = 0
    func statusItem(withLength length: CGFloat) -> NSStatusItem { created += 1; return NSStatusItem() }
}
final class NSWindow: NSObject {
    var isVisible = false
    @objc func performClose(_ sender: Any?) {}
}
final class NSApplication: NSObject {
    enum TerminateReply: Equatable { case terminateCancel, terminateNow, terminateLater }
    var mainMenu: NSMenu?
    var activations = 0, terminateRequests = 0
    func activate(ignoringOtherApps: Bool) { activations += 1 }
    @objc func terminate(_ sender: Any?) { terminateRequests += 1 }
    func reset() { mainMenu = nil; activations = 0; terminateRequests = 0 }
}
let NSApp = NSApplication()
final class NSAlert {
    static var shown: [NSAlert] = []
    // Review hook: runs while the alert is "on screen" (modal run loop spinning), before runModal returns.
    static var whileModal: (() -> Void)?
    var messageText = "", informativeText = ""
    var activationsWhenShown = 0
    @discardableResult func runModal() -> Int {
        activationsWhenShown = NSApp.activations; NSAlert.shown.append(self)
        let hook = NSAlert.whileModal; NSAlert.whileModal = nil; hook?()
        return 0
    }
}
final class NSRunningApplication: NSObject {
    static var running: [NSRunningApplication] = [] {
        didSet { NSWorkspace.shared.runningApplications = running }
    }
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    var bundleURL: URL?
    var isTerminated = false
    init(bundleIdentifier: String, pid: pid_t, at path: String? = nil) {
        self.bundleIdentifier = bundleIdentifier; processIdentifier = pid
        bundleURL = URL(fileURLWithPath: path ?? "/Applications/\(bundleIdentifier).app"); super.init()
    }
    static func runningApplications(withBundleIdentifier id: String) -> [NSRunningApplication] { running.filter { $0.bundleIdentifier == id } }
}
final class NSWorkspace: NSObject {
    @objc dynamic var runningApplications: [NSRunningApplication] = []
    static var shared = NSWorkspace()
    static let applicationUserInfoKey = "NSWorkspaceApplicationKey"
    static let willSleepNotification = Notification.Name("NSWorkspaceWillSleepNotification")
    static let didWakeNotification = Notification.Name("NSWorkspaceDidWakeNotification")
    static let willPowerOffNotification = Notification.Name("NSWorkspaceWillPowerOffNotification")
    static let didLaunchApplicationNotification = Notification.Name("NSWorkspaceDidLaunchApplicationNotification")
    static let didTerminateApplicationNotification = Notification.Name("NSWorkspaceDidTerminateApplicationNotification")
    let notificationCenter = NotificationCenter()   // real Foundation center, private to this double
    var installed: Set<String> = []
    var locations: [String: String] = [:]   // where an app is installed, when its folder is not named for its id
    var opened: [URL] = []
    var openSucceeds = true
    func urlForApplication(withBundleIdentifier id: String) -> URL? {
        installed.contains(id) ? URL(fileURLWithPath: locations[id] ?? "/Applications/\(id).app") : nil
    }
    @discardableResult func open(_ url: URL) -> Bool { opened.append(url); return openSucceeds }
}

// MARK: - ServiceManagement double
final class SMAppService {
    enum Status: Int { case notRegistered = 0, enabled = 1, requiresApproval = 2, notFound = 3 }
    static var mainApp = SMAppService()
    static var settingsOpened = 0
    static func openSystemSettingsLoginItems() { settingsOpened += 1 }
    var status = Status.notRegistered
    var registerError: Error?, unregisterError: Error?
    var registerOutcome = Status.enabled   // macOS may leave a fresh registration at .requiresApproval
    var registered = 0, unregistered = 0
    func register() throws { registered += 1; if let error = registerError { throw error }; status = registerOutcome }
    func unregister() throws { unregistered += 1; if let error = unregisterError { throw error }; status = .notRegistered }
}

// MARK: - Audio doubles (Ducking/SavedVolume in main.swift are Core Audio; the App uses only this surface)
struct SavedVolume {
    static var supported = true
    static var captures = 0
    static func capture() throws -> SavedVolume {
        captures += 1
        guard supported else { throw HarnessError.captureFailed }
        return SavedVolume()
    }
}
final class Ducking {
    enum TerminateBehavior { case immediate(String?), deferred(String?), never }
    static var created = 0
    let queue = FakeQueue(label: "io.mostlyserious.siga.audio")
    let display: (AudioStatus) -> Void
    let initialPercent: Int
    var enabled = true
    var roots: [String] = []
    var report: (([String]) -> Void)?
    var events: [String] = []
    var terminateBehavior = TerminateBehavior.immediate(nil)
    var terminateCalls = 0
    var pendingTerminations: [(String?) -> Void] = []
    init(percent: Int, display: @escaping (AudioStatus) -> Void) {
        initialPercent = percent; self.display = display; Ducking.created += 1
    }
    func setPercent(_ percent: Int) { events.append("percent:\(percent)") }
    func start() { events.append("start") }
    func show() { events.append("show") }
    func setRoots(_ next: [String]) { guard next != roots else { return }; roots = next; events.append("roots:\(next.joined(separator: ","))") }
    func watchAll(_ next: (([String]) -> Void)?) { report = next; events.append(next == nil ? "watchAll:off" : "watchAll:on") }
    func setEnabled(_ value: Bool) { enabled = value; events.append("enabled:\(value)") }
    func manualRestore() { events.append("manualRestore") }
    func setAwake(_ value: Bool) { events.append("awake:\(value)") }
    func terminate(_ completion: @escaping (String?) -> Void) {
        terminateCalls += 1; events.append("terminate")
        switch terminateBehavior {
        case .immediate(let advice): completion(advice)
        case .deferred(let advice): queue.async { completion(advice) }
        case .never: pendingTerminations.append(completion)
        }
    }
}

// The real ones resolve symlinks and read Info.plist; here a bundle is its path, and its id its folder name.
func bundleRoot(_ url: URL) -> String? { url.path + "/" }
var bundleIDs: [String: String] = [:]
func bundleID(at root: String) -> String? { bundleIDs[root] }

// MARK: - Welcome double (Welcome.swift is AppKit; the App uses only this surface)
// The product never compares these, so only the assertions here need them comparable.
extension SetupSnapshot: Equatable {}
extension SetupAction: Equatable {}
final class Welcome {
    let percent: Int, firstRun: Bool, initialStep: SetupStep?
    let onRefresh: () -> Void, onAction: (SetupAction) -> Void
    let onVolume: (Int) -> Void, onFinish: (Int) -> Void, onClose: () -> Void
    var window: NSWindow? = NSWindow()
    var finishingLog: [Bool] = []
    var snapshots: [SetupSnapshot] = []
    var attentionShown = 0, completeShown = 0, presented = 0, closed = 0
    init(percent: Int, firstRun: Bool, initialStep: SetupStep? = nil,
         onRefresh: @escaping () -> Void, onAction: @escaping (SetupAction) -> Void,
         onVolume: @escaping (Int) -> Void, onFinish: @escaping (Int) -> Void, onClose: @escaping () -> Void) {
        self.percent = percent; self.firstRun = firstRun; self.initialStep = initialStep
        self.onRefresh = onRefresh; self.onAction = onAction; self.onVolume = onVolume
        self.onFinish = onFinish; self.onClose = onClose
    }
    var finishing: Bool { finishingLog.last ?? false }
    func update(_ value: SetupSnapshot) { snapshots.append(value) }
    func setFinishing(_ value: Bool) { finishingLog.append(value) }
    func showAttention() { attentionShown += 1 }
    func showComplete() { if firstRun { completeShown += 1 } else { close() } }
    func present() { presented += 1; window?.isVisible = true }
    // NSWindowController.close() closes the window; windowWillClose then reports onClose synchronously.
    func close() { closed += 1; window?.isVisible = false; onClose() }
    // Stand-ins for what the real window does on user input.
    // Like the real window, whose controls are disabled while a check is pending.
    func pressStart(_ percent: Int) { if !finishing { onFinish(percent) } }
    func toggleLoginCheckbox(_ on: Bool) { onAction(.login(on)) }
    func windowBecameKey() { onRefresh() }
}
