// siga-probe: a read-only Core Audio observer for making a dictation app’s record (see CONTRIBUTING).
// It never opens the microphone, never writes a property, and needs no permission.
//
//   swift tests/probe.swift                 one snapshot of every audio client process
//   swift tests/probe.swift watch 120       watch for 120 s: logs every input start/stop, and for
//                                          each one whether a property LISTENER reported it and
//                                          whether it beat a 5 ms reference poll
//   swift tests/probe.swift watch 900 willow,superwhisper
//                                          same, but the reference poll reads only clients whose
//                                          bundle id or path contains one of those words (lighter
//                                          for long runs); listeners still cover every client
//
// Snapshot and watch modes also print the default output device's volume controls and mute switch, and "watch"
// logs every change to them. With Sigá not running, any change during dictation is the dictation
// app's own doing. Still read-only: nothing is written and no audio is captured.
//
// Run "player SECONDS" separately for read-only Music player state and sound volume.
// Run "watch", then dictate once in each app (Willow, Wispr Flow, superwhisper, Aqua, Apple
// Dictation…) and join one call (Zoom/Meet) so the log shows which process really holds the mic.
import CoreAudio
import Foundation

// Errors are explicit and repeated failures are counted, not mistaken for silence.
var failures: [String: Int] = [:]
var errorCount = 0
func checked(_ status: OSStatus, _ context: String) -> Bool {
    if status == noErr {
        if let count = failures.removeValue(forKey: context) {
            print("\(stamp()) READ RECOVERED \(context) after=\(count)")
        }
        return true
    }
    errorCount += 1
    failures[context, default: 0] += 1
    if failures[context] == 1 {
        print("\(stamp()) READ ERROR \(context) status=\(status)")
    }
    return false
}
let system = AudioObjectID(kAudioObjectSystemObject)
func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}
func processes() -> [AudioObjectID]? {
    var a = addr(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
    guard checked(AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size), "list size selector=\(a.mSelector)") else { return nil }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    guard checked(AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids), "list data selector=\(a.mSelector)") else { return nil }
    return Array(ids.prefix(Int(size) / 4))
}
func number(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32? {
    var a = addr(s), v: UInt32 = 0, size: UInt32 = 4
    return checked(AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v), "object=\(o) selector=\(s)") ? v : nil
}
func bundle(_ o: AudioObjectID) -> String {
    var a = addr(kAudioProcessPropertyBundleID), v: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard checked(AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v), "bundle object=\(o)"), let v else { return "READ_ERROR" }
    let s = v.takeRetainedValue() as String
    return s.isEmpty ? "(no bundle id)" : s
}
func executable(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, 4096) > 0 else {
        let status = errno == 0 ? EIO : errno
        _ = checked(OSStatus(status), "path pid=\(pid)")
        return "PATH_READ_ERROR(errno=\(status))"
    }
    _ = checked(noErr, "path pid=\(pid)")
    return String(cString: buffer)
}
func stamp() -> String {
    return "epoch=\(Date().timeIntervalSince1970) uptime=\(ProcessInfo.processInfo.systemUptime)"
}
func describe(_ o: AudioObjectID) -> String {
    let pid = pid_t(number(o, kAudioProcessPropertyPID) ?? 0)
    return "\(bundle(o)) pid=\(pid) \(executable(pid))"
}
func deviceName(_ d: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName), v: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard checked(AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v), "name device=\(d)"), let v else { return "device \(d) NAME_READ_ERROR" }
    return v.takeRetainedValue() as String
}
// Output side. "absent" means no control; "READ_ERROR" means a failed read; "*" means writable.
func outputLevels() -> String {
    guard let d = number(system, kAudioHardwarePropertyDefaultOutputDevice), d != 0 else { return "no output device" }
    func control(_ s: AudioObjectPropertySelector, _ element: UInt32) -> String {
        var a = AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(d, &a) else { return "absent" }
        var raw: UInt32 = 0, size: UInt32 = 4, writable: DarwinBoolean = false
        let context = "device=\(d) selector=\(s) element=\(element)"
        guard checked(AudioObjectGetPropertyData(d, &a, 0, nil, &size, &raw), context) else { return "READ_ERROR" }
        let known = checked(AudioObjectIsPropertySettable(d, &a, &writable), "settable \(context)")
        let text = s == kAudioDevicePropertyMute ? "\(raw)" : String(Double(Float32(bitPattern: raw)))
        return text + (known ? (writable.boolValue ? "*" : "") : "[SETTABLE_ERROR]")
    }
    let volume = (0...2).map { control(kAudioDevicePropertyVolumeScalar, $0) }.joined(separator: " ")
    let mute = (0...2).map { control(kAudioDevicePropertyMute, $0) }.joined(separator: " ")
    return "device=\(d) \(deviceName(d))  volume[main L R]=\(volume)  mute[main L R]=\(mute)"
}

