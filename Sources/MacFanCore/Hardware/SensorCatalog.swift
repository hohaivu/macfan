import Foundation

/// Maps raw SMC keys and HID product names to human names and categories.
///
/// This file is the main place to contribute support for new Macs. Rules are checked
/// top to bottom; the first match wins, so put exact keys before wildcard families.
/// In a pattern, `?` matches any single character. In a name, `#` becomes an ordinal
/// ("CPU 1", "CPU 2"…) and is dropped when only one sensor shares the name.
///
/// Run `swift run macfanctl keys` to list every temperature key on your Mac.
public enum SensorCatalog {
    public struct Rule: Sendable {
        public let pattern: String
        public let category: SensorCategory
        public let name: String

        public init(_ pattern: String, _ category: SensorCategory, _ name: String) {
            self.pattern = pattern
            self.category = category
            self.name = name
        }
    }

    public struct Classification: Hashable, Sendable {
        public let category: SensorCategory
        public let nameTemplate: String
        public let isIdentified: Bool
    }

    public static let smcRules: [Rule] = [
        // CPU — Intel
        Rule("TC0P", .cpu, "CPU Proximity"),
        Rule("TC0D", .cpu, "CPU Die"),
        Rule("TC0E", .cpu, "CPU Die (Virtual)"),
        Rule("TC0F", .cpu, "CPU Die (Filtered)"),
        Rule("TC0H", .cpu, "CPU Heatsink"),
        Rule("TCXC", .cpu, "CPU PECI"),
        Rule("TCSA", .cpu, "CPU System Agent"),
        Rule("TCGC", .gpu, "Integrated GPU"),
        Rule("TC?C", .cpu, "CPU Core #"),
        // CPU — Apple Silicon. Key layouts differ between chip generations, so cores come
        // from `coreKeys`. These wildcards only apply to unknown chips (see `classify(smcKeys:chipFamily:)`).
        Rule("Te??", .cpu, "CPU Efficiency #"),
        Rule("Tp??", .cpu, "CPU #"),
        Rule("Tf??", .cpu, "CPU #"),

        // GPU
        Rule("TG0P", .gpu, "GPU Proximity"),
        Rule("TG0D", .gpu, "GPU Die"),
        Rule("TG0H", .gpu, "GPU Heatsink"),
        Rule("TG??", .gpu, "GPU #"),
        Rule("Tg??", .gpu, "GPU #"),

        // Memory
        Rule("TM0P", .memory, "Memory Proximity"),
        Rule("TM?S", .memory, "Memory Slot #"),
        Rule("Tm??", .memory, "Memory #"),
        Rule("TM??", .memory, "Memory #"),

        // Storage
        Rule("TH0?", .storage, "SSD #"),

        // Battery
        Rule("TB0T", .battery, "Battery"),
        Rule("TB?T", .battery, "Battery Cell #"),

        // Power
        Rule("TPCD", .power, "Platform Controller Hub"),
        Rule("TV??", .power, "Voltage Regulator #"),

        // Wireless
        Rule("TW0P", .wireless, "Wi-Fi Module"),
        Rule("TW??", .wireless, "Wireless #"),

        // Enclosure
        Rule("TA?P", .enclosure, "Ambient #"),
        // `Ta0?` keys on Apple Silicon read well below room temperature; they aren't airflow.
        Rule("TaL?", .enclosure, "Airflow Left #"),
        Rule("TaR?", .enclosure, "Airflow Right #"),
        Rule("TaT?", .enclosure, "Airflow Top #"),
        Rule("Ts?P", .enclosure, "Palm Rest #"),
        Rule("Th?H", .enclosure, "Heat Pipe #"),
        Rule("TI?P", .enclosure, "Thunderbolt #"),
        Rule("TL0P", .enclosure, "Display"),
        Rule("TZ?C", .enclosure, "Thermal Zone #"),
    ]

    /// Fallback when key enumeration is unavailable.
    public static let wellKnownSMCKeys: [String] = smcRules
        .map(\.pattern)
        .filter { !$0.contains("?") }

    /// Core keys per chip family, copied from Stats (exelban/stats, Modules/Sensors/values.swift
    /// @ a0b1c12e8b2162721450962623cb80bf5ee09001). `Tp09` is an efficiency core on M1 and a
    /// performance core on M2/M4, so each family needs its own table.
    private static let coreKeys: [String: [String: String]] = {
        let performance = "CPU Performance Core #", efficiency = "CPU Efficiency Core #", `super` = "CPU Super Core #"
        func table(_ groups: [(String, String)]) -> [String: String] {
            Dictionary(groups.flatMap { name, keys in keys.split(separator: " ").map { (String($0), name) } },
                       uniquingKeysWith: { first, _ in first })
        }
        return [
            "M1": table([(performance, "Tp01 Tp05 Tp0D Tp0H Tp0L Tp0P Tp0X Tp0b"), (efficiency, "Tp09 Tp0T")]),
            "M2": table([(performance, "Tp01 Tp05 Tp09 Tp0D Tp0X Tp0b Tp0f Tp0j"), (efficiency, "Tp1h Tp1t Tp1p Tp1l")]),
            "M3": table([(performance, "Tf04 Tf09 Tf0A Tf0B Tf0D Tf0E Tf44 Tf49 Tf4A Tf4B Tf4D Tf4E"),
                         (efficiency, "Te05 Te0L Te0P Te0S")]),
            "M4": table([(performance, "Tp01 Tp05 Tp09 Tp0D Tp0V Tp0Y Tp0b Tp0e"), (efficiency, "Te05 Te0S Te09 Te0H")]),
            "M5": table([(`super`, "Tp00 Tp04 Tp08 Tp0C Tp0G Tp0K"),
                         (performance, "Tp0O Tp0R Tp0U Tp0X Tp0a Tp0d Tp0g Tp0j Tp0m Tp0p Tp0u Tp0y")]),
            "M6": table([(`super`, "Tp0j Tp0g Tp09 Tp07"), (performance, "Tp0m Tp0L Tp0I Tp0d Tp0E Tp0G Tp0b Tp05"),
                         (efficiency, "Te07 Te08 Te09 Te0c Te0h Te0i")]),
            "A18": table([(performance, "Tp05 Tp0D"), (efficiency, "Te05 Te0S")]),
        ]
    }()

