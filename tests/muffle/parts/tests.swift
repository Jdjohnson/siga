// ===== Deterministic fault tests for MuffleSession =====
// Each case runs control, worker and IOProc in one explicit single-threaded order. Holding queued
// worker work stands in for a blocked HAL call; a real hang of the worker thread inside Core Audio
// is not reproduced. Nothing here plays, captures or changes audio.

var passed = 0, failed = 0, current = "", currentFailed = false
func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", line: Int = #line) {
    guard !condition() else { return }
    currentFailed = true
    print("FAIL: \(current) (line \(line)) \(message())")
}
func test(_ name: String, _ body: () -> Void) {
    current = name; currentFailed = false
    hal = FakeHAL(); FakeQueue.made = []; FakeClock.now = 1000
    let live = FakeDSP.live
    body()
    expect(hal.violations.isEmpty, "HAL misuse: \(hal.violations)")
    expect(FakeQueue.made.allSatisfy { $0.pending.isEmpty }, "work left queued")
    expect(FakeDSP.live == live, "\(FakeDSP.live - live) callback state(s) not freed")
    FakeQueue.made = []
    if currentFailed { failed += 1 } else { passed += 1; print("PASS: \(name)") }
}

struct Change { let phase: MuffleSession.Phase, finished: Bool, engaged: Bool, problem: String? }
final class Rig {
    let control = FakeQueue(label: "control")
    var worker: FakeQueue!
    var session: MuffleSession!
    var changes: [Change] = []
    init(percent: Int = 30) {
        let before = FakeQueue.made.count
        session = MuffleSession(queue: control, percent: percent) { [weak self] in self?.record() }
        let made = FakeQueue.made[before...]
        expect(made.count == 1, "the session should make exactly one worker queue")
        worker = made.last ?? FakeQueue(label: "missing worker")
    }
    func record() {
        changes.append(Change(phase: session.phase, finished: session.finished, engaged: session.engaged, problem: session.problem))
    }
    var finishes: Int { changes.filter(\.finished).count }
    var everEngaged: Bool { changes.contains(where: \.engaged) }
    // Runs everything queued on both queues, worker first, until nothing is left.
    func settle() {
        for _ in 0..<100 {
            if worker.pending.isEmpty && control.pending.isEmpty { return }
            worker.drain(); control.drain()
        }
        expect(false, "queues never settled")
    }
    func activate() {
        session.start(); settle(); hal.render(); session.tick()
        expect(session.phase == .active, "setup did not activate")
    }
    func finishReturn() {
        session.setEngaged(false)
        for _ in 0..<200 { hal.render() }
        session.tick(); settle()
    }
}
let everything: Set<String> = ["listener", "tap", "aggregate", "proc", "running"]
let creation = ["add listener", "create tap", "create aggregate", "create proc", "start"]
func near(_ samples: [Float], _ value: Float) -> Bool { samples.last.map { abs($0 - value) < 0.0001 } ?? false }

print("Sources: \(harnessSources)")

// --- Setup and activation

test("setup engages only after the first callback") {
    let rig = Rig()
    rig.session.start(); rig.session.start()
    rig.settle()
    expect(hal.holds == everything, "route not fully started: \(hal.holds)")
    expect(hal.calls.filter { $0 == "create tap" }.count == 1, "a second start created another route")
    expect(rig.session.phase == .starting && !rig.everEngaged, "engaged before any audio arrived")
    FakeClock.now += 0.9; rig.session.tick()
    expect(rig.session.phase == .starting && !rig.session.engaged)
    let first = hal.render()
    expect(first.allSatisfy { $0 == 0.2 }, "audio changed before activation")
    rig.session.tick()
    expect(rig.session.phase == .active && rig.session.engaged && !rig.session.unavailable)
    expect(rig.changes.last?.engaged == true, "activation was not reported")
    var out: [Float] = []
    for _ in 0..<80 { out = hal.render() }
    expect(near(out, 0.06), "muffled level \(out.last ?? .nan), expected 30% of 0.2")
    rig.session.stop(); rig.settle()
    expect(rig.session.finished && rig.finishes == 1 && hal.holds.isEmpty)
}