// Run separately beside watch: probe player 120 > player.log. No Music launch,
// playback or volume writes. Read-only AppleScript is explicitly part of the test plan.
if CommandLine.arguments.dropFirst().first == "player" {
    let duration = Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "60") ?? 60
    let end = ProcessInfo.processInfo.systemUptime + duration
    var playerErrors = 0
    setvbuf(stdout, nil, _IOLBF, 0)
    repeat {
        let task = Process(), out = Pipe(), err = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "if application \"Music\" is running then", "-e", "tell application \"Music\" to return (player state as text) & \" volume=\" & (sound volume as text)", "-e", "else", "-e", "return \"not-running\"", "-e", "end if"]
        task.standardOutput = out; task.standardError = err
        do {
            try task.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if task.isRunning { playerErrors += 1; print("\(stamp()) PLAYER READ ERROR timeout"); task.terminate() }
            task.waitUntilExit()
            let value = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if task.terminationStatus != 0 { playerErrors += 1 }
            print("\(stamp()) PLAYER status=\(task.terminationStatus) \(value) \(error)")
        } catch { playerErrors += 1; print("\(stamp()) PLAYER READ ERROR \(error)") }
        Thread.sleep(forTimeInterval: 0.5)
    } while ProcessInfo.processInfo.systemUptime < end
    print("\(stamp()) PLAYER readErrors=\(playerErrors)")
    exit(playerErrors == 0 ? 0 : 2)
}
if CommandLine.arguments.count < 2 {
    print("output  \(outputLevels())")
    for d in inputDevices() {
        print("input device=\(d) \(deviceName(d)) running=\(number(d, kAudioDevicePropertyDeviceIsRunningSomewhere).map(String.init) ?? "READ_ERROR")")
    }
    print("object  in out  bundle id / pid / executable")
    for o in processes() ?? [] {
        let i = number(o, kAudioProcessPropertyIsRunningInput).map(String.init) ?? "READ_ERROR"
        let u = number(o, kAudioProcessPropertyIsRunningOutput).map(String.init) ?? "READ_ERROR"
        print("\(o) input=\(i) output=\(u) \(describe(o))")
    }
    exit(errorCount == 0 ? 0 : 2)
}

let seconds = Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "60") ?? 60
let words = (CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "").lowercased()
    .split(separator: ",").map(String.init)
var polled = Set<AudioObjectID>()
let queue = DispatchQueue(label: "probe")
var state: [AudioObjectID: UInt32] = [:]          // last value the reference poll saw
var listenerSaw: [AudioObjectID: (UInt32, Double)] = [:]
var watched = Set<AudioObjectID>()
var identities: [AudioObjectID: String] = [:]
var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
var callbacks = 0, listCallbacks = 0

