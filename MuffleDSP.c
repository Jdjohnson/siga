#include "MuffleDSP.h"
#include <Block.h>
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

MuffleListener *MuffleListenerCreate(AudioObjectPropertyListenerBlock block) {
    return (MuffleListener *)Block_copy(block);
}
void MuffleListenerDestroy(MuffleListener *listener) {
    Block_release((AudioObjectPropertyListenerBlock)listener);
}
OSStatus MuffleListenerAdd(AudioObjectID object, const AudioObjectPropertyAddress *address,
                          dispatch_queue_t queue, MuffleListener *listener) {
    return AudioObjectAddPropertyListenerBlock(object, address, queue, (AudioObjectPropertyListenerBlock)listener);
}
OSStatus MuffleListenerRemove(AudioObjectID object, const AudioObjectPropertyAddress *address,
                             dispatch_queue_t queue, MuffleListener *listener) {
    return AudioObjectRemovePropertyListenerBlock(object, address, queue, (AudioObjectPropertyListenerBlock)listener);
}

/* The IOProc may never wait on a lock, so the atomic types it uses must be lock-free. */
_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "atomic_bool must be lock-free");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "atomic_uint must be lock-free");

/* Control writes percent, engaged and cancelled; the IOProc writes callbacks, dry and fault.
   Configure sets the plain fields before the IOProc exists; after that only the IOProc touches them. */
struct MuffleDSP {
    atomic_uint percent, callbacks;
    atomic_bool engaged, cancelled, dry, fault;
    unsigned channels;
    double rate, b0, b1, b2, a1, a2, z1[2], z2[2];
    double blend, from, to, gain, gainStep;
    uint64_t rampFrames, rampPosition;
};

MuffleDSP *MuffleDSPCreate(void) {
    MuffleDSP *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    atomic_init(&d->percent, 100); atomic_init(&d->callbacks, 0);
    atomic_init(&d->engaged, false); atomic_init(&d->cancelled, false);
    atomic_init(&d->dry, true); atomic_init(&d->fault, false);
    return d;
}
void MuffleDSPDestroy(MuffleDSP *d) { free(d); }
bool MuffleDSPConfigure(MuffleDSP *d, double rate, unsigned channels) {
    if (!(rate >= 8000 && rate <= 96000) || channels < 1 || channels > 2) return false;
    d->rate = rate; d->channels = channels; d->gain = 1;
    d->gainStep = 1.0 / (rate * 0.05); /* A full-range level change takes 50 ms. */
    /* Fixed 1 kHz Butterworth low-pass for this rate, unity gain at DC. */
    const double k = tan(3.14159265358979323846 * 1000.0 / rate);
    const double n = 1.0 / (1.0 + 1.4142135623730951 * k + k * k);
    d->b0 = k * k * n; d->b1 = 2 * d->b0; d->b2 = d->b0;
    d->a1 = 2 * (k * k - 1) * n;
    d->a2 = (1 - 1.4142135623730951 * k + k * k) * n;
    return true;
}
void MuffleDSPSetPercent(MuffleDSP *d, unsigned percent) {
    atomic_store_explicit(&d->percent, percent > 100 ? 100 : percent, memory_order_relaxed);
}
void MuffleDSPSetEngaged(MuffleDSP *d, bool engaged) {
    /* Clear dry before engaging, so control never mistakes a reversal for a finished return. */
    if (engaged) atomic_store_explicit(&d->dry, false, memory_order_relaxed);
    atomic_store_explicit(&d->engaged, engaged, memory_order_release);
}
void MuffleDSPCancel(MuffleDSP *d) { atomic_store(&d->cancelled, true); }
bool MuffleDSPCancelled(const MuffleDSP *d) { return atomic_load(&d->cancelled); }
bool MuffleDSPDry(const MuffleDSP *d) { return atomic_load_explicit(&d->dry, memory_order_acquire); }
bool MuffleDSPFault(const MuffleDSP *d) { return atomic_load(&d->fault); }
unsigned MuffleDSPCallbacks(const MuffleDSP *d) { return atomic_load_explicit(&d->callbacks, memory_order_relaxed); }

