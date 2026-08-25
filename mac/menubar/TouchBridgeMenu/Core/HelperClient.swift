import Foundation
import ServiceManagement

/// Manages the privileged helper daemon and XPC communication.
///
/// The helper is registered via SMAppService.daemon and runs as root.
/// It handles privileged operations: installing the PAM module, patching
/// /etc/pam.d/, and copying the daemon binary to /usr/local/bin/.
@MainActor
class HelperClient: ObservableObject {
    static let machServiceName = "dev.touchbridge.helper"
    static let helperPlistName = "dev.touchbridge.helper.plist"

    @Published var isHelperRegistered = false
    @Published var isHelperResponsive = false

    private var connection: NSXPCConnection?
    private var connectionValid = false

    init() {
        checkHelperStatus()
    }

    // MARK: - Helper registration

    /// Check if the helper daemon is registered and responsive.
    func checkHelperStatus() {
        let service = SMAppService.daemon(plistName: Self.helperPlistName)
        isHelperRegistered = service.status == .enabled

        if isHelperRegistered {
            Task { await pingHelper() }
        } else {
            isHelperResponsive = false
        }
    }

    /// Register the helper daemon via SMAppService.
    /// The user will see a system notification asking them to approve
    /// the background item in System Settings.
    func registerHelper() async -> Bool {
        let service = SMAppService.daemon(plistName: Self.helperPlistName)
        do {
            try await service.register()
            isHelperRegistered = true
            return true
        } catch {
            print("Failed to register helper: \(error)")
            return false
        }
    }

    /// Unregister the helper daemon.
    func unregisterHelper() async {
        let service = SMAppService.daemon(plistName: Self.helperPlistName)
        try? await service.unregister()
        isHelperRegistered = false
        isHelperResponsive = false
    }

    // MARK: - XPC connection

    private func getConnection() -> NSXPCConnection? {
        if let conn = connection, connectionValid {
            return conn
        }
        let conn = NSXPCConnection(machServiceName: Self.machServiceName,
                                   options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.connectionValid = false
            }
        }
        conn.resume()
        connection = conn
        connectionValid = true
        return conn
    }

    private func pingHelper() async {
        guard let conn = getConnection(),
              let proxy = conn.remoteObjectProxyWithErrorHandler(
                { _ in Task { @MainActor in self.isHelperResponsive = false } })
                as? HelperProtocol else {
            isHelperResponsive = false
            return
        }
        proxy.ping { [weak self] ok in
            Task { @MainActor in self?.isHelperResponsive = ok }
        }
    }

    // MARK: - Privileged operations

    /// Install TouchBridge system components via the privileged helper.
    func install(daemonPath: String,
                 pamModulePath: String,
                 patchSudo: Bool,
                 patchScreensaver: Bool) async -> (success: Bool, message: String) {
        guard let proxy = await getProxy() else {
            return (false, "Helper not available")
        }
        return await withCheckedContinuation { continuation in
            proxy.install(daemonPath: daemonPath,
                          pamModulePath: pamModulePath,
                          patchSudo: patchSudo,
                          patchScreensaver: patchScreensaver) { success, message in
                continuation.resume(returning: (success, message))
            }
        }
    }

    /// Uninstall TouchBridge system components via the privileged helper.
    func uninstall(removeBinary: Bool) async -> (success: Bool, message: String) {
        guard let proxy = await getProxy() else {
            return (false, "Helper not available")
        }
        return await withCheckedContinuation { continuation in
            proxy.uninstall(removeBinary: removeBinary) { success, message in
                continuation.resume(returning: (success, message))
            }
        }
    }

    private func getProxy() async -> HelperProtocol? {
        guard let conn = getConnection() else { return nil }
        return await withCheckedContinuation { continuation in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                print("XPC error: \(error)")
                continuation.resume(returning: nil)
            } as? HelperProtocol
            continuation.resume(returning: proxy)
        }
    }
}
