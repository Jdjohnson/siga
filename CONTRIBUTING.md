# Contributing to Sigá

Sigá has one job: lower the volume while you dictate, then bring it back reliably. Small, focused changes are welcome.

Before adding a setting, dependency, background task, or new behavior, explain the problem it solves. The best change often removes work. Keep the app small and preserve its native menu-bar behavior.

## Working locally

Install Apple’s Command Line Tools and run `./build.sh` on an Apple Silicon Mac. Don’t replace a running copy until you’re ready to test it.

Describe the trigger, what happened, what should have happened, your macOS version, and which speakers or headphones you used when reporting a problem. Never include API keys, private recordings, or dictated text.

## Checking a change

For audio changes, check normal dictation, interrupted dictation, manual Restore, Disable, Quit, changing speakers or headphones, disconnect/reconnect, and sleep/wake. Confirm the original volume comes back on the correct device, and that Quit with the original output disconnected still quits with a single message. Record what you actually tested; a clean build is not proof of audio behavior.

For volume settings, check 0%, 30%, and 100%; changing the setting during a fade; and changing it after manual Restore. The original baseline must stay intact. At 100%, there should be no repeated capture or volume writes.

For onboarding, begin with the [isolated preview](preview/README.md). Check the choose screen with no apps, one, many, and a long name; the Use another app… sheet through waiting, hearing, found, Try again, and Cancel; the One thing first page after an unavailable volume check (Open Sound settings and Check again), optional login approval and errors, Back navigation, ⌘W and ⌘Q, keyboard controls, and VoiceOver. Closing unfinished setup must leave automatic lowering inactive. First-run volume stays a draft until Start Sigá and survives Back and Check again; Settings changes save immediately. Recheck real prerequisites at Start, and confirm closing during that check cannot complete setup. Test actual system actions separately in a clean macOS VM with the final signed app.

Run `tests/run.sh` before and after any change to `main.swift` or `Setup.swift`. It compiles the real engine and the real app class against in-memory doubles, and it never plays, records, or changes audio. A fixed defect gets one assertion there.

## Adding a dictation app

Apps with a distinct microphone start/stop signal can be discovered through **Use another app…**. A row in `knownApps` ([Setup.swift](Setup.swift)) adds only two things: the exact names of the settings to turn off, and, with `tile: true`, a tile on the choose screen. A tile needs a complete record from the real app:

1. **Identity.** Bundle id, version, and the path of the process that holds the microphone. `swift tests/probe.swift watch 120` logs it; the probe only reads.
2. **The signal follows dictation.** On at each start and off at each stop, across a fresh launch, a relaunch, and short and long sessions.
3. **The app’s own audio feature.** With Sigá not running and music playing, what the app does to the volume, mute, or player, and the setting names exactly as the app shows them.
4. **Other microphone features.** Whether meetings, recordings, or voice conversations raise the same signal.
5. **With Sigá.** The volume lowers, restores, and verifies on every cycle, with the app’s own feature off.

Name the app version, macOS version, microphone, and where the record was made. Say which results were heard on real speakers or headphones and which were only read from the log. A failed cycle is investigated and fixed; more passing cycles don’t cancel it.

For login behavior, turn **Launch at login** on and off, check that the menu follows changes made in System Settings, and verify a log out and log in with the final signed app.

For documentation or website changes, check the facts against the current source. Don’t list a dictation app as supported until its integration has been implemented and checked. Keep the copy casual and specific. Use “volume” when technical audio terms aren’t needed.

A pull request should explain the smallest concrete change, why it’s needed, and how it was checked. Avoid unrelated cleanup.