test("no first callback while another app is playing releases the route without engaging") {
    let rig = Rig()
    rig.session.start(); rig.settle()
    FakeClock.now += 1.01; rig.session.tick()
    expect(rig.session.phase == .starting, "playback activity must be checked on the worker first")
    rig.settle()
    expect(!rig.session.finished, "a newly active source needs time to start callbacks")
    FakeClock.now += 1.01; rig.session.tick(); rig.settle()
    expect(rig.session.finished && rig.session.problem != nil && rig.session.unavailable)
    expect(!rig.everEngaged && rig.finishes == 1 && hal.holds.isEmpty, "left \(hal.holds)")
}

test("silence before first playback stays ready and resumes without a new route") {
    let rig = Rig(); hal.sourceRunning = false
    rig.session.start(); rig.settle()
    for _ in 0..<20 { FakeClock.now += 1.1; rig.session.tick(); rig.settle() }
    expect(rig.session.phase == .starting && !rig.session.unavailable && rig.session.problem == nil)
    expect(hal.calls.filter { $0 == "create tap" }.count == 1)
    hal.sourceRunning = true; hal.render(); rig.session.tick()
    expect(rig.session.phase == .active, "resumed playback did not activate")
    rig.session.stop(); rig.settle()
}

test("paused playback remains owned and a silent return releases normally") {
    let rig = Rig(); rig.activate(); hal.sourceRunning = false
    for _ in 0..<80 { hal.render() }
    for _ in 0..<5 { FakeClock.now += 1.1; rig.session.tick(); rig.settle() }
    expect(rig.session.phase == .active && rig.session.problem == nil && !rig.session.unavailable)
    rig.session.setEngaged(false); FakeClock.now += 1.1; rig.session.tick(); rig.settle()
    expect(rig.session.finished && rig.session.problem == nil && hal.holds.isEmpty)
}

for vanished in [false, true] {
    test("unrelated or exited playback does not count as a stalled source: \(vanished)") {
        let rig = Rig(); rig.activate()
        if vanished { hal.sourceGone = true } else { hal.sourceOutput = FakeHAL.otherOutput }
        FakeClock.now += 1.1; rig.session.tick(); rig.settle()
        expect(rig.session.phase == .active && rig.session.problem == nil)
        rig.session.stop(); rig.settle()
    }
}

test("a delayed playback query cannot fault a callback that has resumed") {
    let rig = Rig(); rig.activate()
    FakeClock.now += 1.1; rig.session.tick(); rig.session.tick()
    expect(rig.worker.pending.count == 1, "duplicate playback checks queued")
    rig.worker.drain(); hal.render(); rig.control.drain(); rig.session.tick()
    expect(rig.session.phase == .active && rig.session.problem == nil)
    rig.session.stop(); rig.settle()
}

test("a playback query error interrupts stall confirmation") {
    let rig = Rig(); rig.activate()
    FakeClock.now += 1.1; rig.session.tick(); rig.settle()
    hal.fail("read playback activity")
    FakeClock.now += 1.1; rig.session.tick(); rig.settle()
    FakeClock.now += 1.1; rig.session.tick(); rig.settle()
    expect(rig.session.phase == .active && rig.session.problem == nil, "an unknown result became evidence of a stall")
    FakeClock.now += 1.1; rig.session.tick(); rig.settle()
    expect(rig.session.finished && rig.session.problem != nil && hal.holds.isEmpty)
}

test("a held playback query reports a deadline and late work cannot re-engage") {
    let rig = Rig(); rig.activate()
    FakeClock.now += 1.1; rig.session.tick()
    FakeClock.now += 2.1; rig.session.tick()
    expect(rig.session.phase == .cleaning && rig.session.problem != nil && !rig.session.finished)
    expect(rig.worker.pending.count == 2, "cleanup must wait behind the held query")
    rig.settle()
    expect(rig.session.finished && rig.finishes == 1 && hal.holds.isEmpty)
}

