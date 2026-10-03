import CoreAudio
import Foundation

// Muffle: a private process tap carries other apps' playback into a private aggregate device on the
// same output, where the C IOProc in MuffleDSP.c low-passes and attenuates it.
//
// Every property and method here belongs to the supplied control queue, including listener events
// and completions. One worker serializes the HAL calls that can block, and only it touches a route's
// handles; control reaches the callback only through MuffleDSP atomics. Callback memory is freed only
// once its IOProc is gone, so a failed or blocked release leaks rather than frees. A deadline can
// notice a blocked HAL call, but nothing can cancel one.
final class MuffleSession {
    enum Phase { case starting, active, returning, cleaning, fault }
    private(set) var phase = Phase.starting
    // Why the run failed, or why release is failing. Never produced by the callback.
    private var cause: String?, cleanupProblem: String?
    var problem: String? { cleanupProblem ?? cause }
    // True only once every resource is released, whether or not the run failed. In `.fault`, release
    // failed and the live handles are kept; stop() retries.
    private(set) var finished = false
    // A failed start waits for an explicit retry or a new output; a device change may retry next dictation.
    private(set) var unavailable = false
    private var routeStarted = false, checkingFlow = false, suspectedStall = false
    var engaged: Bool { phase == .active || phase == .returning }
    var waitingForPlayback: Bool { phase == .starting && routeStarted }

