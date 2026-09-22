<p align="center"><img src="brand/assets/readme-header.webp" alt="Sigá. Keep your music on." width="100%"></p>

# Sigá

Sigá lowers your Mac’s volume while you dictate, then gently returns it to its previous level. Your music keeps playing.

It lives in your menu bar. No account or extra audio driver needed.

## Get started

You’ll need an **Apple Silicon Mac** and **macOS 14.2 or later**. Tested on macOS 27; earlier versions haven’t been verified.

[Download Sigá for Mac](https://getsiga.app/downloads/Siga.dmg?build=18) · Version 0.2, build 18 (release candidate). You can also [build from source](#build-from-source).

Open Sigá, choose your dictation app, and set how quiet you want your music. Willow and superwhisper appear when installed. For other apps, choose **Use another app…** and dictate once to add them.

If your dictation app already pauses, mutes, or lowers your music, turn that feature off. Sigá shows the setting’s name for apps it knows.

## Use Sigá

Play your music and dictate as usual. The default keeps **30% of your starting volume**: if your Mac is at 50%, Sigá lowers it to 15%, then returns to 50%.

Use the menu to change the volume setting, choose dictation apps, or turn on **Launch at login**.

- **Enabled** turns automatic lowering on or off.
- **Restore volume** brings the sound back and keeps it there until the current recording ends.
- **Quit Sigá** restores the volume before closing.

## Compatibility and volume

- Sigá follows microphone use, so meetings or recordings in a selected app also lower the volume. Always-listening modes and Apple’s built-in Dictation aren’t supported.
- It controls your Mac’s default speakers or headphones. Some displays and audio interfaces don’t allow macOS volume changes; sound sent to a separate device is unaffected.
- It restores the volume saved when dictation started, even if you adjust it while talking. If a device disconnects, Sigá waits for it to return. After a crash or force-quit, you may need to restore the volume yourself.

## How it works

Sigá is written in Swift using AppKit, Core Audio, and ServiceManagement, with no third-party runtime dependencies.

It checks whether a selected app is using its microphone, including helper processes inside that app’s bundle. Helpers outside the bundle can’t be followed. Sigá saves the current volume, lowers it while the microphone is active, and restores it afterward. Your audio and words never pass through Sigá. The app makes no network requests.

The [audio engine and menu](main.swift), [setup state and app discovery](Setup.swift), and [welcome window](Welcome.swift) contain the application code.

## Build from source

Install Apple’s Command Line Tools, then run the build from this repository’s folder:

```sh
xcode-select --install
./build.sh
```

This creates `Siga.app`. Quit any running copy before replacing it. Local builds are signed for development; they aren’t notarized releases.

Run `tests/run.sh` to check the audio engine and app logic without recording or changing audio.

[Contributing](CONTRIBUTING.md) · [Release guide](RELEASING.md) · [MIT license](LICENSE)
