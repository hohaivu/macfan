import MacFanCore
import SwiftUI

/// Design tokens. Every spacing, radius and timing in the app comes from here so the
/// whole interface can be tuned in one place.
enum Theme {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 8
        static let card: CGFloat = 14
        static let large: CGFloat = 20
    }

    /// Springs are described the way Apple does: response (seconds) and damping ratio.
    /// Damping 1 means no overshoot; reserve bounce for motion the user threw.
    enum Motion {
        /// The default for state changes: critically damped, no overshoot.
        static let standard = Animation.spring(response: 0.35, dampingFraction: 1)
        /// Press feedback must feel instant.
        static let press = Animation.spring(response: 0.2, dampingFraction: 1)
        /// Settling after a drag the user released with momentum.
        static let release = Animation.spring(response: 0.3, dampingFraction: 0.8)
        /// Reduced Motion swaps movement for a short cross-fade.
        static let reduced = Animation.easeInOut(duration: 0.2)
    }
}

// MARK: - Temperature level → visuals

extension TemperatureLevel {
    /// Color is never the only signal: every level also has a symbol and a word.
    var tint: Color {
        switch self {
        case .cool: .teal
        case .warm: .orange
        case .hot: .red
        case .critical: .red
        }
    }

    var symbol: String {
        switch self {
        case .cool: "thermometer.low"
        case .warm: "thermometer.medium"
        case .hot: "thermometer.high"
        case .critical: "exclamationmark.triangle.fill"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .cool: "Cool"
        case .warm: "Warm"
        case .hot: "Hot"
        case .critical: "Critical"
        }
    }
}

extension SensorCategory {
    var title: LocalizedStringKey {
        switch self {
        case .cpu: "CPU"
        case .cpuDie: "CPU Die"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .storage: "Storage"
        case .battery: "Battery"
        case .power: "Power"
        case .wireless: "Wireless"
        case .enclosure: "Enclosure"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .cpuDie: "cpu"
        case .gpu: "square.stack.3d.up"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .battery: "battery.75percent"
        case .power: "bolt"
        case .wireless: "wifi"
        case .enclosure: "laptopcomputer"
        case .other: "sensor"
        }
    }
}

// MARK: - Motion helpers

extension View {
    /// Animates `value` changes with the standard spring, or a cross-fade under Reduced Motion.
    func fluidAnimation<V: Equatable>(value: V) -> some View {
        modifier(FluidAnimationModifier(value: value))
    }
}

private struct FluidAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? Theme.Motion.reduced : Theme.Motion.standard, value: value)
    }
}
