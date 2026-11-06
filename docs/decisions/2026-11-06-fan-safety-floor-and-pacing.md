# Fan safety floor and pacing

## Context
Curve and Fixed modes had no protection between normal load and the 100 °C return to macOS.
The planner ignored thermal pressure, which sees throttling that the sensors miss.
Excess fan noise was a complaint of the user.

## Decision
- The floor reads identified `.cpu` and `.gpu` readings only. This is a product default.
- The floor is relative to the critical limit of each category: 0 at −15, 0.5 at −10, 0.8 at −5.
- Serious pressure sets a floor of 0.6. Critical pressure returns the fans to macOS until fair or nominal. Superseded in part by [Emergency full speed](2026-11-06-emergency-full-speed.md).
- A hold time of 10 s delays a fall. We use it instead of a temperature band.
- An urgent rise (any positive floor) bypasses the deadband, the hold and the rise cap of 0.15/s.

## Consequence
- No early warning comes from die, battery, storage or memory readings below their critical limits.
- Battery, storage and memory rely on the emergency at their critical limits of 55, 75 and 85 °C.
- A custom curve below the floor runs at the floor. The curve editor warns about it.
