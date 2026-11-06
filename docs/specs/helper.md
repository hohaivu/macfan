# Helper

The helper is a root process that takes manual control of the fans for MacFan and returns them to macOS. It also returns the fans on its own when the app cannot.

## Terms

| Term | Meaning |
| --- | --- |
| Helper | The `macfan-helper` process. launchd runs it as root. |
| App | The MacFan menu bar app. It is the only client of the helper. |
| SMC | The System Management Controller. It holds the fan keys. |
| Restore | To return every fan to macOS control. `FanControlSession.restore` does it. |
| Control | The state in which a fan may be in manual mode. `FanControlSession.isControlling` records it. |
| Heartbeat | A successful target write. It proves that the app is alive. |
| Watchdog | A timer in the helper. It runs every 5 s and checks the session. |
| Session | The `FanControlSession` object. It owns the control rules and has no timers. |
| launchd | The macOS service manager. It starts the helper and can start it again. |
| KeepAlive | A launchd key that makes launchd start a job again after it exits. |
| Protocol version | A string that the helper reports. The app compares it with its own copy. |

## Entry points

| What | Where |
| --- | --- |
| Process start, listener, signal handling, code-signing requirement | `Sources/MacFanHelper/HelperMain.swift` |
| XPC service, serial queue, watchdog timer, start-up restore | `Sources/MacFanHelper/HelperService.swift` |
| Control rules (`restore`, `setTarget`, `checkWatchdog`) | `Sources/SMCKit/FanControlSession.swift` |
| SMC writes (`restoreAutomatic`, mode keys, `Ftst`) | `Sources/SMCKit/SMCFanControl.swift` |
| Protocol version, watchdog timeout | `Sources/MacFanXPC/HelperProtocol.swift` |
| Install, update and version check in the app | `Sources/MacFan/Services/HelperManager.swift` |
| Restore guard in the app | `Sources/MacFanCore/Control/FanControlEngine.swift` (`returnToSystem`) |
| launchd plist for the shipped app | `Resources/io.github.alvinmr.MacFan.helper.plist` |
| launchd plist for development installs | `scripts/install-helper-dev.sh` |

## Flows and states

### Process start

1. `HelperMain.main` builds the service with the code-signing requirement.
2. `HelperMain.main` installs the signal handlers for SIGTERM, SIGINT and SIGHUP.
3. `HelperService.start` restores the fans.
4. `HelperService.start` starts the 5 s watchdog timer.
5. `HelperMain.main` resumes the XPC listener.

### Session states

| State | Meaning | Leaves the state when |
| --- | --- | --- |
| No session | The helper could not open the SMC yet. | A restore or a command opens the SMC. |
| Idle | A session exists. A fan is not in control. | A target write starts control. |
| Controlling | A fan may be in manual mode. | A restore succeeds. |

### Ways control ends

| Cause | Where |
| --- | --- |
| The app asks for a restore. | `HelperService.restoreSystemControl` |
| The last app connection closes while the session controls. | `HelperService.connectionClosed` |
| The app sends no successful write for 20 s. | `FanControlSession.checkWatchdog` |
| A target write fails. | `FanControlSession.setTarget` |
| The helper receives SIGTERM, SIGINT or SIGHUP. | `HelperMain.main` |
| The helper starts. | `HelperService.start` |

## Contracts

### Client access

- The helper accepts an XPC client only when the client matches the code-signing requirement. Reason: only MacFan may command a root process.
- The requirement pins the bundle identifier. When the helper has a team identifier, it also requires an Apple-anchored certificate of the same team. Reason: an ad-hoc build can pin only the bundle identifier, which is weaker. Release builds must be signed.
- The helper exposes three calls: report the protocol version, set one fan target, restore. Reason: the privileged surface stays small.

### Serial queue

- The helper reads and writes every mutable property of `HelperService` on one serial queue only. Reason: XPC calls arrive on any thread. The queue serializes SMC access with the watchdog timer.
- `HelperService` opens the SMC at the first use. When the SMC cannot open, the call fails with `smcUnavailable`. Reason: not stated in the code.

### Taking and keeping control

- The session counts control before the first write. Reason: a write that fails halfway may already have switched a fan to manual.
- A target write with an invalid fan index or a non-finite speed writes nothing and throws before the session changes any state. An unreadable fan count rejects the write in the same way. Reason: not stated in the code.
- A rejected write keeps the previous control state. A fresh session stays out of control. A session that already controls stays in control and keeps its last heartbeat. Reason: not stated in the code.
- A target write that passes the check and then fails restores every fan at once. The session then throws the original error. A rejected write does not do this, because it writes nothing. Reason: a failed write may leave a fan manual.
- Only a successful write counts as a heartbeat. Reason: an app that retries failed writes must not keep the watchdog away.
- The watchdog restores the fans when the session controls and no heartbeat arrived for `watchdogTimeout`. `watchdogTimeout` is 20 s. Reason: if the app goes silent while fans are manual, macOS must get them back.
- The watchdog leaves a healthy session alone. It does nothing when the heartbeat is recent. Reason: not stated in the code.
- A last-client disconnect restores the fans when the session controls. Reason: the app quit or crashed.

### Restoring

