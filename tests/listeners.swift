import Foundation
import CoreAudio

final class Owner { var calls = 0 }
let queue = DispatchQueue(label: "listener-test")
var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
weak var weakOwner: Owner?
func makeListener() -> OpaquePointer {
    let owner = Owner(); weakOwner = owner
    return MuffleListenerCreate { _, _ in owner.calls += 1 }!
}
let listener = makeListener()
precondition(weakOwner != nil, "copied block keeps its captures after the Swift call returns")
precondition(MuffleListenerAdd(123, &address, queue, listener) == noErr)
precondition(weakOwner?.calls == 1, "registered C block invokes the Swift callback")
precondition(MuffleListenerRemove(123, &address, queue, listener) == noErr)
MuffleListenerDestroy(listener)
precondition(weakOwner == nil, "removal and token destruction release the closure captures")
print("PASS: Swift listener retains one C block identity through registration and removal; captures released")
