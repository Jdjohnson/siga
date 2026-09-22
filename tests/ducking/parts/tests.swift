// ===== Test scaffolding =====
var passed = 0, failed = 0
var failures: [String] = []
var notes: [String] = []
var current = ""
func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { passed += 1; print("PASS [\(current)] \(name)") }
    else { failed += 1; failures.append("[\(current)] \(name)"); print("FAIL [\(current)] \(name)") }
}
func note(_ text: String) { notes.append("[\(current)] \(text)"); print("NOTE [\(current)] \(text)") }
func scenario(_ name: String, _ body: () throws -> Void) {
    current = name
    FakeAudio.removeMisses = []
    do { try body() } catch { failed += 1; failures.append("[\(name)] threw \(error)"); print("FAIL [\(name)] threw \(error)") }
    // Invariant for every scenario: the product never asks the HAL to remove something it does not hold.
    if !FakeAudio.removeMisses.isEmpty {
        failed += 1; failures.append("[\(name)] listener removal matched no live registration: \(FakeAudio.removeMisses)")
        print("FAIL [\(name)] listener removal matched no live registration: \(FakeAudio.removeMisses)")
    }
}

final class Recorder { var displays: [AudioStatus] = [] }
typealias Write = FakeAudio.Write

/// Fresh Ducking against an empty hardware table. `display` is recorded after `DispatchQueue.main.drain()`.
func fresh(percent: Int = 30) -> (Ducking, Recorder) {
    FakeAudio.reset(); FakeTimer.created = []; DispatchQueue.main.reset()
    let recorder = Recorder()
    let ducking = Ducking(percent: percent) { recorder.displays.append($0) }
    return (ducking, recorder)
}
/// Drive the real `start()` → `bind()` path: Willow is chosen and running, and its pid 77 owns audio
/// client 7. Afterwards: three listeners registered, clients == [7], one active poll timer, no saved volume.
func startWatching(_ d: Ducking, _ r: Recorder? = nil, process: AudioObjectID = 7, pid: pid_t = 77) {
    FakeAudio.processes[pid] = process
    FakeAudio.inputRunning[process] = false
    d.roots = [willowRoot]
    d.start()
    precondition(d.clients == [process] && d.poll != nil && d.listeners.count == 3 && d.saved == nil, "startWatching precondition")
    precondition(FakeAudio.reads.map(\.selector) == [kAudioHardwarePropertyProcessObjectList, kAudioProcessPropertyPID, kAudioProcessPropertyIsRunningInput] && FakeAudio.writes.isEmpty && FakeAudio.resolves.isEmpty, "start() only listed the clients, matched one and read its input")
    FakeAudio.reads.removeAll()   // setup traffic is not part of any scenario's evidence
    DispatchQueue.main.drain(); r?.displays.removeAll()
}
/// A captured volume for device id `device` / UID `uid` whose baseline is `starting`.
/// `present` controls whether the UID currently resolves (device plugged in).
func makeSaved(device: AudioDeviceID = 10, uid: String = "UID-A", starting: Float32 = 0.62, present: Bool = true) -> SavedVolume {
    if present { FakeAudio.addDevice(device, uid: uid, volume: starting) }
    return SavedVolume(device: device, uid: uid as CFString, controls: [SavedVolume.Control(element: 0, startingValue: starting)])
}
/// Put the engine into the "lowered" state for `saved` (gain/target at `gain`, hardware at baseline × gain).
func lower(_ d: Ducking, _ saved: SavedVolume, gain: Float32 = 0.3) {
    d.saved = saved; d.gain = gain; d.target = gain
    for control in saved.controls where FakeAudio.volumes[saved.device] != nil {
        FakeAudio.volumes[saved.device]![control.element] = control.startingValue * gain
    }
}
/// Deliver a callback the way Core Audio would: only for selectors the HAL currently holds for this
/// instance's client data, through the real proc, then run the decision it queued.
func fire(_ d: Ducking, _ selectors: [AudioObjectPropertySelector]) {
    let live = selectors.filter { s in FakeAudio.registered.contains { $0.selector == s && $0.context == d.context } }
    guard !live.isEmpty else { return }
    fireLate(d, live)
}
/// Invoke the proc regardless of registration: a callback already in flight before removal.
func fireLate(_ d: Ducking, _ selectors: [AudioObjectPropertySelector]) {
    let changes = selectors.map { address($0) }
    changes.withUnsafeBufferPointer { _ = Ducking.listener(systemAudio, UInt32($0.count), $0.baseAddress!, d.context) }
    d.queue.drain()   // the proc only queues the decision; Ducking itself never uses queue.async
}
/// Registrations made so far, minus removals: the HAL's view of what Sigá is subscribed to.
func registrations() -> (added: Int, removed: Int) { (FakeAudio.listenersAdded.count, FakeAudio.listenersRemoved.count) }
func addSpeakers() { FakeAudio.addDevice(20, uid: "UID-B", volume: 0.5); FakeAudio.defaultOutput = 20 }

let willowRoot = "/Applications/Willow.app/"
let advice62 = "Set it back to about 62% with your Mac’s volume controls."
let adviceGeneric = "Use your Mac’s volume controls to set it back."

print("Ducking regression harness — main.swift SHA-256 \(mainSwiftSHA256), verbatim lines \(verbatimLines)")

// ===== (1) terminate() with no saved volume =====
scenario("1 terminate/no saved") {
    let (d, _) = fresh(); startWatching(d)
    let poll = d.poll!
    var completions: [String?] = []
    d.terminate { completions.append($0) }
    expect(completions.count == 1 && completions[0] == nil, "completion(nil) called exactly once, synchronously")
    expect(d.quitting, "quitting is true")
    expect(d.listeners.isEmpty && FakeAudio.listenersRemoved.count == 3 &&
           Set(FakeAudio.listenersRemoved) == Set(FakeAudio.listenersAdded), "all three lifecycle listeners removed")
    expect(d.poll == nil && poll.cancelled, "polling stopped (timer cancelled, poll nil)")
    d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(completions.count == 1, "no second completion after draining")
    expect(FakeAudio.writes.isEmpty && FakeAudio.resolves.isEmpty && d.restorations.isEmpty, "no restore traffic and no pending restorations")
}

// ===== (2) terminate() with saved and a successful restore =====
scenario("2 terminate/saved restores") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(); lower(d, saved)
    var completions: [String?] = []
    d.terminate { completions.append($0) }
    expect(completions.isEmpty && d.restoring, "completion deferred while readback verifies")
    expect(FakeAudio.writes == [Write(device: 10, element: 0, value: 0.62)], "writes the baseline (0.62) once to the saved device")
    let ran = d.queue.drainDelayed()
    expect(ran == 1, "one verify callback was enough (readback matched)")
    expect(completions == [nil], "completion(nil) exactly once")
    expect(d.saved == nil && !d.restoring && d.gain == 1, "saved cleared, gain reset, not restoring")
    expect(d.listeners.isEmpty && d.poll == nil && d.quitting, "listeners removed, polling stopped, quitting")
}

// ===== (3) terminate() with saved whose UID no longer resolves =====
scenario("3 terminate/saved device gone") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(present: false)   // UID-A unplugged; id 10 stale
    addSpeakers()                           // default output is now device 20
    lower(d, saved)
    var completions: [String?] = []
    d.terminate { completions.append($0) }
    expect(completions.count == 1, "exactly one completion")
    expect(completions.first! == advice62, "advice names the saved level as a rounded percent: \(completions.first!! )")
    expect(d.fault == "Restore failed: Saved output is unavailable", "fault remains (\(d.fault ?? "nil"))")
    expect(d.saved != nil && d.saved!.device == 10, "saved kept")
    expect(FakeAudio.resolves == ["UID-A"], "exactly one restore attempt (one UID resolve)")
    expect(FakeAudio.writes.isEmpty, "no writes to any device (not to 20, not to stale 10)")
    expect(!d.restoring && d.restorations.isEmpty, "not restoring; no pending completions")
    let ran = d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(ran == 0 && completions.count == 1 && FakeAudio.resolves.count == 1 && FakeAudio.writes.isEmpty, "nothing further after draining")
    // Rounding: 0.615 → 62 %, 0.4 → 40 %, generic advice when controls are somehow empty.
    let (e, _) = fresh()
    e.saved = SavedVolume(device: 10, uid: "UID-Z" as CFString, controls: [SavedVolume.Control(element: 0, startingValue: 0.404)])
    var second: [String?] = []
    e.terminate { second.append($0) }
    expect(second == ["Set it back to about 40% with your Mac’s volume controls."], "percent is rounded from startingValue (0.404 → 40%)")
}

// ===== (4) terminate() with saved, write succeeds, readback never matches =====
scenario("4 terminate/readback never matches") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(); lower(d, saved)
    FakeAudio.writesApply = false            // hardware ignores the write; readback stays at 0.186
    var completions: [String?] = []
    d.terminate { completions.append($0) }
    expect(FakeAudio.writes.count == 1 && d.restoring && completions.isEmpty, "one write, verify pending")
    let ran = d.queue.drainDelayed(limit: 100)
    expect(ran == 10, "bounded verification: exactly 10 readbacks (ran \(ran))")
    expect(d.queue.delayed.isEmpty, "no further verify callback scheduled")
    expect(completions.count == 1 && completions[0] == advice62, "completion carries advice once")
    expect(d.fault == "Restore failed: Saved volume did not restore", "fault explains readback failure (\(d.fault ?? "nil"))")
    expect(d.saved != nil && !d.restoring, "saved kept after failed verify")
    expect(FakeAudio.writes.count == 1, "verify loop only reads; no rewrite")
    expect(FakeAudio.reads(of: kAudioDevicePropertyVolumeScalar).count == 10, "ten readbacks of the volume scalar")
}

// ===== (5) terminate() while a restore is already in flight =====
scenario("5 terminate/restore in flight") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(); lower(d, saved)
    var first: [Bool] = []
    d.restore { first.append($0) }
    expect(d.restoring && d.queue.delayed.count == 1 && FakeAudio.writes.count == 1, "first restore in flight")
    var completions: [String?] = []
    d.terminate { completions.append($0) }
    expect(completions.isEmpty, "terminate joins the in-flight restore")
    expect(FakeAudio.resolves.count == 1 && FakeAudio.writes.count == 1 && d.queue.delayed.count == 1, "no second restore attempt started")
    expect(d.quitting && d.listeners.isEmpty && d.poll == nil, "quitting, listeners removed, polling stopped")
    let ran = d.queue.drainDelayed()
    expect(ran == 1 && first == [true] && completions == [nil], "exactly one terminate completion when the in-flight restore finishes")
    d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(completions.count == 1 && d.restorations.isEmpty, "still one completion; queue empty")
    // Same, but the in-flight restore fails at verify → the completion carries advice once.
    let (e, _) = fresh(); startWatching(e)
    let s2 = makeSaved(); lower(e, s2); FakeAudio.writesApply = false
    e.restore { _ in }
    var c2: [String?] = []
    e.terminate { c2.append($0) }
    let ran2 = e.queue.drainDelayed(limit: 100)
    expect(ran2 == 10 && c2 == [advice62] && e.saved != nil, "joined restore that fails delivers advice exactly once")
}

