import Foundation

/// XPC protocol shared between the menubar app and the privileged helper.
///
/// The helper runs as root (via SMAppService.daemon) and performs operations
/// that require elevated privileges: copying the PAM module to /usr/local/lib/pam/,
/// patching /etc/pam.d/, and copying the daemon binary to /usr/local/bin/.
@objc protocol HelperProtocol {
    /// Install TouchBridge system components.
    /// - Parameters:
    ///   - daemonPath: Path to the daemon binary to copy to /usr/local/bin/touchbridge
    ///   - pamModulePath: Path to the PAM module to copy to /usr/local/lib/pam/pam_touchbridge.so
    ///   - patchSudo: Whether to patch the sudo PAM config
    ///   - patchScreensaver: Whether to patch the screensaver PAM config
    ///   - reply: (success, message)
    func install(daemonPath: String,
                 pamModulePath: String,
                 patchSudo: Bool,
                 patchScreensaver: Bool,
                 with reply: @escaping (Bool, String) -> Void)

    /// Uninstall TouchBridge system components.
    /// - Parameters:
    ///   - removeBinary: Whether to also remove /usr/local/bin/touchbridge
    ///   - reply: (success, message)
    func uninstall(removeBinary: Bool,
                   with reply: @escaping (Bool, String) -> Void)

    /// Check if the helper is running and responsive.
    func ping(with reply: @escaping (Bool) -> Void)
}