func watch(_ o: AudioObjectID, event: String) {
    guard !watched.contains(o) else { return }
    watched.insert(o)
    var a = addr(kAudioProcessPropertyIsRunningInput)
    let callback: AudioObjectPropertyListenerBlock = { _, _ in
        guard watched.contains(o) else { return }
        callbacks += 1
        let now = ProcessInfo.processInfo.systemUptime
        guard let v = number(o, kAudioProcessPropertyIsRunningInput) else { return }
        listenerSaw[o] = (v, now)
        print("\(stamp())  LISTENER  input=\(v)  \(describe(o))")
    }
    let status = AudioObjectAddPropertyListenerBlock(o, &a, queue, callback)
    if checked(status, "listener registration object=\(o)") { listeners[o] = callback }
    state[o] = number(o, kAudioProcessPropertyIsRunningInput)
    identities[o] = describe(o)
    print("\(stamp()) \(event) object=\(o) input=\(state[o].map(String.init) ?? "READ_ERROR") \(identities[o]!)")
    let text = identities[o]!.lowercased()
    if words.isEmpty || words.contains(where: text.contains) { polled.insert(o) }
}
func reconcile(_ event: String) {
    guard let ids = processes() else { return } // A failed enumeration is not disappearance.
    let current = Set(ids)
    for o in watched.subtracting(current) {
        print("\(stamp()) DISAPPEARED object=\(o) lastInput=\(state[o].map(String.init) ?? "READ_ERROR") \(identities[o] ?? "unknown")")
        if let callback = listeners.removeValue(forKey: o) {
            var a = addr(kAudioProcessPropertyIsRunningInput)
            let result = AudioObjectRemovePropertyListenerBlock(o, &a, queue, callback)
            if result != noErr { print("\(stamp()) LISTENER REMOVE object=\(o) status=\(result)") }
        }
        watched.remove(o); polled.remove(o); state.removeValue(forKey: o)
        identities.removeValue(forKey: o); listenerSaw.removeValue(forKey: o)
    }
    for o in ids where !watched.contains(o) { watch(o, event: event) }
}
queue.sync { reconcile("INITIAL") }
var list = addr(kAudioHardwarePropertyProcessObjectList)
let listStatus = AudioObjectAddPropertyListenerBlock(system, &list, queue) { _, _ in
    listCallbacks += 1
    reconcile("NEW CLIENT")
}
queue.sync { _ = checked(listStatus, "client-list listener registration") }
// Device level: "some process is using this microphone". This is the signal mic-indicator apps use.
func inputDevices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices), size: UInt32 = 0
    guard checked(AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size), "device list size") else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    guard checked(AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids), "device list data") else { return [] }
    return ids.filter { d in
        var s = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain), n: UInt32 = 0
        return checked(AudioObjectGetPropertyDataSize(d, &s, 0, nil, &n), "input streams device=\(d)") && n > 0
    }
}
var deviceState: [AudioObjectID: UInt32] = [:]
var observedDevices = Set<AudioObjectID>()
var deviceListenerSaw: [AudioObjectID: (UInt32, Double)] = [:]
var deviceCallbacks = 0
var levels = "", tick = 0
queue.sync {
    for d in inputDevices() {
        observedDevices.insert(d)
        var a = addr(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let status = AudioObjectAddPropertyListenerBlock(d, &a, queue) { _, _ in
            deviceCallbacks += 1
            guard let v = number(d, kAudioDevicePropertyDeviceIsRunningSomewhere) else { return }
            deviceListenerSaw[d] = (v, ProcessInfo.processInfo.systemUptime)
            print("\(stamp())  DEVICE LISTENER  running=\(v)  \(deviceName(d))")
        }
        _ = checked(status, "device listener registration device=\(d)")
        deviceState[d] = number(d, kAudioDevicePropertyDeviceIsRunningSomewhere)
        print("\(stamp()) input device=\(d) \(deviceName(d)) running=\(deviceState[d].map(String.init) ?? "READ_ERROR")")
    }
}
let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now(), repeating: .milliseconds(5))
timer.setEventHandler {
    let now = ProcessInfo.processInfo.systemUptime
    tick += 1
    if tick % 50 == 0 { reconcile("NEW CLIENT") }
    if tick % 4 == 1, case let seen = outputLevels(), seen != levels {      // every 20 ms
        levels = seen
        print("\(stamp())  OUTPUT    \(seen)")
    }
    for d in observedDevices {
        guard let v = number(d, kAudioDevicePropertyDeviceIsRunningSomewhere), v != deviceState[d] else { continue }
        deviceState[d] = v
        let note: String
        if let (seen, at) = deviceListenerSaw[d], seen == v, now - at < 1 {
            note = String(format: "device listener was first by %.1f ms", (now - at) * 1000)
        } else { note = "device listener has NOT fired yet" }
        print("\(stamp())  DEVICE POLL      running=\(v)  \(deviceName(d))  [\(note)]")
    }
    for o in polled {
        guard let v = number(o, kAudioProcessPropertyIsRunningInput), v != state[o] else { continue }
        state[o] = v
        let note: String
        if let (seen, at) = listenerSaw[o], seen == v, now - at < 1 {
            note = String(format: "listener was first by %.1f ms", (now - at) * 1000)
        } else { note = "listener has NOT fired yet" }
        print("\(stamp())  POLL      input=\(v)  \(describe(o))  [\(note)]")
    }
}
timer.activate()
setvbuf(stdout, nil, _IOLBF, 0)
print("\(stamp())  listening to \(watched.count) audio clients, reference-polling \(polled.count) for \(Int(seconds)) s. Dictate now.")
queue.asyncAfter(deadline: .now() + seconds) {
    print("\(stamp())  done. input listener callbacks=\(callbacks), device listener callbacks=\(deviceCallbacks), client-list callbacks=\(listCallbacks)")
    print("\(stamp()) totalReadErrors=\(errorCount) unresolved=\(failures)")
    exit(errorCount == 0 ? 0 : 2)
}
dispatchMain()
