/* Linked only by listeners.swift: simulate the SDK's exact block identity requirement. */
#include "../MuffleDSP.h"
#include <Block.h>
#include <assert.h>
static AudioObjectPropertyListenerBlock registered;
static dispatch_queue_t registeredQueue;
OSStatus AudioObjectAddPropertyListenerBlock(AudioObjectID object, const AudioObjectPropertyAddress *address,
                                             dispatch_queue_t queue, AudioObjectPropertyListenerBlock listener) {
    assert(object == 123 && address->mSelector == kAudioObjectPropertyName && !registered);
    registered = Block_copy(listener); registeredQueue = queue;
    listener(1, address);
    return noErr;
}
OSStatus AudioObjectRemovePropertyListenerBlock(AudioObjectID object, const AudioObjectPropertyAddress *address,
                                                dispatch_queue_t queue, AudioObjectPropertyListenerBlock listener) {
    assert(object == 123 && address->mSelector == kAudioObjectPropertyName);
    assert(registered && registered == listener && queue == registeredQueue);
    Block_release(registered); registered = NULL;
    return noErr;
}
