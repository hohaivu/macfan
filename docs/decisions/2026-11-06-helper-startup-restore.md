# Helper start-up restore

## Context
A helper that SIGKILL stopped, or that crashed, leaves the fans in manual mode.
The app cannot always restore them, for example when it is frozen or not running.

## Decision
The helper restores the fans at start, with no check of the current state.
A failed restore does not stop the helper. The existing session watchdog retries it every 5 s.
launchd `KeepAlive` with `SuccessfulExit` false relaunches the helper. We add no separate watchdog process.
The helper then also starts at boot. We accept this.
The app keeps the exact version match. A mismatch stops all commands (fail-closed).

## Consequence
- Every user must click "Update Helper" one time. Development installs must run the dev installer again.
- While the SMC stays unavailable, the helper logs one error every 5 s.
- A repeated crash gives throttled relaunches. Throttling does not stop them.
