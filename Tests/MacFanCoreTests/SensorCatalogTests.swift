import Testing
@testable import MacFanCore

@Suite("SensorCatalog")
struct SensorCatalogTests {
    @Test func `exact keys win over wildcards`() {
        let proximity = SensorCatalog.classify(smcKey: "TC0P")
        #expect(proximity.nameTemplate == "CPU Proximity")
        #expect(proximity.category == .cpu)

        let core = SensorCatalog.classify(smcKey: "TC3C")
        #expect(core.nameTemplate == "CPU Core #")
    }

    @Test func `integrated GPU is not a CPU core`() {
        #expect(SensorCatalog.classify(smcKey: "TCGC").category == .gpu)
    }

    @Test(arguments: [
        ("Tp01", SensorCategory.cpu),
        ("Te05", .cpu),
        ("Tg0D", .gpu),
        ("TH0a", .storage),
        ("TB1T", .battery),
        ("TW0P", .wireless),
        ("TaLP", .enclosure),
    ])
    func `classifies apple silicon and intel families`(key: String, category: SensorCategory) {
        let result = SensorCatalog.classify(smcKey: key)
        #expect(result.category == category)
        #expect(result.isIdentified)
    }

    @Test func `unknown keys are unidentified`() {
        let result = SensorCatalog.classify(smcKey: "TZZZ")
        #expect(result.category == .other)
        #expect(!result.isIdentified)
        #expect(result.nameTemplate == "Sensor TZZZ")
    }

    @Test func `airflow keys below room temperature are not airflow`() {
        #expect(!SensorCatalog.classify(smcKey: "Ta05").isIdentified)
    }

    @Test func `classifies HID products`() {
        #expect(SensorCatalog.classify(hidProduct: "NAND CH0 temp")?.category == .storage)
        #expect(SensorCatalog.classify(hidProduct: "gas gauge battery")?.category == .battery)
        #expect(SensorCatalog.classify(hidProduct: "PMU tdie3")?.category == .cpu)
        #expect(SensorCatalog.classify(hidProduct: "PMU tcal") == nil)
        #expect(SensorCatalog.classify(hidProduct: "Mystery")?.isIdentified == false)
    }

    @Test func `plausibility rejects disconnected sensors`() {
        #expect(!SensorCatalog.isPlausible(celsius: 0))
        #expect(!SensorCatalog.isPlausible(celsius: -40))
        #expect(!SensorCatalog.isPlausible(celsius: .nan))
        #expect(!SensorCatalog.isPlausible(celsius: 200))
        #expect(SensorCatalog.isPlausible(celsius: 45))
    }

    @Test func `temperature types`() {
        #expect(SensorCatalog.isTemperatureType("flt "))
        #expect(SensorCatalog.isTemperatureType("sp78"))
        #expect(!SensorCatalog.isTemperatureType("ui8 "))
    }
}

@Suite("SensorNaming")
struct SensorNamingTests {
    @Test func `numbers repeated templates in order`() {
        #expect(SensorNaming.resolve(["CPU #", "CPU #", "CPU #"]) == ["CPU 1", "CPU 2", "CPU 3"])
    }

    @Test func `drops the number when there is only one`() {
        #expect(SensorNaming.resolve(["GPU #", "Battery"]) == ["GPU", "Battery"])
    }

    @Test func `counts each template separately`() {
        #expect(SensorNaming.resolve(["SSD #", "CPU #", "SSD #"]) == ["SSD 1", "CPU", "SSD 2"])
    }
}

@Suite("Temperature")
struct TemperatureTests {
    @Test func `levels follow category thresholds`() {
        #expect(SensorCategory.cpu.thresholds.level(for: 85) == .warm)
        #expect(SensorCategory.cpu.thresholds.level(for: 95) == .hot)
        // The same temperature is alarming for a battery.
        #expect(SensorCategory.battery.thresholds.level(for: 56) == .critical)
    }

