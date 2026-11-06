import Foundation

/// Identifiers shared by the app, the helper, and `Resources/*.plist`.
/// If you fork MacFan, change them here and in `Resources/` together.
public enum HelperConstants {
    public static let appBundleIdentifier = "io.github.alvinmr.MacFan"
    public static let helperLabel = "io.github.alvinmr.MacFan.helper"
    public static let machServiceName = helperLabel
    /// File name inside `MacFan.app/Contents/Library/LaunchDaemons/`.
    public static let daemonPlistName = "\(helperLabel).plist"

    /// Bump whenever `MacFanHelperProtocol` *or the helper's behavior* changes, so the app
    /// asks to update the helper. Replacing the app doesn't restart a running helper: without
    /// a bump, an updated app keeps talking to the old helper code until the Mac restarts.
    public static let protocolVersion = "3"

    /// If the app goes silent this long while fans are manual, the helper hands them back to macOS.
    public static let watchdogTimeout: TimeInterval = 20

    public static let errorDomain = "io.github.alvinmr.MacFan.helper"
}

/// The entire privileged surface. Kept deliberately tiny: the helper can set a fan
/// target and give control back, nothing else.
@objc public protocol MacFanHelperProtocol {
    func protocolVersion(withReply reply: @escaping @Sendable (String) -> Void)

    /// Takes manual control of one fan (if needed) and sets its target speed.
    /// The helper clamps `rpm` to the fan's supported range.
    func setTargetRPM(_ rpm: Double, fanIndex: Int, withReply reply: @escaping @Sendable (NSError?) -> Void)

    /// Returns every fan to macOS.
    func restoreSystemControl(withReply reply: @escaping @Sendable (NSError?) -> Void)
}

public enum HelperErrorCode: Int, Sendable {
    case smcUnavailable = 1
    case writeFailed = 2
}

extension NSError {
    public static func helper(_ code: HelperErrorCode, _ message: String) -> NSError {
        NSError(domain: HelperConstants.errorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
