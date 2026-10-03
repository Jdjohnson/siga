var checks=0, scenarios=0
func expect(_ condition:@autoclosure ()->Bool,_ reason:String) {
    checks+=1
    if !condition() { print("FAIL: \(reason)"); exit(1) }
}
func drain() {
    for _ in 0..<30 {
        var n=0
        for q in DispatchQueue.made {n+=q.drain();n+=q.drainDelayed()}
        if n==0 {return}
    }
    fatalError("Queue loop")
}
func engine() -> Ducking {
    expect(FakeDSP.live==0,"prior scenario released DSP")
    DispatchQueue.made=[.main]; DispatchQueue.main.reset();FakeTimer.created=[]
    hal=FakeHAL();FakeAudio.reset();FakeClock.now=1000
    FakeAudio.defaultOutput=FakeHAL.output
    FakeAudio.addDevice(FakeHAL.output,uid:"test-output",volume:0.8)
    FakeAudio.processes=[77:11];FakeAudio.inputRunning=[11:true]
    let e=Ducking(percent:30) {_ in};e.roots=["/Applications/Willow.app/"];e.muffleEnabled=true;e.start();drain()
    expect(e.muffle != nil && e.saved==nil,"real session starts as sole owner")
    return e
}
func activate(_ e:Ducking) {
    hal.render();e.poll?.handler?();drain()
    expect(e.muffle?.phase == .active,"first real callback activates Muffle")
}
func advance(_ e:Ducking,_ seconds:Double,render:Bool=true) {
    if render && hal.running {hal.render(frames:Int(seconds*48000))}
    FakeClock.now+=seconds;e.poll?.handler?();e.ramp?.handler?();drain()
}
func finish(_ e:Ducking) {
    var done=0;e.terminate {_ in done+=1};drain()
    expect(done==1,"termination completion exactly once")
    expect(e.muffle==nil && e.saved==nil && e.poll==nil,"termination releases owners and timer")
    expect(hal.holds.isEmpty && FakeDSP.live==0,"all route resources released")
    expect(hal.violations.isEmpty,"no cross-owner or lifecycle violations: \(hal.violations)")
    expect(FakeAudio.registered.isEmpty,"global listeners removed")
    scenarios+=1
}
// Actual Session synchronously re-enters the actual controller at start and release boundaries.
do {
 let e=engine();activate(e)
 e.manualRestore();expect(e.restoring,"manual restore waits for worker");drain()
 expect(e.muffle==nil && e.suppressed && e.saved==nil,"manual restore holds until input stops")
 expect(FakeAudio.writes.isEmpty,"Muffle never writes hardware on restore")
 FakeAudio.inputRunning[11]=false;e.readInput();FakeAudio.inputRunning[11]=true;e.readInput();drain();activate(e)
 finish(e)
}
do {
 let e=engine();activate(e)
 hal.fail("stop")
 var first=0;e.restore {_ in first+=1};drain()
 expect(first==1 && !e.restoring && e.muffle?.phase == .fault,"real release failure completes once with retained ownership")
 expect(e.saved==nil && e.poll==nil,"fault blocks Lower and stops polling")
 let samples=hal.render(frames:48000);expect(samples.suffix(128).allSatisfy {$0==0.2},"surviving callback returns to passthrough")
 e.manualRestore();drain()
 expect(e.muffle==nil && e.saved==nil && e.suppressed,"retry clears ownership without capturing volume")
 finish(e)
}
do {
 let e=engine();activate(e)
 hal.fail("destroy aggregate")
 e.setMuffle(false);drain()
 expect(e.muffle?.phase == .fault && e.saved==nil,"effect switch waits through cleanup failure")
 expect(FakeAudio.writes.isEmpty,"no double lowering after failed switch")
 e.manualRestore();drain();expect(e.muffle==nil && e.saved==nil,"retry releases before Lower resumes")
 FakeAudio.inputRunning[11]=false;e.readInput();FakeAudio.inputRunning[11]=true;e.readInput();advance(e,0.5)
 expect(e.saved != nil && FakeAudio.writes.count>0,"next dictation can use Lower")
 expect(abs((FakeAudio.volumes[FakeHAL.output]?[0] ?? -1)-0.24)<0.001,"Lower uses original hardware baseline")
 finish(e)
}
do {
 let e=engine();activate(e)
 e.setEnabled(false);expect(e.restoring && e.poll != nil,"Disable still supervises cleanup");drain()
 expect(!e.enabled && e.muffle==nil && e.poll==nil,"Disable finishes idle")
 e.setEnabled(true);drain();activate(e);finish(e)
}
do {
 let e=engine();activate(e)
 // Hold the worker while cleanup's deadline passes; late completion remains authoritative.
 e.manualRestore();FakeClock.now+=3;e.poll?.handler?()
 expect(e.muffle?.problem=="macOS audio isn’t responding" && e.restoring,"held worker reports deadline without false completion")
 expect(e.saved==nil,"Lower cannot take over from blocked release")
 drain();expect(e.muffle==nil && !e.restoring,"late cleanup resolves controller restore")
 finish(e)
}
do {
 let e=engine();activate(e)
 advance(e,0.5)
 FakeAudio.inputRunning[11]=false;e.readInput();let first=e.muffle
 advance(e,0.1);FakeAudio.inputRunning[11]=true;e.readInput();drain()
 expect(e.muffle === first && e.muffle?.phase == .active,"quick restart reverses same real session")
 expect(hal.calls.filter {$0=="create tap"}.count==1,"return reversal creates no second tap")
 finish(e)
}
print("PASS: \(scenarios) coupled controller/session scenarios, \(checks) assertions; simulated HAL with actual DSP")

// Optional repeat run: MUFFLE_ASAN=1 zsh tests/integration/run.sh 10000
let repetitions=CommandLine.arguments.count>1 ? Int(CommandLine.arguments[1]) : 0
guard let repetitions, (0...100000).contains(repetitions) else {fatalError("Expected 0...100000 repetitions")}
for cycle in 0..<repetitions {
    let e=engine();activate(e)
    switch cycle%5 {
    case 0: e.manualRestore();drain()
    case 1: e.setEnabled(false);drain()
    case 2:
        e.setPercent(cycle%101)
        FakeAudio.inputRunning[11]=false;e.readInput();advance(e,1)
    case 3:
        hal.fail("destroy aggregate");e.manualRestore();drain();e.manualRestore();drain()
    default: break
    }
    finish(e)
}
if repetitions>0 {print("PASS: \(repetitions) repeated full-controller cycles; \(checks) total assertions")}
