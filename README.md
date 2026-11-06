<p align="center">
  <img src="docs/images/icon.png" width="128" alt="MacFan icon">
</p>

<h1 align="center">MacFan</h1>

<p align="center">
  <a href="https://github.com/alvinmr/macfan/releases/latest"><img src="https://img.shields.io/github/v/release/alvinmr/macfan" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-universal-blue" alt="Universal">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/alvinmr/macfan" alt="MIT License"></a>
</p>

<p align="center">
  <a href="https://github.com/alvinmr/macfan/releases/latest/download/MacFan-macOS.dmg"><b>Download MacFan</b></a>
</p>

A free, open-source temperature monitor and fan controller for the Mac.

<p align="center">
  <img src="docs/images/overview.png" width="720" alt="MacFan overview">
</p>

MacFan answers one question first — *is my Mac OK?* — in plain language, then gets
out of the way. When you want more, every sensor, fan and battery detail is one
click deeper.

## Features

- **Plain-language status.** "Running cool", "Warm, and that's normal", "Running hot",
  with what to do about it. Combines sensor readings with macOS thermal pressure, so it
  also tells you when your Mac is slowing itself down to cool off.
- **Every sensor, grouped.** CPU, GPU, memory, SSD, battery, power, wireless and
  enclosure sensors on Apple Silicon and Intel, each with a 10-minute sparkline.
  Filterable, and with sensible per-part thresholds (a 90 °C CPU is fine; a 50 °C battery is not).
- **History.** Click any card, fan or sensor for the last hour as a chart, with the
  average, the highest, and the peak since MacFan opened.
- **What's making it warm.** The apps using the most CPU, with their share, right on
  the Overview and in the menu bar.
- **Power draw.** How many watts your Mac is using, and on a laptop how fast the
  battery is charging or draining and how long it has left.
- **Pinned sensors.** Right-click a sensor to keep it in the sidebar.
- **Insights.** *Hot moments* lists each time your Mac ran hot or slowed itself down,
  with the apps that were busy. *Cooling Health* spends two weeks learning how your Mac
  normally cools, to later spot when it gets worse — the usual sign of dust in the vents.
  Automatic and each Smart Curve are learned separately; Fixed Speed and Max pause it.
  Kept only on your Mac.
- **Four cooling modes.**
  - *Automatic* — macOS decides (the default).
  - *Smart Curve* — fan speed follows a temperature. Pick Quiet, Balanced or Strong,
    or drag the points to draw your own.
  - *Fixed Speed* — one steady speed.
  - *Full Speed* — everything at maximum.
  - Optionally switch modes on their own when you plug in or unplug, say Automatic on
    battery and Smart Curve on the adapter.
- **Safety first.** Fans go back to macOS when you quit, when the Mac sleeps, or if
  MacFan crashes or stops responding. By default, when a part gets critically hot or
  macOS reports critical thermal pressure, Smart Curve and Fixed Speed run every fan at
  full speed until it eases; a setting marked risky lets them keep your speed instead.
- **Menu bar.** Temperature, fan speed, or both. Any sensor can be pinned there.
- **Light on your Mac.** Under 2% CPU with the window open, and close to nothing when
  it's only in the menu bar. MacFan shouldn't be a reason your Mac runs warm.
- **Battery health.** Capacity vs. new, cycle count, temperature, and a clear verdict.
- **Alerts** that stay rare enough to mean something: only after 30 s above your
  threshold, at most every 15 minutes.
- **CSV logging**, one file per day.
- **Automatic updates** with [Sparkle](https://sparkle-project.org), verified by signature.
- **`macfanctl` CLI** for scripts and bug reports.

<p align="center">
  <img src="docs/images/fans.png" width="49%" alt="Fan control with a draggable curve">
  <img src="docs/images/battery.png" width="49%" alt="Battery health">
</p>

## Download

Get `MacFan-v<version>-macOS.dmg` from the
[latest release](https://github.com/alvinmr/macfan/releases/latest). One download runs
on **Apple Silicon and Intel**, on **macOS 14 Sonoma or later**.

1. Open the DMG and drag **MacFan** to **Applications**.
2. Open MacFan from Applications.

MacFan is not yet notarized by Apple, so the first time you open it macOS will block it.
If you trust the download, go to **System Settings → Privacy & Security** and click
**Open Anyway**. You only need to do this once. Each release lists the DMG's SHA-256
checksum so you can verify the download:

```sh
shasum -a 256 ~/Downloads/MacFan-v*-macOS.dmg
```

Or install with [Homebrew](https://brew.sh):

```sh
brew install --cask alvinmr/tap/macfan
```

### Updates

MacFan checks for updates once a day and installs them with Sparkle, which verifies each
update's signature before installing it. Use **MacFan → Check for Updates…** to check now,
or turn automatic checks off in **Settings → General**.

## Build from source

Requires Xcode 26 / Swift 6.2 or later.

```sh
make app     # builds and signs build/MacFan.app (ad-hoc)
make dmg     # universal app + DMG + checksum, exactly as releases are built
make run     # builds, then opens it
make test    # unit tests
```

Or from source without bundling: `swift run MacFan` (alerts and helper installation
need the bundled app).

### Command line

```sh
swift run macfanctl sensors        # recognised sensors
swift run macfanctl sensors --all  # including unidentified ones
swift run macfanctl fans
swift run macfanctl battery
swift run macfanctl power          # system power draw and battery charge rate
swift run macfanctl apps           # apps using the most CPU
swift run macfanctl keys           # raw SMC temperature keys, for contributors
```

## Fan control and the helper

Reading temperatures needs no permission. *Changing* fan speed requires root, so
MacFan installs a small privileged helper the first time you pick a mode other than
Automatic (**Fans → Install Helper**). macOS will ask you to allow it in
**System Settings → General → Login Items → Allow in the Background**.

The helper's entire interface is three calls: *version*, *set fan target*, *give fans
back to macOS*. It:

- only accepts connections from an app signed as `io.github.alvinmr.MacFan` (and, for
  Developer ID builds, signed by the same team as the helper);
- returns all fans to macOS when the app disconnects, when it receives no command for
  20 seconds, and when it is stopped.

Remove it any time from **Settings → Helper → Uninstall Helper**.

### Troubleshooting

**"The helper is registered but isn't responding."** Some macOS versions refuse to
launch daemons from ad-hoc signed apps. Either sign with a Developer ID:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make app
```

…or, for local development only, install the helper the classic way:

```sh
sudo scripts/install-helper-dev.sh install
sudo scripts/install-helper-dev.sh uninstall   # to remove
```

**A sensor has a generic name like "Sensor TC2X".** MacFan doesn't know that key yet.
See [Adding sensors](docs/ADDING_SENSORS.md) — it's usually a one-line change.

## Security

- No network access, analytics or tracking.
- The only privileged code is `Sources/MacFanHelper` (under 200 lines) plus the SMC writer
  in `Sources/SMCKit/SMCFanControl.swift`. Please review them.
- Ad-hoc builds can only pin the client's bundle identifier. Distributed builds should
  be signed with a Developer ID and notarized so the helper also pins the team.

## Contributing

Ideas, bug reports and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer

Changing fan speeds is at your own risk. MacFan never lets fans run below the
firmware's minimum, hands control back to macOS when it can't read temperatures or
apply your setting, and by default runs the fans at full speed in an emergency,
but no software can promise your hardware is safe.

MacFan is not affiliated with Apple or with Tunabelly Software (TG Pro).

## License

[MIT](LICENSE)
