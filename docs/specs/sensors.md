# Sensors

MacFan turns raw SMC keys and HID products into named sensors. It also decides which sensors drive the CPU temperature and the safety checks.

## Terms

| Term | Meaning |
| --- | --- |
| SMC key | A four-character name of a value in the System Management Controller. Example: `Tp01`. |
| HID sensor | A temperature service from the IOHID event system. Apple Silicon Macs expose it. |
| Chip family | The generation of the Apple chip. Example: `M4` or `A18`. |
| Core key | An SMC key that reads one CPU core. Each chip family has its own list of them. |
| Die key | Any other `Tp??`, `Te??` or `Tf??` key on a chip family with a core-key list. |
| Identified | A sensor that has a name from a rule. Unidentified sensors are hidden by default. |

## Entry points

| What | Where |
| --- | --- |
| Rule table and classification | `Sources/MacFanCore/Hardware/SensorCatalog.swift` |
| Name numbering (`SensorNaming.resolve`) | `Sources/MacFanCore/Hardware/SensorCatalog.swift` |
| SMC, HID and merged discovery | `Sources/MacFanCore/Hardware/SensorProviders.swift` |
| Chip brand string (`ChipReader.brand`) | `Sources/MacFanCore/Hardware/HardwareMonitor.swift` |
| Categories and thresholds | `Sources/MacFanCore/Models/Sensor.swift` |
| Snapshot queries | `Sources/MacFanCore/Models/HardwareSnapshot.swift` |
| Curve source | `Sources/MacFanCore/Control/CoolingSettings.swift` |
| Emergency logic | `Sources/MacFanCore/Control/CoolingPlanner.swift` |
| Cooling Health log | `Sources/MacFanCore/Insights/CoolingHealth.swift`, `Sources/MacFanCore/Insights/InsightsStore.swift` |

## Classification

### Rule table

`SensorCatalog.smcRules` is an ordered list of rules. Each rule has a key pattern, a category and a name template.

- The first matching rule wins. Reason: exact keys must come before wildcard families.
- In a pattern, `?` matches exactly one character. Reason: not stated in the code.
- In a name template, `#` becomes an ordinal. `SensorNaming.resolve` drops the `#` when only one sensor shares the template. Reason: sensors that share a template need different names, and a lone sensor needs no number.
- A key that matches no rule is `.other`, named "Sensor XXXX", and unidentified. MacFan lists such a key only when the user shows unidentified sensors. Reason: not stated in the code.

### CPU keys

- On Apple Silicon without a core-key list, every `Te??` key is `.cpu` "CPU Efficiency #". Every `Tp??` and `Tf??` key is `.cpu` "CPU #". Reason: not stated in the code.
- A chip family that has a core-key list classifies keys by that list. See "Core keys per chip family". Reason: key layouts differ between chip generations, so a wildcard cannot select the cores.

### HID products

`classify(hidProduct:)` maps a product name to a category.

| Product contains | Result |
| --- | --- |
| `tcal` | Dropped. Reason: it is a calibration constant. |
| `nand` | `.storage` "SSD #" |
| `battery` | `.battery` "Battery #" |
| `tdie` | `.cpu` "SoC Die #" |
| `tdev` | `.enclosure` "Logic Board #" |
| anything else | `.other`, unidentified |

Reason for the names and categories of the other products: not stated in the code.

### Plausibility

- A key is a temperature when its SMC type is `flt ` or starts with `sp` or `fp`. Reason: these are the SMC data types that can hold a temperature.
- A reading counts when it is finite and above 5 °C and below 130 °C. Reason: disconnected sensors read 0 or less, and garbage readings fall outside the range.

## Core keys per chip family

On Apple Silicon, MacFan reads the chip family from `machdep.cpu.brand_string`. `SensorCatalog.chipFamily(brand:)` parses the brand. "Apple M4 Pro" gives `M4`. "Apple A18 Pro" gives `A18`. Intel and any other brand give no family. Reason: the lists cover only Apple chips.

Each supported family (M1, M2, M3, M4, M5, M6, A18) has its own list of core keys. The lists come from the Stats app, at a pinned commit. Reason: users compare MacFan against Stats, and MacFan does not guess from key structure. See [the decision](../decisions/2026-11-06-cpu-core-keys-from-stats.md).

Classification for a family with a list:

