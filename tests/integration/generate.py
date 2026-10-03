#!/usr/bin/env python3
"""Couple the current controller and session through the existing test doubles.

No audio API is called. HAL, dispatch, time and process discovery are simulated;
MuffleDSP.c is linked unchanged. Shared device identities let this harness catch
cross-owner writes and late completions that either unit suite alone can miss.
"""
from pathlib import Path
import re
here=Path(__file__).resolve().parent
repo=here.parent.parent
out=here.parent/'.build'
out.mkdir(exist_ok=True)
main=(repo/'main.swift').read_text();session=(repo/'MuffleSession.swift').read_text()
def extract(text, marker):
 start=text.index(marker);end=text.index('{',start)+1;depth=1
 while depth:depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
controller=extract(main,'final class Ducking')
core=main[main.index('let systemAudio'):main.index(controller)+len(controller)]
duck=(repo/'tests/ducking/parts/doubles.swift').read_text()
queues=duck[duck.index('struct FakeTime'):duck.index('// --- In-memory audio hardware table.')]
queues=queues.replace('final class DispatchQueue {','final class DispatchQueue {\n    static var made: [DispatchQueue] = []')
queues=queues.replace('self.label = label }','self.label = label; Self.made.append(self) }')
audio=duck[duck.index('enum FakeAudio'):duck.index('// Only MuffleSession is replaced')]
controllerCalls=sorted(set(re.findall(r'func (AudioObject\w+)\(',audio)))
for name in controllerCalls:audio=re.sub(r'\b'+name+r'\b','Controller'+name,audio)
audio=audio.replace('func proc_pidpath(', 'func FakeProcPidpath(')
muffle=(repo/'tests/muffle/parts/doubles.swift').read_text()
muffle=muffle[:muffle.index('// Work waits')]+muffle[muffle.index('enum FakeClock'):]
muffle='typealias FakeQueue = DispatchQueue\n'+muffle
hal=sorted(set(re.findall(r'func (FakeAudio\w+)\(',muffle)))
for name in hal:session=re.sub(r'\b'+name.removeprefix('Fake')+r'\b(?=\s*\()',name,session)
for name in controllerCalls:core=re.sub(r'\b'+name+r'\b(?=\s*\()', 'Controller'+name,core)
# Shared helpers use the route's actual IDs and formats; only hardware volume and dictation signals
# are delegated to the controller doubles. This prevents two disjoint audio inventories.
core=core.replace('ControllerAudioObjectGetPropertyData(', 'JoinedAudioGet(')
core=core.replace('ControllerAudioObjectGetPropertyDataSize(', 'FakeAudioObjectGetPropertyDataSize(')
core=core.replace('proc_pidpath(', 'FakeProcPidpath(')
for name,text in [('core',core),('session',session)]:
 text=text.replace('ProcessInfo.processInfo.systemUptime','FakeClock.now').replace('Thread.sleep(forTimeInterval:', 'FakeClock.sleep(forTimeInterval:')
 text=text.replace('MuffleDSPCreate(', 'FakeDSP.create(').replace('MuffleDSPDestroy(', 'FakeDSP.destroy(')
 if name=='core':core=text
 else:session=text
bridge='''
func JoinedAudioGet(_ id: AudioObjectID, _ a: UnsafePointer<AudioObjectPropertyAddress>, _ qs: UInt32,
                    _ q: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutableRawPointer) -> OSStatus {
    switch a.pointee.mSelector {
    case kAudioProcessPropertyPID, kAudioProcessPropertyIsRunningInput,
         kAudioDevicePropertyVolumeScalar, kAudioHardwarePropertyTranslateUIDToDevice:
        return ControllerAudioObjectGetPropertyData(id,a,qs,q,size,data)
    default: return FakeAudioObjectGetPropertyData(id,a,qs,q,size,data)
    }
}
'''
# Any lowered hardware write while a process tap still owns playback is a test failure.
audio=audio.replace('let value = data.load(as: Float32.self)', 'if hal.tapUID != nil { hal.misuse("hardware volume written while Muffle owns playback") }; let value = data.load(as: Float32.self)')
# Fail generation if a new product HAL call would bypass the doubles.
product=core+'\n'+session
sdk_types={'AudioObjectPropertyAddress','AudioObjectID','AudioDeviceID'}
leftovers=set(re.findall(r'(?<!\w)(Audio(?:Object|Hardware|Device)\w*)\s*\(',product))-sdk_types
if leftovers:
    raise SystemExit(f'Unmapped HAL calls: {sorted(leftovers)}')
for token in ['ProcessInfo.', 'Thread.', 'proc_pidpath(']:
    if token in product:
        raise SystemExit(f'Unmapped system call: {token}')
(out/'integration.swift').write_text('// Generated: simulated HAL, dispatch and clock; actual controller, session and DSP.\n'+ '\n'.join([queues,muffle,audio,bridge,core,session,(here/'tests.swift').read_text()]))