test("callbacks stopping while muffling release the route") {
    let rig = Rig()
    rig.activate()
    FakeClock.now += 1.1; rig.session.tick(); rig.settle()
    expect(!rig.session.finished, "the first positive playback check is not persistent evidence")
    FakeClock.now += 1.1; rig.session.tick(); rig.settle()
    expect(rig.session.finished && rig.session.problem != nil && !rig.session.unavailable)
    expect(hal.holds.isEmpty && rig.finishes == 1)
}

test("latest gain is heard after setup, return and reversal") {
    let rig = Rig(percent: 80)
    rig.session.start()
    rig.session.setPercent(30)  // Before the worker runs.
    rig.worker.drain()
    rig.session.setPercent(55)  // Route running, completion not yet delivered.
    rig.control.drain()
    hal.render(); rig.session.tick()
    expect(rig.session.phase == .active)
    var out: [Float] = []
    for _ in 0..<80 { out = hal.render() }
    expect(near(out, 0.11), "level \(out.last ?? .nan), expected 55% of 0.2")
    rig.session.setEngaged(false)
    expect(rig.session.phase == .returning && rig.session.engaged)
    for _ in 0..<20 { hal.render() }
    rig.session.tick()
    expect(rig.session.phase == .returning, "released before the return finished")
    rig.session.setPercent(10)
    rig.session.setEngaged(true)
    expect(rig.session.phase == .active, "reversal did not re-engage")
    for _ in 0..<100 { out = hal.render() }
    expect(near(out, 0.02), "level \(out.last ?? .nan), expected 10% of 0.2 after reversal")
    rig.session.setPercent(150)
    for _ in 0..<100 { out = hal.render() }
    expect(near(out, 0.2), "out-of-range gain was not clamped to 100%")
    rig.session.setEngaged(false)
    for _ in 0..<200 { out = hal.render() }
    expect(out.allSatisfy { $0 == 0.2 }, "settled return is not the input itself")
    rig.session.tick(); rig.settle()
    expect(rig.session.finished && rig.session.problem == nil && hal.holds.isEmpty)
}

test("normal return frees everything") {
    weak var released: MuffleSession?
    let live = FakeDSP.live
    do {
        let rig = Rig()
        released = rig.session
        rig.activate()
        expect(FakeDSP.live == live + 1)
        rig.finishReturn()
        expect(rig.session.finished && rig.session.problem == nil && !rig.session.unavailable && rig.finishes == 1)
        expect(hal.holds.isEmpty && hal.listeners.isEmpty, "left \(hal.holds)")
        expect(FakeDSP.live == live, "callback state not freed on return")
    }
    expect(released == nil, "session retained after return")
}

// --- Cancellation

for stage in ["before the worker runs"] + creation {
    test("stop during setup: \(stage)") {
        let rig = Rig()
        if creation.contains(stage) {
            hal.hooks[stage] = { rig.session.stop() } // Control stops while the worker is inside this call.
            rig.session.start()
        } else {
            rig.session.start(); rig.session.setEngaged(false) // Disengaging during setup cancels it.
        }
        rig.settle()
        expect(rig.session.finished && rig.session.problem == nil && rig.finishes == 1 && !rig.everEngaged)
        expect(hal.holds.isEmpty, "left \(hal.holds)")
        let cut = max(1, (creation.firstIndex(of: stage) ?? 0) + 1)
        if stage == "before the worker runs" { expect(hal.calls.isEmpty, "cancelled setup still called the HAL") }
        let later = creation[cut...].filter { hal.calls.contains($0) }
        expect(later.isEmpty, "setup continued past cancellation: \(later)")
    }
}

