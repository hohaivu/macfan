# Fan control

Fan control turns the cooling mode, the temperature readings, the thermal pressure of macOS and the emergency override into one fan decision for each tick.

## Terms

| Term | Meaning |
| --- | --- |
| Tick | One refresh of the hardware snapshot. `AppModel.tick` runs it, then calls the engine. |
| Decision | The result of `CoolingPlanner.decide`. macOS controls the fans (`.system` with a reason), MacFan runs every fan at one speed (`.manual`), or MacFan runs every fan at full speed in an emergency (`.emergency`). |
| Speed | A number from 0 to 1 of the range of a fan. 0 is the minimum speed of the fan. |
| Thermal pressure | The `ProcessInfo.ThermalState` of macOS: nominal, fair, serious or critical. |
| Emergency | Either latch is set: a safety reading reached its critical temperature, or macOS reports critical thermal pressure. In Fixed and Curve with `keepsSettingInEmergency` off, MacFan runs every fan at full speed. |
| Latch | A flag that stays set until a stated condition clears it. |
| Floor | The lowest speed that MacFan allows in Fixed and Curve modes. |
| Governor | `SpeedGovernor`. It paces the changes of the speed. |
| Deadband | A fall of this size or smaller counts as no change. The value is 0.02. |
| Hold | The wait before a fall of the speed starts. The value is 10 s. |
| Urgent rise | A rise that the governor meets at once. |

## Entry points

| What | Where |
| --- | --- |
| `CoolingPlanner`, `SpeedGovernor`, `SafetyPolicy` | `Sources/MacFanCore/Control/CoolingPlanner.swift` |
| Modes, settings, temperature source | `Sources/MacFanCore/Control/CoolingSettings.swift` |
| Curves and presets | `Sources/MacFanCore/Control/FanCurve.swift` |
| `FanControlEngine` | `Sources/MacFanCore/Control/FanControlEngine.swift` |
| Thermal pressure in the snapshot | `Sources/MacFanCore/Models/HardwareSnapshot.swift`, `Sources/MacFanCore/Hardware/HardwareMonitor.swift` |
| Tick and thermal notification | `Sources/MacFan/App/AppModel.swift` |
| Curve warning, status banner, footnote | `Sources/MacFan/Features/Fans/FansView.swift` |
| Mode tag text | `Sources/MacFan/Features/Overview/OverviewView.swift` |
| Emergency setting | `Sources/MacFan/Features/Settings/SettingsView.swift` |

## Settings and modes

`CoolingSettings` holds everything the user chose about cooling: `mode`, `preset`, `customCurve`, `source`, `fixedSpeed` and `keepsSettingInEmergency`.

- A change of mode keeps the other settings. Reason: not stated in the code.
- The defaults are Automatic, the Balanced preset, a custom curve equal to Balanced, the source Hottest CPU and a fixed speed of 0.5. Reason: not stated in the code.
- `activeCurve` is the curve of the preset. For the Custom preset, it is `customCurve`. Reason: not stated in the code.
- Decoding rejects a fixed speed outside 0 to 1. Reason: corrupt settings fall back to the defaults instead of driving the fans.
- `decide` also clamps the fixed speed to 0 to 1. Reason: not stated in the code.
- `keepsSettingInEmergency` is false by default. Decoding treats a missing key as false. Reason: settings saved by earlier versions keep the other choices of the user, and a strict decode resets them all.
- Turning on `keepsSettingInEmergency` is opt-in and risky. Reason: the owner chose to allow it. See [the decision](../decisions/2026-11-06-emergency-full-speed.md).

| Mode | Meaning |
| --- | --- |
| Automatic | macOS controls the fans. It is the default, and MacFan always returns to it. |
| Curve | The speed follows a temperature curve. |
| Fixed | One constant speed. |
| Max | Every fan runs at maximum. |

Every mode except Automatic needs the privileged helper. Reason: not stated in the code.

The source of a curve resolves to one temperature. See "Curve source" in [sensors.md](sensors.md).

## Curves

`FanCurve.speed(at:)` interpolates linearly between the points of the curve. Below the first point and above the last point, the speed stays flat. Reason: not stated in the code.

A curve has these invariants:

- Points stay in order of temperature and at least 1 °C apart. Reason: not stated in the code.
- Speed never falls when temperature rises. Reason: hotter never means slower.
- Temperature is between 30 and 105 °C, and speed is between 0 and 1. Reason: not stated in the code.
- A curve has 2 to 16 points. Reason: not stated in the code.

A curve comes from the decoder or from the constructor. Each path enforces the invariants in a different way.