// ===== (6) outputChanged() with fault set and UID unresolvable =====
scenario("6 outputChanged/fault, device still gone") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)
    // A fault text a failed restore would not produce: proves outputChanged() left it alone.
    d.fault = "Read audio state (-1)"; d.stopPolling()
    d.outputChanged()
    expect(d.fault == "Read audio state (-1)", "fault intact")
    expect(d.saved != nil && d.saved!.device == 10 && d.saved!.controls[0].startingValue == 0.62, "saved intact")
    expect(FakeAudio.writes.isEmpty, "no writes")
    expect(FakeAudio.resolves == ["UID-A"] && !d.restoring && d.queue.delayed.isEmpty, "one probe resolve, no restore started")
    expect(d.poll == nil && FakeTimer.created.count == 1, "nothing resumed")
    d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(FakeAudio.writes.isEmpty && d.fault != nil && d.saved != nil, "still nothing after draining")
}

// ===== (7) outputChanged() with fault set and UID resolving again =====
scenario("7a outputChanged/fault, device back, operational") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)   // saved.device 10 is stale
    d.fault = "Restore failed: Saved output is unavailable"; d.stopPolling()
    FakeAudio.addDevice(11, uid: "UID-A", volume: 0.19)                        // same UID, re-enumerated as id 11
    let timersBefore = FakeTimer.created.count
    d.outputChanged()
    expect(d.fault == nil, "fault cleared")
    expect(d.restoring && d.queue.delayed.count == 1, "restore in flight")
    expect(FakeAudio.writes == [Write(device: 11, element: 0, value: 0.62)], "starting value written to the resolved id 11 only (not stale 10, not default 20)")
    expect(FakeAudio.writesTo(20).isEmpty && FakeAudio.writesTo(10).isEmpty, "no writes to the current default device or the stale id")
    let ran = d.queue.drainDelayed()
    expect(ran == 1 && d.saved == nil && !d.restoring, "saved cleared on success")
    expect(d.poll != nil && d.poll!.activated && !d.poll!.cancelled && FakeTimer.created.count == timersBefore + 1, "polling resumed (new poll timer activated)")
    expect(FakeAudio.listenersAdded.count == 3 && d.listeners.count == 3, "start() did not re-register listeners that were never removed")
    expect(FakeAudio.writes.count == 1, "still exactly one write")
    DispatchQueue.main.drain()
    expect(r.displays.last?.title == "Ready" && r.displays.last?.restorable == false, "status back to Ready")
}
scenario("7b outputChanged/fault, device back, enabled == false") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)
    d.fault = "Restore failed: Saved output is unavailable"; d.stopPolling(); d.enabled = false
    FakeAudio.addDevice(11, uid: "UID-A", volume: 0.19)
    let timersBefore = FakeTimer.created.count
    d.outputChanged()
    expect(d.fault == nil && d.restoring, "fault cleared, restore started even though disabled")
    expect(FakeAudio.writes == [Write(device: 11, element: 0, value: 0.62)], "restore still writes the baseline to the resolved device")
    let ran = d.queue.drainDelayed()
    expect(ran == 1 && d.saved == nil, "saved cleared on success")
    expect(d.poll == nil && FakeTimer.created.count == timersBefore, "no poll timer created (not operational)")
    expect(FakeAudio.listenersAdded.count == 3, "start() not invoked (no listener registration)")
    DispatchQueue.main.drain()
    expect(r.displays.last?.title == "Disabled" && r.displays.last?.enabled == false, "status shows Disabled, not Watching")
}
scenario("7c outputChanged/fault, device back, awake == false") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)
    d.fault = "Restore failed: Saved output is unavailable"; d.stopPolling(); d.awake = false
    FakeAudio.addDevice(11, uid: "UID-A", volume: 0.19)
    let timersBefore = FakeTimer.created.count
    d.outputChanged(); let ran = d.queue.drainDelayed()
    expect(ran == 1 && d.saved == nil && d.fault == nil, "restore succeeded while asleep")
    expect(d.poll == nil && FakeTimer.created.count == timersBefore, "nothing resumed while asleep")
    expect(FakeAudio.writes == [Write(device: 11, element: 0, value: 0.62)], "single write to the resolved device")
}
scenario("7d outputChanged/fault, device back but restore fails again") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)
    d.fault = "Restore failed: Saved output is unavailable"; d.stopPolling()
    FakeAudio.addDevice(11, uid: "UID-A", volume: 0.19); FakeAudio.writeFailures.insert(11)
    d.outputChanged()
    expect(d.fault == "Restore failed: Write output channel 0 (\(kAudioHardwareIllegalOperationError))", "write failure re-sets the fault (\(d.fault ?? "nil"))")
    expect(d.saved != nil && !d.restoring && d.poll == nil, "saved kept, no resume")
    expect(FakeAudio.writes.map(\.device) == [11], "one write attempt, only to the resolved device")
}

// ===== (8) outputChanged() with no fault and default device != saved.device =====
scenario("8 outputChanged/no fault, default moved") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(); lower(d, saved); addSpeakers()
    let inputReadsBefore = FakeAudio.reads(of: kAudioProcessPropertyIsRunningInput).count
    d.outputChanged()
    expect(FakeAudio.writes == [Write(device: 10, element: 0, value: 0.62)] && d.restoring, "restore started, baseline written to the saved device")
    expect(FakeAudio.writesTo(20).isEmpty, "nothing written to the new default device")
    let ran = d.queue.drainDelayed()
    expect(ran == 1 && d.saved == nil, "restore verified and saved cleared")
    expect(FakeAudio.reads(of: kAudioProcessPropertyIsRunningInput).count == inputReadsBefore + 1, "readInput() ran after the restore")
    expect(d.fault == nil, "no fault")
    // Default output unchanged → nothing happens.
    let (e, _) = fresh(); startWatching(e)
    let s2 = makeSaved(); lower(e, s2); FakeAudio.defaultOutput = 10
    e.outputChanged()
    expect(FakeAudio.resolves.isEmpty && FakeAudio.writes.isEmpty && !e.restoring && e.saved != nil, "same default device: no restore")
}

// ===== (9) the listener block =====
scenario("9 listener guard") {
    let (d, _) = fresh(); startWatching(d)
    d.enabled = false
    let saved = makeSaved(); lower(d, saved); addSpeakers()
    fire(d, [kAudioHardwarePropertyDefaultOutputDevice])
    expect(FakeAudio.reads(of: kAudioHardwarePropertyDefaultOutputDevice).count == 1, "disabled + saved: DefaultOutputDevice change reached outputChanged()")
    expect(FakeAudio.resolves == ["UID-A"] && FakeAudio.writes == [Write(device: 10, element: 0, value: 0.62)], "…and the restore ran")
    d.queue.drainDelayed()
    expect(d.saved == nil && !d.restoring, "restore completed; readInput() after it was a no-op while disabled")
    expect(FakeAudio.reads(of: kAudioProcessPropertyIsRunningInput).isEmpty, "no input read while disabled")
    // saved == nil and disabled → ignored entirely.
    let (e, _) = fresh(); startWatching(e)
    e.enabled = false; addSpeakers()
    fire(e, [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList])
    expect(FakeAudio.reads.isEmpty && FakeAudio.resolves.isEmpty && FakeAudio.writes.isEmpty, "disabled + no saved: change ignored (no reads at all)")
    // quitting with saved → dropped: terminate() owns the one bounded restore attempt.
    let (f, _) = fresh(); startWatching(f)
    f.quitting = true; let s3 = makeSaved(); lower(f, s3); addSpeakers()
    fireLate(f, [kAudioHardwarePropertyDefaultOutputDevice])
    expect(FakeAudio.writes.isEmpty && FakeAudio.resolves.isEmpty && f.saved != nil, "quitting + saved: the callback is dropped (no restore outside terminate)")
    // operational, no saved: DefaultOutputDevice change is a no-op inside outputChanged; ProcessObjectList binds.
    let (g, _) = fresh(); startWatching(g)
    fire(g, [kAudioHardwarePropertyDefaultOutputDevice])
    expect(FakeAudio.reads.isEmpty, "operational + no saved: outputChanged returns before reading")
    let processReads = FakeAudio.reads(of: kAudioHardwarePropertyProcessObjectList).count
    fire(g, [kAudioHardwarePropertyProcessObjectList])
    expect(FakeAudio.reads(of: kAudioHardwarePropertyProcessObjectList).count == processReads + 1, "ProcessObjectList change re-binds Willow's process")
}

// ===== (10) fail(error) =====
scenario("10a fail/device present") {
    let (d, _) = fresh(); startWatching(d)
    let poll = d.poll!
    let saved = makeSaved(); lower(d, saved)
    d.fail(AudioFailure("Read audio state", -1))
    expect(d.fault == "Read audio state (-1)", "fault set from the error")
    expect(d.poll == nil && poll.cancelled, "polling stopped")
    expect(d.saved != nil && d.restoring, "saved kept while the single restore is in flight")
    expect(FakeAudio.resolves == ["UID-A"] && FakeAudio.writes == [Write(device: 10, element: 0, value: 0.62)], "restores exactly once")
    let ran = d.queue.drainDelayed()
    expect(ran == 1 && d.saved == nil && d.fault == "Read audio state (-1)", "restore succeeded; fault persists until a lifecycle retry")
    expect(d.poll == nil && FakeTimer.created.count == 1, "polling not resumed by a successful restore inside fail()")
}
scenario("10b fail/device gone") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)
    d.fail(AudioFailure("Read audio state", -1))
    expect(d.saved != nil && d.saved!.controls[0].startingValue == 0.62, "saved kept")
    expect(d.fault != nil && d.poll == nil, "faulted, polling stopped")
    expect(FakeAudio.resolves.count == 1 && FakeAudio.writes.isEmpty, "one attempt, no writes")
    d.queue.drainDelayed()
    expect(d.saved != nil && !d.restoring && FakeAudio.resolves.count == 1, "no further attempt")
    note("fail() then restore failure replaces the original fault text: \(d.fault ?? "nil") (main.swift:272 then :292)")
}

