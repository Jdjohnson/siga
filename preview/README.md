# Trial onboarding safely

Run `./preview/build.sh` from the repository, then open **Sigá Onboarding Preview.app** inside `preview`.

The preview uses the exact production `Welcome.swift` screens and `Setup.swift` states. The window looks like the app’s, and the menu bar app name says **Sigá Preview**. All actions change values in memory. It never opens real System Settings, launches or looks for a dictation app, listens to the microphone, changes volume, registers Login Items, or reads/writes Sigá preferences. The audio engine and ServiceManagement integration are not compiled into this app.

Use the **Sigá Preview** menu (the application menu) to choose a scenario: **Two apps**, **No apps**, **One app**, **Twelve apps**, **Long name**, **Volume unavailable**, **Login approval needed**, **Login request failed**, **Login unavailable**, **Dictation lowered the volume**, **Volume was already off**, or **Settings**, the slider-and-Done window Sigá shows after setup. The apps are supplied records with stand-in icons, not apps on this Mac. **Restart onboarding** (⌘R) starts the screens again. **Close** (⌘W) closes the window; click the Dock icon to bring it back. Quit with ⌘Q.

The checkbox, **Open Login Items**, and **Open Sound settings** are status transitions, not real macOS dialogs. **Open Login Items** simulates a granted approval, and **Open Sound settings** simulates choosing an output with volume controls.

Try these paths:

1. Choose an app (Continue stays off until you do), Continue, adjust the slider, go Back, then Continue again and confirm the draft value remains. Start Sigá shows a brief check, then shows “You’re all set.” Done closes the window.
2. Choose **Use another app…**. The sheet waits, then a scripted start and stop one second apart play through the real discovery logic: hearing, then found, with the note on screen before Add works. Check that **Add** keeps its cream text while disabled in waiting/hearing and when enabled after discovery; the disabled button must not respond to a click or Return. Try **Try again** and **Cancel**. Select **No apps** to see the screen with that tile alone.
3. Select **Volume unavailable**, then Start Sigá. The **One thing first** page appears with Open Sound settings and Check again, and the chosen volume is kept. Choose Open Sound settings, then Check again to finish.
4. Select **Login approval needed** or **Login request failed**. A note appears under the checkbox (with an Open Login Items link when approval is needed) and never blocks Start Sigá.
5. After Start Sigá, select **Dictation lowered the volume** or **Volume was already off** to see the last screen answer a first dictation.
6. Close midway with ⌘W, including during the check after Start Sigá, and restart. Nothing completes after a close. This preview saves nothing.

For a fresh native-rendered screenshot set, run the executable with `--render /absolute/output/folder`. These images are offscreen renders; native controls can appear inactive.

The final signed app still needs a clean macOS VM test for real system dialogs, first-run installation, and Login Items. Actual speaker/headphone volume behavior needs a physical Mac check.

Set `SIGA_PREVIEW_HEIGHT=520` (or 488) when rendering to inspect compact layouts. This size override is compiled only into the isolated preview, never the production app.