| Path | Behavior | Reason |
| --- | --- | --- |
| Decoder | Rejects a stored curve that breaks any invariant, with the full bounds above. It does not repair the curve. | Repairing corrupt settings could produce a curve that nobody chose. |
| Constructor `FanCurve(points:)` | Requires at least 2 points. It has no upper limit on the count. It then normalizes the points. | Not stated in the code. |

Normalization does these steps:

1. It clamps each temperature to 30 to 105 °C and each speed to 0 to 1.
2. It sorts the points by temperature.
3. It moves each point to at least 1 °C above the previous point. It raises each speed to at least the speed of the previous point.

Step 3 can push a temperature above 105 °C. Example: two points at 105 °C become 105 °C and 106 °C. A constructor can also keep more than 16 points. Reason: not stated in the code.

The `move(pointAt:to:)` mutation keeps the temperature between the neighbors of the point and the speed between 0 and 1. It pushes the speed of the neighbors so that the curve does not fall. Reason: dragging a point keeps the curve valid.

Each preset is a deliberate trade-off between noise and temperature. Points show °C and speed.

| Preset | Points |
| --- | --- |
| Quiet | 50 and 0, 65 and 0.15, 78 and 0.4, 88 and 0.7, 95 and 1 |
| Balanced | 45 and 0, 60 and 0.25, 72 and 0.5, 84 and 0.8, 92 and 1 |
| Performance | 40 and 0.15, 55 and 0.4, 68 and 0.7, 78 and 0.9, 85 and 1 |
| Custom | The points in `customCurve`. |

## Decision for each tick

`CoolingPlanner.decide` runs these steps in order. The first step that returns ends the tick.

1. It reads the safety readings and updates the temperature emergency latch. See "Emergency and planning" in [sensors.md](sensors.md) for these rules.
2. It updates the pressure latch. See "Thermal pressure".
3. It records every category that has reported. Reason: the planner must tell "this Mac has no GPU sensor" from "the GPU sensor stopped reporting".
4. When the mode differs from the mode of the previous call, it resets the governor. See "Pacing".
5. Automatic returns `.system(.userChoice)`. It also resets the governor.
6. When either latch is set, the mode is not Max and `keepsSettingInEmergency` is off, it resets the governor and returns `.emergency`.
7. Max returns `.manual(speed: 1, temperature: nil)`. Max needs no data.
8. Fixed returns `.system(.noData)` without safety readings. Otherwise it returns the fixed speed, raised to the floor.
9. Curve returns `.system(.noData)` without safety readings or without a source temperature, and resets the governor. Otherwise it returns the speed of the curve, raised to the floor.

With `keepsSettingInEmergency` on, step 6 does not return. Steps 7 to 9 run as usual, with the floor, the pacing and the `noData` guards.

Reasons for the order of these steps are in [sensors.md](sensors.md): Max is the exception to an emergency, and missing data is never good news.

## Safety floor

The floor is a minimum speed. It applies in Fixed and Curve modes, after the curve or the fixed speed. `SafetyPolicy.minimumSpeed` computes it as the largest of three values:

1. The floor of each identified `.cpu` or `.gpu` reading.
2. 0.6 when thermal pressure is serious or critical.
3. 0.

The floor of a reading depends on its distance from the critical limit of its category. For `.cpu` and `.gpu`, the critical limit is 100 °C.

| Reading relative to critical | Floor |
| --- | --- |
| At or below critical − 15 (85 °C) | 0 |
| critical − 10 (90 °C) | 0.5 |
| At or above critical − 5 (95 °C) | 0.8 |

Between these points, the floor rises linearly. A `.cpu` reading of 94 °C gives 0.74.

- Only identified `.cpu` and `.gpu` readings feed the floor. Reason: die keys under moderate load and battery heat made the fans loud, and excess fan noise was the complaint of the user.
- Each reading uses the critical limit of its own category. Reason: the floor keeps the fans up before an emergency at the critical limit.
- `.cpuDie`, battery, storage, memory, power and enclosure readings give a floor of 0. They keep only the emergency path where `triggersEmergency` applies. Reason: the same noise reason.
- Unidentified readings give a floor of 0. Reason: not stated in the code.

## Thermal pressure

Thermal pressure comes from `ProcessInfo.ThermalState`. The snapshot carries it. A snapshot built without it is nominal. Reason: callers that build a snapshot need no change.