// ===== (11) manualRestore() under fault =====
scenario("11a manualRestore/fault, device present") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(); lower(d, saved)
    d.fault = "Restore failed: Saved output is unavailable"; d.stopPolling()
    let timersBefore = FakeTimer.created.count
    d.manualRestore()
    expect(d.fault == nil && d.suppressed && d.restoring, "fault cleared, suppressed set, restore in flight")
    expect(FakeAudio.writes == [Write(device: 10, element: 0, value: 0.62)], "baseline written once")
    let ran = d.queue.drainDelayed()
    expect(ran == 1 && d.saved == nil && d.gain == 1, "restored and cleared")
    expect(d.poll != nil && d.poll!.activated && FakeTimer.created.count == timersBefore + 1, "polling resumed")
    DispatchQueue.main.drain()
    expect(r.displays.last?.title == "Ready", "status resumes (\(r.displays.last?.title ?? "nil"))")
}
scenario("11b manualRestore/fault, device gone") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)
    d.fault = "Restore failed: Saved output is unavailable"; d.stopPolling()
    d.manualRestore()
    expect(d.fault == "Restore failed: Saved output is unavailable" && d.saved != nil, "fault re-set, saved kept")
    expect(d.poll == nil && FakeAudio.writes.isEmpty && FakeAudio.resolves.count == 1, "no resume, no writes, one attempt")
}

// ===== (12) show() =====
scenario("12 show") {
    let (d, r) = fresh()
    d.fault = "Read audio state (-1)"
    d.show(); DispatchQueue.main.drain()
    var s = r.displays.last
    expect(s?.title == "Audio error" && s?.detail == "Read audio state (-1)", "fault + no saved → Audio error, detail == fault")
    expect(s?.restorable == false && s?.lowered == false && s?.enabled == true, "not restorable, not lowered")
    let saved = makeSaved(); lower(d, saved)   // gain 0.3
    d.show(); DispatchQueue.main.drain(); s = r.displays.last
    expect(s?.title == "Couldn’t restore volume" && s?.detail == "Read audio state (-1)", "fault + saved → Couldn’t restore volume, detail == fault")
    expect(s?.restorable == true && s?.lowered == true, "restorable and lowered (gain < 1)")
    d.gain = 1
    d.show(); DispatchQueue.main.drain(); s = r.displays.last
    expect(s?.restorable == true && s?.lowered == false, "gain == 1 → restorable but not lowered")
    let dispatched = DispatchQueue.main.asyncCount
    d.show(); d.show()
    expect(DispatchQueue.main.asyncCount == dispatched && DispatchQueue.main.pending.isEmpty, "identical status is not dispatched twice")
    expect(r.displays.count == 3, "three distinct statuses delivered")
    d.fault = nil; d.enabled = false
    d.show(); DispatchQueue.main.drain(); s = r.displays.last
    expect(s?.title == "Disabled" && s?.detail == nil && s?.restorable == true && s?.enabled == false, "no fault: detail nil, restorable follows saved")
    d.enabled = true; d.saved = nil
    d.show(); DispatchQueue.main.drain(); s = r.displays.last
    expect(s?.title == "Waiting for your dictation app" && s?.restorable == false, "no saved → not restorable")
}

// ===== (13) suppressed stays set after manualRestore =====
scenario("13 suppressed after manualRestore") {
    let (d, r) = fresh(percent: 30); startWatching(d, r)
    FakeAudio.addDevice(10, uid: "UID-A", volume: 0.62); FakeAudio.defaultOutput = 10
    FakeAudio.inputRunning[7] = true
    // Willow starts dictating: the real readInput() captures and starts a fade.
    d.readInput()
    expect(d.saved != nil && d.saved!.device == 10 && d.saved!.controls[0].startingValue == 0.62, "capture on first active read (via real SavedVolume.capture)")
    expect(d.ramp != nil && d.ramp!.activated && d.target == 0.3, "fade timer created and activated (not run)")
    let captureReads = FakeAudio.reads(of: kAudioDevicePropertyDeviceUID).count
    lower(d, d.saved!)   // stand in for the fade having completed
    d.manualRestore()
    expect(d.suppressed && d.ramp == nil, "manual restore suppresses and cancels the fade")
    d.queue.drainDelayed()
    expect(d.saved == nil && d.poll != nil, "restored; polling resumed")
    d.readInput()   // next poll tick, Willow still recording
    expect(d.suppressed && d.saved == nil && d.ramp == nil && FakeAudio.reads(of: kAudioDevicePropertyDeviceUID).count == captureReads, "input still active: no re-capture, no lowering")
    expect(FakeAudio.writesTo(10).count == 1, "the only write to the device was the restore")
    DispatchQueue.main.drain()
    expect(r.displays.last?.title == "Restored · waiting for dictation to stop", "status explains the suppression (\(r.displays.last?.title ?? "nil"))")
    FakeAudio.inputRunning[7] = false
    d.readInput()
    expect(!d.suppressed && d.saved == nil, "input inactive clears suppression")
    FakeAudio.inputRunning[7] = true
    d.readInput()
    expect(d.saved != nil && d.ramp != nil && d.target == 0.3 && FakeAudio.reads(of: kAudioDevicePropertyDeviceUID).count == captureReads + 1, "next activation captures again and lowers")
}

// ===== (14) restore() only writes to the device resolved from the saved UID =====
scenario("14 restore target device") {
    let (d, _) = fresh()
    let saved = makeSaved(present: false)                       // saved.device 10 is stale
    FakeAudio.addDevice(11, uid: "UID-A", volume: 0.1); addSpeakers()
    lower(d, saved)
    var results: [Bool] = []
    d.restore { results.append($0) }
    expect(FakeAudio.writes == [Write(device: 11, element: 0, value: 0.62)], "writes only to resolved id 11 (not saved.device 10, not default 20)")
    d.queue.drainDelayed()
    expect(results == [true] && d.saved == nil, "verified on the resolved device")
    // alreadyWrittenTo == resolved device → skip the write, still verify.
    let (e, _) = fresh(); let s2 = makeSaved(present: false); FakeAudio.addDevice(11, uid: "UID-A", volume: 0.62); lower(e, s2)
    FakeAudio.volumes[11]![0] = 0.62
    var r2: [Bool] = []
    e.restore(alreadyWrittenTo: 11) { r2.append($0) }
    expect(FakeAudio.writes.isEmpty && e.restoring, "endpoint write for the same resolved device is skipped")
    e.queue.drainDelayed()
    expect(r2 == [true] && e.saved == nil, "still verified by readback")
    // alreadyWrittenTo == stale saved.device while the UID resolves elsewhere → write to the resolved id.
    let (f, _) = fresh(); let s3 = makeSaved(present: false); FakeAudio.addDevice(11, uid: "UID-A", volume: 0.1); lower(f, s3)
    f.restore(alreadyWrittenTo: 10) { _ in }
    expect(FakeAudio.writes.map(\.device) == [11], "stale alreadyWrittenTo does not suppress the write to the resolved device")
    // Unresolvable → no write anywhere, completion(false), fault.
    let (g, _) = fresh(); let s4 = makeSaved(present: false); addSpeakers(); lower(g, s4)
    var r4: [Bool] = []
    g.restore { r4.append($0) }
    expect(FakeAudio.writes.isEmpty && r4 == [false] && g.fault == "Restore failed: Saved output is unavailable" && g.saved != nil, "unresolvable UID: no writes, completion(false), fault, saved kept")
    // Verify guards against the UID moving mid-readback.
    let (h, _) = fresh(); let s5 = makeSaved(); lower(h, s5)
    h.restore { _ in }
    FakeAudio.devicesByUID["UID-A"] = 12
    h.queue.drainDelayed()
    expect(h.fault == "Restore failed: Saved output changed during restore" && h.saved != nil, "UID re-resolving to another id during verify fails safely")
    expect(FakeAudio.writes.map(\.device) == [10], "no write to the new id 12")
}

// ===== (15) build-11 fixes: polling stops on a failed restore; listeners survive lifecycle retries =====
scenario("15a restore failure via outputChanged stops the poll") {
    let (d, _) = fresh(); startWatching(d)
    let poll = d.poll!
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)
    d.outputChanged()                       // default moved, saved UID gone → restore fails synchronously
    expect(d.fault == "Restore failed: Saved output is unavailable" && d.saved != nil, "fault set, saved kept")
    expect(d.poll == nil && poll.cancelled, "the 100 ms poll is cancelled once the restore fails")
    expect(d.listeners.count == 3, "listeners stay registered for the recovery")
    // Readback failure (asynchronous path) also stops the poll.
    let (e, _) = fresh(); startWatching(e)
    let poll2 = e.poll!
    let s2 = makeSaved(); lower(e, s2); addSpeakers(); FakeAudio.writesApply = false
    e.outputChanged(); e.queue.drainDelayed(limit: 100)
    expect(e.fault == "Restore failed: Saved volume did not restore" && e.poll == nil && poll2.cancelled, "verify failure also cancels the poll")
}
scenario("15b setEnabled(false) while faulted keeps the recovery listener; output change restores while paused") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)
    d.outputChanged()                       // device gone → fault, saved kept
    d.setEnabled(false)                     // reconfigure() no longer removes listeners
    expect(d.listeners.count == 3 && FakeAudio.listenersRemoved.isEmpty, "listeners kept through reconfigure()")
    expect(d.fault == "Restore failed: Saved output is unavailable" && d.saved != nil && d.poll == nil, "reconfigure's retry failed again: fault back, saved kept, no poll")
    expect(FakeAudio.resolves.count == 2 && FakeAudio.writes.isEmpty, "two bounded attempts so far, no writes anywhere")
    FakeAudio.addDevice(11, uid: "UID-A", volume: 0.19)
    let timersBefore = FakeTimer.created.count
    fire(d, [kAudioHardwarePropertyDefaultOutputDevice])   // the saved output is back while Disabled
    expect(d.fault == nil && d.restoring, "listener guard admits the change (saved != nil) and the restore runs")
    expect(FakeAudio.writes == [Write(device: 11, element: 0, value: 0.62)], "baseline written only to the re-resolved saved device")
    d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(d.saved == nil && d.gain == 1, "restored and cleared")
    expect(!d.enabled && d.poll == nil && FakeTimer.created.count == timersBefore, "still Disabled: no polling resumed")
    expect(r.displays.last?.title == "Disabled" && r.displays.last?.restorable == false, "menu shows Disabled with nothing to restore")
    FakeAudio.inputRunning[7] = true
    d.setEnabled(true)
    expect(d.enabled && d.clients == [7] && d.poll != nil && d.listeners.count == 3 && FakeAudio.listenersAdded.count == 3, "re-enable binds and polls without re-registering listeners")
}
scenario("15c setAwake(false) while faulted, device returns during sleep") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)
    d.outputChanged(); d.setAwake(false)
    expect(d.listeners.count == 3 && d.fault != nil && d.saved != nil, "asleep, faulted, saved kept, listeners kept")
    FakeAudio.addDevice(11, uid: "UID-A", volume: 0.19)
    fire(d, [kAudioHardwarePropertyDefaultOutputDevice]); d.queue.drainDelayed()
    expect(d.saved == nil && d.fault == nil && d.poll == nil, "restored while asleep; nothing resumed")
    expect(FakeAudio.writes == [Write(device: 11, element: 0, value: 0.62)], "one write, to the resolved device")
    FakeAudio.inputRunning[7] = false
    d.setAwake(true)
    expect(d.awake && d.poll != nil && d.clients == [7] && FakeAudio.listenersAdded.count == 3, "wake resumes watching with the original listeners")
}
scenario("15d a relaunched app rebinds without listener churn") {
    let (d, _) = fresh(); startWatching(d)
    FakeAudio.processes = [78: 8]; FakeAudio.inputRunning[8] = false
    fire(d, [kAudioHardwarePropertyProcessObjectList])
    expect(d.clients == [8] && d.poll != nil, "rebound to the new Willow process")
    expect(FakeAudio.listenersAdded.count == 3 && FakeAudio.listenersRemoved.isEmpty && d.listeners.count == 3, "no listener removal or re-registration")
    d.setRoots([])
    expect(d.clients.isEmpty && d.poll == nil && d.listeners.count == 3, "Willow gone: unbound, no poll, listeners kept")
}
scenario("15e ServiceRestarted while faulted with the device back") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)
    d.outputChanged()
    FakeAudio.addDevice(11, uid: "UID-A", volume: 0.19)
    fire(d, [kAudioHardwarePropertyServiceRestarted]); d.queue.drainDelayed()
    expect(d.fault == nil && d.saved == nil && FakeAudio.writes == [Write(device: 11, element: 0, value: 0.62)], "lifecycle retry restores to the resolved device")
    expect(d.clients == [7] && d.poll != nil && d.listeners.count == 3, "watching resumes")
    expect(FakeAudio.listenersRemoved.count == 3 && FakeAudio.listenersAdded.count == 6, "the reset dropped and re-registered all three listeners once")
}