1. A core key is `.cpu`, identified. Its name template is "CPU Performance Core #", "CPU Efficiency Core #" or "CPU Super Core #". Reason: the default CPU number must follow the cores (invariant 1).
2. Any other `Tp??`, `Te??` or `Tf??` key is `.cpuDie`, identified, named "CPU Die #". Reason: die keys run hotter than the cores but still show overheating first (invariants 1 and 3).
3. Every other key follows the rule table. Reason: non-CPU sensors do not change.

Each family uses its own list. The same key can mean a different core type in different families. Example: `Tp09` is an efficiency core on M1 and a performance core on M2 and M4. Reason: a shared list would give a wrong core type on some families.

### Fallback

The family-agnostic rules apply when any of these is true:

- The Mac is an Intel Mac. Reason: Intel has no list.
- The chip family is unknown or has no list. Reason: MacFan has no table to route by.
- None of the core keys of the family exist on this Mac. Reason: the table does not fit this Mac.

In the fallback, every `Tp/Te/Tf` key is `.cpu`. Reason: a Mac with an empty `.cpu` category would make the curve source fall back to the overall hottest sensor, which can read much higher.

## Discovery

`SMCSensorProvider.discover` finds the sensors of one Mac.

1. It enumerates every SMC key. When enumeration fails, it uses the exact keys of the rule table. Reason: the rule table gives a usable list when enumeration is unavailable.
2. It keeps keys that start with `T`, have a temperature type and have a plausible value. Reason: see "Plausibility".
3. It classifies the kept keys together with the chip family. The chip family comes from `ChipReader.brand()` and is read one time. Reason: the batch call lets the fallback see every key. Reading one time: not stated in the code.
4. It sorts the sensors by key and resolves the names. Reason: not stated in the code.

A sensor ID is `smc.<key>`. Reason: IDs must stay stable, because preferences store them.

`CompositeSensorProvider.discover` lists the SMC sensors first. It adds a HID sensor only when no identified SMC sensor covers its category. HID `tdie` therefore appears only when SMC has no identified `.cpu` sensor. Reason: the same part must not appear twice. On Apple Silicon, HID usually fills the SSD.

## Categories

`SensorCategory` case order is the display order. `.cpuDie` comes right after `.cpu`. Reason: not stated in the code.

Thresholds differ by part. Reason: an Apple Silicon CPU at 90 °C under load is normal, and a battery at 45 °C is not. `.power` has higher limits. Reason: voltage regulators routinely run in the 70s and 80s. `.cpuDie` uses the limits of `.cpu`. Reason: not stated in the code. Invariant 4 states the safety effect.

| Category | Warm | Hot | Critical | Safety-relevant | Triggers emergency |
| --- | --- | --- | --- | --- | --- |
| `.cpu`, `.gpu` | 70 | 90 | 100 | yes | yes |
| `.cpuDie` | 70 | 90 | 100 | no | yes |
| `.memory` | 50 | 70 | 85 | yes | yes |
| `.storage` | 50 | 65 | 75 | yes | yes |
| `.battery` | 35 | 45 | 55 | yes | yes |
| `.power` | 75 | 95 | 110 | no | no |
| `.wireless`, `.enclosure`, `.other` | 50 | 70 | 85 | no | no |

`triggersEmergency` is true for each safety-relevant category and for `.cpuDie`. Only the emergency checks use it. Reason: die sensors run hotter than the cores but show overheating first. Every other consumer uses the safety-relevant flag, except the safety floor. Safety-relevant categories are those whose overheating is a reason to step in.

The safety floor reads only `.cpu` and `.gpu`. `.cpuDie`, battery, storage and memory keep only the emergency path. Reason: die keys under moderate load and battery heat made the fans loud. See [fan-control.md](fan-control.md).

## Temperature queries

| Query | Result |
| --- | --- |
| `hottest(in:)` | The highest identified reading in the given categories. All categories when none are given. |
| `worstLevel` | The worst level of identified, safety-relevant readings. |
| `summaries()` | One hottest, average and count for each category. |

Reason for `hottest(in:)` choosing the highest Celsius reading in the supplied categories, or across all categories when none are supplied: not stated in the code.

Reason for `worstLevel`: only parts whose overheating is a reason to step in decide the level. Reason for the identified filter and for `summaries()`: not stated in the code.