    private let queue: DispatchQueue, changed: () -> Void
    private let worker = DispatchQueue(label: "io.mostlyserious.siga.muffle", qos: .userInitiated)
    private var route: Route?
    private var percent: Int
    private var deadline = TimeInterval.infinity, lastAdvance: TimeInterval = 0, lastCount: UInt32 = 0
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(queue: DispatchQueue, percent: Int, changed: @escaping () -> Void) {
        self.queue = queue; self.changed = changed
        self.percent = min(100, max(0, percent))
    }
    func start() {
        guard route == nil, !finished else { return }
        let observer: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.fail("Audio output changed") }
        guard let next = Route(queue: queue, observer: observer) else {
            cause = "Couldn’t allocate audio state"; unavailable = true; finished = true; return changed()
        }
        route = next; deadline = now + 15 // Includes a System Audio Recording prompt.
        MuffleDSPSetPercent(next.dsp, UInt32(percent))
        worker.async { [self] in
            let result = Result { try next.open() }
            queue.async { [self] in opened(result) }
        }
    }
    // Atomic, so it applies at any phase; activation and reversal always use the latest value.
    func setPercent(_ value: Int) {
        percent = min(100, max(0, value))
        if let route { MuffleDSPSetPercent(route.dsp, UInt32(percent)) }
    }
    // Disengaging during setup cancels it: nothing audible has changed yet.
    func setEngaged(_ value: Bool) {
        guard let route else { return }
        if phase == .starting, !value { return stop() }
        guard phase == (value ? Phase.returning : .active) else { return }
        phase = value ? .active : .returning
        MuffleDSPSetEngaged(route.dsp, value)
        changed()
    }
    func stop() {
        if route == nil, !finished { finished = true; return changed() } // Never started.
        release(nil)
    }
    func tick() {
        guard let route else { return }
        let time = now
        switch phase {
        case .starting:
            if MuffleDSPFault(route.dsp) {
                unavailable = true; release("Audio buffer layout changed")
            } else if routeStarted, MuffleDSPCallbacks(route.dsp) != 0 {
                phase = .active; lastAdvance = time; lastCount = MuffleDSPCallbacks(route.dsp)
                suspectedStall = false
                MuffleDSPSetEngaged(route.dsp, true); changed()
            } else if time > deadline {
                if routeStarted { checkFlow(route) }
                else { unavailable = true; release("Audio setup timed out") }
            }
        case .active, .returning:
            let count = MuffleDSPCallbacks(route.dsp)
            if count != lastCount { lastCount = count; lastAdvance = time; suspectedStall = false }
            if MuffleDSPFault(route.dsp) { release("Audio buffer layout changed") }
            else if phase == .returning, MuffleDSPDry(route.dsp) || time - lastAdvance > 1 { release(nil) }
            else if time - lastAdvance > 1 { checkFlow(route) }
        case .cleaning:
            // Reported once. The call stays in flight and its result is still authoritative.
            if time > deadline { deadline = .infinity; cleanupProblem = "macOS audio isn’t responding"; changed() }
        case .fault: break
        }
    }

    // Core Audio can stop callbacks when every playback source is paused. Only diagnose a stall
    // while another process is actually playing to this output. All HAL reads stay on the worker.
    private func checkFlow(_ route: Route) {
        if checkingFlow {
            if now > deadline { release("Playback check timed out") }
            return
        }
        checkingFlow = true; deadline = now + 2
        let count = MuffleDSPCallbacks(route.dsp)
        worker.async { [self] in
            let playing = try? route.hasPlayback()
            queue.async { [self] in
                checkingFlow = false
                guard self.route === route, phase == .starting || phase == .active else { return }
                if MuffleDSPCallbacks(route.dsp) != count { suspectedStall = false; return }
                // A source may have just resumed. Require a second positive check a second later.
                let stalled = playing == true && suspectedStall
                suspectedStall = playing == true
                lastAdvance = now; deadline = now + 1
                if stalled { unavailable = phase == .starting; release("Audio stopped flowing") }
            }
        }
    }

    private func fail(_ reason: String) {
        if phase == .starting || engaged { release(reason) }
    }
    private func opened(_ result: Result<Void, Error>) {
        // A cancelled run's late result changes nothing; its release is already queued behind it.
        guard phase == .starting, route != nil else { return }
        if case .failure(let error) = result { unavailable = true; return release("\(error)") }
        routeStarted = true; deadline = now + 1
        tick()
        if phase == .starting { changed() }
    }
    // The only path that schedules release, so at most one is in flight and each has one completion.
    // Cancellation is only a flag the worker checks between HAL calls.
    private func release(_ reason: String?) {
        guard let route, phase != .cleaning else { return }
        if let reason { cause = reason }
        cleanupProblem = nil
        phase = .cleaning; deadline = now + 2
        MuffleDSPCancel(route.dsp)
        MuffleDSPSetEngaged(route.dsp, false) // A callback surviving a blocked stop returns to passthrough.
        changed()
        worker.async { [self] in
            let failure = route.close()
            queue.async { [self] in released(failure) }
        }
    }
    private func released(_ failure: String?) {
        if let failure { phase = .fault; cleanupProblem = "Couldn’t release audio: \(failure)" }
        else { cleanupProblem = nil; route = nil; finished = true }
        deadline = .infinity
        changed()
    }

    // Handles belong to the worker: only open() and close() touch them, and never concurrently.
    private final class Route {
        let dsp: OpaquePointer
        private let queue: DispatchQueue, observer: OpaquePointer
        private let uid = "io.mostlyserious.siga.muffle.\(UUID().uuidString)"
        private var tap: AudioObjectID = 0, tapUID = "", aggregate: AudioObjectID = 0
        private var output: AudioObjectID = 0, process: AudioObjectID = 0
        private var proc: AudioDeviceIOProcID?, running = false
        private var listeners: [(id: AudioObjectID, selector: AudioObjectPropertySelector)] = []

        init?(queue: DispatchQueue, observer: @escaping AudioObjectPropertyListenerBlock) {
            guard let dsp = MuffleDSPCreate() else { return nil }
            guard let listener = MuffleListenerCreate(observer) else { MuffleDSPDestroy(dsp); return nil }
            self.dsp = dsp; self.queue = queue; self.observer = listener
        }
        // A live or unreleased IOProc may still read dsp; leaking it is the only safe choice.
        deinit { MuffleListenerDestroy(observer); if proc == nil { MuffleDSPDestroy(dsp) } }

        func open() throws {
            try boundary()
            output = try readNumber(systemAudio, kAudioHardwarePropertyDefaultOutputDevice)
            guard output != 0 else { throw AudioFailure("No audio output") }
            let outputUID = try Self.text(output, kAudioDevicePropertyDeviceUID)
            // A duplex device would add its own inputs to the aggregate, and their buffer order
            // is unmeasured. Reject it rather than guess.
            guard try Self.objects(output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty else {
                throw AudioFailure("Outputs with a microphone aren’t supported yet")
            }
            let streams = try Self.objects(output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            guard streams.count == 1 else { throw AudioFailure("Output needs exactly one stream") }
            let format = try Self.format(streams[0], kAudioStreamPropertyVirtualFormat)
            try observe(output, kAudioDevicePropertyDeviceIsAlive)
            try observe(output, kAudioDevicePropertyNominalSampleRate)
            try observe(streams[0], kAudioStreamPropertyVirtualFormat)
            try boundary()

            // Sigá's own route output must never feed back into its tap.
            var pid = getpid(), size: UInt32 = 4
            var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            try check(AudioObjectGetPropertyData(systemAudio, &a, UInt32(MemoryLayout<pid_t>.size), &pid,
                                                 &size, &process), "Find Sigá’s audio process")
            guard size == 4, process != 0 else { throw AudioFailure("Couldn’t exclude Sigá from the tap") }
            let description = CATapDescription(excludingProcesses: [process], deviceUID: outputUID, stream: 0)
            description.name = "Sigá Muffle"; description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            tapUID = description.uuid.uuidString // Ownership survives a failed UID read below.
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create playback tap")
            tapUID = try Self.text(tap, kAudioTapPropertyUID)
            guard try Self.same(Self.format(tap, kAudioTapPropertyFormat), format),
                  MuffleDSPConfigure(dsp, format.mSampleRate, format.mChannelsPerFrame) else {
                throw AudioFailure("Playback tap format differs from the output")
            }
            try boundary()

            let configuration: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Sigá Muffle",
                kAudioAggregateDeviceUIDKey: uid,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregate),
                      "Create private audio route")
            let ready = ProcessInfo.processInfo.systemUptime + 0.5
            while try readNumber(aggregate, kAudioDevicePropertyDeviceIsAlive) == 0 {
                try boundary()
                guard ProcessInfo.processInfo.systemUptime < ready else { throw AudioFailure("Private audio route isn’t ready") }
                Thread.sleep(forTimeInterval: 0.01)
            }
            // The output has no inputs, so the tap must be the aggregate's only input.
            for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
                let list = try Self.objects(aggregate, kAudioDevicePropertyStreams, scope: scope)
                guard list.count == 1, try Self.same(Self.format(list[0], kAudioStreamPropertyVirtualFormat), format) else {
                    throw AudioFailure("Private audio route has an unexpected layout")
                }
            }
            try boundary()
            let current = try readNumber(systemAudio, kAudioHardwarePropertyDefaultOutputDevice)
            guard try Self.text(current, kAudioDevicePropertyDeviceUID) == outputUID else {
                throw AudioFailure("Audio output changed")
            }
            try check(AudioDeviceCreateIOProcID(aggregate, MuffleRender, UnsafeMutableRawPointer(dsp), &proc),
                      "Create audio callback")
            guard proc != nil else { throw AudioFailure("Missing audio callback") }
            try boundary()
            running = true
            try check(AudioDeviceStart(aggregate, proc), "Start audio (check System Audio Recording permission)")
            try boundary()
        }
        // Attempts everything that can be released now. A handle is cleared only once it is
        // really gone, so a returned failure leaves the rest for an explicit retry.
        func close() -> String? {
            var failures: [String] = []
            listeners.removeAll { listener in
                var a = address(listener.selector)
                let status = MuffleListenerRemove(listener.id, &a, queue, observer)
                if status == noErr || status == kAudioHardwareBadObjectError { return true }
                failures.append(AudioFailure("Remove audio listener", status).description)
                return false
            }
            do {
                if aggregate != 0, try !Self.owns(aggregate, kAudioDevicePropertyDeviceUID, uid) {
                    // The server already removed our route and its callback. Never touch a reused ID.
                    aggregate = 0; proc = nil
                }
                if let proc {
                    if running { try check(AudioDeviceStop(aggregate, proc), "Stop audio callback"); running = false }
                    try check(AudioDeviceDestroyIOProcID(aggregate, proc), "Release audio callback")
                    self.proc = nil
                }
                if aggregate != 0 {
                    try check(AudioHardwareDestroyAggregateDevice(aggregate), "Release private audio route")
                    aggregate = 0
                }
                if tap != 0 {
                    if try Self.owns(tap, kAudioTapPropertyUID, tapUID) {
                        try check(AudioHardwareDestroyProcessTap(tap), "Release playback tap")
                    }
                    tap = 0
                }
            } catch { failures.append("\(error)") }
            return failures.isEmpty ? nil : failures.joined(separator: "; ")
        }

        private func boundary() throws {
            if MuffleDSPCancelled(dsp) { throw AudioFailure("Cancelled") }
        }
        func hasPlayback() throws -> Bool {
            for client in try Self.objects(systemAudio, kAudioHardwarePropertyProcessObjectList) where client != process {
                if try ignoringGone({
                    guard try readNumber(client, kAudioProcessPropertyIsRunningOutput) != 0 else { return false }
                    return try Self.objects(client, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput).contains(output)
                }) == true { return true }
            }
            return false
        }
        private func observe(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws {
            var a = address(selector)
            try check(MuffleListenerAdd(id, &a, queue, observer), "Observe audio output")
            listeners.append((id, selector))
        }
        private static func owns(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ uid: String) throws -> Bool {
            try ignoringGone { try text(id, selector) } == uid
        }
        private static func text(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
            var a = address(selector), value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value), "Read audio identity")
            guard let value else { throw AudioFailure("Missing audio identity") }
            let identity = value.takeRetainedValue() as String
            guard size == MemoryLayout<Unmanaged<CFString>?>.size else { throw AudioFailure("Invalid audio identity") }
            return identity
        }
        private static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
            var a = address(selector, scope: scope), size: UInt32 = 0
            try check(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "Read audio objects")
            guard size % 4 == 0 else { throw AudioFailure("Invalid audio object list") }
            if size == 0 { return [] }
            let capacity = size
            var list = [AudioObjectID](repeating: 0, count: Int(size) / 4)
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &list), "Read audio objects")
            guard size <= capacity, size % 4 == 0 else { throw AudioFailure("Audio objects changed") }
            return Array(list.prefix(Int(size) / 4))
        }
        // Mono or stereo packed native Float32, interleaved or planar, at 8–96 kHz. No resampling.
        private static func format(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> AudioStreamBasicDescription {
            var a = address(selector), f = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &f), "Read audio format")
            let planar = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            guard size == MemoryLayout<AudioStreamBasicDescription>.size, f.mFormatID == kAudioFormatLinearPCM,
                  f.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  f.mFormatFlags & kAudioFormatFlagIsPacked != 0,
                  f.mBitsPerChannel == 32, (1...2).contains(f.mChannelsPerFrame), f.mFramesPerPacket == 1,
                  f.mBytesPerFrame == 4 * (planar ? 1 : f.mChannelsPerFrame), f.mBytesPerPacket == f.mBytesPerFrame,
                  (8000...96000).contains(f.mSampleRate) else {
                throw AudioFailure("Output format isn’t supported")
            }
            return f
        }
        private static func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
            a.mSampleRate == b.mSampleRate && a.mChannelsPerFrame == b.mChannelsPerFrame
        }
    }
}
