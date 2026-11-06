import Foundation
import MacFanXPC
import Security

@main
enum HelperMain {
    static func main() {
        let service = HelperService(clientRequirement: CodeSigningPolicy.clientRequirement())

        // Installed before start(): a signal during the start-up restore must still restore.
        // Exit 0 only after a confirmed restore; a non-zero exit lets launchd relaunch the helper.
        let terminations = [SIGTERM, SIGINT, SIGHUP].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { exit(service.restoreSynchronously() ? EXIT_SUCCESS : EXIT_FAILURE) }
            source.resume()
            return source
        }

        service.start()

        let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
        listener.delegate = service
        listener.resume()

        withExtendedLifetime((listener, terminations)) {
            dispatchMain()
        }
    }
}

/// Builds the code-signing requirement a client must satisfy.
///
/// When the helper is signed with a Developer ID, clients must be signed by the same team.
/// Ad-hoc builds (local development, `make app`) can only pin the bundle identifier, which
/// is weaker; release builds should always be signed. See README → Security.
enum CodeSigningPolicy {
    static func clientRequirement() -> String {
        let identifier = "identifier \"\(HelperConstants.appBundleIdentifier)\""
        guard let team = ownTeamIdentifier() else { return identifier }
        return "\(identifier) and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let info = information as? [String: Any]
        else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