### Curve source

`TemperatureSource.temperature` resolves the temperature that a curve follows.

- `.hottestCPU` and `.hottestGPU` return the hottest reading of that category. Reason: not stated in the code.
- When the category never reported, they return the overall hottest reading. Reason: this Mac has no such sensor, so the curve needs another source.
- When the category reported before and went quiet, they return nothing. Reason: following a cooler part would under-cool the part that matters.
- `.hottestOverall` returns the hottest identified reading. Reason: not stated in the code.
- `.sensor(id:)` returns the reading of that sensor. Reason: the user chose that sensor.

## Emergency and planning

`CoolingPlanner.decide` runs once for each tick.

- Safety readings are identified readings whose category triggers an emergency. Reason: not stated in the code.
- The planner re-evaluates the emergency only when safety readings exist. Reason: only valid readings can prove that an emergency is over. Missing data is never good news, so an emergency stays an emergency.
- A reading at or above the critical limit of its category starts an emergency. In an emergency, the limit drops by the recovery margin of 5 °C. Reason: the emergency lasts until temperatures fall this far below critical. The code does not state why the margin is 5 °C.
- Automatic mode gives the fans to macOS. Reason: the user chose it, and macOS is where MacFan always returns to.
- In an emergency, the fans go to macOS. Reason: when a part is critically hot, the controller of macOS is the safest place to be. Max mode is the exception and runs at full speed. Reason: Max is already the strongest cooling, so it never needs rescue.
- Critical thermal pressure starts an emergency too, with the same Max exception. Reason: one emergency rule, two triggers. The floor, the pressure latch and the pacing of speeds are in [fan-control.md](fan-control.md).
- Max mode needs no data. Reason: nothing stronger exists to fall back to.
- Fixed mode needs safety readings. Without them, the fans go to macOS with reason `noData`. Reason: without safety readings, MacFan cannot see an emergency.
- Curve mode needs safety readings and a source temperature. Without them, the fans go to macOS with reason `noData`. Reason: the same, and the curve has no temperature to follow.

## Cooling Health log

`CoolingLog` and `InsightsData` persist in one JSON file, `Application Support/MacFan/insights.json`. The file holds `moments` and `cooling`. Reason for one file: not stated in the code.

- `CoolingLog` stores `loadKind`, `entries` and a measure version. The current version is 2. A missing version counts as 1. Reason: version 2 measures the rise on CPU cores, and files of 0.3.x have no version.
- An entry holds the day, the load band and the controller. An entry without a controller decodes as macOS. Reason: logs from before Smart Curve was learned from held only the minutes of macOS.
- A change of `loadKind` empties the entries. Reason: watts and CPU shares cannot be compared.
- A log with a version other than the current one decodes as an empty log. Reason: the CPU rise now measures cores, so earlier entries are not comparable. Learning restarts.
- A reset of the log keeps the `moments`. Reason: not stated in the code.
- A file that cannot be read loads as empty `InsightsData`. Reason: losing history is better than refusing to start.

## Invariants

1. The default CPU number is the hottest core reading. It drives the curve source Hottest CPU, the Overview card, the menu bar rows, the default menu bar title, alerts, the status headline, hot moments and Cooling Health. Reason: die keys run hotter than the cores and made the fans run harder than macOS does.
2. `.cpuDie` readings stay out of the default summaries, the status and the alerts. They stay in the Sensors list and its history. Pinned sensors, the menu bar sensor, a specific sensor as curve source and `hottestOverall` still include them. Reason: the default number must follow the cores (invariant 1). The code does not state why these consumers keep die readings.
3. The set of readings that can start an emergency stays the same as before die keys got their own category. Reason: die sensors are where overheating shows first, and protection must not shrink.
4. A `.cpuDie` reading at or above 100 °C starts an emergency in curve and fixed modes. It uses the same limit and recovery margin as `.cpu`. Reason: invariant 3.
5. A Mac with a known chip family never has zero `.cpu` sensors while it has `Tp/Te/Tf` keys. The fallback guarantees this. Reason: an empty `.cpu` category makes the curve follow the overall hottest sensor.
6. Sensor IDs do not change when names change. Reason: preferences store the IDs.

## Related decisions

- [CPU core keys from Stats](../decisions/2026-11-06-cpu-core-keys-from-stats.md)
