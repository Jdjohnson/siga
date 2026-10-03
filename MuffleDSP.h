#ifndef SIGA_MUFFLE_DSP_H
#define SIGA_MUFFLE_DSP_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

CF_ASSUME_NONNULL_BEGIN
/* Callback state. Control uses only the atomic setters and getters; MuffleRender owns the rest. */
typedef struct MuffleDSP MuffleDSP;
MuffleDSP * _Nullable MuffleDSPCreate(void);
void MuffleDSPDestroy(MuffleDSP *dsp); /* Only once no IOProc can reference it. */
bool MuffleDSPConfigure(MuffleDSP *dsp, double sampleRate, unsigned channels); /* Before the IOProc exists. */
void MuffleDSPSetPercent(MuffleDSP *dsp, unsigned percent);
void MuffleDSPSetEngaged(MuffleDSP *dsp, bool engaged);
void MuffleDSPCancel(MuffleDSP *dsp);
bool MuffleDSPCancelled(const MuffleDSP *dsp);
bool MuffleDSPDry(const MuffleDSP *dsp);
bool MuffleDSPFault(const MuffleDSP *dsp);
unsigned MuffleDSPCallbacks(const MuffleDSP *dsp); /* Wraps; compare only for change. */
OSStatus MuffleRender(AudioObjectID device, const AudioTimeStamp *now,
                      const AudioBufferList *input, const AudioTimeStamp *inputTime,
                      AudioBufferList *output, const AudioTimeStamp *outputTime,
                      void * _Nullable context);
CF_ASSUME_NONNULL_END
#endif
