# CPU core keys from Stats

## Context
Wildcards labelled 117 keys as CPU on an M4 Pro, and the CPU number was the maximum of them.
The third key of each `Tp`/`Te` triplet runs 8 to 20 °C hotter than the cores.
Smart Curve then ran the fans much harder than macOS does.
Key layouts differ between chip generations, so a wildcard cannot select the cores.

## Decision
MacFan copies the per-family core-key tables of the Stats app (exelban/stats, `Modules/Sensors/values.swift`, commit `a0b1c12e8b2162721450962623cb80bf5ee09001`).
Stats is widely used and maintained, and users compare MacFan against it. We do not guess from key structure.
All other `Tp/Te/Tf` keys become `.cpuDie`. Emergency checks still read them.
The CPU number is the hottest core, not the core average. Reason: the curve stays conservative.

## Consequence
- The tables are a reference mapping, not verified thermistor semantics. They do not promise a key for every physical core.
- `Tp0Y` on M4 Pro acts like a hotspot key, about 8 °C above the other cores. MacFan keeps it to match Stats.
- A wrong key that is present goes undetected. The fallback covers only missing keys.