// ===== (16) a fault raised before any level was saved clears on an output change =====
scenario("16a pre-save fault clears when the output changes (operational)") {
    let (d, r) = fresh(); startWatching(d, r)
    FakeAudio.inputRunning[7] = true; FakeAudio.defaultOutput = 30   // an output with no volume control
    d.readInput()                                                     // capture fails → fail()
    expect(d.fault != nil && d.saved == nil && d.poll == nil, "capture failure: fault, nothing saved, poll stopped (\(d.fault ?? "nil"))")
    DispatchQueue.main.drain()
    expect(r.displays.last?.title == "Audio error" && r.displays.last?.restorable == false, "menu shows Audio error")
    addSpeakers()                                                     // the user picks the speakers
    fire(d, [kAudioHardwarePropertyDefaultOutputDevice])
    expect(d.fault == nil, "fault cleared by the output change")
    expect(d.clients == [7] && d.poll != nil && d.poll!.activated && activePolls() == 1, "polling resumed on the same Willow process")
    expect(FakeAudio.listenersAdded.count == 3 && FakeAudio.writes.isEmpty && FakeAudio.resolves.isEmpty, "no listener re-registration, no writes, no restore")
    DispatchQueue.main.drain()
    expect(r.displays.last?.title != "Audio error" && r.displays.last?.detail == nil, "menu leaves Audio error (\(r.displays.last?.title ?? "nil"))")
    expect(d.saved != nil && d.saved!.device == 20 && d.ramp != nil, "the rebind reads at once: dictation now lowers the new output")
}
scenario("16b pre-save fault stays while paused; output change with no fault is inert") {
    let (d, _) = fresh(); startWatching(d)
    d.fail(AudioFailure("Read audio state", -1)); d.enabled = false
    fire(d, [kAudioHardwarePropertyDefaultOutputDevice])
    expect(d.fault == "Read audio state (-1)" && d.poll == nil, "disabled + no saved: the listener guard ignores the change")
    d.enabled = true
    let (e, _) = fresh(); startWatching(e)
    let timersBefore = FakeTimer.created.count
    e.outputChanged()
    expect(e.fault == nil && e.poll != nil && FakeTimer.created.count == timersBefore && FakeAudio.reads.isEmpty, "no fault + no saved: nothing happens")
}
scenario("16c pre-save fault with Willow gone: output change clears it without polling") {
    let (d, _) = fresh(); startWatching(d)
    d.fail(AudioFailure("Read audio state", -1)); d.clients = []; d.roots = []
    fire(d, [kAudioHardwarePropertyDefaultOutputDevice])
    expect(d.fault == nil && d.poll == nil && d.clients.isEmpty, "fault cleared, nothing to poll until Willow returns")
}


// ===== Review scenarios (build 11, changes A/B/C) =====
func activePolls() -> Int { FakeTimer.created.filter { $0.repeating == .milliseconds(100) && $0.activated && !$0.cancelled }.count }

scenario("R1 ServiceRestarted: listener re-establishment accounting") {
    let (d, _) = fresh(); startWatching(d)
    expect(FakeAudio.listenersAdded.count == 3 && FakeAudio.listenersRemoved.isEmpty, "three registrations at start")
    fire(d, [kAudioHardwarePropertyServiceRestarted]); d.queue.drainDelayed()
    expect(FakeAudio.listenersAdded.count == 6 && FakeAudio.listenersRemoved.count == 3 && d.listeners.count == 3, "restart: three removed, three re-added, three held (added=\(FakeAudio.listenersAdded.count) removed=\(FakeAudio.listenersRemoved.count))")
    expect(d.clients == [7] && activePolls() == 1, "watching resumed after the restart")
    let (e, _) = fresh(); startWatching(e); e.setEnabled(false)
    fire(e, [kAudioHardwarePropertyServiceRestarted])
    expect(FakeAudio.listenersAdded.count == 6 && FakeAudio.listenersRemoved.count == 3 && e.listeners.count == 3 && e.clients.isEmpty && activePolls() == 0, "disabled + nothing saved: listeners re-registered, then the restart is dropped by the guard")
    e.setEnabled(true)
    expect(e.clients == [7] && activePolls() == 1 && FakeAudio.listenersAdded.count == 6, "re-enable rebinds without re-registering")
}

scenario("R2 pre-save fault clears on output change while Willow's process object changed") {
    let (d, r) = fresh(); startWatching(d, r)
    FakeAudio.inputRunning[7] = true; FakeAudio.defaultOutput = 30
    d.readInput()
    expect(d.fault != nil && d.saved == nil && activePolls() == 0, "capture failure: faulted, poll stopped")
    FakeAudio.processes[77] = 8; FakeAudio.inputRunning[8] = false
    addSpeakers()
    fire(d, [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList])
    expect(d.fault == nil && d.clients == [8], "fault cleared and rebound to the new process object")
    expect(activePolls() == 1 && d.poll != nil, "exactly one active poll timer (activePolls=\(activePolls()))")
    expect(FakeAudio.listenersAdded.count == 3 && FakeAudio.writes.isEmpty && FakeAudio.resolves.isEmpty, "no listener churn, no writes, no restore")
    DispatchQueue.main.drain()
    expect(r.displays.last?.title == "Ready", "status Ready (\(r.displays.last?.title ?? "nil"))")
}

scenario("R3 fault raised during an in-flight restore, then the output change retries") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(); lower(d, saved); FakeAudio.defaultOutput = 10
    addSpeakers()
    d.outputChanged()
    expect(d.restoring && d.poll != nil && FakeAudio.writes == [Write(device: 10, element: 0, value: 0.62)], "restore in flight, poll still running")
    FakeAudio.inputFailures = [7]
    d.readInput()
    expect(d.fault == "Read audio state (\(kAudioHardwareIllegalOperationError))" && d.restoring && d.saved != nil && d.poll == nil, "fault while restoring; poll stopped; saved kept (\(d.fault ?? "nil"))")
    FakeAudio.inputFailures = []
    fire(d, [kAudioHardwarePropertyDefaultOutputDevice])
    expect(d.fault == nil && d.restoring && d.restorations.count == 3, "output change clears the fault and joins the in-flight restore (pending=\(d.restorations.count))")
    expect(FakeAudio.writes.count == 1, "no second write while the first restore verifies")
    let ran = d.queue.drainDelayed()
    expect(ran == 1 && d.saved == nil && !d.restoring && d.fault == nil, "restore verified once; saved cleared")
    expect(activePolls() == 1 && d.poll != nil && d.listeners.count == 3 && FakeAudio.listenersAdded.count == 3, "polling resumed exactly once on the retained listeners (activePolls=\(activePolls()))")
    expect(FakeAudio.writes.count == 1 && FakeAudio.writesTo(20).isEmpty, "still one write, nothing to the new default")
}

scenario("R4 partial listener registration failure, then lifecycle retry") {
    let (d, r) = fresh()
    FakeAudio.processes[77] = 7; FakeAudio.inputRunning[7] = false; d.roots = [willowRoot]
    FakeAudio.addListenerFailures = [kAudioHardwarePropertyDefaultOutputDevice]
    d.start()
    expect(d.fault == "Observe audio lifecycle (\(kAudioHardwareIllegalOperationError))" && d.listeners.isEmpty, "registration failure faults and empties the list (\(d.fault ?? "nil"))")
    expect(FakeAudio.listenersAdded == [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] && FakeAudio.listenersRemoved == [kAudioHardwarePropertyProcessObjectList], "only the successful registration is removed")
    expect(d.poll == nil && d.clients.isEmpty, "nothing bound, nothing polled")
    DispatchQueue.main.drain()
    expect(r.displays.last?.title == "Audio error", "menu shows Audio error")
    FakeAudio.addListenerFailures = []
    d.setEnabled(false); d.setEnabled(true)
    expect(d.fault == nil && d.listeners.count == 3 && FakeAudio.listenersAdded.count == 5 && d.clients == [7] && activePolls() == 1, "toggle retry registers all three exactly once and watches (added=\(FakeAudio.listenersAdded.count))")
    d.setRoots([])
    expect(FakeAudio.listenersAdded.count == 5 && d.listeners.count == 3 && d.clients.isEmpty && activePolls() == 0, "later retries never re-register")
}

scenario("R5 late HAL callbacks after terminate() never re-register or poll") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)
    var c: [String?] = []
    d.terminate { c.append($0) }
    expect(c == [advice62] && d.listeners.isEmpty && d.fault != nil && d.saved != nil, "terminate: one failed attempt, listeners removed")
    FakeAudio.addDevice(11, uid: "UID-A", volume: 0.19)
    let before = (FakeAudio.writes.count, FakeAudio.resolves.count)
    fireLate(d, [kAudioHardwarePropertyServiceRestarted]); d.queue.drainDelayed()
    expect(d.listeners.isEmpty && FakeAudio.listenersAdded.count == 3 && d.poll == nil && activePolls() == 0, "late ServiceRestarted after terminate: no listeners re-added, no poll")
    expect(FakeAudio.writes.count == before.0 && FakeAudio.resolves.count == before.1 && c.count == 1, "late ServiceRestarted after terminate: no second restore attempt, no second completion")
    note("after terminate + ServiceRestarted with the device back: saved nil=\(d.saved == nil), fault=\(d.fault ?? "nil"), writes=\(FakeAudio.writes.map { "\($0.device):\($0.value)" }), completions=\(c.count)")
    let (e, _) = fresh(); startWatching(e)
    let s2 = makeSaved(present: false); addSpeakers(); lower(e, s2)
    var c2: [String?] = []
    e.terminate { c2.append($0) }
    FakeAudio.addDevice(11, uid: "UID-A", volume: 0.19)
    let writes = FakeAudio.writes.count
    fireLate(e, [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList]); e.queue.drainDelayed()
    expect(e.listeners.isEmpty && FakeAudio.listenersAdded.count == 3 && e.poll == nil && activePolls() == 0 && c2.count == 1, "late DefaultOutputDevice after terminate: no listeners, no poll, one completion")
    expect(FakeAudio.writes.count == writes && e.saved != nil, "late DefaultOutputDevice after terminate: no restore attempt after the bounded one")
}