    @Test func `converts to fahrenheit`() {
        #expect(TemperatureUnit.fahrenheit.convert(fromCelsius: 100) == 212)
        #expect(TemperatureUnit.fahrenheit.convertDelta(fromCelsius: 10) == 18)
        #expect(TemperatureUnit.celsius.convert(fromCelsius: 42) == 42)
    }

    @Test func `display order is natural`() {
        let names = ["CPU 10", "CPU 2", "CPU 1"].map { Fixtures.reading(50, id: $0) }
        #expect(names.sorted(by: SensorReading.displayOrder).map(\.sensor.name) == ["CPU 1", "CPU 2", "CPU 10"])
    }
}

/// Per-family core keys. Expectations are written by hand from the Stats table
/// (exelban/stats, Modules/Sensors/values.swift @ a0b1c12e8b2162721450962623cb80bf5ee09001),
/// never computed from the production tables.
@Suite("Chip family core keys")
struct ChipFamilyTests {
    typealias Expected = (category: SensorCategory, template: String)
    static let perf: Expected = (.cpu, "CPU Performance Core #")
    static let eff: Expected = (.cpu, "CPU Efficiency Core #")
    static let `super`: Expected = (.cpu, "CPU Super Core #")
    static let die: Expected = (.cpuDie, "CPU Die #")

    /// `macfanctl keys` on Mac16,8 (Apple M4 Pro).
    static let m4ProKeys = """
        Tp00 Tp01 Tp02 Tp04 Tp05 Tp06 Tp08 Tp09 Tp0A Tp0C Tp0D Tp0E Tp0G Tp0H Tp0I Tp0K Tp0L Tp0M Tp0O Tp0P Tp0Q Tp0S Tp0T Tp0U Tp0W Tp0X Tp0Y \
        Tp0a Tp0b Tp0c Tp0d Tp0e Tp0f Tp0g Tp0i Tp0k Tp0l Tp0m Tp0n Tp0o Tp0q Tp0t Tp0u Tp0v Tp0w Tp1i Tp1j Tp1k Tp1m Tp1n Tp1o Tp1q Tp1t Tp1u \
        Tp1v Tp1w Tp1x Tp1y Tp1z Tp20 Tp21 Tp22 Tp23 Tp24 Tp25 Tp26 Tp27 Tp28 Tp29 Tp2A Tp2B Tp2C Tp2D Tp2E Tp2G Tp2I Tp2J Tp2K Tp2L Tp2M Tp2N \
        Tp2O Tp2Q Tp2R Tp2S Tp2T Tp2U Tp2V Tp2W Tp2X Tpx0 Tpx1 Tpx2 Tpx3 Tpx4 Tpx5 Tpx8 Tpx9 TpxA TpxB TpxC TpxD Te04 Te05 Te06 Te0R Te0S Te0T \
        Tex0 Tex1 Tex2 Tex3 TfC0 TfC1 TfC2 TfC3 TfC4 Tg0K Tg1U TH0a TB0T TW0P TaLP Ts0P TVMR TMVR TCMz
        """.split(separator: " ").map(String.init)

    @Test(arguments: [
        ("Apple M4 Pro", "M4"),
        ("Apple M1", "M1"),
        ("Apple M2 Ultra", "M2"),
        ("Apple A18 Pro", "A18"),
    ] as [(String, String?)] + [
        ("Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz", nil),
        ("", nil),
    ])
    func `parses the chip family from the brand`(brand: String, family: String?) {
        #expect(SensorCatalog.chipFamily(brand: brand) == family)
    }

