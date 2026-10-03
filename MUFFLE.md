# Muffle preview: validation and rollback

This feature is isolated on `codex/siga-muffle`, based on main `224854620d8bb15c14aca7207cfd0dadf77a6b2c`. Lower volume remains the default. No installed app or public download has been replaced.

## Implementation

The existing controller chooses one volume owner. Lower uses the existing hardware-volume path. Muffle owns a temporary private process tap and aggregate device on the current output, with a C callback applying one fixed 1 kHz low-pass filter and the existing slider. It never writes hardware volume. Switching effects waits for the old owner to release.

The route excludes this process, validates stream layouts, and retains handles after a cleanup failure so Restore can retry. The callback allocates nothing, takes no locks, and makes no system calls. Healthy silence is allowed. The existing 100 ms detection timer supervises a live route; no additional Muffle timer or callback remains after cleanup. Return fades can reverse without rebuilding the route.

## Verified so far

- `zsh tests/run.sh`: 387 controller assertions, 215 app assertions, 49 actual-session scenarios using a simulated HAL, and 36,389 C processor checks pass.
- C processor AddressSanitizer/UndefinedBehaviorSanitizer and session AddressSanitizer runs pass.
- A signed transparent routing probe on MacBook Pro Speakers, 48 kHz stereo, received 463 callbacks and preserved every observed input sample exactly, then released its route. This proves callback equality, not an acoustic listening result.
- A signed probe of the real session and processor passed 0/30/100%, interrupted return, normal return, explicit stop, and cancellation during setup. It completed three sessions in 9.16 seconds. With a generated 220 Hz + 4 kHz tone, measured output/input RMS was 0 at 0%, 0.212 at 30%, and 0.707 at 100%, as expected for the fixed filter.
- The native app and real controller passed 30 physical routing cycles, an eight-second playback pause/resume, Restore, Disable and normal App termination. Only dictation discovery/input was synthetic. This exposed and fixed a real error: callback absence during paused playback must not latch Muffle unavailable. The run completed in 55.22 seconds.
- `zsh tests/controls/run.sh`: 96 assertions pass against the real native controls. Labels and the spoken slider percentage now attach to the accessible cells, preserving the numeric value.
- Both native Settings layouts were rendered from the real AppKit source and inspected in light and dark appearances. Interactive keyboard and VoiceOver checks remain open.
- The release-signed executable is 217,456 bytes with strict signature verification. **The 200,000-byte build gate still fails and remains unchanged.**

All live results above used macOS 27.2 (26B5091g). Instrumented tests save counts and measurements, never audio samples. They do not substitute for dictation with a real microphone.

## Open release gates

- Resolve the executable-size budget without removing reliability checks or hiding code in another binary.
- Complete matched app/coreaudiod CPU, wakeup, memory and latency measurements. The native-app smoke test measured 0.45–0.48% of one core during Muffle and 13.9 MiB physical footprint after 30 cycles. A matched 30-second comparison measured added app CPU of about 0.29 percentage points and added coreaudiod CPU of about 1.60 points, each relative to one core. That exceeds the proposed 1% combined target. Core Audio also showed substantial activity during rapid route creation; the combined performance gate remains open. These short windows are not a passing endurance result.
- Verify the everyday headphone/microphone pairing, actual dictation, listening quality, volume keys, device changes, disconnects, sleep/wake, permission denial/revocation, and the final release identity.
- Verify interactive accessibility.
- Demonstrate recovery from a genuinely blocked Core Audio call. Deadlines report unresponsiveness but cannot cancel a system call. A surviving callback returns to unfiltered playback when cleanup begins; successful cleanup still needs the OS call to return.
- Complete the planned long-cycle test and 14 days of ordinary use in the same process. Accelerated simulation is not elapsed-time evidence.

Keep the PR draft while these gates remain open. No notarized release is produced from this branch yet.

## Rollback

Keep this feature in one squash commit. To remove it after merging, create a new branch from current main, revert that one commit with `git revert`, and submit the revert as a normal PR. Do not reset or force-push main. Run the restored regression suite and build/sign checks, then check Lower volume, Restore and Quit on real hardware.

For a local trial, quit the candidate and confirm its process has ended before restoring the retained signed build 18 app. The old app ignores the additive `audioEffect` preference, so no preference migration or deletion is required. If a release has been published, distribute the reverted code under a new, higher build number and verify the downloaded artifact.