test("late success after cancellation cannot activate or complete twice") {
    let rig = Rig()
    rig.session.start()
    rig.worker.drain()   // Setup succeeded; its completion waits on control.
    rig.session.stop()   // Control handles a stop first.
    let heard = hal.render()
    rig.control.drain(); rig.session.tick()
    expect(rig.session.phase == .cleaning && !rig.session.engaged && !rig.everEngaged, "late success re-activated")
    expect(heard.allSatisfy { $0 == 0.2 }, "a cancelled route changed audio")
    rig.settle()
    expect(rig.session.finished && rig.session.problem == nil && rig.finishes == 1 && hal.holds.isEmpty)
    let count = rig.changes.count
    rig.session.stop(); rig.session.start(); rig.session.setEngaged(true); rig.session.setPercent(5)
    FakeClock.now += 30; rig.session.tick(); rig.settle()
    expect(rig.changes.count == count, "a finished session reported again")
    expect(hal.calls.filter { $0 == "create tap" }.count == 1, "a finished session restarted")
}

test("late error after cancellation keeps the first outcome and completes once") {
    let timedOut = Rig()
    timedOut.session.start()
    FakeClock.now += 15.1; timedOut.session.tick()  // The worker never ran.
    let reason = timedOut.session.problem
    expect(reason != nil && timedOut.session.phase == .cleaning)
    hal.fail("read default output")  // The held setup then fails.
    timedOut.settle()
    expect(timedOut.session.finished && timedOut.session.problem == reason && timedOut.finishes == 1)
    expect(hal.holds.isEmpty)

    let stopped = Rig()
    stopped.session.start(); stopped.session.stop()
    hal.fail("add listener")
    stopped.settle()
    expect(stopped.session.finished && stopped.session.problem == nil && stopped.finishes == 1, "late error became a failure")
    expect(hal.holds.isEmpty)
}

// --- Setup failures

for (stage, skipped) in [("add listener", 1), ("create tap", 0), ("read tap uid", 0), ("create aggregate", 0),
                         ("create proc", 0), ("start", 0)] {
    test("setup failure releases partial state: \(stage)") {
        let rig = Rig()
        hal.fail(stage, after: skipped)
        rig.session.start(); rig.settle()
        expect(rig.session.finished && rig.session.problem != nil && rig.finishes == 1 && !rig.everEngaged)
        expect(hal.holds.isEmpty, "left \(hal.holds)")
    }
}

let rejections: [(String, () -> Void)] = [
    ("unsupported output format", { hal.outputFormat.mBitsPerChannel = 16 }),
    ("tap format differs from the output", { hal.tapFormat.mSampleRate = 44100 }),
    ("route has an extra input stream", { hal.aggregateInputs = [201, 203] }),
    ("default output changes during setup", { hal.hooks["create aggregate"] = { hal.defaultOutput = FakeHAL.otherOutput } }),
    ("route never becomes ready", { hal.aggregateAlive = false }),
]
for (name, arrange) in rejections {
    test("rejected safely: \(name)") {
        let rig = Rig()
        arrange()
        rig.session.start(); rig.settle()
        expect(rig.session.finished && rig.session.problem != nil && !rig.everEngaged && rig.finishes == 1)
        expect(!hal.calls.contains("create proc"), "a callback was created for a rejected route")
        expect(hal.holds.isEmpty, "left \(hal.holds)")
    }
}

for (name, arrange) in [("own process missing", { hal.ownProcess = 0 }), ("duplex output", { hal.duplex = true })]
    as [(String, () -> Void)] {
    test("rejected before any tap: \(name)") {
        let rig = Rig()
        arrange()
        rig.session.start(); rig.settle()
        expect(rig.session.finished && rig.session.problem != nil && rig.finishes == 1)
        expect(!hal.calls.contains("create tap"), "a tap was created")
        if name == "duplex output" { expect(!hal.calls.contains("add listener"), "a duplex output was observed") }
        expect(hal.holds.isEmpty, "left \(hal.holds)")
    }
}

