# Muffle preview: validation and rollback

This feature is isolated on `codex/siga-muffle`, based on main `224854620d8bb15c14aca7207cfd0dadf77a6b2c`. Lower volume remains the default. No installed app or public download has been replaced.

## Implementation

The existing controller chooses one volume owner. Lower uses the existing hardware-volume path. Muffle owns a temporary private process tap and aggregate device on the current output, with a C callback applying one fixed 1 kHz low-pass filter and the existing slider. It never writes hardware volume. Switching effects waits for the old owner to release.

The route excludes this process, validates stream layouts, and retains handles after a cleanup failure so Restore can retry. The callback allocates nothing, takes no locks, and makes no system calls. Healthy silence is allowed. The existing 100 ms detection timer supervises a live route; no additional Muffle timer or callback remains after cleanup. Return fades can reverse without rebuilding the route.

## Verified so far

- `zsh tests/run.sh`: 387 controller assertions, 215 app assertions, 49 actual-session scenarios using a simulated HAL, and 36,389 C processor checks pass.
- C processor AddressSanitizer/UndefinedBehaviorSanitizer and session AddressSanitizer runs pass. The coupled controller/session harness passed ten failure-path scenarios (115 assertions) and 10,000 accelerated lifecycle cycles with both Swift and C under AddressSanitizer (80,115 assertions). Those checks use a simulated HAL, not physical routing.
- Route listeners retain one copied C block so registration and removal use the same identity. A real macOS property-change probe reproduced removal failure with the old Swift closure and confirmed removal with the fix; the regression suite also checks block identity and capture release.
- The coupled tests reproduce and verify recovery when Lower fallback is unavailable, an output changes during failed setup, and the user reselects Muffle while cleanup is pending. A further regression verifies the unavailable-fallback explanation stays bounded across repeated dictations.
- A signed transparent routing probe on MacBook Pro Speakers, 48 kHz stereo, received 463 callbacks and preserved every observed input sample exactly, then released its route. This proves callback equality, not an acoustic listening result.
- A signed probe of the real session and processor passed 0/30/100%, interrupted return, normal return, explicit stop, and cancellation during setup. It completed three sessions in 9.16 seconds. With a generated 220 Hz + 4 kHz tone, measured output/input RMS was 0 at 0%, 0.212 at 30%, and 0.707 at 100%, as expected for the fixed filter.
- Final product source completed **1,000 physical cycles over 7,290.56 seconds**. DSP contexts, Muffle listener-call counts and device/tap inventories returned to baseline before each new route; 20 temporary inventory differences all cleared within 101 ms. Final footprint was 15.83 MiB, up 1.44 MiB from cycle 100; highest sampled footprint was 16.03 MiB. Across 176,549 callbacks, processor p99 was below 17.6 microseconds with no measured deadline overrun or timestamp gap. Startup p95 was **239.93 ms**, above the proposed 150 ms target.
- A diagnostic completed 200 physical cycles in 522.12 seconds with no persistent route-resource difference. All four transient list entries cleared within 101 ms. Final app footprint was 15.00 MiB; there was no observed timestamp gap or processor overrun in 35,357 callbacks. The earlier failed 100-cycle run remains a failed result.
- The native app and real controller passed 30 physical routing cycles, an eight-second playback pause/resume, Restore, Disable and normal App termination. Only dictation discovery/input was synthetic. This exposed and fixed a real error: callback absence during paused playback must not latch Muffle unavailable. The run completed in 55.22 seconds.
- A later live timing run completed 100 physical cycles in 265.96 seconds with no leftover audio objects. Across 17,716 callbacks, processor p99 was below 18 microseconds with no observed overrun; the 10% callback budget was 1,066.7 microseconds. Startup p95 was 204.20 ms, above the proposed 150 ms target. Scheduled host-time separation was 23.333 ms; acoustic latency remains unmeasured.
- `zsh tests/controls/run.sh`: 96 assertions pass against the real native controls. Labels and the spoken slider percentage now attach to the accessible cells, preserving the numeric value.
- Both native Settings layouts were rendered from the real AppKit source and inspected in light and dark appearances. Interactive keyboard and VoiceOver checks remain open.
- The release-signed executable is 217,504 bytes with strict signature verification. **The 200,000-byte build gate still fails and remains unchanged.**

All live results above used macOS 27.2 (26B5091g). Instrumented tests save counts and measurements, never audio samples. They do not substitute for dictation with a real microphone.

## Open release gates

- Resolve the executable-size budget without removing reliability checks or hiding code in another binary.
- Resolve the combined CPU and startup targets. Three ten-minute windows compared source-built original release Lower at 100%, current Muffle at 30%, and original release Lower at 100%. Against the mean baseline, Muffle added 0.250 percentage points in the app and 1.084 in coreaudiod: **1.334% of one core combined**, above the proposed 1% target. Final physical endurance measured startup p95 **239.93 ms** versus 150 ms. In the steady comparison, the app used 14.28 MiB at the end of Muffle and 13.58 MiB after cleanup; its lifetime peak was 14.72 MiB. All windows include the same test-only microphone-use guard; other audio clients limit attribution. coreaudiod resident memory was recorded, but its protected physical-footprint and wakeup counters were unavailable.
- Verify the everyday headphone/microphone pairing, actual dictation, listening quality, volume keys, device changes, disconnects, sleep/wake, permission denial/revocation, and the final release identity.
- Verify interactive accessibility.
- Demonstrate recovery from a genuinely blocked Core Audio call. Deadlines report unresponsiveness but cannot cancel a system call. A surviving callback returns to unfiltered playback when cleanup begins; successful cleanup still needs the OS call to return.
- Complete 14 days of ordinary use in the same process. The planned 1,000 physical cycles over at least two hours have passed. The test retains per-cycle measurements, and its bounded memory growth does not establish a flat ordinary-use trend. An earlier 400-cycle run was stopped to repair listener removal; a later 100-cycle run failed on an extra device entry whose identity was lost. Both remain recorded. The final run captured one temporary device ID matching the just-released aggregate; this supports that particular settling observation without retroactively identifying the earlier entry. Accelerated simulation is not elapsed-time evidence.

Keep the PR draft while these gates remain open. No notarized release is produced from this branch yet.

## Rollback

Keep this feature in one squash commit. To remove it after merging, create a new branch from current main, revert that one commit with `git revert`, and submit the revert as a normal PR. Do not reset or force-push main. Run the restored regression suite and build/sign checks, then check Lower volume, Restore and Quit on real hardware.

For a local trial, quit the candidate and confirm its process has ended before restoring the retained signed build 18 app. The old app ignores the additive `audioEffect` preference, so no preference migration or deletion is required. If a release has been published, distribute the reverted code under a new, higher build number and verify the downloaded artifact.
