# Contributing

Thanks for helping. The most valuable contributions, roughly in order:

1. **Sensor names for your Mac** — see [docs/ADDING_SENSORS.md](docs/ADDING_SENSORS.md).
2. **Bug reports** with your Mac model, macOS version, and the output of
   `swift run macfanctl sensors --all` and `swift run macfanctl fans`.
3. **Fixes and features** — open an issue first for anything bigger than a small fix, so
   we can agree on the approach.

## Development

```sh
swift build        # everything
swift test         # unit tests (must pass)
make app           # build/MacFan.app
```

### Project layout

| Module | What it does |
| --- | --- |
| `CPrivateIOKit` | C declarations: SMC parameter block, private HID temperature API |
| `SMCKit` | Talks to the SMC: keys, value encoding, fan control |
| `MacFanCore` | Domain logic: sensors, catalog, curves, safety, history, logging. No UI. |
| `MacFanXPC` | The app ↔ helper contract |
| `MacFanHelper` | The root daemon |
| `MacFanCLI` | The `macfanctl` command |
| `MacFan` | The SwiftUI app |

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing structure.

## Guidelines

- **Swift 6.2, strict concurrency, no warnings.** The package builds warning-free; keep it so.
- **Concurrency defaults.** The app target is main-actor by default with Approachable
  Concurrency; don't add `@MainActor` there. Libraries (`SMCKit`, `MacFanCore`) stay
  `nonisolated`. Move work off the main actor only with a reason you can state in a comment.
- **Value types first.** `struct`/`enum` unless you need identity or shared mutable state.
  `@unchecked Sendable` only with real synchronization, explained in a comment.
- **Tests use Swift Testing** with readable raw-identifier names:
  `` @Test func `hotter never means slower`() ``.
- **Logic goes in `MacFanCore`, with tests.** Views should only lay out and forward actions.
- **Use the design system.** Spacing, radii, motion and colors come from
  `Sources/MacFan/DesignSystem`. No magic numbers in views.
- **Write copy for people.** Short, specific, and actionable. "Running hot — quit heavy apps
  you aren't using" beats "Thermal threshold exceeded".
- **Accessibility is not optional.** Never encode meaning in color alone; give custom
  controls labels and values; respect Reduced Motion.
- **Changes to the helper or `MacFanHelperProtocol` need extra review.** They run as root.
  Bump `HelperConstants.protocolVersion` when the protocol changes.
- **Never weaken a safety net** (restore on quit/sleep/disconnect/watchdog, full speed in an emergency)
  without discussing it in an issue first.

## Commit style

Small, focused commits with imperative subjects: "Add M4 GPU sensor names", "Fix fan
restore after wake".