test("callback state allocation failure finishes without HAL calls") {
    let rig = Rig()
    FakeDSP.failNext = true
    rig.session.start()
    expect(rig.session.finished && rig.session.problem != nil && rig.finishes == 1 && hal.calls.isEmpty)
    let never = Rig()
    never.session.stop()
    expect(never.session.finished && never.finishes == 1 && hal.calls.isEmpty, "a never-started stop touched the HAL")
}

// --- Observers and buffer layout

test("output change during setup releases before engaging") {
    let rig = Rig()
    rig.session.start(); rig.settle()
    hal.fire(kAudioDevicePropertyDeviceIsAlive); rig.settle()
    expect(rig.session.finished && rig.session.problem != nil && !rig.everEngaged && hal.holds.isEmpty)
    expect(!rig.session.unavailable, "a device change during setup must allow a new attempt")
}

for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate, kAudioStreamPropertyVirtualFormat] {
    test("output observer while muffling releases the route: \(selector)") {
        let rig = Rig()
        rig.activate()
        guard let stale = hal.listeners.first(where: { $0.selector == selector }) else { expect(false, "not observed"); return }
        hal.fire(selector); rig.settle()
        expect(rig.session.finished && rig.session.problem != nil && rig.finishes == 1 && hal.holds.isEmpty)
        let count = rig.changes.count
        hal.deliver(stale); rig.settle() // A change already in flight when the listener was removed.
        expect(rig.changes.count == count, "a stale observer changed a finished session")
    }
}

test("malformed callback buffers emit silence and release the route") {
    let rig = Rig()
    rig.activate()
    let out = hal.render(malformed: true)
    expect(out.allSatisfy { $0 == 0 }, "malformed buffers were not silenced")
    rig.session.tick(); rig.settle()
    expect(rig.session.finished && rig.session.problem != nil && hal.holds.isEmpty)
}

// --- Release failures and held work

for (stage, held) in [("remove listener", ["listener"]), ("stop", ["running", "proc", "aggregate", "tap"]),
                      ("destroy proc", ["proc", "aggregate", "tap"]), ("destroy aggregate", ["aggregate", "tap"]),
                      ("destroy tap", ["tap"])] as [(String, Set<String>)] {
    test("release failure retains ownership until an explicit retry: \(stage)") {
        let live = FakeDSP.live
        let rig = Rig()
        rig.activate()
        for _ in 0..<80 { hal.render() }
        hal.fail(stage)
        rig.session.stop(); rig.settle()
        expect(rig.session.phase == .fault && !rig.session.finished && !rig.session.engaged && rig.session.problem != nil)
        expect(hal.holds == held, "holds \(hal.holds), expected \(held)")
        expect(FakeDSP.live == live + 1, "callback state freed while still owned")
        if hal.running {
            var out: [Float] = []
            for _ in 0..<200 { out = hal.render() }
            expect(out.allSatisfy { $0 == 0.2 }, "a surviving callback did not return to exact passthrough")
        }
        let count = rig.changes.count
        FakeClock.now += 5; rig.session.tick()
        hal.fire(kAudioDevicePropertyDeviceIsAlive); rig.settle()
        expect(rig.changes.count == count, "a faulted session changed without a retry")
        rig.session.stop(); rig.settle()
        expect(rig.session.finished && rig.finishes == 1 && hal.holds.isEmpty, "retry left \(hal.holds)")
        expect(FakeDSP.live == live)
        expect(rig.session.problem == nil, "successful retry kept a stale cleanup warning")
    }
}