scenario("R6 Disabled + faulted saved: restart retries without resuming; output return restores; enable resumes") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)
    d.outputChanged(); d.setEnabled(false)
    expect(d.fault != nil && d.saved != nil && d.poll == nil && d.listeners.count == 3, "disabled, faulted, saved kept, listeners kept")
    fire(d, [kAudioHardwarePropertyServiceRestarted]); d.queue.drainDelayed()
    expect(d.fault == "Restore failed: Saved output is unavailable" && d.saved != nil && d.poll == nil && activePolls() == 0, "restart while disabled: bounded retry fails again, nothing resumes")
    expect(FakeAudio.listenersAdded.count == 6 && FakeAudio.listenersRemoved.count == 3 && d.listeners.count == 3 && FakeAudio.writes.isEmpty, "listeners re-registered once for the reset, no writes")
    FakeAudio.addDevice(11, uid: "UID-A", volume: 0.19)
    fire(d, [kAudioHardwarePropertyDefaultOutputDevice]); d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(d.saved == nil && d.fault == nil && d.poll == nil && activePolls() == 0 && !d.enabled, "restored while disabled; still not polling")
    expect(FakeAudio.writes == [Write(device: 11, element: 0, value: 0.62)], "one write to the re-resolved device")
    expect(r.displays.last?.title == "Disabled", "menu shows Disabled (\(r.displays.last?.title ?? "nil"))")
    d.setEnabled(true)
    expect(d.clients == [7] && activePolls() == 1 && FakeAudio.listenersAdded.count == 6, "enable resumes watching on the same listeners")
}

scenario("R7 single-poll invariant across transitions") {
    let (d, _) = fresh(); startWatching(d)
    func check(_ label: String) {
        let polls = activePolls()
        let ok = polls <= 1 && (d.poll == nil) == (polls == 0) && !(d.fault != nil && polls > 0) && !(!d.operational && polls > 0)
        expect(ok, "\(label): activePolls=\(polls) poll=\(d.poll != nil) fault=\(d.fault != nil) operational=\(d.operational)")
    }
    FakeAudio.addDevice(10, uid: "UID-A", volume: 0.62); FakeAudio.defaultOutput = 10; FakeAudio.inputRunning[7] = true
    d.readInput(); check("captured")
    lower(d, d.saved!)
    FakeAudio.defaultOutput = 30; FakeAudio.devicesByUID["UID-A"] = nil
    d.outputChanged(); check("restore failed on output move")
    d.setEnabled(false); check("disabled")
    d.setEnabled(true); check("re-enabled, still faulted")
    FakeAudio.addDevice(11, uid: "UID-A", volume: 0.19)
    fire(d, [kAudioHardwarePropertyDefaultOutputDevice]); check("device back, restoring")
    d.queue.drainDelayed(); check("restored, watching")
    d.manualRestore(); check("manual restore with nothing saved")
    d.setAwake(false); check("asleep"); d.setAwake(true); check("awake")
    fire(d, [kAudioHardwarePropertyServiceRestarted]); d.queue.drainDelayed(); check("after restart")
    fire(d, [kAudioHardwarePropertyProcessObjectList]); check("after process list change")
    d.setRoots([]); check("willow gone"); d.setRoots([willowRoot]); check("willow back")
    expect(d.listeners.count == 3 && FakeAudio.listenersAdded.count == 6 && FakeAudio.listenersRemoved.count == 3, "listeners registered once at start and once more for the one reset, never otherwise")
}

scenario("R8 fade-up restore that fails verification stops the poll; manual restore resumes it") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(); lower(d, saved); FakeAudio.defaultOutput = 10
    d.gain = 1; d.target = 0.3
    d.fade(to: 1)
    expect(d.ramp != nil, "ramp created")
    d.ramp!.handler!()
    expect(d.restoring && FakeAudio.writes == [Write(device: 10, element: 0, value: 0.62)], "endpoint write, verify pending")
    FakeAudio.volumes[10]![0] = 0.5
    let ran = d.queue.drainDelayed(limit: 100)
    expect(ran == 10 && d.fault == "Restore failed: Saved volume did not restore" && d.saved != nil, "bounded verify fails (\(d.fault ?? "nil"))")
    expect(d.poll == nil && activePolls() == 0, "B: poll stopped on the failed restore")
    DispatchQueue.main.drain()
    expect(r.displays.last?.title == "Couldn’t restore volume" && r.displays.last?.restorable == true, "menu offers Restore volume")
    FakeAudio.volumes[10]![0] = 0.3
    d.manualRestore(); d.queue.drainDelayed()
    expect(d.saved == nil && d.fault == nil && activePolls() == 1, "manual restore succeeds and polling resumes")
}

scenario("R9 pre-save fault clears on output change after Willow died unnoticed") {
    let (d, r) = fresh(); startWatching(d, r)
    FakeAudio.inputFailures = [7]; d.readInput()
    expect(d.fault != nil && d.poll == nil && d.clients == [7], "faulted on a failed read")
    FakeAudio.inputFailures = []; FakeAudio.processes[77] = nil; FakeAudio.inputRunning[7] = nil; addSpeakers()
    fire(d, [kAudioHardwarePropertyDefaultOutputDevice]); DispatchQueue.main.drain()
    expect(d.fault == nil && d.clients.isEmpty && d.poll == nil && activePolls() == 0, "fault cleared; unbound; nothing polled")
    expect(r.displays.last?.title == "Waiting for your dictation app", "menu says Waiting for Willow (\(r.displays.last?.title ?? "nil"))")
    FakeAudio.processes[77] = 9; FakeAudio.inputRunning[9] = false
    fire(d, [kAudioHardwarePropertyProcessObjectList])
    expect(d.clients == [9] && activePolls() == 1, "Willow's new process binds and polls")
}

scenario("R10 pre-save fault: each output change is one bounded retry") {
    let (d, _) = fresh(); startWatching(d)
    FakeAudio.inputRunning[7] = true; FakeAudio.defaultOutput = 30
    d.readInput(); expect(d.fault != nil && activePolls() == 0, "first fault")
    FakeAudio.defaultOutput = 31
    let before = FakeAudio.reads(of: kAudioHardwarePropertyDefaultOutputDevice).count
    fire(d, [kAudioHardwarePropertyDefaultOutputDevice])
    expect(d.fault != nil && activePolls() == 0 && d.saved == nil, "the retry reads at once and faults again; nothing polls")
    let captureReads = FakeAudio.reads(of: kAudioHardwarePropertyDefaultOutputDevice).count
    expect(captureReads == before + 1, "one capture attempt for the one output change")
    d.readInput(); d.readInput()
    expect(FakeAudio.reads(of: kAudioHardwarePropertyDefaultOutputDevice).count == captureReads, "no further capture attempts while faulted")
}

// ===== (N) build-12: listener re-establishment after a Core Audio reset =====
scenario("N1 reset with the saved output still absent: retry fails, then the device's return recovers on the new listeners") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)
    d.outputChanged()
    expect(d.fault != nil && d.saved != nil && d.poll == nil, "faulted with the level saved")
    fire(d, [kAudioHardwarePropertyServiceRestarted]); d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(d.fault == "Restore failed: Saved output is unavailable" && d.saved != nil && d.saved!.device == 10 && d.poll == nil, "reset: one bounded retry fails again, saved identity kept")
    expect(d.listeners.count == 3 && FakeAudio.listenersAdded.count == 6 && FakeAudio.listenersRemoved.count == 3, "listeners re-registered after the reset")
    expect(FakeAudio.writes.isEmpty && FakeAudio.writesTo(20).isEmpty, "nothing written to the current default")
    expect(r.displays.last?.title == "Couldn’t restore volume" && r.displays.last?.restorable == true, "menu still offers Restore volume")
    FakeAudio.addDevice(11, uid: "UID-A", volume: 0.19)
    fire(d, [kAudioHardwarePropertyDefaultOutputDevice]); d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(d.saved == nil && d.fault == nil && FakeAudio.writes == [Write(device: 11, element: 0, value: 0.62)], "the device's return restores to the re-resolved id")
    expect(d.clients == [7] && activePolls() == 1 && d.listeners.count == 3 && FakeAudio.listenersAdded.count == 6, "watching resumes; no further registrations")
    expect(r.displays.last?.title == "Ready", "menu back to Ready (\(r.displays.last?.title ?? "nil"))")
}
scenario("N2 reset whose re-registration fails: fault reported, saved kept, a later toggle registers again") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(); lower(d, saved); FakeAudio.defaultOutput = 10
    FakeAudio.addListenerFailures = [kAudioHardwarePropertyServiceRestarted]
    fire(d, [kAudioHardwarePropertyServiceRestarted]); d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(d.listeners.isEmpty && d.fault == "Observe audio lifecycle (\(kAudioHardwareIllegalOperationError))", "failed re-registration leaves nothing registered and reports the fault (\(d.fault ?? "nil"))")
    expect(d.saved == nil && FakeAudio.writes == [Write(device: 10, element: 0, value: 0.62)], "the saved level was still restored once to its device")
    note("after a reset whose re-registration fails: fault=\(d.fault ?? "nil") saved=\(d.saved != nil) writes=\(FakeAudio.writes.map { "\($0.device):\($0.value)" }) title=\(r.displays.last?.title ?? "nil")")
    expect(d.poll == nil && activePolls() == 0, "no polling without listeners")
    FakeAudio.addListenerFailures = []
    d.setEnabled(false); d.setEnabled(true)
    expect(d.listeners.count == 3 && d.fault == nil && d.clients == [7] && activePolls() == 1, "the next toggle registers all three and watches again (fault=\(d.fault ?? "nil"))")
}
scenario("N3 reset while asleep with nothing saved re-registers and stays idle until wake") {
    let (d, _) = fresh(); startWatching(d); d.setAwake(false)
    expect(d.poll == nil && d.clients.isEmpty, "asleep: idle")
    fire(d, [kAudioHardwarePropertyServiceRestarted]); d.queue.drainDelayed()
    expect(d.listeners.count == 3 && FakeAudio.listenersAdded.count == 6 && FakeAudio.listenersRemoved.count == 3, "re-registered while asleep")
    expect(d.poll == nil && d.clients.isEmpty && FakeAudio.writes.isEmpty && FakeAudio.resolves.isEmpty, "nothing else happened")
    d.setAwake(true)
    expect(d.clients == [7] && activePolls() == 1 && FakeAudio.listenersAdded.count == 6, "wake resumes watching on the new registrations")
}
scenario("N4 reset arriving after terminate() while a saved level is pending is dropped") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(); lower(d, saved); FakeAudio.defaultOutput = 10
    var c: [String?] = []
    d.terminate { c.append($0) }
    d.queue.drainDelayed()
    expect(c == [nil] && d.saved == nil && d.listeners.isEmpty, "terminate restored and removed listeners")
    fireLate(d, [kAudioHardwarePropertyServiceRestarted]); d.queue.drainDelayed()
    expect(d.listeners.isEmpty && FakeAudio.listenersAdded.count == 3 && d.poll == nil && c.count == 1, "late reset after terminate: no re-registration, no poll, no completion")
}

