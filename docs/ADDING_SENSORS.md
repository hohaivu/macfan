# Adding sensors

Every Mac model exposes a different set of SMC keys. MacFan names them using a small rule
table in [`Sources/MacFanCore/Hardware/SensorCatalog.swift`](../Sources/MacFanCore/Hardware/SensorCatalog.swift).
Sensors that match no rule still appear, as "Sensor XXXX", when **Show Unidentified
Sensors** is on in the Sensors toolbar.

## 1. Find the key

```sh
swift run macfanctl keys
```

prints every temperature key, its type, its current value, and the name MacFan gives it
(`—` means unidentified):

```
TC10  flt     56.35  —
TB0T  flt     39.40  Battery
TH0a  flt     42.20  SSD #
```

Put your Mac under a load that heats only the part you're curious about (for example
`yes > /dev/null` for the CPU, a game for the GPU, a large file copy for the SSD) and watch
which values rise.

## 2. Add a rule

Apple Silicon CPU cores are not wildcard rules. Add them to the per-family core-key
table in `SensorCatalog.swift` (see [the sensors spec](specs/sensors.md)). A core key
becomes `.cpu`. Any other `Tp??`, `Te??` or `Tf??` key on that family becomes `.cpuDie`,
which stays out of the default CPU temperature but still counts for safety. The rules
below cover everything else.

```swift
Rule("TC1?", .cpu, "CPU Cluster #"),
```

- `?` matches any single character.
- `#` becomes a number ("CPU Cluster 1", "CPU Cluster 2"…), dropped when only one key matches.
- Rules are checked top to bottom; the first match wins. Put exact keys above wildcards.

## 3. Add a test

Add a case to the `classifies apple silicon and intel families` test in
`Tests/MacFanCoreTests/SensorCatalogTests.swift`, then run `swift test`.

## 4. Open a pull request

Include your Mac model (`sysctl -n hw.model`), your chip, and how you identified the key.
If you are not sure what a key measures, open an issue with the `macfanctl keys` output
instead — guesses presented as facts make the app less trustworthy.