/* Mono, interleaved stereo, or planar stereo only. Checked every callback before any sample is read. */
static bool layout(const AudioBufferList *list, unsigned channels, UInt32 *frames) {
    if (!list || !list->mNumberBuffers || list->mNumberBuffers > 2) return false;
    if (list->mNumberBuffers != 1 && list->mNumberBuffers != channels) return false;
    const unsigned per = list->mNumberBuffers == 1 ? channels : 1;
    for (UInt32 b = 0; b < list->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &list->mBuffers[b];
        if (!buffer->mData || buffer->mNumberChannels != per ||
            buffer->mDataByteSize % (per * sizeof(float))) return false;
        const UInt32 count = buffer->mDataByteSize / (per * sizeof(float));
        if (!count || (b && count != *frames)) return false;
        *frames = count;
    }
    return true;
}
static void silence(AudioBufferList *output) {
    if (!output) return;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
}

/* Real-time path: no allocation, locks, logging, strings, or system calls. */
OSStatus MuffleRender(AudioObjectID device, const AudioTimeStamp *now,
                      const AudioBufferList *input, const AudioTimeStamp *inputTime,
                      AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    MuffleDSP *d = context;
    if (!d) { silence(output); return noErr; }
    atomic_fetch_add_explicit(&d->callbacks, 1, memory_order_relaxed);
    UInt32 frames = 0, outFrames = 0;
    /* A malformed buffer is fatal and sticky: silence until control releases the route. */
    if (atomic_load_explicit(&d->fault, memory_order_relaxed) || !d->channels ||
        !layout(input, d->channels, &frames) || !layout(output, d->channels, &outFrames) || frames != outFrames) {
        atomic_store_explicit(&d->fault, true, memory_order_relaxed);
        silence(output); return noErr;
    }
    const double gain = atomic_load_explicit(&d->percent, memory_order_relaxed) / 100.0;
    const double target = atomic_load_explicit(&d->engaged, memory_order_acquire) ? 1 : 0;
    if (target != d->to) {
        /* Smoothstep 400 ms in, 850 ms out, scaled by the distance left so reversals neither snap nor drag. */
        d->from = d->blend; d->to = target; d->rampPosition = 0;
        d->rampFrames = (uint64_t)(d->rate * fmax(0.15, (target ? 0.40 : 0.85) * fabs(target - d->blend)));
    }
    const bool packedIn = input->mNumberBuffers == 1, packedOut = output->mNumberBuffers == 1;
    for (UInt32 frame = 0; frame < frames; frame++) {
        if (d->rampPosition < d->rampFrames) {
            const double p = (double)++d->rampPosition / d->rampFrames;
            d->blend = d->from + (d->to - d->from) * p * p * (3 - 2 * p);
        } else d->blend = d->to;
        d->gain += fmax(-d->gainStep, fmin(d->gainStep, gain - d->gain));
        for (unsigned ch = 0; ch < d->channels; ch++) {
            const float *in = input->mBuffers[packedIn ? 0 : ch].mData;
            float *out = output->mBuffers[packedOut ? 0 : ch].mData;
            const double x = in[packedIn ? frame * d->channels + ch : frame];
            const double low = d->b0 * x + d->z1[ch];
            d->z1[ch] = d->b1 * x - d->a1 * low + d->z2[ch];
            d->z2[ch] = d->b2 * x - d->a2 * low;
            /* Fully disengaged output is the input itself, so a settled return is bit-exact. */
            float y = (float)(d->blend == 0 ? x : x + d->blend * (d->gain * low - x));
            /* A nonfinite sample would poison this channel's filter: restart it and emit silence. */
            if (!isfinite(y)) { d->z1[ch] = d->z2[ch] = 0; y = 0; }
            out[packedOut ? frame * d->channels + ch : frame] = y;
        }
    }
    /* Flush inaudible filter tails so silent input cannot produce denormal work. */
    for (unsigned ch = 0; ch < d->channels; ch++) {
        if (fabs(d->z1[ch]) < 1e-24) d->z1[ch] = 0;
        if (fabs(d->z2[ch]) < 1e-24) d->z2[ch] = 0;
    }
    atomic_store_explicit(&d->dry, d->blend == 0 && target == 0, memory_order_release);
    return noErr;
}