// ===== (L) build-12 review: listener identity — a removal must match what the HAL holds =====
scenario("L1 registrations carry this instance's client data") {
    let (d, _) = fresh(); startWatching(d)
    expect(FakeAudio.registered.count == 3 && FakeAudio.registered.allSatisfy { $0.context == d.context }, "three live registrations, all with this instance's client data")
    expect(Set((0..<3).map { _ in d.context }).count == 1, "the client data pointer is stable across calls")
}
scenario("L2 terminate() leaves the HAL holding nothing") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(); lower(d, saved); FakeAudio.defaultOutput = 10
    var c: [String?] = []
    d.terminate { c.append($0) }; d.queue.drainDelayed()
    expect(c == [nil] && FakeAudio.registered.isEmpty && FakeAudio.removeMisses.isEmpty, "every removal matched; the HAL's view is empty")
    let reads = FakeAudio.reads.count, pending = d.queue.pending.count
    fire(d, [kAudioHardwarePropertyProcessObjectList])
    expect(FakeAudio.reads.count == reads && d.queue.pending.count == pending, "with nothing registered the HAL has nothing to deliver")
}
scenario("L3 a Core Audio reset swaps registrations instead of stacking them") {
    let (d, _) = fresh(); startWatching(d)
    fire(d, [kAudioHardwarePropertyServiceRestarted]); d.queue.drainDelayed()
    expect(FakeAudio.registered.count == 3 && FakeAudio.listenersAdded.count == 6 && FakeAudio.listenersRemoved.count == 3, "three live registrations after the reset, not six")
    fire(d, [kAudioHardwarePropertyServiceRestarted]); d.queue.drainDelayed()
    expect(FakeAudio.registered.count == 3 && FakeAudio.listenersAdded.count == 9 && FakeAudio.listenersRemoved.count == 6, "still three after a second reset")
}
scenario("L4 removal is scoped by client data: one instance cannot unregister another") {
    let (d, _) = fresh(); startWatching(d)
    let e = Ducking(percent: 30) { _ in }; startWatching(e)   // second instance on the same hardware table
    expect(FakeAudio.registered.count == 6, "two instances, six registrations")
    d.removeListeners()
    expect(FakeAudio.registered.count == 3 && FakeAudio.registered.allSatisfy { $0.context == e.context }, "only the first instance's three were removed")
    e.removeListeners()
    expect(FakeAudio.registered.isEmpty, "then the second's")
}
scenario("L5 the proc copies the addresses and hands the decision to the audio queue") {
    let (d, _) = fresh(); startWatching(d)
    var changes = [address(kAudioHardwarePropertyProcessObjectList)]
    let status = changes.withUnsafeMutableBufferPointer { Ducking.listener(systemAudio, 1, UnsafePointer($0.baseAddress!), d.context) }
    expect(status == noErr && d.queue.pending.count == 1 && FakeAudio.reads.isEmpty, "returns noErr with one queued decision and nothing decided yet")
    changes[0].mSelector = kAudioHardwarePropertyServiceRestarted   // the HAL's buffer is gone by the time the queue runs
    d.queue.drain()
    expect(FakeAudio.listenersAdded.count == 3 && FakeAudio.reads(of: kAudioHardwarePropertyProcessObjectList).count == 1, "the queued decision used the copied selector (bind), not the mutated buffer (reset)")
    let nothing = Ducking.listener(systemAudio, 1, &changes[0], nil)
    expect(nothing == noErr && d.queue.pending.isEmpty, "a callback without client data is ignored")
}

// ===== (B) build-12 review: Willow's audio process changing while a restore is in flight =====
scenario("B1 ProcessObjectList change during a restore is not lost") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(); lower(d, saved); FakeAudio.defaultOutput = 10
    d.restore { _ in }                                   // in flight: endpoint written, verify pending
    expect(d.restoring && d.poll != nil, "restore in flight while polling continues")
    FakeAudio.processes[77] = 8; FakeAudio.inputRunning[8] = false; FakeAudio.inputRunning[7] = nil   // Willow's audio process was replaced
    fire(d, [kAudioHardwarePropertyProcessObjectList])
    d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(d.saved == nil && d.fault == nil, "restore completed (\(d.fault ?? "no fault"))")
    expect(d.clients == [8] && d.poll != nil && activePolls() == 1, "the new process is bound and polled once the restore finished (clients=\(d.clients))")
    d.poll!.handler!(); DispatchQueue.main.drain()
    expect(d.fault == nil && d.lastDisplay?.title == "Ready", "the next poll reads the live process (fault=\(d.fault ?? "nil"))")
}
scenario("B2 the deferred bind is dropped when the restore fails") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(); lower(d, saved); FakeAudio.defaultOutput = 10
    FakeAudio.writesApply = false                         // hardware ignores the write: verify will fail
    d.restore { _ in }
    FakeAudio.processes[77] = 8; FakeAudio.inputRunning[8] = false
    fire(d, [kAudioHardwarePropertyProcessObjectList])
    d.queue.drainDelayed()
    expect(d.fault == "Restore failed: Saved volume did not restore" && d.saved != nil, "restore failed (\(d.fault ?? "nil"))")
    expect(d.clients == [7] && d.poll == nil && activePolls() == 0, "nothing bound or polled while faulted (clients=\(d.clients))")
}

// ===== (F) fade: retargeting mid-ramp and the 100% setting =====
scenario("F1 setPercent() during a fade retargets the running ramp without a second timer") {
    let (d, _) = fresh(); startWatching(d)
    FakeAudio.addDevice(10, uid: "UID-A", volume: 0.8); FakeAudio.defaultOutput = 10
    FakeAudio.inputRunning[7] = true
    d.poll!.handler!()                                    // dictation starts: capture, ramp toward 30%
    expect(d.saved != nil && d.ramp != nil && d.target == 0.3 && d.gain == 1, "captured at 0.8, ramp created toward 30%")
    let ramp = d.ramp!
    d.setPercent(60)
    expect(d.ramp === ramp && d.target == 0.6 && FakeTimer.created.count == 2, "same ramp timer, new target 60%")
    d.setPercent(100)
    expect(d.target == 1 && d.ramp === ramp, "100% retargets to full volume on the same ramp")
    expect(FakeAudio.writes.isEmpty, "no write until the ramp ticks")
}
scenario("F2 at 100% nothing is captured or written while Willow dictates") {
    let (d, r) = fresh(percent: 100); startWatching(d, r)
    FakeAudio.addDevice(10, uid: "UID-A", volume: 0.8); FakeAudio.defaultOutput = 10
    FakeAudio.inputRunning[7] = true
    d.poll!.handler!(); d.poll!.handler!(); DispatchQueue.main.drain()
    expect(d.saved == nil && d.ramp == nil && FakeAudio.writes.isEmpty && FakeAudio.reads(of: kAudioHardwarePropertyDefaultOutputDevice).isEmpty, "no capture, no ramp, no writes at 100%")
    expect(d.lastDisplay?.title == "Ready" && d.lastDisplay?.lowered == false, "status stays Ready")
}

