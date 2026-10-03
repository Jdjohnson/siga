// ===== Doubles: simulated HAL, held queues, clock, DSP allocation count =====
// SDK types, constants and CATapDescription are the real ones, so each double keeps its native
// signature; only the listener functions' queue parameter is FakeQueue, matching the mapped source.
// No double reaches Core Audio: nothing here plays, captures or changes audio.
import CoreAudio
import Foundation

// Work waits until a test runs it. Not running the worker is how a blocked HAL call is simulated.
final class FakeQueue {
    static var made: [FakeQueue] = []
    let label: String
    private(set) var pending: [() -> Void] = []
    init(label: String, qos: DispatchQoS = .unspecified) { self.label = label; FakeQueue.made.append(self) }
    func async(execute work: @escaping () -> Void) { pending.append(work) }
    @discardableResult func drain() -> Int {
        var ran = 0
        while !pending.isEmpty { pending.removeFirst()(); ran += 1 }
        return ran
    }
}

enum FakeClock {
    static var now: TimeInterval = 1000
    static func sleep(forTimeInterval interval: TimeInterval) { now += interval }
}

// Counts the real MuffleDSP allocations, so a test can see callback state freed or kept.
enum FakeDSP {
    static var live = 0, failNext = false
    static func create() -> OpaquePointer? {
        if failNext { failNext = false; return nil }
        guard let dsp = MuffleDSPCreate() else { return nil }
        live += 1; return dsp
    }
    static func destroy(_ dsp: OpaquePointer) { live -= 1; MuffleDSPDestroy(dsp) }
}

// Keep the real C block token, while property changes stay within the simulated HAL.
enum FakeListeners {
    static var blocks: [OpaquePointer: AudioObjectPropertyListenerBlock] = [:]
}
func FakeMuffleListenerCreate(_ block: @escaping AudioObjectPropertyListenerBlock) -> OpaquePointer? {
    guard let listener = MuffleListenerCreate(block) else { return nil }
    FakeListeners.blocks[listener] = block
    return listener
}
func FakeMuffleListenerDestroy(_ listener: OpaquePointer) {
    FakeListeners.blocks.removeValue(forKey: listener)
    MuffleListenerDestroy(listener)
}
func FakeMuffleListenerAdd(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                           _ queue: FakeQueue, _ listener: OpaquePointer) -> OSStatus {
    FakeAudioObjectAddPropertyListenerBlock(id, address, queue, FakeListeners.blocks[listener]!)
}
func FakeMuffleListenerRemove(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                              _ queue: FakeQueue, _ listener: OpaquePointer) -> OSStatus {
    FakeAudioObjectRemovePropertyListenerBlock(id, address, queue, FakeListeners.blocks[listener]!)
}