    /// Classifications before this change (base 50f5030), written out by hand from its `smcRules`:
    /// every Tp??/Tf?? is "CPU #", every Te?? is "CPU Efficiency #", all identified `.cpu`.
    static func legacy(_ key: String) -> SensorCatalog.Classification {
        func c(_ category: SensorCategory, _ name: String, _ identified: Bool = true) -> SensorCatalog.Classification {
            .init(category: category, nameTemplate: name, isIdentified: identified)
        }
        switch key {
        case _ where key.hasPrefix("Tp") || key.hasPrefix("Tf"): return c(.cpu, "CPU #")
        case _ where key.hasPrefix("Te"): return c(.cpu, "CPU Efficiency #")
        case "Tg0K", "Tg1U": return c(.gpu, "GPU #")
        case "TH0a": return c(.storage, "SSD #")
        case "TB0T": return c(.battery, "Battery")
        case "TW0P": return c(.wireless, "Wi-Fi Module")
        case "TaLP": return c(.enclosure, "Airflow Left #")
        case "Ts0P": return c(.enclosure, "Palm Rest #")
        case "TVMR": return c(.power, "Voltage Regulator #")
        case "TMVR": return c(.memory, "Memory #")
        case "TCMz": return c(.other, "Sensor TCMz", false)
        default: preconditionFailure("no hand-written legacy expectation for \(key)")
        }
    }

    @Test(arguments: [
        ("Tp01", SensorCategory.cpu, "CPU #", true),
        ("Tf10", .cpu, "CPU #", true),
        ("Te05", .cpu, "CPU Efficiency #", true),
        ("Tex0", .cpu, "CPU Efficiency #", true),
        ("TC0P", .cpu, "CPU Proximity", true),
        ("TC3C", .cpu, "CPU Core #", true),
        ("TCGC", .gpu, "Integrated GPU", true),
        ("Tg0K", .gpu, "GPU #", true),
        ("TH0a", .storage, "SSD #", true),
        ("TCMz", .other, "Sensor TCMz", false),
        ("TZZZ", .other, "Sensor TZZZ", false),
    ] as [(String, SensorCategory, String, Bool)])
    func `key without a family classifies as before this change`(key: String, category: SensorCategory, name: String, identified: Bool) {
        let expected = SensorCatalog.Classification(category: category, nameTemplate: name, isIdentified: identified)
        #expect(SensorCatalog.classify(smcKey: key) == expected)
        #expect(SensorCatalog.classify(smcKey: key, chipFamily: nil) == expected)
        #expect(SensorCatalog.classify(smcKeys: [key], chipFamily: nil) == [expected])
    }

    @Test func `no family classifies every M4 Pro key as before`() {
        let expected = Self.m4ProKeys.map(Self.legacy)
        #expect(Self.m4ProKeys.map { SensorCatalog.classify(smcKey: $0) } == expected)
        #expect(Self.m4ProKeys.map { SensorCatalog.classify(smcKey: $0, chipFamily: nil) } == expected)
        #expect(SensorCatalog.classify(smcKeys: Self.m4ProKeys, chipFamily: nil) == expected)
        #expect(SensorCatalog.classify(smcKeys: Self.m4ProKeys, chipFamily: "M9") == expected)
    }

    /// Regression for the reported bug: the default CPU reading was the hottest of every Tp/Te/Tf key,
    /// so die hotspots (83 °C) drove it instead of the cores (62 °C Stats shows).
    @Test func `M4 Pro default CPU reading follows the cores, not the die hotspots`() {
        let cores: Set = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0Y", "Tp0b", "Tp0e", "Te05", "Te0S"]
        let keys = Self.m4ProKeys
        let readings = zip(keys, SensorCatalog.classify(smcKeys: keys, chipFamily: "M4")).map { key, classification in
            Fixtures.reading(cores.contains(key) ? 62 : (["Tp", "Te", "Tf"].contains { key.hasPrefix($0) } ? 83 : 40),
                             category: classification.category, id: key)
        }
        let snapshot = Fixtures.snapshot(readings)
        #expect(snapshot.hottest(in: [.cpu])?.celsius == 62)
        #expect(snapshot.hottest(in: [.cpu, .gpu])?.celsius == 62)
        #expect(snapshot.summaries().first { $0.category == .cpu }?.hottest.celsius == 62)
        #expect(snapshot.hottest()?.celsius == 83, "hotspots stay visible overall")
    }