// ===== (X) deferred bind during a restore (round-2 reviewer scenarios, adopted) =====
scenario("X1 several ProcessObjectList changes during one restore: bounded pile-up, one rebind, one poll") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(); lower(d, saved); FakeAudio.defaultOutput = 10
    d.restore { _ in }
    expect(d.restoring && d.restorations.count == 1, "restore in flight")
    FakeAudio.processes[77] = 8; FakeAudio.inputRunning[8] = false; FakeAudio.inputRunning[7] = nil
    for _ in 0..<3 { fire(d, [kAudioHardwarePropertyProcessObjectList]) }
    expect(d.restorations.count == 4, "one deferred bind per event, nothing else queued (pending=\(d.restorations.count))")
    expect(FakeAudio.reads(of: kAudioHardwarePropertyProcessObjectList).isEmpty && FakeAudio.writes.count == 1, "no lookup and no extra write while the restore verifies")
    d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(d.saved == nil && d.fault == nil && !d.restoring && d.restorations.isEmpty, "restore finished, completion list empty (fault=\(d.fault ?? "nil"))")
    expect(d.clients == [8] && d.poll != nil && activePolls() == 1, "bound once to the new process, one poll (clients=\(d.clients), polls=\(activePolls()))")
    expect(FakeAudio.reads(of: kAudioHardwarePropertyProcessObjectList).count == 3, "each deferred bind looked the pid up exactly once, then stopped (lookups=\(FakeAudio.reads(of: kAudioHardwarePropertyProcessObjectList).count))")
    expect(FakeAudio.writes.count == 1 && d.queue.delayed.isEmpty, "still one write; nothing left scheduled")
    expect(r.displays.last?.title == "Ready", "menu says Ready (\(r.displays.last?.title ?? "nil"))")
}
scenario("X2 process object replaced during an output-change restore: the new process is bound, no fault") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(); lower(d, saved)
    addSpeakers()                                  // default output moved to device 20 while lowered
    d.outputChanged()
    expect(d.restoring && d.poll != nil && FakeAudio.writes == [Write(device: 10, element: 0, value: 0.62)], "restore in flight to the saved device")
    FakeAudio.processes[77] = 8; FakeAudio.inputRunning[8] = false; FakeAudio.inputRunning[7] = nil   // Willow's audio process replaced
    fire(d, [kAudioHardwarePropertyProcessObjectList])
    expect(d.restoring && d.restorations.count == 2, "deferred bind queued ahead of the output-change completion")
    d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(d.saved == nil && !d.restoring, "restore completed")
    expect(d.fault == nil, "no fault after the process change (fault=\(d.fault ?? "nil"))")
    expect(d.clients == [8], "bound to the new process (clients=\(d.clients))")
    expect(d.poll != nil && activePolls() == 1, "polling the new process (polls=\(activePolls()))")
    expect(r.displays.last?.title == "Ready", "menu says Ready (\(r.displays.last?.title ?? "nil"))")
    note("X2 outcome: fault=\(d.fault ?? "nil") clients=\(d.clients) poll=\(d.poll != nil) title=\(r.displays.last?.title ?? "nil") lookups=\(FakeAudio.reads(of: kAudioHardwarePropertyProcessObjectList).count)")
    // Does anything short of a new lifecycle event recover?
    fire(d, [kAudioHardwarePropertyProcessObjectList]); DispatchQueue.main.drain()
    note("X2 after one more ProcessObjectList event: fault=\(d.fault ?? "nil") clients=\(d.clients) poll=\(d.poll != nil)")
    fire(d, [kAudioHardwarePropertyDefaultOutputDevice]); DispatchQueue.main.drain()
    note("X2 after a DefaultOutputDevice event: fault=\(d.fault ?? "nil") clients=\(d.clients) poll=\(d.poll != nil) title=\(r.displays.last?.title ?? "nil")")
}
scenario("X2b same event during a manual restore: recovered through start()") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(); lower(d, saved); FakeAudio.defaultOutput = 10
    d.manualRestore()
    expect(d.restoring && d.poll == nil, "manual restore in flight")
    FakeAudio.processes[77] = 8; FakeAudio.inputRunning[8] = false; FakeAudio.inputRunning[7] = nil
    fire(d, [kAudioHardwarePropertyProcessObjectList])
    d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(d.fault == nil && d.clients == [8] && activePolls() == 1, "start() rebinds before the deferred bind runs (fault=\(d.fault ?? "nil"), clients=\(d.clients), polls=\(activePolls()))")
}
scenario("X3 terminate() while a deferred bind is queued: the bind is dropped, nothing polls, one completion") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(); lower(d, saved); FakeAudio.defaultOutput = 10
    d.restore { _ in }
    FakeAudio.processes[77] = 8; FakeAudio.inputRunning[8] = false
    fire(d, [kAudioHardwarePropertyProcessObjectList])
    expect(d.restoring && d.restorations.count == 2, "deferred bind queued")
    var c: [String?] = []
    d.terminate { c.append($0) }
    expect(d.listeners.isEmpty && FakeAudio.registered.isEmpty && d.restorations.count == 3 && d.restoring && c.isEmpty, "terminate joined the in-flight restore; HAL holds nothing")
    d.queue.drainDelayed()
    expect(c == [nil] && d.saved == nil && !d.restoring && d.restorations.isEmpty, "one successful completion")
    expect(d.clients == [7] && d.poll == nil && activePolls() == 0 && FakeAudio.reads(of: kAudioHardwarePropertyProcessObjectList).isEmpty, "deferred bind dropped after terminate: no lookup, no poll")
    expect(FakeAudio.writes.count == 1 && d.queue.delayed.isEmpty, "one write, nothing scheduled")
}
scenario("X4 Core Audio reset during an in-flight restore joins it; watching resumes once on fresh registrations") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(); lower(d, saved); FakeAudio.defaultOutput = 10
    d.restore { _ in }
    expect(d.restoring, "in flight")
    fire(d, [kAudioHardwarePropertyServiceRestarted])
    expect(d.listeners.count == 3 && FakeAudio.registered.count == 3 && FakeAudio.listenersAdded.count == 6 && FakeAudio.listenersRemoved.count == 3, "re-registered once")
    expect(d.restoring && d.clients.isEmpty && d.poll == nil && d.restorations.count == 2 && FakeAudio.writes.count == 1, "reconfigure joined the in-flight restore; no second write (pending=\(d.restorations.count))")
    d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(d.saved == nil && d.fault == nil && d.clients == [7] && d.poll != nil && activePolls() == 1, "restored once, rebound, one poll (fault=\(d.fault ?? "nil"))")
    expect(FakeAudio.writes.count == 1 && r.displays.last?.title == "Ready", "still one write; Ready")
}
scenario("X5 the chosen apps change while a bind is deferred: the deferred bind uses the current choice, one poll") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(); lower(d, saved); FakeAudio.defaultOutput = 10
    d.restore { _ in }
    FakeAudio.processes[77] = 8; FakeAudio.inputRunning[8] = false
    fire(d, [kAudioHardwarePropertyProcessObjectList])
    FakeAudio.processes[78] = 9; FakeAudio.inputRunning[9] = false; FakeAudio.paths[78] = "/Applications/Other.app/Contents/MacOS/Other"
    d.setRoots(["/Applications/Other.app/"])
    expect(d.restoring && d.clients == [7] && d.restorations.count == 3, "the change joined the restore; the client list waits for it (pending=\(d.restorations.count))")
    d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(d.saved == nil && d.fault == nil, "restored (fault=\(d.fault ?? "nil"))")
    expect(d.clients == [9] && d.poll != nil && activePolls() == 1, "bound once to the newly chosen app's client (clients=\(d.clients), polls=\(activePolls()))")
    expect(FakeAudio.reads(of: kAudioHardwarePropertyProcessObjectList).count == 2, "two lookups, one per deferred bind (lookups=\(FakeAudio.reads(of: kAudioHardwarePropertyProcessObjectList).count))")
}
scenario("X6 Disabled while a bind is deferred: nothing resumes until enabled again") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(); lower(d, saved); FakeAudio.defaultOutput = 10
    d.restore { _ in }
    FakeAudio.processes[77] = 8; FakeAudio.inputRunning[8] = false
    fire(d, [kAudioHardwarePropertyProcessObjectList])
    d.setEnabled(false)
    d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(d.saved == nil && d.fault == nil && d.poll == nil && activePolls() == 0 && d.clients.isEmpty, "restored while disabled: nothing bound or polled")
    expect(r.displays.last?.title == "Disabled", "menu says Disabled (\(r.displays.last?.title ?? "nil"))")
    d.setEnabled(true); DispatchQueue.main.drain()
    expect(d.clients == [8] && activePolls() == 1 && r.displays.last?.title == "Ready", "enable binds the current process once")
}
scenario("X7 dictation starting during a restore does not write against the verify") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(); lower(d, saved); FakeAudio.defaultOutput = 10
    d.restore { _ in }
    FakeAudio.inputRunning[7] = true
    d.poll!.handler!()
    expect(d.inputActive && d.ramp == nil && FakeAudio.writes.count == 1 && d.target == 1, "input noticed, no ramp, no second write while restoring")
    d.queue.drainDelayed(); DispatchQueue.main.drain()
    expect(d.saved == nil && d.fault == nil && d.gain == 1, "restore verified")
    d.poll!.handler!()
    expect(d.saved != nil && d.ramp != nil && d.target == 0.3, "the next poll captures again and lowers")
}
scenario("X8 Willow quits during an output-change restore and the restore settles before didTerminate arrives; a relaunch is watched again") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(); lower(d, saved)
    addSpeakers()
    d.outputChanged()
    expect(d.restoring, "restore in flight")
    FakeAudio.processes[77] = nil; FakeAudio.inputRunning[7] = nil      // Willow's process object gone
    fire(d, [kAudioHardwarePropertyProcessObjectList])
    d.queue.drainDelayed(); DispatchQueue.main.drain()                   // restore settles before didTerminate arrives
    note("X8 after settle, before didTerminate: fault=\(d.fault ?? "nil") clients=\(d.clients) poll=\(d.poll != nil) title=\(r.displays.last?.title ?? "nil")")
    d.setRoots([]); d.queue.drainDelayed(); DispatchQueue.main.drain()  // didTerminate
    note("X8 after didTerminate: fault=\(d.fault ?? "nil") clients=\(d.clients) poll=\(d.poll != nil) title=\(r.displays.last?.title ?? "nil")")
    FakeAudio.processes[78] = 9; FakeAudio.inputRunning[9] = false
    d.setRoots([willowRoot]); d.queue.drainDelayed(); DispatchQueue.main.drain()   // didLaunch
    expect(d.fault == nil, "no fault after relaunch (fault=\(d.fault ?? "nil"))")
    expect(d.clients == [9] && d.poll != nil && activePolls() == 1, "polling the relaunched Willow (clients=\(d.clients), polls=\(activePolls()))")
    expect(r.displays.last?.title == "Ready", "menu says Ready (\(r.displays.last?.title ?? "nil"))")
}

// ===== (E) every dictation app: clients matched by bundle path, several at once =====
let flowRoot = "/Applications/Flow.app/", flowHelper = flowRoot + "Contents/Frameworks/Flow Helper.app/Contents/MacOS/Flow Helper"
/// Two chosen apps, each an audio client: Willow (pid 77, client 5) and Flow's helper (pid 50, client 6).
func watchTwo(_ d: Ducking) {
    FakeAudio.processes = [77: 5, 50: 6]; FakeAudio.paths[50] = flowHelper
    FakeAudio.inputRunning = [5: false, 6: false]
    FakeAudio.addDevice(10, uid: "UID-A", volume: 0.8); FakeAudio.defaultOutput = 10
    d.roots = [willowRoot, flowRoot]; d.start()
    precondition(d.clients == [5, 6] && activePolls() == 1, "watchTwo precondition")
}
/// The fade runs on the real clock; backdate the running segment so the next tick is its last.
func finishFade(_ d: Ducking) {
    d.segment = Fade(from: d.gain, to: d.target, fullSpan: 1 - d.duckGain, now: 0)
    d.ramp!.handler!()
}
func captures() -> Int { FakeAudio.reads(of: kAudioDevicePropertyDeviceUID).count }

