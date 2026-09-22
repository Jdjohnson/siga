# Changelog

## 0.2 — Unreleased

- Choose your dictation app in setup. Willow and superwhisper appear when installed; nothing is chosen for you, and Sigá follows only the apps you choose.
- Add any other app with Use another app…: dictate once, and Sigá offers the app whose microphone it heard start and stop. The sheet names what to turn off in that app before Add works.
- See and change your apps later under Dictation apps in the menu.
- Follow an app’s helper processes by where the app lives on disk, and run no timer at all while no chosen app is using audio.
- Fade by the clock with a smooth 400 ms lowering and 850 ms restoration, so a quick tap reverses smoothly instead of snapping.
- Leave the volume alone for the whole session when it was already at zero.
- Show “That’s it. Sigá lowered the volume.” on the last setup screen only after a real lowering.
- Run one copy at a time; a second copy says so and quits without touching audio.
- Keep the app under a 200 KB size budget, checked by the build.

## 0.1 — Unreleased

- Lower your Mac’s volume during Willow dictation and fade it back afterward.
- Use the menu bar to enable automatic lowering, restore the volume, or quit.
- Choose how much volume to keep while dictating, with a saved 0–100% control.
- Set up in two short pages followed by a completion screen: a welcome, then one page for your volume and an optional Open Sigá when I log in checkbox. A “You’re all set” screen confirms successful setup and explains how to begin. Start Sigá checks your Mac’s volume controls and asks for an output choice only when needed. Closing unfinished setup leaves automatic lowering inactive, and Finish setting up Sigá in the menu returns to it.
- Quit Sigá makes one bounded attempt to restore the volume, then quits. If the restore fails, one message tells you to set it back by hand, with the saved level when Sigá knows it.
- Restore the saved volume automatically when the original speakers or headphones return as the default output, even while Sigá is disabled or after your Mac has been asleep. Restore volume is available only when there is a volume to restore.
- Clear an audio error automatically when the output changes and nothing is waiting to be restored, retry a failed restore when the original output returns, and stop watching Willow after a failed restore until the volume is back.
- Close the setup window with ⌘W and quit with ⌘Q. Audio problems show a short menu title with the technical detail in a tooltip.
- Keep navigation visible on smaller screens, with compact spacing and scrolling only when needed.
- Finish setup before installing Willow, then wait for the dictation app.
- Let you try launch at login again after an error, and clear the error once macOS reaches the requested state.
- Lock the volume choice during final setup checks so the displayed and saved values agree.
- Trial the identical native screens with an isolated preview using simulated states.
- Choose Launch at login to open Sigá automatically when you log in.
- Keep the saved volume tied to the original speakers or headphones during device changes.
- Recover through audio lifecycle changes and verify volume restoration.
- Introduce the Everyday quiet brand, wave-accent wordmark, one-wave app icon, and small static website. Keep the three-wave menu-bar icon.

The source targets Apple Silicon and macOS 14.2 or later. The signed app download and final hands-on release checks are still pending.
