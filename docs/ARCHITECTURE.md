# Architecture

MacFan is a Swift package. There is no Xcode project to keep in sync; `scripts/build-app.sh`
assembles the `.app` bundle from the package's products.

```
              ┌──────────────┐        XPC         ┌───────────────┐
              │  MacFan app  │ ─────────────────▶ │ macfan-helper │  (root)
              │  (SwiftUI)   │   MacFanXPC        │               │
              └──────┬───────┘                    └───────┬───────┘
                     │ reads                              │ writes
              ┌──────▼───────┐                    ┌───────▼───────┐
              │  MacFanCore  │ ─────────────────▶ │    SMCKit     │
              └──────────────┘                    └───────┬───────┘
                                                          │
                                                  ┌───────▼───────┐
                                                  │ CPrivateIOKit │ ─▶ AppleSMC, IOHID
                                                  └───────────────┘
```

## Rules of the road

1. **Reading never needs privileges; writing always goes through the helper.** The app
   process never writes to the SMC.
2. **Decisions are pure.** `CoolingPlanner`, `SpeedGovernor`, `SafetyPolicy`, `FanCurve`,
   `SensorCatalog`, `ActivityTracker` and `BatteryInfo(properties:)` take values and return values. They are
   where the interesting logic lives and they are covered by tests. Keep I/O out of them.
3. **macOS is the safe default.** Every unusual situation — no data, sleep,
   quit, crash, lost connection — ends with the fans back under macOS control. An emergency in Smart Curve or Fixed Speed runs every fan at full speed instead, unless the user opted to keep their setting.
4. **The privileged surface stays tiny.** Adding a method to `MacFanHelperProtocol` is a
   security decision. Bump `HelperConstants.protocolVersion` when you change it.

## Modules

### `CPrivateIOKit`
C only. Declares the 80-byte `SMCParamStruct` the AppleSMC user client expects, and the
private `IOHIDEventSystem` functions used to read Apple Silicon temperature sensors.
Private symbols are bound with `__asm` labels so they never collide with IOKit's headers.

### `SMCKit`
- `SMCConnection` — open/close, read, write, key info (cached), key enumeration. Thread-safe.
- `SMCCodec` — `flt `, `fpXY`, `spXY`, `ui8/16/32`, `si8/16` ⇄ `Double`.
- `SMCFanControl` — fan readings; manual mode (`F<n>Md` + `Ftst` on Apple Silicon,
  `FS! ` bitmask on older Intel); target speed; restore.

### `MacFanCore`
- **Models** — `Sensor`, `SensorReading`, `SensorCategory` (+ thresholds), `FanStatus`,
  `BatteryInfo`, `HardwareSnapshot`.
- **Hardware** — `SensorCatalog` (key → name/category rules), `SMCSensorProvider`,
  `HIDSensorProvider`, `CompositeSensorProvider` (HID only fills categories SMC misses),
  `HardwareMonitor` (actor; one call → one `HardwareSnapshot`).
- **Control** — `FanCurve`, `CurvePreset`, `CoolingSettings`, `CoolingPlanner`,
  `SpeedGovernor`, `SafetyPolicy`, `PowerProfiles` (a mode per power source).
- **History** — `RingBuffer`, `HistoryStore` (raw samples for sparklines, 10-second
  averages for the last hour, peaks; memory stays flat however long MacFan runs).
- **Activity** — `ActivityTracker` (pure: process CPU time → per-app CPU %, helpers
  folded into their app) and `ActivityMonitor` (actor; reads `libproc`). The app only
  samples while a view showing the result is on screen, or during a hot moment.
- **Insights** — `HotMomentRecorder` (pure: snapshots → hot moments with culprits),
  `CoolingSampler` and `CoolingLog` (pure: steady one-minute samples → daily averages per
  workload band and `CoolingController`, macOS or one exact Smart Curve), `InsightsFile` (one JSON file in Application Support).
- **Logging** — `CSVLogger` (actor).

### `MacFanXPC`
`MacFanHelperProtocol` and `HelperConstants` (bundle IDs, Mach service name, watchdog
timeout). If you fork and rename, change these and `Resources/*.plist` together.

### `MacFanHelper`
`HelperService` serializes all SMC access on one queue, validates clients with a
code-signing requirement, and runs the watchdog. `CodeSigningPolicy` derives the
requirement from the helper's own signature.

### `MacFan` (app)
- `App/` — `MacFanApp` (scenes), `AppModel` (the one observable source of truth: polling
  loop, sleep/wake, termination), `ThermalStatus` (numbers → sentence).
- `Services/` — `Preferences`, `HelperManager` (SMAppService + XPC), `FanControlEngine`
  (applies planner decisions), `AlertCenter`.
- `DesignSystem/` — tokens (`Theme`) and shared components. Use these instead of
  literal numbers and colors.
- `Features/` — one folder per screen.

## The tick

Every `refreshInterval` seconds (default 2) `AppModel.tick()`:

1. `HardwareMonitor.snapshot()` reads sensors, fans and (every 30 s) the battery.
2. `HistoryStore.record` appends to the sparklines.
3. `FanControlEngine.update` asks `CoolingPlanner` what to do and sends it to the helper.
   Manual targets are re-sent every tick; that doubles as the helper's heartbeat.
4. `AlertCenter.evaluate` and, if enabled, `CSVLogger.append`.

`AppModel.refreshNow()` cuts the wait short, so mode changes apply immediately.

## Design principles

The interface follows Apple's design guidance:

- **Answer first.** Overview leads with one sentence and what to do about it; detail is
  one level deeper.
- **Respond immediately.** Buttons react on press, numbers roll with
  `.contentTransition(.numericText)` instead of flashing, and the curve redraws on every
  pointer move.
- **Direct manipulation.** Curve points are grabbed where you touch them, resist
  progressively past their limits (rubber-banding), and spring back on release.
- **Springs, not durations.** `Theme.Motion` defines critically damped springs by default;
  a little bounce only where a gesture carried momentum.
- **Never color alone.** Every temperature level also has a symbol and a word.
- **Respect the system.** Reduced Motion swaps movement for cross-fades; system font,
  semantic colors, light and dark mode.
