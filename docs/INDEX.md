# Documentation index

| Domain | Spec file | Key code paths | One-line summary |
| --- | --- | --- | --- |
| Sensors | [docs/specs/sensors.md](specs/sensors.md) | `Sources/MacFanCore/Hardware/SensorCatalog.swift`, `Sources/MacFanCore/Hardware/SensorProviders.swift`, `Sources/MacFanCore/Models/Sensor.swift` | How SMC/HID keys become named sensors and which ones drive CPU temperature and safety |
| Helper | [docs/specs/helper.md](specs/helper.md) | `Sources/MacFanHelper/HelperService.swift`, `Sources/MacFanHelper/HelperMain.swift`, `Sources/SMCKit/FanControlSession.swift`, `Resources/io.github.alvinmr.MacFan.helper.plist` | How the privileged helper takes and returns fan control |

## Other documents

- [Architecture](ARCHITECTURE.md)
- [Adding sensors](ADDING_SENSORS.md)
- [Releasing](RELEASING.md)

## Active decisions

- [CPU core keys from Stats](decisions/2026-11-06-cpu-core-keys-from-stats.md)
- [Helper start-up restore](decisions/2026-11-06-helper-startup-restore.md)