    /// "Apple M4 Pro" → "M4", "Apple A18 Pro" → "A18"; Intel and anything else → `nil`.
    public static func chipFamily(brand: String) -> String? {
        guard brand.hasPrefix("Apple ") else { return nil }
        let family = brand.dropFirst("Apple ".count).prefix { $0.isLetter || $0.isNumber }
        guard let letter = family.first, "MA".contains(letter), family.dropFirst().allSatisfy(\.isNumber), family.count > 1
        else { return nil }
        return String(family)
    }

    /// With a family that has a core table, cores are `.cpu` and every other `Tp??`/`Te??`/`Tf??`
    /// key is `.cpuDie`; everything else follows `smcRules`. Prefer `classify(smcKeys:chipFamily:)`,
    /// which also falls back when the table doesn't fit this Mac.
    public static func classify(smcKey key: String, chipFamily: String? = nil) -> Classification {
        if let cores = chipFamily.flatMap({ coreKeys[$0] }) {
            if let name = cores[key] {
                return Classification(category: .cpu, nameTemplate: name, isIdentified: true)
            }
            if ["Tp", "Te", "Tf"].contains(where: key.hasPrefix), key.count == 4 {
                return Classification(category: .cpuDie, nameTemplate: "CPU Die #", isIdentified: true)
            }
        }
        if let rule = smcRules.first(where: { matches(key, pattern: $0.pattern) }) {
            return Classification(category: rule.category, nameTemplate: rule.name, isIdentified: true)
        }
        return Classification(category: .other, nameTemplate: "Sensor \(key)", isIdentified: false)
    }

    /// One result per key, in order. When none of the family's core keys exist on this Mac the
    /// table doesn't fit, so classify as for an unknown chip rather than leave `.cpu` empty.
    public static func classify(smcKeys keys: [String], chipFamily: String?) -> [Classification] {
        let family = chipFamily.flatMap { coreKeys[$0] }.flatMap { cores in keys.contains(where: cores.keys.contains) ? chipFamily : nil }
        return keys.map { classify(smcKey: $0, chipFamily: family) }
    }

    /// Classifies a HID temperature service by its `Product` name.
    /// Returns `nil` for services that never carry a useful temperature.
    public static func classify(hidProduct product: String) -> Classification? {
        let name = product.lowercased()
        if name.contains("tcal") { return nil } // calibration constant
        if name.contains("nand") {
            return Classification(category: .storage, nameTemplate: "SSD #", isIdentified: true)
        }
        if name.contains("battery") {
            return Classification(category: .battery, nameTemplate: "Battery #", isIdentified: true)
        }
        if name.contains("tdie") {
            return Classification(category: .cpu, nameTemplate: "SoC Die #", isIdentified: true)
        }
        if name.contains("tdev") {
            return Classification(category: .enclosure, nameTemplate: "Logic Board #", isIdentified: true)
        }
        return Classification(category: .other, nameTemplate: product, isIdentified: false)
    }

    /// SMC data types that can hold a temperature.
    public static func isTemperatureType(_ dataType: String) -> Bool {
        dataType == "flt " || dataType.hasPrefix("sp") || dataType.hasPrefix("fp")
    }

    /// Filters out disconnected sensors (0, negative) and garbage readings.
    public static func isPlausible(celsius: Double) -> Bool {
        celsius.isFinite && celsius > 5 && celsius < 130
    }

    static func matches(_ key: String, pattern: String) -> Bool {
        guard key.count == pattern.count else { return false }
        return zip(key, pattern).allSatisfy { $1 == "?" || $0 == $1 }
    }
}

/// Turns name templates into final names: "CPU #" ×3 → "CPU 1", "CPU 2", "CPU 3"; "GPU #" ×1 → "GPU".
public enum SensorNaming {
    public static func resolve(_ templates: [String]) -> [String] {
        let totals = Dictionary(templates.map { ($0, 1) }, uniquingKeysWith: +)
        var seen: [String: Int] = [:]
        return templates.map { template in
            guard template.contains("#") else { return template }
            if totals[template] == 1 {
                return template
                    .replacingOccurrences(of: " #", with: "")
                    .replacingOccurrences(of: "#", with: "")
            }
            let ordinal = (seen[template] ?? 0) + 1
            seen[template] = ordinal
            return template.replacingOccurrences(of: "#", with: String(ordinal))
        }
    }
}
