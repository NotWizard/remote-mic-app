# Remote Mic · NotWizard fork

[![License](https://img.shields.io/badge/license-GPL--3.0--only-blue.svg)](LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)](Package.swift)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-blue.svg)](Sources/RemoteMic)
[![Fork](https://img.shields.io/badge/fork%20of-HD838A%2Fremote--mic--app-informational.svg)](https://github.com/HD838A/remote-mic-app)
[![Upstream Sync](https://img.shields.io/badge/upstream%20sync-v1.8.25-success.svg)](#relationship-to-upstream)
[![Last Commit](https://img.shields.io/github/last-commit/NotWizard/remote-mic-app.svg)](https://github.com/NotWizard/remote-mic-app/commits/main)
[![Stars](https://img.shields.io/github/stars/NotWizard/remote-mic-app.svg?style=flat)](https://github.com/NotWizard/remote-mic-app/stargazers)

[简体中文](README.md)

> This repository is a fork of [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app). On top of upstream v1.8.25 it adds a **configurable voice trigger key** and an **external-microphone capture mode**, and fixes two modifier-injection defects. See [What this fork changes](#what-this-fork-changes).

![Remote Mic — a voice remote for Vibe Coding](Screenshots/Remote-Mic-Introduce-1.png)

Remote Mic is a macOS app that turns a Xiaomi Bluetooth Remote 2 Pro into a wireless voice remote for your Mac. It provides both a standard Dock entry and a persistent menu bar entry.

Hold the remote voice button to speak. The direction, OK, Back, Home, Menu, TV, Power, and volume buttons can control macOS or launch commonly used apps.

Remote Mic is built natively with SwiftUI. While running in the background, it uses less than 0.5% CPU and around 50 MB of memory — lighter than a single Chrome tab.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/connection-and-voice-dark-en.png">
  <img alt="Connection and Voice settings" src="Screenshots/connection-and-voice-en.png">
</picture>

## Relationship to upstream

Lineage: [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge) → [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app) → this repository.

Upstream owns the product roadmap, signed and notarized releases, and the official distribution channels. This fork only layers the changes below on top; everything else — features, protocol, and default behavior — matches upstream v1.8.25. Upstream releases are merged in periodically.

## What this fork changes

### Configurable voice trigger key

Upstream hard-maps the voice key to Fn. This fork lets you pick the trigger key from the voice-key card on the **Button Mapping** page:

| Trigger key | Use case |
| --- | --- |
| **Fn** (default) | Doubao Input Method, macOS dictation — byte-for-byte identical to upstream |
| Right Command | Third-party voice tools that use a right-side modifier as their push-to-talk key |
| Right Option | Same as above |
| Right Shift | Same as above |

Only the emitted trigger key changes. Push-to-talk semantics, audio streaming, and the hold/tap state machine are untouched. The setting persists and is included in configuration import/export; older configurations without the field fall back to Fn.

Right-side modifiers require Accessibility permission. Without it the voice key causes no side effects and prompts for authorization instead.

### External microphone capture mode

Adds a **Use the remote's built-in microphone** switch, **on by default** (identical to upstream: trigger key + remote microphone into the virtual mic).

When it is off, the voice key becomes a pure trigger — holding it only sends the trigger key and no longer captures or routes the remote's ATVV audio. That lets an external microphone serve as the input source, giving you "remote triggers, external mic captures" for noisy rooms or existing professional microphones.

Turning it off automatically disables **Simulate Fn Tap on Voice Key** (Typeless compatibility), because that injection depends on remote audio draining.

### Fix: right-side modifier sticking

With the trigger key set to Right Command / Option / Shift, the modifier could stick — preventing stop, toggling VoiceOver, or making the system laggy. The modifier is now injected as a press/release tied to the start and stop of speech, and is always released on disconnect, quit, or trigger-key change.

### Fix: custom shortcuts lost the modifier side

Recording something like "Right Command + comma" was stored upstream as a plain Command, so third-party tools that distinguish left from right never responded.

This fork preserves the side, holds the matching physical modifier when sending (Right ⌘=54, Right ⌥=61, Right ⇧=60, Right ⌃=62; left side 55/58/56/59) and releases in reverse order, and shows L/R in the UI. Older configurations without side information keep the original flags-only path.

Modifier injection was corrected at the same time: modifiers used to be sent as ordinary key presses, which never actually changed the system modifier state, so a shortcut could both trigger the target tool and leak to the frontmost app (for example opening DingTalk's settings). Modifiers are now sent as real modifier-state changes (`flagsChanged`), matching a physical keypress.

### Verification status

Automated: 244 unit tests via `swift test` and 42 project self-checks in `scripts/test.sh` all pass. Unit tests cover trigger-key constants, mapper remapping, the default-Fn regression, injected key codes and modifiers, and configuration import/export round-trips.

Not done: none of the four changes above have been **verified end-to-end on real RC003 hardware with third-party voice software**. Test plans are in [`Testing/VoiceTriggerKey.md`](Testing/VoiceTriggerKey.md) and [`Testing/CustomShortcutModifierSide.md`](Testing/CustomShortcutModifierSide.md).

> **Build note**: upstream v1.8.25 declares the private `GetSayAll/sayall-mac-remote` component as an unconditional dependency, so SwiftPM fails during resolution without read access. This fork points it at a local stub under [`Vendor/sayall-mac-remote`](Vendor/sayall-mac-remote), which makes `swift build`, `swift test`, and release builds work. The cost is that **iPhone, Apple Watch, and web voice connections are unavailable in fork builds** — the counterparties for those three transports (the iOS app, the watch app, the relay server) all live in private repositories and cannot be reimplemented here. Every RC003 physical remote feature is unaffected.

## Requirements

- Apple Silicon Mac with macOS 14 or later, or Intel Mac with macOS 13 or later
- Xiaomi Bluetooth Remote 2 Pro
- For voice input, install the compatible microphone, or use an existing loopback device such as BlackHole 2ch

## Installation

This fork publishes an Apple Silicon `Remote-Mic-<version>.dmg` on [Releases](https://github.com/NotWizard/remote-mic-app/releases), ad-hoc signed and not notarized.

Open the DMG and double-click the single `Install Remote Mic.pkg`. The installer installs Remote Mic and checks the existing `MiRemoteV 2ch`: a healthy, compatible driver is kept as is; a missing or unusable one is installed or updated.

**The first launch requires right-click → Open** on the app icon, or run `xattr -dr com.apple.quarantine "/Applications/Remote Mic.app"` first. This fork has no Apple Developer ID certificate and can only sign ad-hoc, which Gatekeeper blocks on a plain double-click.

If you need an Apple-signed and notarized package, use [upstream's official Releases](https://github.com/HD838A/remote-mic-app/releases) — they do not contain this fork's changes.

### Automatic updates are disabled

Fork builds point Sparkle at this repository and disable automatic checks. Build output still carries upstream's bundle identifier `com.hd838a.RemoteMic`, so leaving the feed on upstream's appcast would let Sparkle treat upstream's signed release as an update and **silently overwrite the fork build**, discarding all four changes.

The trade-off is manual upgrades: download the newer DMG yourself. This fork publishes no appcast asset, so even a manual "Check for Updates…" finds nothing.

### Build from source

```zsh
swift test               # 244 unit tests
./scripts/test.sh        # 42 project self-checks
./scripts/build-app.sh   # produces dist/Remote Mic.app
./scripts/build-dmg.sh   # produces dist/Remote-Mic-<version>.dmg and .sha256
```

## First use

1. Turn on Bluetooth in System Settings.
2. Hold the remote TV button for about 2 seconds until the white light at the bottom blinks.
3. Hold Home and Menu together to enter pairing mode.
4. Pair the device named `MI RC`, `Xiaomi Bluetooth Remote 2`, `Xiaomi Bluetooth Remote 2 Pro`, or 小米蓝牙语音遥控器.
5. Launch Remote Mic and grant Bluetooth access when asked.
6. To customize ordinary buttons, also grant Input Monitoring and Accessibility, then quit and reopen the app.

Remote Mic appears in the Dock and remains in the menu bar after launch:

- Click the Dock icon, or left-click the menu bar icon, to open Settings.
- Right-click the menu bar icon for status, reconnect, logs, About, version, update, GitHub, and Quit.

The **About** page at the bottom of the Settings sidebar provides version, update, version history, glossary, GitHub, language, Dock display, and launch controls. Turn off **Open main window at launch** to keep ordinary launches in the menu bar; an update relaunch still opens the main window unconditionally.

**App Language** offers **System Default**, **简体中文**, and **English**. System permission prompts and third-party panels continue to follow the language selected by macOS.

## Use voice input

1. Open **Connection & Voice**.
2. Select **Refresh Audio Devices**.
3. Select `MiRemoteV 2ch`, or another loopback device you already installed.
4. Choose the same device as the microphone in the app that receives dictation or voice input.
5. Click the target text field, hold the remote voice button to speak, then release to finish.

To confirm the audio path, send a one-second test tone or watch the input level in QuickTime Player's **New Audio Recording** window.

To capture with an external microphone instead, turn off **Use the remote's built-in microphone**, skip steps 2–4, and select your external microphone directly in the target app.

### Working with third-party voice software

When a third-party voice tool uses a right-side modifier as its push-to-talk key, change the voice trigger key to the matching Right Command / Option / Shift on the **Button Mapping** page. This capability is new in this fork — see [Configurable voice trigger key](#configurable-voice-trigger-key).

### Typeless compatibility

Tap-to-toggle voice tools such as Typeless are incompatible with the RC003's default Fn-hold behavior. Enable **Simulate Fn Tap on Voice Key** under **Connection & Voice** to send one Fn tap when the voice stream starts and a matching tap after queued audio drains. Typeless and Remote Mic must still select the same loopback device, and Accessibility permission is required.

You must still **hold the RC003 voice key while speaking and release it to finish**. The RC003 firmware stops microphone audio when the key is released, so this is not continuous or hands-free recording. The mode is off by default; keep it off for Fn-hold tools such as Doubao Input Method.

If Doubao Input Method cannot see an ordinary virtual microphone, install `MiRemoteV 2ch` first, then select it in Remote Mic. See the [Doubao Input Method Compatibility Guide](Resources/豆包输入法兼容说明.en.md).

## Customize remote buttons

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/key-mapping-dark-en.png">
  <img alt="Button mapping settings" src="Screenshots/key-mapping-en.png">
</picture>

Open **Button Mapping** and enable custom mapping to change the direction, OK, Back, Home, Menu, TV, Power, and volume buttons.

Each ordinary button supports a single-click action and optional double-click and long-press actions. Available actions include keyboard input, system volume, playback control, launching installed apps, and recording any custom keyboard shortcut.

When recording a custom shortcut, this fork preserves which side of a modifier was pressed and shows L/R in the UI. After moving over from upstream, re-record affected shortcuts — older recordings carry no side information.

**Open Custom App** lets you select any local `.app`, then either open it only, send its focus shortcut after activation, or record a target input field once and focus it automatically. Re-record the target if an app update changes its interface. Remote Mic does not use fixed screen coordinates or save text from the input field.

- Without double-click or long-press configuration, single-click keeps its immediate response and hold-to-repeat behavior.
- A double-click waits about 0.3 seconds so the app can distinguish a single click.
- A long press triggers after about 0.55 seconds and suppresses the single-click action.
- Buttons with a configured double-click or long-press do not hold-repeat, preventing multiple actions from firing at once.

The voice button does not participate in ordinary button mapping; its trigger key is configured separately on the same page.

## Usage statistics

The **Statistics** page shows remote button presses, voice duration, and the longest individual voice sessions for the selected day, week, or all-time range. All statistics stay on this Mac and are never uploaded.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/statistics-dark-en.png">
  <img alt="Remote Mic usage statistics" src="Screenshots/statistics-en.png">
</picture>

## Permissions and privacy

- Bluetooth: connect to the remote and receive voice.
- Input Monitoring: identify ordinary remote buttons.
- Accessibility: send mapped button actions to the active app; also required when the voice trigger key is a right-side modifier.

Remote Mic does not upload or store voice, does not change the system default input or output device, and does not log voice content, Bluetooth addresses, or peripheral identifiers.

## Uninstall

1. Quit Remote Mic.
2. Run `Uninstall Remote Mic.pkg` to remove `MiRemoteV 2ch`.
3. Delete Remote Mic.app from Applications.

Uninstalling the compatible microphone does not change or remove BlackHole.

## Troubleshooting

Read the [Troubleshooting Guide](TROUBLESHOOTING.en.md) first. The complete onboarding flow is in the [First-Install Guide](Resources/首次安装说明.en.md).

For development, build, protocol, test, and release details, see the [Technical Documentation](TECHNICAL.en.md).

Report issues with this fork's own changes in [this repository's Issues](https://github.com/NotWizard/remote-mic-app/issues); report upstream product issues in the [upstream repository](https://github.com/HD838A/remote-mic-app/issues).

## License and sources

The macOS app, driver, and related software code in this repository are GPL-3.0-only. The macOS app logo and app icon are proprietary brand assets that require a separate grant; this fork neither receives nor sublicenses those brand rights. See [LOGO-LICENSE.en.md](LOGO-LICENSE.en.md). Full copyright and third-party information is available in [COPYRIGHT.en.md](COPYRIGHT.en.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The project was originally forked from [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge), then maintained independently in [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app), from which this repository is forked.

The MiRemoteV 2ch naming and USB-transport compatibility approach for Doubao device enumeration were informed by [VincentKingHsu/MiRemoteVoice](https://github.com/VincentKingHsu/MiRemoteVoice) v1.0.0-beta.1 (MIT). This project does not reuse that project's binary replacement script. Instead, it independently derives MiRemoteV2ch.driver from [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole) v0.7.1 at commit e2b22aaaba4e507a097131704bf96dabc004d9cf under GPL-3.0. The driver has a separate identity, coexists with BlackHole, and never overwrites or removes BlackHole files.
