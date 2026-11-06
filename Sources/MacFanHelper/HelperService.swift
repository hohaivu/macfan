import Foundation
import MacFanXPC
import SMCKit
import os

/// Serves `MacFanHelperProtocol` as root.
///
/// The safety rules live in `FanControlSession` (and its tests); this type adds XPC,
/// logging and timers. Safety nets, in order of how often they matter:
/// 1. Every fan is handed back to macOS when the last client disconnects (app quit or crash).
/// 2. A watchdog does the same if the app stops sending successful commands for
///    `watchdogTimeout`, and keeps retrying if a hand-back fails.
/// 3. On SIGTERM, SIGINT or SIGHUP fans are restored before exiting; the exit status is
///    non-zero if that failed, so launchd relaunches the helper.
/// 4. On start, fans are handed back to macOS, retried every 5 s until confirmed.
///
/// `@unchecked Sendable` is backed by a real rule: every mutable property is read and
/// written only on the serial `queue`. XPC delivers calls on arbitrary threads, so the
/// queue — not an actor — is what serializes SMC access with the watchdog timer.
final class HelperService: NSObject, NSXPCListenerDelegate, MacFanHelperProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.alvinmr.MacFan.helper.smc")
    private let log = Logger(subsystem: HelperConstants.helperLabel, category: "service")
    private let clientRequirement: String

    // Everything below is only touched on `queue`.
    private var session: FanControlSession<SMCConnection>?
    private var openConnections = 0
    private var watchdog: DispatchSourceTimer?

    init(clientRequirement: String) {
        self.clientRequirement = clientRequirement
        super.init()
    }

    func start() {
        // A failure is logged and the watchdog retries it; exiting would only loop on a transient SMC error.
        queue.sync { _ = restoreLocked(reason: "helper started") }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.checkWatchdog() }
        timer.resume()
        queue.sync { watchdog = timer }
        log.info("Helper started; client requirement: \(self.clientRequirement, privacy: .public)")
    }

    func restoreSynchronously() -> Bool {
        queue.sync { restoreLocked(reason: "terminating") == nil }
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Messages from anything not signed as MacFan are rejected by the system.
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: MacFanHelperProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in self?.connectionClosed() }
        queue.sync { openConnections += 1 }
        connection.resume()
        return true
    }

    // MARK: MacFanHelperProtocol

    func protocolVersion(withReply reply: @escaping @Sendable (String) -> Void) {
        reply(HelperConstants.protocolVersion)
    }

    func setTargetRPM(_ rpm: Double, fanIndex: Int, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        queue.async { [self] in
            do {
                try activeSession().setTarget(rpm: rpm, fan: fanIndex, at: Date())
                reply(nil)
            } catch let error as NSError where error.domain == HelperConstants.errorDomain {
                reply(error)
            } catch {
                log.error("setTarget failed: \(String(describing: error), privacy: .public)")
                reply(.helper(.writeFailed, String(describing: error)))
            }
        }
    }

    func restoreSystemControl(withReply reply: @escaping @Sendable (NSError?) -> Void) {
        queue.async { [self] in
            reply(restoreLocked(reason: "requested"))
        }
    }

    // MARK: Private (call on `queue`)

    private func activeSession() throws -> FanControlSession<SMCConnection> {
        if let session { return session }
        do {
            let created = FanControlSession(
                fans: SMCFanControl(smc: try SMCConnection()),
                watchdogTimeout: HelperConstants.watchdogTimeout
            )
            session = created
            return created
        } catch {
            throw NSError.helper(.smcUnavailable, String(describing: error))
        }
    }

    /// `nil` when every fan is confirmably back with macOS; otherwise the reason it isn't.
    private func restoreLocked(reason: String) -> NSError? {
        do {
            try activeSession().restore()
            log.info("Fans returned to macOS (\(reason, privacy: .public))")
            return nil
        } catch let error as NSError where error.domain == HelperConstants.errorDomain {
            log.error("Returning fans to macOS failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return error
        } catch {
            log.error("Returning fans to macOS failed (\(reason, privacy: .public)): \(String(describing: error), privacy: .public)")
            return .helper(.writeFailed, String(describing: error))
        }
    }

    private func connectionClosed() {
        queue.async { [self] in
            openConnections = max(0, openConnections - 1)
            if openConnections == 0, session?.isControlling == true {
                _ = restoreLocked(reason: "client disconnected")
            }
        }
    }

    private func checkWatchdog() {
        // No session means the SMC could not be opened yet: retry opening it and restoring.
        guard let session else { _ = restoreLocked(reason: "helper started, retry"); return }
        switch session.checkWatchdog(at: Date()) {
        case .returnedFans:
            log.info("Watchdog returned the fans to macOS: no commands for \(Int(HelperConstants.watchdogTimeout))s")
        case .restoreFailed:
            log.error("Watchdog could not return the fans to macOS; retrying")
        case .idle:
            break
        }
    }
}