// One output (100, stream 101), the route's tap (300) and aggregate (200, streams 201/202).
// A failed create still leaves its object behind, the harder case for cleanup.
final class FakeHAL {
    static let output: AudioObjectID = 100, outputStream: AudioObjectID = 101, otherOutput: AudioObjectID = 400
    static let aggregateID: AudioObjectID = 200, tapID: AudioObjectID = 300
    static let stereo = AudioStreamBasicDescription(
        mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    struct Listener {
        let id: AudioObjectID, selector: AudioObjectPropertySelector, queue: FakeQueue?, block: AudioObjectPropertyListenerBlock
    }
    var calls: [String] = [], violations: [String] = []
    var fails: [String: Int] = [:]          // call name -> matching calls let through before one fails
    var hooks: [String: () -> Void] = [:]   // runs once inside the named call, as if control ran then
    var defaultOutput = FakeHAL.output, ownProcess: AudioObjectID = 10, duplex = false
    var sourceRunning = true, sourceGone = false, sourceOutput = FakeHAL.output
    var outputFormat = FakeHAL.stereo, tapFormat = FakeHAL.stereo, aggregateFormat = FakeHAL.stereo
    var aggregateInputs: [AudioObjectID] = [201], aggregateAlive = true
    var tapUID: String?, aggregateUID: String?, aggregateForeign = false
    var proc: (callback: AudioDeviceIOProc, context: UnsafeMutableRawPointer?)?
    var running = false
    var listeners: [Listener] = []

    func fail(_ name: String, after skipped: Int = 0) { fails[name] = skipped }
    func misuse(_ what: String) { violations.append(what) }
    func status(_ name: String) -> OSStatus {
        calls.append(name)
        hooks.removeValue(forKey: name)?()
        guard let skip = fails[name] else { return noErr }
        if skip > 0 { fails[name] = skip - 1; return noErr }
        fails[name] = nil
        return kAudioHardwareIllegalOperationError
    }
    func ownsRoute(_ id: AudioObjectID) -> Bool { id == Self.aggregateID && aggregateUID != nil && !aggregateForeign }
    // What Sigá still holds in the HAL.
    var holds: Set<String> {
        var held = Set<String>()
        if !listeners.isEmpty { held.insert("listener") }
        if tapUID != nil { held.insert("tap") }
        if ownsRoute(Self.aggregateID) { held.insert("aggregate") }
        if proc != nil { held.insert("proc") }
        if running { held.insert("running") }
        return held
    }
    func uid(of id: AudioObjectID) -> String? {
        switch id {
        case Self.output: return "test-output"
        case Self.otherOutput: return "other-output"
        case Self.aggregateID: return aggregateUID
        default: return nil
        }
    }
    func streams(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioObjectID]? {
        let input = scope == kAudioObjectPropertyScopeInput
        switch id {
        case Self.output: return input ? (duplex ? [102] : []) : [Self.outputStream]
        case Self.aggregateID where aggregateUID != nil: return input ? aggregateInputs : [202]
        default: return nil
        }
    }
    func objects(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> [AudioObjectID]? {
        switch a.mSelector {
        case kAudioDevicePropertyStreams: return streams(id, a.mScope)
        case kAudioHardwarePropertyProcessObjectList where id == systemAudio: return [ownProcess, 11]
        case kAudioProcessPropertyDevices where id == 11 && !sourceGone:
            return a.mScope == kAudioObjectPropertyScopeOutput ? [sourceOutput] : []
        default: return nil
        }
    }
    // The server removed Sigá's route and callback; with `reused`, another client now has its ID.
    func serverRemovedRoute(reused: Bool) {
        proc = nil; running = false
        aggregateUID = reused ? "another-owner" : nil; aggregateForeign = reused
    }
    // Delivers a property change on the queue the listener registered with, as the HAL does.
    func deliver(_ listener: Listener) {
        listener.queue?.async { var a = address(listener.selector); listener.block(1, &a) }
    }
    func fire(_ selector: AudioObjectPropertySelector) {
        for listener in listeners where listener.selector == selector { deliver(listener) }
    }
    // One IOProc cycle over interleaved stereo synthetic buffers, through the real MuffleRender.
    @discardableResult func render(_ value: Float = 0.2, frames: Int = 256, malformed: Bool = false) -> [Float] {
        guard let proc, running else { misuse("rendered without a running IOProc"); return [] }
        let samples = frames * 2, bytes = UInt32(samples * MemoryLayout<Float>.size)
        let input = UnsafeMutablePointer<Float>.allocate(capacity: samples)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: samples)
        let stamp = UnsafeMutablePointer<AudioTimeStamp>.allocate(capacity: 1)
        let lists = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 2)
        defer { input.deallocate(); output.deallocate(); stamp.deallocate(); lists.deallocate() }
        input.initialize(repeating: value, count: samples)
        output.initialize(repeating: 9, count: samples)
        stamp.initialize(to: AudioTimeStamp())
        lists.initialize(to: AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: malformed ? 1 : 2, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(input))))
        (lists + 1).initialize(to: AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 2, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(output))))
        _ = proc.callback(Self.aggregateID, stamp, lists, stamp, lists + 1, stamp, proc.context)
        return Array(UnsafeBufferPointer(start: output, count: samples))
    }
}
var hal = FakeHAL()

