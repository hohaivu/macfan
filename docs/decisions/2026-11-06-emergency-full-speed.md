# Emergency full speed

## Context
In an emergency, Fixed and Curve gave the fans to macOS. The user saw "macOS is cooling your Mac" and asked MacFan to cool harder.

## Decision
- In an emergency, Fixed and Curve run every fan at full speed.
- The opt-in `keepsSettingInEmergency` keeps the normal control instead. It is off by default and labelled risky.
- Max and Automatic stay unchanged. The safety floor still applies with the opt-in on.
- Missing readings keep the fans at full speed while a latch holds and the flag is off.

## Consequence
- The default no longer gives the fans to macOS on critical heat or critical pressure.
- Keep-my-setting weakens a safety net. CONTRIBUTING requires an issue for this change.
- The owner asked for all of it explicitly. The fork has issues disabled, so the pull request description records the decision instead of an issue.