- Serious or critical pressure gives a floor of at least 0.6. Reason: macOS sees throttling that the sensors miss.
- Critical pressure starts the pressure emergency. Fixed and Curve run every fan at full speed unless the user keeps their setting. Max is unchanged. Reason: macOS sees throttling that the sensors miss.
- The pressure latch starts at critical, stays set at serious, and clears at fair or nominal. Reason: not stated in the code.
- The pressure latch updates on every tick, also with no readings. Critical pressure with an empty snapshot returns `.emergency`, not `.noData`. With `keepsSettingInEmergency` on, it returns `.system(.noData)`. Reason: the thermal state comes from macOS, not from sensors.
- The pressure latch and the temperature latch are independent. Neither clears the other. Reason: not stated in the code.

An example of independence: pressure falls to fair while a reading is still at or above critical − 5. The emergency stays.

## Pacing

The governor smooths the speed of Fixed and Curve modes. Reason: fans must not hunt up and down with every reading, and a slow fall sounds calmer.

`SpeedGovernor.next(target:at:urgent:)` takes the target speed, the sample date and an urgent flag. It applies the first rule that matches.

1. First sample after a reset: return the target.
2. The target is above the current speed and the rise is urgent: return the target. This rule runs before every other rule, so each positive urgent rise is met.
3. The target is above the current speed: raise the speed by at most 0.15 for each second since the previous sample, up to the target. A rise has no deadband.
4. The target is below the current speed by the deadband or less: keep the current speed.
5. Less than the hold time passed since the last demand: keep the current speed.
6. Otherwise: lower the speed by at most 0.04 for each second of fall time, never below the target.

Definitions for these rules:

- The last demand is the last sample that met rule 1, 2, 3 or 4.
- Fall time counts only the time after the hold expired. It runs from the later of the previous sample and the end of the hold.
- A sample dated before the previous sample counts as zero elapsed time, so it never lowers the speed.

The rules have these effects:

- The hold ends exactly 10 s after the last demand. At that moment, the speed is still held.
- A demand at full speed, then a target of 0 at 12 s, gives 0.92. Only the 2 s after the hold count.
- A demand at full speed, then one sample with a target of 0 at 30 s, gives 0.2. The fall time is 20 s.
- A fall never goes below the target.
- With urgent set on every call and a hold of 0, the governor matches the earlier governor: instant rise, 0.02 deadband and 0.04 for each second of fall.

Reason for rule 2: an urgent rise must not delay protection. Reason for rules 3 to 6: they stop oscillation.
Reason for the numbers 0.15, 0.04, 0.02 and 10 s: not stated in the code.

The governor resets on Automatic, on Curve mode without data, and on a change of mode. It also resets on an emergency, but only when the override fires (`keepsSettingInEmergency` off). After a change of mode, the first call returns its target. A change from Curve to Fixed with no floor gives the fixed speed on the next call. Reason: not stated in the code.

### Speed in each mode

- Fixed returns the larger of the fixed speed and the governed floor. The floor passes through the governor as an urgent target. A change of the slider applies at once. A falling floor comes down through the hold and the fall.
- Curve passes the larger of the curve speed and the floor to the governor. The rise is urgent when the floor is above 0. The decision keeps the curve temperature.

Reason for both: pacing without delaying protection.

## Floor invariant

In Fixed and Curve modes, every `.manual` speed is at least the floor of the same snapshot. This holds on every sample, also for a rise smaller than the deadband and for a step from 0.59 to 0.60 at serious pressure. Reason: protection must not wait for pacing.

## Curve warning

`SafetyPolicy.isBelowMinimum` returns true when a curve gives a speed below the floor curve at any point temperature of the two curves. It uses the critical limit of 100 °C. No preset is below the floor. A custom curve with 0.4 at 90 °C is below it. A curve that touches the floor exactly is not.

The curve editor shows an orange warning under the live summary only when the active curve is below the floor. The text is "This curve is below the safety minimum. MacFan runs the fans at least 50% at <temperature at 90> and 80% at <temperature at 95>." The temperatures use the unit of the user. Reason: the text tells the user that the floor overrides the curve.

## Applying a decision

`FanControlEngine.update` applies each decision to the hardware. It ignores a tick when the engine is suspended or the snapshot has no fans. Reason: not stated in the code.

| Decision | State of the engine |
| --- | --- |
| `.system(.userChoice)` | `.system` |
| `.system(.noData)` | `.noData` |
| `.manual`, helper ready | `.controlling(speed:)` |
| `.manual`, helper not ready | `.needsHelper` |
| `.emergency`, helper ready | `.emergency` |
| `.emergency`, helper not ready | `.needsHelper` |
| A failed write or a failed return | `.failed(message)` |

