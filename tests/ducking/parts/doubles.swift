// ===== Doubles: Core Audio types, constants and C-function stand-ins; Dispatch stand-ins =====
// Foundation only. Every name below shadows the SDK symbol the product code references, so the
// verbatim `Ducking`/`SavedVolume`/`readNumber` source compiles against in-memory state.
import Foundation

typealias AudioObjectID = UInt32
typealias AudioDeviceID = AudioObjectID
typealias AudioObjectPropertySelector = UInt32
typealias AudioObjectPropertyScope = UInt32
typealias AudioObjectPropertyElement = UInt32
struct AudioObjectPropertyAddress {
    var mSelector: AudioObjectPropertySelector
    var mScope: AudioObjectPropertyScope
    var mElement: AudioObjectPropertyElement
}
// In the SDK this is a C function pointer, and Remove matches on its address plus client data. A
// pointer to a Swift-defined struct cannot appear in a @convention(c) type, so the double keeps a
// Swift function type and matches on (selector, client data); Ducking passes one static proc.
typealias AudioObjectPropertyListenerProc = (AudioObjectID, UInt32, UnsafePointer<AudioObjectPropertyAddress>, UnsafeMutableRawPointer?) -> OSStatus

func fourcc(_ code: String) -> UInt32 { code.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
let kAudioObjectSystemObject = 1
let kAudioObjectPropertyScopeGlobal = fourcc("glob")
let kAudioObjectPropertyElementMain: AudioObjectPropertyElement = 0
let kAudioDevicePropertyScopeOutput = fourcc("outp")
let kAudioDevicePropertyVolumeScalar = fourcc("volm")
let kAudioDevicePropertyDeviceUID = fourcc("uid ")
let kAudioHardwarePropertyDefaultOutputDevice = fourcc("dOut")
let kAudioHardwarePropertyTranslateUIDToDevice = fourcc("uidd")
let kAudioHardwarePropertyProcessObjectList = fourcc("prs#")
let kAudioHardwarePropertyServiceRestarted = fourcc("srst")
let kAudioProcessPropertyIsRunningInput = fourcc("pinr")
let kAudioProcessPropertyPID = fourcc("ppid")
let kAudioHardwareBadObjectError = OSStatus(bitPattern: fourcc("!obj"))
let kAudioHardwareUnknownPropertyError = OSStatus(bitPattern: fourcc("who?"))
let kAudioHardwareBadPropertySizeError = OSStatus(bitPattern: fourcc("!siz"))
let kAudioHardwareIllegalOperationError = OSStatus(bitPattern: fourcc("nope"))

// --- Dispatch doubles: blocks are captured and drained explicitly; timers are recorded, never run.
struct FakeTime {
    static func now() -> FakeTime { FakeTime() }
    static func + (lhs: FakeTime, rhs: FakeInterval) -> FakeTime { lhs }
}
enum FakeInterval: Equatable { case milliseconds(Int), nanoseconds(Int), seconds(Int) }

final class DispatchQueue {
    enum QoS { case userInitiated }
    static let main = DispatchQueue(label: "main", qos: .userInitiated)
    let label: String
    var pending: [() -> Void] = []
    var delayed: [() -> Void] = []
    var asyncCount = 0, delayedCount = 0
    init(label: String, qos: QoS) { self.label = label }
    func async(execute work: @escaping () -> Void) { asyncCount += 1; pending.append(work) }
    func asyncAfter(deadline: FakeTime, execute work: @escaping () -> Void) { delayedCount += 1; delayed.append(work) }
    /// Runs captured `async` blocks in order (including ones they enqueue). Returns how many ran.
    @discardableResult func drain() -> Int {
        var ran = 0
        while !pending.isEmpty { pending.removeFirst()(); ran += 1 }
        return ran
    }
    /// Runs captured `asyncAfter` blocks in order, bounded by `limit` so an unbounded retry is detectable.
    @discardableResult func drainDelayed(limit: Int = 100) -> Int {
        var ran = 0
        while !delayed.isEmpty && ran < limit { delayed.removeFirst()(); ran += 1 }
        return ran
    }
    func reset() { pending = []; delayed = []; asyncCount = 0; delayedCount = 0 }
}

final class FakeTimer {
    static var created: [FakeTimer] = []
    let queue: DispatchQueue
    var handler: (() -> Void)?
    var scheduled = false, activated = false, cancelled = false
    var repeating: FakeInterval?
    init(queue: DispatchQueue) { self.queue = queue }
    func setEventHandler(handler: @escaping () -> Void) { self.handler = handler }
    func schedule(deadline: FakeTime, repeating: FakeInterval, leeway: FakeInterval) { scheduled = true; self.repeating = repeating }
    func activate() { activated = true }
    func cancel() { cancelled = true }
}
typealias DispatchSourceTimer = FakeTimer
enum DispatchSource {
    static func makeTimerSource(queue: DispatchQueue) -> FakeTimer {
        let timer = FakeTimer(queue: queue)
        FakeTimer.created.append(timer)
        return timer
    }
}

// --- In-memory audio hardware table.
enum FakeAudio {
    struct Write: Equatable { let device: AudioDeviceID, element: UInt32, value: Float32 }
    struct Read: Equatable { let object: AudioObjectID, selector: UInt32 }
    static var defaultOutput: AudioDeviceID = 0
    static var uids: [AudioDeviceID: String] = [:]
    static var devicesByUID: [String: AudioDeviceID] = [:]
    static var volumes: [AudioDeviceID: [UInt32: Float32]] = [:]
    static var settable: [AudioDeviceID: Set<UInt32>] = [:]
    static var processes: [pid_t: AudioObjectID] = [:]
    static var inputRunning: [AudioObjectID: Bool] = [:]
    /// Executable path per pid. A pid with no entry is Willow's own process, so `processes[77] = 7`
    /// keeps meaning "Willow is an audio client".
    static var paths: [pid_t: String] = [:]
    static var unreadablePaths: Set<pid_t> = []         // proc_pidpath answers nothing for these
    static var inputFailures: Set<AudioObjectID> = []   // IsRunningInput fails with a real error, not "gone"
    static var listFails = false
    static var writeFailures: Set<AudioDeviceID> = []
    static var writesApply = true
    static var addListenerStatus: OSStatus = 0
    static var addListenerFailures: Set<UInt32> = []   // review: fail registration for these selectors only
    static var writes: [Write] = []
    static var reads: [Read] = []
    static var resolves: [String] = []
    static var listenersAdded: [UInt32] = []
    static var listenersRemoved: [UInt32] = []          // removals that matched a live registration
    /// One live registration as the HAL holds it: selector plus the exact proc and client data.
    struct Registration: Equatable { let selector: UInt32; let context: UnsafeMutableRawPointer? }
    static var registered: [Registration] = []          // the HAL's current view of Sigá's subscriptions
    static var removeMisses: [UInt32] = []              // removals that matched nothing; cleared per scenario, not by reset()
    static func reset() {
        defaultOutput = 0; uids = [:]; devicesByUID = [:]; volumes = [:]; settable = [:]
        processes = [:]; inputRunning = [:]; paths = [:]; unreadablePaths = []; inputFailures = []; listFails = false; writeFailures = []; writesApply = true; addListenerStatus = 0; addListenerFailures = []
        writes = []; reads = []; resolves = []; listenersAdded = []; listenersRemoved = []; registered = []
    }
    static func addDevice(_ id: AudioDeviceID, uid: String, volume: Float32, element: UInt32 = 0) {
        uids[id] = uid; devicesByUID[uid] = id
        volumes[id, default: [:]][element] = volume
        settable[id, default: []].insert(element)
    }
    static func writesTo(_ device: AudioDeviceID) -> [Write] { writes.filter { $0.device == device } }
    static func reads(of selector: UInt32) -> [Read] { reads.filter { $0.selector == selector } }
}

func AudioObjectHasProperty(_ object: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>) -> Bool {
    let a = address.pointee
    guard a.mSelector == kAudioDevicePropertyVolumeScalar, a.mScope == kAudioDevicePropertyScopeOutput else { return false }
    return FakeAudio.volumes[object]?[a.mElement] != nil
}
func AudioObjectIsPropertySettable(_ object: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                   _ out: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus {
    let a = address.pointee
    guard a.mSelector == kAudioDevicePropertyVolumeScalar, a.mScope == kAudioDevicePropertyScopeOutput,
          FakeAudio.volumes[object]?[a.mElement] != nil else { return kAudioHardwareUnknownPropertyError }
    out.pointee = DarwinBoolean(FakeAudio.settable[object]?.contains(a.mElement) ?? false)
    return noErr
}
// Sizing is not evidence of anything a scenario asserts, so it is not recorded as a read.
func AudioObjectGetPropertyDataSize(_ object: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                    _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?,
                                    _ size: UnsafeMutablePointer<UInt32>) -> OSStatus {
    guard address.pointee.mSelector == kAudioHardwarePropertyProcessObjectList, object == systemAudio else { return kAudioHardwareUnknownPropertyError }
    if FakeAudio.listFails { return kAudioHardwareIllegalOperationError }
    size.pointee = UInt32(FakeAudio.processes.count * 4)
    return noErr
}
// Same signature as libproc's, so the verbatim product call resolves here.
func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer!, _ buffersize: UInt32) -> Int32 {
    guard !FakeAudio.unreadablePaths.contains(pid) else { return 0 }
    let path = (FakeAudio.paths[pid] ?? "/Applications/Willow.app/Contents/MacOS/Willow").utf8CString
    path.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: min($0.count, Int(buffersize))) }
    return Int32(path.count - 1)
}
func AudioObjectGetPropertyData(_ object: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?,
                                _ size: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutableRawPointer) -> OSStatus {
    let a = address.pointee
    FakeAudio.reads.append(.init(object: object, selector: a.mSelector))
    switch a.mSelector {
    case kAudioHardwarePropertyDefaultOutputDevice where object == systemAudio:
        guard size.pointee >= 4 else { return kAudioHardwareBadPropertySizeError }
        data.storeBytes(of: FakeAudio.defaultOutput, as: AudioDeviceID.self); size.pointee = 4
        return noErr
    case kAudioHardwarePropertyProcessObjectList where object == systemAudio:
        if FakeAudio.listFails { return kAudioHardwareIllegalOperationError }
        let all = FakeAudio.processes.values.sorted()
        guard Int(size.pointee) >= all.count * 4 else { return kAudioHardwareBadPropertySizeError }
        for (index, client) in all.enumerated() { data.storeBytes(of: client, toByteOffset: index * 4, as: AudioObjectID.self) }
        size.pointee = UInt32(all.count * 4)
        return noErr
    case kAudioProcessPropertyPID:
        guard let pid = FakeAudio.processes.first(where: { $0.value == object })?.key else { return kAudioHardwareBadObjectError }
        data.storeBytes(of: pid, as: pid_t.self); size.pointee = 4
        return noErr
    case kAudioHardwarePropertyTranslateUIDToDevice where object == systemAudio:
        guard let qualifier, qualifierSize == UInt32(MemoryLayout<Unmanaged<CFString>>.size) else { return kAudioHardwareBadPropertySizeError }
        let uid = Unmanaged<CFString>.fromOpaque(qualifier.load(as: UnsafeMutableRawPointer.self)).takeUnretainedValue() as String
        FakeAudio.resolves.append(uid)
        data.storeBytes(of: FakeAudio.devicesByUID[uid] ?? 0, as: AudioDeviceID.self); size.pointee = 4
        return noErr
    case kAudioDevicePropertyDeviceUID:
        guard let uid = FakeAudio.uids[object] else { return kAudioHardwareBadObjectError }
        // The product code takes a retained value; hand it one.
        data.storeBytes(of: Optional(Unmanaged.passRetained(uid as CFString).toOpaque()), as: UnsafeMutableRawPointer?.self)
        size.pointee = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
        return noErr
    case kAudioDevicePropertyVolumeScalar where a.mScope == kAudioDevicePropertyScopeOutput:
        guard let level = FakeAudio.volumes[object]?[a.mElement] else { return kAudioHardwareUnknownPropertyError }
        data.storeBytes(of: level, as: Float32.self); size.pointee = 4
        return noErr
    case kAudioProcessPropertyIsRunningInput:
        if FakeAudio.inputFailures.contains(object) { return kAudioHardwareIllegalOperationError }
        guard let running = FakeAudio.inputRunning[object] else { return kAudioHardwareBadObjectError }
        data.storeBytes(of: UInt32(running ? 1 : 0), as: UInt32.self); size.pointee = 4
        return noErr
    default:
        return kAudioHardwareUnknownPropertyError
    }
}
func AudioObjectSetPropertyData(_ object: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?,
                                _ size: UInt32, _ data: UnsafeRawPointer) -> OSStatus {
    let a = address.pointee
    guard a.mSelector == kAudioDevicePropertyVolumeScalar, a.mScope == kAudioDevicePropertyScopeOutput, size == 4 else {
        return kAudioHardwareUnknownPropertyError
    }
    let value = data.load(as: Float32.self)
    FakeAudio.writes.append(.init(device: object, element: a.mElement, value: value))   // record every attempt, even to stale ids
    if FakeAudio.writeFailures.contains(object) { return kAudioHardwareIllegalOperationError }
    guard FakeAudio.volumes[object]?[a.mElement] != nil else { return kAudioHardwareBadObjectError }
    if FakeAudio.writesApply { FakeAudio.volumes[object]![a.mElement] = value }
    return noErr
}
@discardableResult
func AudioObjectAddPropertyListener(_ object: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                    _ proc: @escaping AudioObjectPropertyListenerProc, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    let selector = address.pointee.mSelector
    FakeAudio.listenersAdded.append(selector)
    if FakeAudio.addListenerFailures.contains(selector) { return kAudioHardwareIllegalOperationError }
    if FakeAudio.addListenerStatus != noErr { return FakeAudio.addListenerStatus }
    FakeAudio.registered.append(.init(selector: selector, context: context))
    return noErr
}
@discardableResult
func AudioObjectRemovePropertyListener(_ object: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                       _ proc: @escaping AudioObjectPropertyListenerProc, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    let selector = address.pointee.mSelector
    let key = FakeAudio.Registration(selector: selector, context: context)
    // Like the HAL, only a registration made with the same proc and client data is removed.
    guard let index = FakeAudio.registered.firstIndex(of: key) else {
        FakeAudio.removeMisses.append(selector); return kAudioHardwareBadObjectError
    }
    FakeAudio.registered.remove(at: index)
    FakeAudio.listenersRemoved.append(selector)
    return noErr
}
