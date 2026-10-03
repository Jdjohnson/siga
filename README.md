<p align="center"><img src="brand/assets/readme-header.webp" alt="Sigá. Keep your music on." width="100%"></p>

# Sigá

Sigá softens your Mac’s sound while you dictate, then gently brings it back. Your music keeps playing.

It lives in your menu bar. No account or extra audio driver needed.

## Get started

You’ll need an **Apple Silicon Mac** and **macOS 14.2 or later**. Tested on macOS 27; earlier versions haven’t been verified.

[Download Sigá for Mac](https://getsiga.app/downloads/Siga.dmg?build=18) · Version 0.2, build 18. You can also [build from source](#build-from-source).

Open Sigá, choose your dictation app, and set how quiet you want your music. Willow and superwhisper appear when installed. For other apps, choose **Use another app…** and dictate once to add them.

If your dictation app already pauses, mutes, or lowers your music, turn that feature off. Sigá shows the setting’s name for apps it knows.

## Use Sigá

Play your music and dictate as usual. The default keeps **30% of your starting volume**: if your Mac is at 50%, Sigá lowers it to 15%, then returns to 50%.

Use the menu to change the volume setting, choose dictation apps, or turn on **Launch at login**.

- **Enabled** turns automatic lowering on or off.
- **Restore sound** brings the sound back and keeps it there until the current recording ends.
- **Quit Sigá** restores the volume before closing.

## Muffle preview

This branch adds **Muffle** in Settings, alongside the default **Lower volume** effect. The published build 18 download above still has Lower volume only. Muffle is not release-ready; see [validation and rollback](MUFFLE.md).

Muffle softens higher frequencies and uses the same volume slider. At 100%, the filter stays active; at 0%, playback is silent. It processes playback locally and asks macOS for System Audio Recording permission on first use. It never opens your microphone, saves audio, or uploads it.

The current route supports one mono or stereo Float32 output stream at 8–96 kHz. An output device that also exposes input streams is not yet supported. If Muffle cannot start, Sigá releases its route before trying Lower volume and shows the reason in its status. Lower still requires macOS volume controls on that output.

## Compatibility and volume

- Sigá follows microphone use, so meetings or recordings in a selected app also lower the volume. Always-listening modes and Apple’s built-in Dictation aren’t supported.
- It controls your Mac’s default speakers or headphones. Some displays and audio interfaces don’t allow macOS volume changes; sound sent to a separate device is unaffected.
- It restores the volume saved when dictation started, even if you adjust it while talking. If a device disconnects, Sigá waits for it to return. After a crash or force-quit, you may need to restore the volume yourself.

## How it works

Sigá is written in Swift and C using AppKit, Core Audio, and ServiceManagement, with no third-party runtime dependencies.

It checks whether a selected app is using its microphone, including helper processes inside that app’s bundle. Helpers outside the bundle can’t be followed. Lower volume saves the current level, lowers it while the microphone is active, and restores it afterward. Muffle instead processes other apps’ playback through a private Core Audio tap and route. Sigá never opens the microphone or makes network requests.

The application code is in the [audio engine and menu](main.swift), [setup state and app discovery](Setup.swift), [welcome window](Welcome.swift), [Muffle session](MuffleSession.swift), and [Muffle processor](MuffleDSP.c).

## Build from source

Install Apple’s Command Line Tools, then run the build from this repository’s folder:

```sh
xcode-select --install
./build.sh
```

This creates `Siga.app`. Quit any running copy before replacing it. Local builds are signed for development; they aren’t notarized releases.

Run `tests/run.sh` to check the audio engine and app logic without recording or changing audio.

[Contributing](CONTRIBUTING.md) · [Release guide](RELEASING.md) · [MIT license](LICENSE)
