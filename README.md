# MonitorOnOff

<img src="Resources/AppIcon.png" width="128" alt="MonitorOnOff icon">

A native macOS menu bar utility for turning external display output on and off.

[简体中文说明](README.zh-CN.md) · [Download](https://github.com/JenW1nt0p/MonitorOnOff/releases/latest)

## Features

- Control multiple external displays independently from the menu bar.
- Keep a restore entry for physically connected displays whose output is turned off; unplugged displays disappear automatically.
- Protect the built-in display and keep at least one output enabled.
- Restore connected outputs turned off by the app when quitting. Retain records for unplugged displays and keep recovery records when restoration fails.
- Refresh on display connection changes.
- Launch at login by default on first launch, with a menu option to disable it.
- Follow the macOS preferred language: English, Simplified Chinese, Traditional Chinese, Korean, and Japanese. Unsupported preferences fall back to English.

Turning off output in software is different from powering off the monitor hardware. Standby behavior depends on macOS, the driver, monitor, and connection.

## Install

1. Download the universal `.dmg` from [Releases](https://github.com/JenW1nt0p/MonitorOnOff/releases/latest).
2. Open it and copy `MonitorOnOff.app` to `/Applications` or `~/Applications`.
3. Eject the disk image, then open the installed copy. Do not enable launch at login from the mounted disk image.
4. Click the display icon in the menu bar, choose a display, and select **Turn Output Off** or **Turn Output On**.

The app targets macOS 13.0 and later and contains Apple Silicon and Intel binaries. Runtime verification has been performed on Apple Silicon; Intel and older macOS releases have not been verified on hardware.

The downloadable app currently uses an ad hoc signature and is **not Developer ID signed or notarized**. macOS may block the downloaded app or show an unidentified-developer warning. Review the source before running it. Building locally is an alternative.

If you change the macOS system or per-app language, restart MonitorOnOff to apply it. Physical display names remain as reported by the system.

## Build

Install Apple's Xcode Command Line Tools or Xcode. No third-party app dependencies are required.

```sh
./build.sh
./package-dmg.sh
```

Outputs are written to `dist/`. To use a different directory or package an existing build:

```sh
./build.sh /path/to/output
./package-dmg.sh /path/to/output/MonitorOnOff.app /path/to/output
```

The build script compiles both architectures, assembles the app bundle, includes all five localization catalogs, and applies an ad hoc signature. The packaging script creates a compressed DMG with an Applications shortcut and installation notes.

## Test and diagnose

```sh
./test.sh
python3 Tests/localization.py dist/MonitorOnOff.app
dist/MonitorOnOff.app/Contents/MacOS/MonitorOnOff --diagnostics
```

Logic tests include unplugging after software output-off, clicking stale menu entries, reconnecting with a new display ID, and independent handling of multiple displays. They use a simulated display backend and do not change real outputs or login items. Localization tests check all 225 catalog entries and 14 language preference scenarios.

For a native menu test, using an isolated recovery journal:

```sh
dist/MonitorOnOff.app/Contents/MacOS/MonitorOnOff \
  --ui-test /tmp/monitor-ja.json -AppleLanguages '(ja)'
```

The test instance reads display state, verifies its menu, writes a report, and quits. It does not switch outputs, change login items, or modify the system language. Run separately for `en`, `zh-Hans`, `zh-Hant`, `ko`, and `ja`.

Other maintenance commands:

```sh
dist/MonitorOnOff.app/Contents/MacOS/MonitorOnOff --quit-running
dist/MonitorOnOff.app/Contents/MacOS/MonitorOnOff --login-item enable
dist/MonitorOnOff.app/Contents/MacOS/MonitorOnOff --login-item disable
dist/MonitorOnOff.app/Contents/MacOS/MonitorOnOff --localization-diagnostics
```

## Implementation and limitations

`DisplayBridge.c` dynamically loads the non-public CoreGraphics function `CGSConfigureDisplayEnabled` and uses a display configuration transaction with `kCGConfigureForSession`. It checks the begin, configure, and commit results. This interface may change or disappear in future macOS releases; the app disables switching if the symbol is unavailable.

`DisplayModel.swift` tracks displays by UUID and stores recovery records in `~/Library/Application Support/DisplayOutputSwitch/recovery.json`. The original bundle ID and data directory are retained for upgrade compatibility. The journal contains display metadata; it is never uploaded.

`DisplayConnections.swift` reads IOKit connection services. For offline displays on Apple Silicon, it matches EDID hardware identity against DisplayPort endpoints with an asserted hot-plug signal; on Intel, it checks existing `IODisplayConnect` services. It saves the endpoint path when a unique match is available. Offline devices with ambiguous or unavailable connection information are hidden until detected again, while their recovery records remain saved. A cached display ID or hardware identity alone is insufficient evidence of a physical connection.

`LoginItems.swift` uses the public `SMAppService.mainApp` API. After applying the first-launch default once, the app respects changes made in its menu or System Settings. The app must remain at a stable installed path for launch at login to work reliably.

`Localization.swift` uses standard `.lproj/Localizable.strings` resources and native `Bundle` language selection. The application icon was generated with an image generation tool; the original asset and prompt are included in `Resources/`.

Forced termination cannot execute the normal restore flow. Reconnect unplugged displays before restoring their output. Software output control depends on hardware and driver support; a successful configuration request is followed by a state check. Real external-display toggling and hot-plug recovery have not yet been verified on hardware.

## License

Released under the [MIT License](LICENSE). The license is also included in the app bundle and DMG.