- The session ends control only after `restoreAutomatic` returns without an error. Reason: a wrong release leaves fans stuck in manual.
- A failed restore keeps the session in control, also on a session that never wrote. The next watchdog check tries again until a restore succeeds. Reason: a failed restore means a fan may still be manual.
- A restore on an SMC that is already automatic succeeds and changes no value. Reason: not stated in the code.
- `restoreAutomatic` tries every fan. When a fan fails, it throws the last error after the loop. Reason: not stated in the code.
- For a fan with an `F<n>Md` key, a restore writes 0 to the key and reads it back. The restore retries up to `modeSwitchAttempts` times (default 20) with `modeSwitchInterval` pauses (default 0.05 s). When the key never reads 0, the restore throws `writeNotApplied`. Reason: the thermal manager can take a moment to release the fan.
- After the last fan leaves manual mode, a restore writes 0 to `Ftst`. A restore never writes `Ftst` while a fan is manual. Reason: not stated in the code.
- For a Mac without `F<n>Md` keys, a restore clears the bit of the fan in `FS! `. Reason: older Intel firmware uses one bitmask key. Bit `n` forces fan `n`.
- A restore that finds no `FNum` key or an unusable `FNum` throws. Reason: "cannot tell" does not mean "no fans".
- The app skips its restore call while the helper is not ready. The app keeps its restore obligation and restores when the helper becomes ready. Reason: the app cannot have written anything without the helper, and a leftover manual state must clear once the helper is ready.

### Start-up restore

- The helper restores the fans at start, before the first XPC call. The app sends no request. Reason: a helper that SIGKILL stopped, or that crashed, leaves the fans manual.
- The helper never exits because of a failed start-up restore. It keeps running and resumes the listener. Reason: a restart loop does not fix a transient SMC error.
- The helper retries every 5 s until the restore succeeds. This includes a start where the SMC cannot open. Reason: the fans may still be manual.
- With no session, the watchdog tries to open the SMC and restore. With a session, the session rule above owns the retry. Reason: not stated in the code.
- After a successful restore, the helper does not restore again without a new cause. Reason: not stated in the code.
- A command during an unresolved start-up restore behaves as before. `setTargetRPM` and `restoreSystemControl` use the same session and fail with `smcUnavailable` when the SMC cannot open. A successful target write makes the app the owner of control. A successful restore from any path ends the start-up obligation. Reason: not stated in the code.
- The helper logs each failed restore with the reason, also an error from the helper domain. While the SMC stays unavailable, the helper logs one error every 5 s. Reason: not stated in the code.

### Signals and exit status

- SIGTERM makes the helper restore the fans, then exit. Reason: unregister and shutdown send SIGTERM.
- SIGINT and SIGHUP make the helper restore the fans, then exit, as SIGTERM does. Reason: not stated in the code.
- The helper installs the signal handlers before the start-up restore. Reason: a signal during the start-up restore must still restore.
- A signal handler restores on the serial queue. A signal that arrives during the start-up restore restores again after the start-up restore ends. Reason: not stated in the code.
- The helper exits with status 0 when the restore succeeded and with status 1 when it failed. Reason: a non-zero exit lets launchd relaunch the helper into the start-up retry.
- The helper must never exit with status 0 after a failed restore. Reason: launchd does not relaunch the helper after exit 0.
- The helper cannot handle SIGKILL. Reason: a process cannot catch SIGKILL. The launchd relaunch and the start-up restore cover it.

### launchd

- Both plists contain `KeepAlive` with `SuccessfulExit` set to false. launchd then starts the helper again after a crash, SIGKILL or a non-zero exit. The plists contain no other new key. Reason: recovery without the app running.
- `KeepAlive` also starts the helper at boot. After exit 0, only a request to the Mach service starts the helper. Reason: not stated in the code.
- launchd throttles frequent relaunches. Throttling slows a repeated crash and does not stop it. Reason: not stated in the code.
- `bootout`, unregister and shutdown stop relaunches. When the SMC itself fails, no restore is guaranteed. Reason: not stated in the code.
- The shipped plist uses `BundleProgram`, `MachServices` and `AssociatedBundleIdentifiers`. `SMAppService` registers it. Reason: not stated in the code.
- The development plist uses `Program` with `/Library/PrivilegedHelperTools/io.github.alvinmr.MacFan.helper` and `MachServices`. The dev installer makes a classic daemon in `/Library/LaunchDaemons`. Reason: macOS can refuse to start the helper of an ad-hoc signed build.

### Protocol version

- `HelperConstants.protocolVersion` is "3". Reason: the helper behavior and its plist changed. The update re-registers the daemon, so launchd loads the new plist.
- The author bumps the version when the protocol or the helper behavior changes. Reason: replacing the app does not restart a running helper. Without a bump, an updated app keeps talking to the old helper code until the Mac restarts.
- The app compares the helper version with its own version by exact equality. Any difference gives the status `.outdated`. Reason: not stated in the code.
- The app sends no command to a helper with the status `.outdated`. The fans stay with macOS. Reason: not stated in the code.
- A helper that answers wins over the `SMAppService` status. Reason: this also covers helpers that `scripts/install-helper-dev.sh` installed.
- "Update Helper" unregisters the daemon, then registers it again, when the status is `.outdated` or the service is enabled. Reason: not stated in the code.
- "Update Helper" does not replace a helper that `scripts/install-helper-dev.sh` installed. That helper is a classic daemon. The developer runs the dev installer again. Reason: not stated in the code.

## Related decisions

- [Helper start-up restore](../decisions/2026-11-06-helper-startup-restore.md)