test("held setup: deadline reports once, keeps state, late completion is authoritative") {
    let live = FakeDSP.live
    let rig = Rig()
    rig.session.start()  // The worker is held: setup is stuck in a HAL call.
    FakeClock.now += 14.9; rig.session.tick()
    expect(rig.session.phase == .starting && rig.changes.isEmpty)
    FakeClock.now += 0.2; rig.session.tick()
    expect(rig.session.phase == .cleaning && rig.session.problem != nil && rig.changes.count == 1)
    FakeClock.now += 2.1; rig.session.tick(); rig.session.tick()
    FakeClock.now += 30; rig.session.tick()
    expect(rig.changes.count == 2 && rig.session.problem != nil, "release deadline reported \(rig.changes.count - 1) times")
    expect(!rig.session.finished && FakeDSP.live == live + 1, "state dropped while the worker was held")
    rig.settle()
    expect(rig.session.finished && rig.finishes == 1 && hal.holds.isEmpty, "late completion left \(hal.holds)")
    expect(!hal.calls.contains("create tap"), "cancelled setup created a tap")
}

for lateFailure in [false, true] {
    test("held release: deadline reports once, keeps the route, late \(lateFailure ? "failure" : "success") is authoritative") {
        let live = FakeDSP.live
        let rig = Rig()
        rig.activate()
        rig.session.stop()  // The worker is held: release is stuck in a HAL call.
        let before = rig.changes.count
        FakeClock.now += 1.9; rig.session.tick()
        expect(rig.changes.count == before)
        FakeClock.now += 0.2; rig.session.tick(); rig.session.tick()
        FakeClock.now += 30; rig.session.tick()
        expect(rig.changes.count == before + 1 && rig.session.problem != nil, "reported \(rig.changes.count - before) times")
        expect(rig.session.phase == .cleaning && !rig.session.finished && hal.holds == everything)
        expect(FakeDSP.live == live + 1 && hal.render().count == 512, "route state dropped while the worker was held")
        if lateFailure { hal.fail("destroy aggregate") }
        rig.settle()
        if lateFailure {
            expect(rig.session.phase == .fault && !rig.session.finished && hal.holds == ["aggregate", "tap"])
            rig.session.stop(); rig.settle()
        }
        expect(rig.session.finished && rig.finishes == 1 && hal.holds.isEmpty, "left \(hal.holds)")
    }
}

test("reused aggregate ID is never stopped or destroyed") {
    for reused in [true, false] {
        let rig = Rig()
        rig.activate()
        hal.serverRemovedRoute(reused: reused)
        let mark = hal.calls.count
        rig.session.stop(); rig.settle()
        let after = hal.calls[mark...]
        expect(!after.contains("stop") && !after.contains("destroy proc") && !after.contains("destroy aggregate"),
               "touched a route Sigá no longer owns (reused: \(reused))")
        expect(rig.session.finished && hal.holds.isEmpty, "left \(hal.holds)")
        if reused { expect(hal.aggregateUID == "another-owner", "another client's route was changed") }
    }
}

// --- Repetition

test("100 mixed cycles leave no handles, listeners, queued work or callback state") {
    let live = FakeDSP.live
    for cycle in 0..<100 {
        weak var released: MuffleSession?
        do {
            let rig = Rig()
            released = rig.session
            switch cycle % 4 {
            case 0: rig.activate(); rig.finishReturn()
            case 1: hal.hooks["create aggregate"] = { rig.session.stop() }; rig.session.start()
            case 2: hal.fail("create proc"); rig.session.start()
            default: rig.activate(); hal.fail("destroy proc"); rig.session.stop(); rig.settle(); rig.session.stop()
            }
            rig.settle()
            expect(rig.session.finished && rig.finishes == 1, "cycle \(cycle) did not finish exactly once")
            expect(rig.worker.pending.isEmpty && rig.control.pending.isEmpty, "cycle \(cycle) left queued work")
        }
        expect(released == nil, "cycle \(cycle) retained its session")
        expect(hal.holds.isEmpty, "cycle \(cycle) left \(hal.holds)")
        FakeClock.now += 3
    }
    expect(FakeDSP.live == live && hal.listeners.isEmpty && hal.hooks.isEmpty)
}

print("SUMMARY: \(passed) passed, \(failed) failed (deterministic fault tests; a real worker hang in Core Audio is not reproduced)")
exit(failed == 0 ? 0 : 1)
