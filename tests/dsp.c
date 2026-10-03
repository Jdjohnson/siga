#include "../MuffleDSP.h"
#include <assert.h>
#include <math.h>
#include <float.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

enum { frames = 256 };
typedef struct { UInt32 count; AudioBuffer buffers[2]; } Buffers;
static AudioTimeStamp stamp;
static float input[2][frames * 2], output[2][frames * 2];
static unsigned checks;
#define REQUIRE(condition) do { checks++; if (!(condition)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); return 1; } } while (0)

static Buffers buffers(float values[2][frames * 2], unsigned channels, bool planar) {
    Buffers b = { .count = planar ? channels : 1 };
    for (unsigned i = 0; i < b.count; i++) {
        unsigned per = planar ? 1 : channels;
        b.buffers[i] = (AudioBuffer){ .mNumberChannels = per, .mDataByteSize = frames * per * sizeof(float), .mData = values[i] };
    }
    return b;
}
static void render(MuffleDSP *d, Buffers *in, Buffers *out) {
    MuffleRender(0, &stamp, (AudioBufferList *)in, &stamp, (AudioBufferList *)out, &stamp, d);
}
static double response(double rate, double hz) {
    MuffleDSP *d = MuffleDSPCreate(); assert(d);
    assert(MuffleDSPConfigure(d, rate, 2));
    MuffleDSPSetPercent(d, 100); MuffleDSPSetEngaged(d, true);
    Buffers in = buffers(input, 2, false), out = buffers(output, 2, false);
    double a = 0, b = 0;
    for (unsigned block = 0; block < 500; block++) {
        for (unsigned i = 0; i < frames; i++) {
            float sample = (float)(0.5 * sin(2 * 3.141592653589793 * hz * (block * frames + i) / rate));
            input[0][2 * i] = sample; input[0][2 * i + 1] = 0;
        }
        render(d, &in, &out);
        if (block > 250) for (unsigned i = 0; i < frames; i++) {
            a += input[0][2 * i] * input[0][2 * i];
            b += output[0][2 * i] * output[0][2 * i];
            assert(output[0][2 * i + 1] == 0); // Channel isolation.
        }
    }
    assert(!MuffleDSPFault(d)); MuffleDSPDestroy(d);
    return sqrt(b / a);
}
int main(void) {
    for (unsigned channels = 1; channels <= 2; channels++) {
        for (unsigned planarIn = 0; planarIn <= 1; planarIn++) {
            for (unsigned planarOut = 0; planarOut <= 1; planarOut++) {
                MuffleDSP *d = MuffleDSPCreate(); REQUIRE(d);
                REQUIRE(MuffleDSPConfigure(d, 48000, channels));
                MuffleDSPSetPercent(d, 30);
                Buffers in = buffers(input, channels, planarIn), out = buffers(output, channels, planarOut);
                for (unsigned f = 0; f < frames; f++) for (unsigned c = 0; c < channels; c++)
                    input[planarIn ? c : 0][planarIn ? f : f * channels + c] = (float)sin(f + c * 37.0) * 0.8f;
                render(d, &in, &out);
                for (unsigned f = 0; f < frames; f++) for (unsigned c = 0; c < channels; c++)
                    REQUIRE(input[planarIn ? c : 0][planarIn ? f : f * channels + c] == output[planarOut ? c : 0][planarOut ? f : f * channels + c]);
                REQUIRE(!MuffleDSPFault(d)); MuffleDSPDestroy(d);
            }
        }
    }
    for (unsigned r = 0; r < 2; r++) {
        const double rate = r ? 48000 : 44100;
        const double bass = response(rate, 100), cutoff = response(rate, 1000), treble = response(rate, 8000);
        REQUIRE(bass > 0.999 && bass < 1.001);
        REQUIRE(cutoff > 0.700 && cutoff < 0.715);
        REQUIRE(treble < 0.02);
        printf("Frequency response %.0f Hz: 100 Hz %.6f; 1 kHz %.6f; 8 kHz %.6f\n", rate, bass, cutoff, treble);
    }
    MuffleDSP *d = MuffleDSPCreate(); REQUIRE(d);
    REQUIRE(!MuffleDSPConfigure(d, 96001, 2)); REQUIRE(!MuffleDSPConfigure(d, 48000, 6));
    REQUIRE(MuffleDSPConfigure(d, 48000, 2));
    MuffleDSPSetPercent(d, 30); MuffleDSPSetEngaged(d, true);
    Buffers in = buffers(input, 2, false), out = buffers(output, 2, false);
    for (unsigned i = 0; i < frames * 2; i++) input[0][i] = 0.2f;
    for (unsigned i = 0; i < 80; i++) render(d, &in, &out);
    REQUIRE(fabs(output[0][frames * 2 - 1] - 0.06) < 0.00001);
    MuffleDSPSetEngaged(d, false);
    for (unsigned i = 0; i < 20; i++) render(d, &in, &out);
    float previous = output[0][frames * 2 - 1];
    MuffleDSPSetEngaged(d, true); render(d, &in, &out);
    REQUIRE(fabs(output[0][0] - previous) < 0.0001);
    REQUIRE(!MuffleDSPDry(d));
    MuffleDSPSetEngaged(d, false);
    for (unsigned i = 0; i < 170; i++) render(d, &in, &out);
    REQUIRE(MuffleDSPDry(d)); REQUIRE(output[0][frames * 2 - 1] == input[0][frames * 2 - 1]);
    MuffleDSPSetPercent(d, 0); MuffleDSPSetEngaged(d, true);
    for (unsigned i = 0; i < 80; i++) render(d, &in, &out);
    REQUIRE(output[0][frames * 2 - 1] == 0);
    MuffleDSPSetPercent(d, 100);
    previous = output[0][frames * 2 - 1]; render(d, &in, &out);
    REQUIRE(fabs(output[0][0] - previous) < 0.0001);
    for (unsigned i = 0; i < 80; i++) render(d, &in, &out);
    REQUIRE(fabs(output[0][frames * 2 - 1] - 0.2) < 0.00001);
    memset(input, 0, sizeof(input));
    for (unsigned i = 0; i < 5000; i++) render(d, &in, &out);
    REQUIRE(output[0][0] == 0); REQUIRE(!MuffleDSPFault(d)); // Silence is legitimate.
    MuffleDSPDestroy(d);

    // Invalid layouts and nonfinite samples must not read past buffers or replay stale output.
    for (unsigned fault = 0; fault < 3; fault++) {
        d = MuffleDSPCreate(); REQUIRE(d); REQUIRE(MuffleDSPConfigure(d, 48000, 2));
        in = buffers(input, 2, false); out = buffers(output, 2, false);
        memset(input, 0, sizeof(input));
        for (unsigned i = 0; i < frames * 2; i++) output[0][i] = 0.9f;
        if (fault == 0) in.buffers[0].mData = NULL;
        if (fault == 1) in.buffers[0].mNumberChannels = 1;
        if (fault == 2) in.buffers[0].mDataByteSize -= 8;
        render(d, &in, &out); REQUIRE(MuffleDSPFault(d));
        for (unsigned i = 0; i < frames * 2; i++) REQUIRE(output[0][i] == 0);
        MuffleDSPDestroy(d);
    }
    // Bad samples and values that overflow Float32 recover on the next finite sample.
    for (unsigned bad = 0; bad < 3; bad++) {
        d = MuffleDSPCreate(); REQUIRE(d); REQUIRE(MuffleDSPConfigure(d, 48000, 2));
        in = buffers(input, 2, false); out = buffers(output, 2, false);
        MuffleDSPSetEngaged(d, true);
        for (unsigned i = 0; i < frames * 2; i++) input[0][i] = 0.25f;
        for (unsigned i = 0; i < 100; i++) render(d, &in, &out);
        input[0][13] = bad == 0 ? NAN : bad == 1 ? INFINITY : FLT_MAX;
        render(d, &in, &out);
        for (unsigned i = 0; i < frames * 2; i++) REQUIRE(isfinite(output[0][i]));
        REQUIRE(!MuffleDSPFault(d));
        input[0][13] = 0.25f;
        for (unsigned i = 0; i < 100; i++) render(d, &in, &out);
        REQUIRE(fabs(output[0][frames * 2 - 1] - 0.25) < 0.00001);
        MuffleDSPDestroy(d);
    }
    // Every accepted rate is stable; the endpoints have ample Nyquist margin for 1 kHz.
    for (unsigned rate = 8000; rate <= 96000; rate += 1000) {
        REQUIRE(response(rate, 100) > 0.998);
        const double cutoff = response(rate, 1000); REQUIRE(cutoff > 0.700 && cutoff < 0.715);
    }
    in = buffers(input, 2, false); out = buffers(output, 2, false); memset(input, 0, sizeof(input));
    for (unsigned i = 0; i < 10000; i++) {
        d = MuffleDSPCreate(); REQUIRE(d); REQUIRE(MuffleDSPConfigure(d, 48000, 2));
        MuffleDSPSetPercent(d, 30); MuffleDSPSetEngaged(d, true);
        render(d, &in, &out); MuffleDSPCancel(d); REQUIRE(MuffleDSPCancelled(d)); MuffleDSPDestroy(d);
    }
    // CPU-only DSP benchmark, not an app or coreaudiod performance measurement.
    d = MuffleDSPCreate(); REQUIRE(d); REQUIRE(MuffleDSPConfigure(d, 48000, 2));
    MuffleDSPSetPercent(d, 30); MuffleDSPSetEngaged(d, true);
    for (unsigned i = 0; i < frames * 2; i++) input[0][i] = (float)sin(i * 0.15) * 0.5f;
    const unsigned blocks = 200000;
    const clock_t began = clock();
    for (unsigned i = 0; i < blocks; i++) render(d, &in, &out);
    const double cpu = (double)(clock() - began) / CLOCKS_PER_SEC;
    printf("DSP-only CPU: %.6f seconds / %.3f audio seconds = %.5f%% of one core\n", cpu, (double)blocks * frames / 48000, cpu / ((double)blocks * frames / 48000) * 100);
    MuffleDSPDestroy(d);
    printf("PASS: %u DSP assertions; 10,000 offline allocation/render/free cycles\n", checks);
    return 0;
}
