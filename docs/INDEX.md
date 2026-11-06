# Documentation index

| Domain | Spec file | Key code paths | One-line summary |
| --- | --- | --- | --- |
| Sensors | [docs/specs/sensors.md](specs/sensors.md) | `Sources/MacFanCore/Hardware/SensorCatalog.swift`, `Sources/MacFanCore/Hardware/SensorProviders.swift`, `Sources/MacFanCore/Models/Sensor.swift` | How SMC/HID keys become named sensors and which ones drive CPU temperature and safety |
| Fan control | [docs/specs/fan-control.md](specs/fan-control.md) | `Sources/MacFanCore/Control/CoolingPlanner.swift`, `Sources/MacFanCore/Control/FanCurve.swift`, `Sources/MacFanCore/Control/FanControlEngine.swift` | How a mode, curve, safety floor and thermal pressure become a fan speed |

## Other documents

- [Architecture](ARCHITECTURE.md)
- [Adding sensors](ADDING_SENSORS.md)
- [Releasing](RELEASING.md)

## Active decisions

- [CPU core keys from Stats](decisions/2026-11-06-cpu-core-keys-from-stats.md)
- [Fan safety floor and pacing](decisions/2026-11-06-fan-safety-floor-and-pacing.md)