    @Test func `M4 Pro keeps exactly the Stats core keys as CPU`() {
        let keys = Self.m4ProKeys
        let result = SensorCatalog.classify(smcKeys: keys, chipFamily: "M4")
        #expect(result.count == keys.count)

        let cores = Set(["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0Y", "Tp0b", "Tp0e", "Te05", "Te0S"])
        #expect(Set(zip(keys, result).filter { $0.1.category == .cpu }.map(\.0)) == cores)

        for (key, classification) in zip(keys, result) {
            if cores.contains(key) {
                let template = key.hasPrefix("Te") ? "CPU Efficiency Core #" : "CPU Performance Core #"
                #expect(classification == .init(category: .cpu, nameTemplate: template, isIdentified: true), "\(key)")
            } else if ["Tp", "Te", "Tf"].contains(where: key.hasPrefix) {
                #expect(classification == .init(category: .cpuDie, nameTemplate: "CPU Die #", isIdentified: true), "\(key)")
            } else {
                #expect(classification == SensorCatalog.classify(smcKey: key), "\(key) must not change")
            }
        }
    }

    @Test func `a known family never ends up without CPU sensors`() {
        for family in ["M1", "M2", "M3", "M4", "M5", "M6", "A18"] {
            let result = SensorCatalog.classify(smcKeys: Self.m4ProKeys + ["Tf04", "Tp0O", "Tp0j", "Tp1h"], chipFamily: family)
            #expect(result.contains { $0.category == .cpu }, "\(family)")
        }
    }

    @Test(arguments: [
        ("M1", [("Tp01", perf), ("Tp09", eff), ("Tp0T", eff), ("Tp02", die)]),
        ("M2", [("Tp09", perf), ("Tp1h", eff), ("Tp0T", die)]),
        ("M3", [("Tf04", perf), ("Te05", eff), ("Tf14", die), ("Tp01", die)]),
        ("M4", [("Tp09", perf), ("Te05", eff), ("Tp0T", die)]),
        ("M5", [("Tp00", `super`), ("Tp0O", perf), ("Te05", die)]),
        ("M6", [("Tp0j", `super`), ("Tp05", perf), ("Te07", eff), ("Tp01", die)]),
        ("A18", [("Tp05", perf), ("Te05", eff), ("Tp01", die)]),
    ] as [(String, [(String, Expected)])])
    func `each family routes keys through its own table`(family: String, rows: [(String, Expected)]) {
        // Tg0K and TB0T ride along: non-CPU keys never change.
        let keys = rows.map(\.0) + ["Tg0K", "TB0T"]
        let result = SensorCatalog.classify(smcKeys: keys, chipFamily: family)
        for (index, row) in rows.enumerated() {
            #expect(result[index] == .init(category: row.1.category, nameTemplate: row.1.template, isIdentified: true), "\(family) \(row.0)")
        }
        #expect(result[rows.count] == SensorCatalog.classify(smcKey: "Tg0K"))
        #expect(result[rows.count + 1] == SensorCatalog.classify(smcKey: "TB0T"))
    }

    @Test func `working tables are told apart from the all-legacy fallback`() {
        let keys = ["Tp01", "Tp02", "Te05", "Tf10", "TH0a"]
        let result = SensorCatalog.classify(smcKeys: keys, chipFamily: "M2")
        #expect(result.map(\.category) == [.cpu, .cpuDie, .cpuDie, .cpuDie, .storage])
        #expect(result[0].nameTemplate == "CPU Performance Core #")
        #expect(result[1...3].allSatisfy { $0.nameTemplate == "CPU Die #" && $0.isIdentified })
    }

    @Test(arguments: [
        (nil, ["Tp01", "Tp02", "Te05", "Tf10", "TH0a", "Tg0K"]),
        ("M9", ["Tp01", "Tp02", "Te05", "Tf10", "TH0a", "Tg0K"]),
        // None of M4's core keys are present, so the table doesn't fit this Mac.
        ("M4", ["Tp00", "Tp02", "Te04", "TfC0", "Tg0K"]),
    ] as [(String?, [String])])
    func `falls back to the family-less rules`(family: String?, keys: [String]) {
        let result = SensorCatalog.classify(smcKeys: keys, chipFamily: family)
        #expect(result == keys.map { SensorCatalog.classify(smcKey: $0) })
        #expect(!result.contains { $0.category == .cpuDie })
    }
}