func FakeAudioObjectGetPropertyDataSize(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                        _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?,
                                        _ size: UnsafeMutablePointer<UInt32>) -> OSStatus {
    let a = address.pointee
    let status = hal.status(a.mSelector == kAudioDevicePropertyStreams ? "read streams" : "read playback objects")
    guard status == noErr else { return status }
    guard let list = hal.objects(id, a) else { return kAudioHardwareBadObjectError }
    size.pointee = UInt32(list.count * 4)
    return noErr
}
func FakeAudioObjectGetPropertyData(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                    _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?,
                                    _ size: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutableRawPointer) -> OSStatus {
    let a = address.pointee
    func put<T>(_ value: T) -> OSStatus {
        guard Int(size.pointee) >= MemoryLayout<T>.size else { return kAudioHardwareBadPropertySizeError }
        data.storeBytes(of: value, as: T.self); size.pointee = UInt32(MemoryLayout<T>.size)
        return noErr
    }
    // The product takes a retained value; hand it one. A missing identity means the object is gone.
    func text(_ value: String?) -> OSStatus {
        guard let value else { return kAudioHardwareBadObjectError }
        return put(Unmanaged.passRetained(value as CFString))
    }
    let name: String
    switch a.mSelector {
    case kAudioHardwarePropertyDefaultOutputDevice: name = "read default output"
    case kAudioHardwarePropertyTranslatePIDToProcessObject: name = "read own process"
    case kAudioDevicePropertyDeviceUID: name = "read uid"
    case kAudioTapPropertyUID: name = "read tap uid"
    case kAudioDevicePropertyDeviceIsAlive: name = "read alive"
    case kAudioDevicePropertyStreams: name = "read streams"
    case kAudioHardwarePropertyProcessObjectList, kAudioProcessPropertyDevices: name = "read playback objects"
    case kAudioProcessPropertyIsRunningOutput: name = "read playback activity"
    case kAudioStreamPropertyVirtualFormat, kAudioTapPropertyFormat: name = "read format"
    default: return kAudioHardwareUnknownPropertyError
    }
    let status = hal.status(name)
    guard status == noErr else { return status }
    switch a.mSelector {
    case kAudioHardwarePropertyDefaultOutputDevice where id == systemAudio:
        return put(hal.defaultOutput)
    case kAudioHardwarePropertyTranslatePIDToProcessObject where id == systemAudio:
        guard qualifierSize == UInt32(MemoryLayout<pid_t>.size), qualifier?.load(as: pid_t.self) == getpid() else {
            hal.misuse("translated a PID other than Sigá’s own"); return kAudioHardwareIllegalOperationError
        }
        return put(hal.ownProcess)
    case kAudioDevicePropertyDeviceUID:
        return text(hal.uid(of: id))
    case kAudioTapPropertyUID where id == FakeHAL.tapID:
        return text(hal.tapUID)
    case kAudioDevicePropertyDeviceIsAlive where id == FakeHAL.output:
        return put(UInt32(1))
    case kAudioDevicePropertyDeviceIsAlive where id == FakeHAL.aggregateID && hal.aggregateUID != nil:
        return put(UInt32(hal.aggregateAlive ? 1 : 0))
    case kAudioProcessPropertyIsRunningOutput where id == hal.ownProcess:
        hal.misuse("counted Sigá’s own output as a playback source"); return put(UInt32(1))
    case kAudioProcessPropertyIsRunningOutput where id == 11 && !hal.sourceGone:
        return put(UInt32(hal.sourceRunning ? 1 : 0))
    case kAudioDevicePropertyStreams, kAudioHardwarePropertyProcessObjectList, kAudioProcessPropertyDevices:
        guard let list = hal.objects(id, a) else { return kAudioHardwareBadObjectError }
        guard Int(size.pointee) >= list.count * 4 else { return kAudioHardwareBadPropertySizeError }
        for (index, stream) in list.enumerated() { data.storeBytes(of: stream, toByteOffset: index * 4, as: AudioObjectID.self) }
        size.pointee = UInt32(list.count * 4)
        return noErr
    case kAudioStreamPropertyVirtualFormat where id == FakeHAL.outputStream:
        return put(hal.outputFormat)
    case kAudioStreamPropertyVirtualFormat where [201, 202, 203].contains(id) && hal.aggregateUID != nil:
        return put(hal.aggregateFormat)
    case kAudioTapPropertyFormat where id == FakeHAL.tapID && hal.tapUID != nil:
        return put(hal.tapFormat)
    default:
        return kAudioHardwareBadObjectError
    }
}
func FakeAudioObjectAddPropertyListenerBlock(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                             _ queue: FakeQueue?, _ block: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
    let status = hal.status("add listener")
    if status == noErr { hal.listeners.append(.init(id: id, selector: address.pointee.mSelector, queue: queue, block: block)) }
    return status
}
func FakeAudioObjectRemovePropertyListenerBlock(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                                _ queue: FakeQueue?, _ block: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
    let status = hal.status("remove listener")
    guard status == noErr else { return status }
    let selector = address.pointee.mSelector
    guard let index = hal.listeners.firstIndex(where: { $0.id == id && $0.selector == selector && $0.queue === queue }) else {
        hal.misuse("removed a listener that was never added"); return kAudioHardwareBadObjectError
    }
    hal.listeners.remove(at: index)
    return noErr
}
func FakeAudioHardwareCreateProcessTap(_ description: CATapDescription, _ id: UnsafeMutablePointer<AudioObjectID>) -> OSStatus {
    if hal.tapUID != nil { hal.misuse("created a second tap") }
    let excludesOnlySiga = description.isExclusive
        && (description.processes as NSArray).isEqual(to: [NSNumber(value: hal.ownProcess)])
    if !(excludesOnlySiga && description.isPrivate && description.muteBehavior == .mutedWhenTapped
         && description.deviceUID == "test-output") {
        hal.misuse("tap is not a private, muting tap of the output excluding only Sigá")
    }
    hal.tapUID = description.uuid.uuidString; id.pointee = FakeHAL.tapID
    return hal.status("create tap")
}
func FakeAudioHardwareDestroyProcessTap(_ id: AudioObjectID) -> OSStatus {
    guard id == FakeHAL.tapID, hal.tapUID != nil else { hal.misuse("destroyed a tap Sigá doesn’t own"); return kAudioHardwareBadObjectError }
    if hal.ownsRoute(FakeHAL.aggregateID) { hal.misuse("destroyed the tap under a live route") }
    let status = hal.status("destroy tap")
    if status == noErr { hal.tapUID = nil }
    return status
}
func FakeAudioHardwareCreateAggregateDevice(_ description: CFDictionary, _ id: UnsafeMutablePointer<AudioObjectID>) -> OSStatus {
    let configuration = description as NSDictionary
    let taps = configuration[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
    if hal.ownsRoute(FakeHAL.aggregateID) { hal.misuse("created a second route") }
    if (configuration[kAudioAggregateDeviceIsPrivateKey] as? Bool) != true || taps?.count != 1
        || (taps?.first?[kAudioSubTapUIDKey] as? String) != hal.tapUID {
        hal.misuse("route is not private over exactly this tap")
    }
    hal.aggregateUID = configuration[kAudioAggregateDeviceUIDKey] as? String ?? "missing"; hal.aggregateForeign = false
    id.pointee = FakeHAL.aggregateID
    return hal.status("create aggregate")
}
func FakeAudioHardwareDestroyAggregateDevice(_ id: AudioObjectID) -> OSStatus {
    guard hal.ownsRoute(id) else { hal.misuse("destroyed a route Sigá doesn’t own"); return kAudioHardwareBadObjectError }
    if hal.proc != nil { hal.misuse("destroyed the route before its callback"); return kAudioHardwareIllegalOperationError }
    let status = hal.status("destroy aggregate")
    if status == noErr { hal.aggregateUID = nil }
    return status
}
func FakeAudioDeviceCreateIOProcID(_ id: AudioObjectID, _ callback: AudioDeviceIOProc, _ context: UnsafeMutableRawPointer?,
                                   _ proc: UnsafeMutablePointer<AudioDeviceIOProcID?>) -> OSStatus {
    if !hal.ownsRoute(id) || hal.proc != nil { hal.misuse("created a callback outside a fresh route") }
    hal.proc = (callback, context); proc.pointee = callback
    return hal.status("create proc")
}
func FakeAudioDeviceDestroyIOProcID(_ id: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus {
    guard hal.ownsRoute(id), hal.proc != nil else { hal.misuse("destroyed a callback Sigá doesn’t own"); return kAudioHardwareBadObjectError }
    if hal.running { hal.misuse("destroyed a running callback"); return kAudioHardwareIllegalOperationError }
    let status = hal.status("destroy proc")
    if status == noErr { hal.proc = nil }
    return status
}
func FakeAudioDeviceStart(_ id: AudioObjectID, _ proc: AudioDeviceIOProcID?) -> OSStatus {
    guard hal.ownsRoute(id), hal.proc != nil, proc != nil else { hal.misuse("started something other than this route"); return kAudioHardwareBadObjectError }
    hal.running = true // A failed start may still have started; cleanup must stop it.
    return hal.status("start")
}
func FakeAudioDeviceStop(_ id: AudioObjectID, _ proc: AudioDeviceIOProcID?) -> OSStatus {
    guard hal.ownsRoute(id), hal.proc != nil else { hal.misuse("stopped a route Sigá doesn’t own"); return kAudioHardwareBadObjectError }
    let status = hal.status("stop")
    if status == noErr { hal.running = false }
    return status
}