scenario("E1 a helper inside the chosen bundle is matched; a sibling with a longer name is not") {
    let (d, _) = fresh()
    FakeAudio.processes = [50: 5, 51: 6, 52: 7, 53: 8]
    FakeAudio.paths = [50: flowHelper, 51: "/Applications/Flow.app.backup/Contents/MacOS/Flow",
                       52: "/Users/me/.codex/helper", 53: flowRoot + "Contents/MacOS/Flow"]
    FakeAudio.unreadablePaths = [53]
    FakeAudio.inputRunning = [5: false, 6: true, 7: true, 8: true]
    d.roots = [flowRoot]; d.start()
    expect(d.clients == [5], "only the helper under the chosen bundle is a client (clients=\(d.clients))")
    expect(!d.inputActive && d.saved == nil && FakeAudio.writes.isEmpty, "microphones held by other apps change nothing")
    let (e, _) = fresh()
    FakeAudio.processes = [50: 5]; FakeAudio.inputRunning[5] = true
    e.start()
    expect(e.clients.isEmpty && activePolls() == 0 && FakeAudio.reads.isEmpty, "no chosen app running: nothing listed, nothing polled")
}
scenario("E2 two apps overlapping: one capture, one restore") {
    let (d, _) = fresh(); watchTwo(d)
    FakeAudio.inputRunning[5] = true; d.poll!.handler!()
    expect(d.saved != nil && d.target == 0.3 && captures() == 1, "the first app lowers")
    finishFade(d)
    expect(FakeAudio.volumes[10]![0] == Float32(0.8) * 0.3 && d.ramp == nil, "lowered to exactly 30% of 0.8")
    FakeAudio.inputRunning[6] = true; d.poll!.handler!()
    FakeAudio.inputRunning[5] = false; d.poll!.handler!()
    expect(captures() == 1 && d.target == 0.3 && d.ramp == nil && FakeAudio.writes.count == 1, "the second app joins and the first leaves: nothing moves")
    FakeAudio.inputRunning[6] = false; d.poll!.handler!()
    expect(d.target == 1 && d.ramp != nil, "the last app stops: fade up")
    finishFade(d); d.queue.drainDelayed()
    expect(d.saved == nil && d.fault == nil && FakeAudio.volumes[10]![0] == 0.8 && FakeAudio.writes.count == 2, "one restore, to the captured level")
}
scenario("E3 a helper vanishing while another app dictates changes nothing") {
    let (d, _) = fresh(); watchTwo(d)
    FakeAudio.inputRunning = [5: true, 6: true]; d.poll!.handler!(); finishFade(d)
    FakeAudio.processes[50] = nil; FakeAudio.inputRunning[6] = nil
    d.poll!.handler!()
    expect(d.fault == nil && d.inputActive && d.target == 0.3, "the poll before the rebind reads the vanished client as not dictating")
    fire(d, [kAudioHardwarePropertyProcessObjectList])
    expect(d.clients == [5] && d.saved != nil && d.target == 0.3 && d.ramp == nil, "rebound to the remaining client, still lowered")
    expect(captures() == 1 && FakeAudio.writes.count == 1 && activePolls() == 1, "no restore, no second capture, one poll")
}
scenario("E4 a vanished client is not dictating; any other error faults, whatever the order") {
    for gone in [AudioObjectID(5), 6] {
        let (d, _) = fresh(); watchTwo(d)
        FakeAudio.inputRunning = [5: true, 6: true]; FakeAudio.inputRunning[gone] = nil
        d.readInput()
        expect(d.fault == nil && d.inputActive && d.saved != nil, "client \(gone) gone, the other still counts")
        FakeAudio.inputRunning = [:]
        d.readInput()
        expect(d.fault == nil && !d.inputActive && d.target == 1, "both gone: dictation over, no fault")
    }
    for failing in [AudioObjectID(5), 6] {
        let (d, _) = fresh(); watchTwo(d)
        FakeAudio.inputRunning = [5: true, 6: true]; FakeAudio.inputFailures = [failing]
        d.readInput()
        expect(d.fault == "Read audio state (\(kAudioHardwareIllegalOperationError))" && d.saved == nil && activePolls() == 0, "client \(failing) fails to read: fault, nothing captured")
    }
    let (d, _) = fresh(); watchTwo(d)
    FakeAudio.listFails = true
    fire(d, [kAudioHardwarePropertyProcessObjectList])
    expect(d.fault == "Size audio clients (\(kAudioHardwareIllegalOperationError))" && activePolls() == 0, "an unreadable client list faults (\(d.fault ?? "nil"))")
}
scenario("E5 switching off the app that is dictating restores; switching off another does nothing") {
    let (d, _) = fresh(); watchTwo(d)
    FakeAudio.inputRunning[5] = true; d.poll!.handler!(); finishFade(d)
    d.setRoots([willowRoot])
    expect(d.clients == [5] && d.target == 0.3 && d.ramp == nil && FakeAudio.writes.count == 1, "the idle app switched off: still lowered, nothing written")
    d.setRoots([])
    expect(d.clients.isEmpty && activePolls() == 0 && !d.inputActive && d.target == 1 && d.ramp != nil, "the dictating app switched off: the empty list is read once and the fade up starts")
    finishFade(d); d.queue.drainDelayed()
    expect(d.saved == nil && d.fault == nil && FakeAudio.volumes[10]![0] == 0.8 && activePolls() == 0, "restored; no timer left running")
}
scenario("E6 volume already off: the whole session is left alone; the next one ducks") {
    let (d, r) = fresh(); watchTwo(d); FakeAudio.volumes[10]![0] = 0
    FakeAudio.inputRunning[5] = true; d.poll!.handler!(); DispatchQueue.main.drain()
    expect(d.saved == nil && d.ramp == nil && d.skipped && FakeAudio.writes.isEmpty, "nothing captured, nothing written")
    expect(r.displays.last?.title == "Volume was already off, so Sigá left it alone" && r.displays.last?.skipped == true && r.displays.last?.lowered == false, "status says so (\(r.displays.last?.title ?? "nil"))")
    FakeAudio.volumes[10]![0] = 0.5                       // the other app, or the user, raises it mid-session
    let before = captures()
    d.poll!.handler!(); d.poll!.handler!()
    expect(d.saved == nil && captures() == before && FakeAudio.writes.isEmpty && d.skipped, "still left alone after the volume comes up")
    FakeAudio.inputRunning[5] = false; d.poll!.handler!(); DispatchQueue.main.drain()
    expect(!d.skipped && !d.suppressed && r.displays.last?.title == "Ready" && r.displays.last?.skipped == false, "dictation over: back to Ready")
    FakeAudio.inputRunning[5] = true; d.poll!.handler!()
    expect(d.saved != nil && d.target == 0.3 && d.ramp != nil, "the next session lowers from 0.5")
}
scenario("E7 one silent stereo channel still ducks") {
    let (d, _) = fresh(); watchTwo(d)
    FakeAudio.addDevice(12, uid: "UID-PODS", volume: 0, element: 1); FakeAudio.addDevice(12, uid: "UID-PODS", volume: 0.6, element: 2)
    FakeAudio.defaultOutput = 12
    FakeAudio.inputRunning[5] = true; d.poll!.handler!()
    expect(d.saved?.controls.map(\.startingValue) == [0, 0.6] && !d.skipped && d.ramp != nil, "captured both channels and lowers")
    finishFade(d)
    expect(FakeAudio.volumes[12]! == [1: 0, 2: Float32(0.6) * 0.3], "the audible channel is lowered; the silent one stays silent")
}
scenario("E8 the fade lands exactly on its target, never moves away from it, and retargets from where it is") {
    let down = Fade(from: 1, to: 0.3, fullSpan: 0.7, now: 100)
    var last: Float32 = 1, monotonic = true
    for step in 0...200 {
        let value = down.gain(at: 100 + down.duration * Double(step) / 200).value
        if value > last { monotonic = false }
        last = value
    }
    expect(monotonic && last == 0.3 && down.gain(at: 100 + down.duration).finished && !down.gain(at: 100 + down.duration * 0.99).finished, "B down: monotonic, exact endpoint, finished only at the end")
    expect(down.duration == 0.40, "B: a full fade takes its full time")
    let mid = down.gain(at: 100 + down.duration / 2).value
    let up = Fade(from: mid, to: 1, fullSpan: 0.7, now: 200)
    expect(up.gain(at: 200).value == mid && up.gain(at: 200 + up.duration).value == 1, "B reversed mid-fade: starts at the current gain, ends at exactly 1")
    expect(up.duration < 0.85 && up.duration >= 0.15, "B: the shorter distance takes less time, never under 150 ms (\(up.duration))")
    var rising = true; last = mid
    for step in 0...200 {
        let value = up.gain(at: 200 + up.duration * Double(step) / 200).value
        if value < last { rising = false }
        last = value
    }
    expect(rising, "B up: monotonic")
    let fullUp = Fade(from: 0.3, to: 1, fullSpan: 0.7, now: 0)
    expect(fullUp.duration == 0.85, "B: a full restore takes 850 ms")
    let still = Fade(from: 1, to: 1, fullSpan: 0.7, now: 0)
    expect(still.gain(at: 0).finished && still.gain(at: 0).value == 1, "nowhere to go: finished on the first tick")
    let (d, _) = fresh(); watchTwo(d)
    FakeAudio.inputRunning[5] = true; d.poll!.handler!()
    d.gain = 0.5; d.setPercent(60)
    expect(d.segment?.from == 0.5 && d.segment?.to == 0.6 && FakeTimer.created.filter { $0.repeating == .nanoseconds(16_666_667) }.count == 1, "a new target mid-fade starts from the current gain on the same timer")
}
scenario("E9 watching every app for Use another app… only reads, and an unreadable tick reports nothing") {
    let (d, _) = fresh(); watchTwo(d)
    var reports: [[String]] = []
    d.watchAll { reports.append($0) }
    let watcher = d.watcher!
    expect(watcher.activated && watcher.repeating == .milliseconds(100), "one 100 ms watcher")
    watcher.handler!(); DispatchQueue.main.drain()
    FakeAudio.inputRunning[6] = true
    watcher.handler!(); DispatchQueue.main.drain()
    expect(reports == [[], [flowHelper]], "reports the executables holding the microphone (\(reports))")
    FakeAudio.listFails = true
    watcher.handler!(); DispatchQueue.main.drain()
    expect(reports.count == 2 && d.fault == nil, "an unreadable tick is not reported as silence, and never faults the engine")
    d.watchAll(nil)
    expect(watcher.cancelled && d.watcher == nil && FakeAudio.writes.isEmpty && d.saved == nil, "stopped; the watcher never touched the volume")
}

// ===== Observations (not counted as pass/fail) =====
scenario("obs D poll tick on a replaced process object during a restore (same pid, no relaunch): reported, not required") {
    let (d, r) = fresh(); startWatching(d, r)
    let saved = makeSaved(); lower(d, saved)
    addSpeakers()
    d.outputChanged()
    FakeAudio.processes[77] = 8; FakeAudio.inputRunning[8] = false; FakeAudio.inputRunning[7] = nil
    fire(d, [kAudioHardwarePropertyProcessObjectList])
    d.poll!.handler!()                                   // the 100 ms poll is still armed during an output-change restore
    d.queue.drainDelayed(); DispatchQueue.main.drain()
    note("obs D outcome: fault=\(d.fault ?? "nil") clients=\(d.clients) polls=\(activePolls()) title=\(r.displays.last?.title ?? "nil"): Core Audio replaces a process object only when the process or coreaudiod restarts, and both of those paths (X8, X4) recover; this exact ordering is left as is")
}
scenario("obs C second terminate() after a failed one retries") {
    let (d, _) = fresh(); startWatching(d)
    let saved = makeSaved(present: false); addSpeakers(); lower(d, saved)
    var c: [String?] = []
    d.terminate { c.append($0) }
    d.terminate { c.append($0) }
    note("two terminate() calls → completions=\(c.count), resolves=\(FakeAudio.resolves.count): each call is its own bounded attempt (the App now calls it at most once per process)")
}

print("")
print("main.swift SHA-256: \(mainSwiftSHA256)")
print("passed \(passed) failed \(failed)")
for failure in failures { print("  FAILED: \(failure)") }
exit(failed == 0 ? 0 : 1)