- For each `.system` decision, the engine first returns the fans to macOS. When the return fails, the state is `.failed` and the next tick tries again. Reason: a failed return stays visible.
- A `.manual` or `.emergency` decision needs the helper. Without it, the state is `.needsHelper`. Reason: the chosen mode needs the helper.
- An `.emergency` decision writes every fan at speed 1 (maximum RPM), through the same writer as `.manual`. The helper, limits, restore obligation, generation and failed-write rules are the same. Reason: one write path keeps the safety rules in one place.
- On successful writes, an `.emergency` decision never returns the fans to macOS: not on entry, not during the emergency, not on recovery to Fixed or Curve. Reason: the owner wants MacFan, not macOS, to cool hard.
- A `.manual` or `.emergency` decision needs fans with known limits. Without them, the state is `.failed` and the fans return to macOS. Reason: not stated in the code.
- The engine writes the target of each fan on every tick, also when it did not change. Reason: the write is the heartbeat of the helper.
- A failed write sets `.failed` and returns the fans to macOS. Reason: a write can fail halfway and leave some fans manual.
- `isCriticallyHot` is true while either latch is set, whatever the decision. Reason: the interface warns the user who keeps their setting in an emergency.

The restore obligation keeps the promise that the fans return to macOS:

1. `mayBeControlling` starts true. Reason: a manual state left by a crash clears on the first tick.
2. The engine sets it before the first write. It clears it only after macOS confirms that it has the fans. Reason: no failure path can lose the obligation to restore.
3. Without a ready helper, the return succeeds and keeps the obligation. Reason: MacFan cannot have written anything in this session, and the obligation clears once the helper is ready.

The fans also return to macOS before sleep and on quit. Reason: macOS is where MacFan always returns to. The helper does the same when the app vanishes or goes silent.

- `suspend()` invalidates each update in flight. An update checks its generation after every `await`. Reason: no target can follow the return.
- `shutdown()` is synchronous and calls a bounded restore when the obligation is set and the helper is ready. Reason: the process is about to exit.

## Thermal state in the app

`HardwareMonitor.snapshot(at:)` stores `ProcessInfo.processInfo.thermalState` in the snapshot. `AppModel.tick` copies `snapshot.thermalState` to its own `thermalState`. Reason: the planner and the interface see one value. The interface uses it for the status and for the throttling flag of hot moments.

`AppModel` also observes `ProcessInfo.thermalStateDidChangeNotification` and refreshes. The refresh only wakes the pending sleep of the loop. A tick in flight is not pre-empted. Reason: not stated in the code.

## Invariants

1. A `.manual` speed in Fixed and Curve modes is never below the floor of that tick. Reason: protection must not wait for pacing.
2. Max never goes to macOS because of an emergency. Reason: Max is already the strongest cooling.
3. Missing data never clears an emergency. Reason: missing data is never good news.
4. No failure path loses the obligation to restore system control. Reason: see "Applying a decision".
5. In Fixed and Curve with the flag off, every tick with either latch set writes full speed. MacFan never gives the fans to macOS because of an emergency. Reason: the owner wants MacFan, not macOS, to cool hard.
6. MacFan still gives the fans to macOS on Automatic, on missing data, on a failed write, on sleep and on quit. Reason: macOS is where MacFan always returns to.
7. With the flag on, the Fixed or Curve speed is never below the floor of the tick. The floor comes from CPU and GPU readings and from pressure only. Die, battery, storage and memory emergencies add no speed. Reason: the floor is the only protection that stays with the flag on.

## Interface

| Element | Behavior |
| --- | --- |
| Mode tag | `.emergency` shows "Full speed (safety)". |
| Fans banner | `.emergency` shows an orange banner, "Fans at full speed". It names both triggers. |
| Keep-setting banner | A red banner, "Critically hot — keeping your setting", shows only in Fixed and Curve with the flag on, while the state is `.controlling` and `isCriticallyHot` is true. |
| Fans footnote | The text covers Smart Curve and Fixed Speed only. It changes with the flag. |
| Setting | Settings › General has the toggle "Keep my fan setting during emergencies". Its footer starts with "Risky." and names both triggers. |

Reason for the flag in the banner rule: with the flag off, `isCriticallyHot` turns true before the full-speed writes finish. The banner must not claim that the user opted out.

## Related decisions

- [Fan safety floor and pacing](../decisions/2026-11-06-fan-safety-floor-and-pacing.md)
- [Emergency full speed](../decisions/2026-11-06-emergency-full-speed.md)
