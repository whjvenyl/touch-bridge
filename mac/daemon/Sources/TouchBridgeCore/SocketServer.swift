import Foundation
import OSLog

/// JSON request from the PAM module or control app.
/// `user`, `service`, `pid` are only present for `authenticate` actions.
/// `deviceID` is only present for `unpair` actions.
public struct PAMRequest: Codable, Sendable {
    public let action: String
    public let user: String?
    public let service: String?
    public let pid: Int?
    public let deviceID: String?

    public init(action: String, user: String? = nil, service: String? = nil, pid: Int? = nil, deviceID: String? = nil) {
        self.action = action
        self.user = user
        self.service = service
        self.pid = pid
        self.deviceID = deviceID
    }
}

/// JSON response. Auth responses use only `result` + `reason`.
/// Control responses add `status` or `pairingData` as needed.
/// The PAM module checks for `"result":"success"` via string search —
/// extra fields don't affect it.
public struct PAMResponse: Codable, Sendable {
    public let result: String
    public let reason: String?
    public let status: DaemonStatus?
    public let pairingData: String?

    public init(result: String, reason: String? = nil, status: DaemonStatus? = nil, pairingData: String? = nil) {
        self.result = result
        self.reason = reason
        self.status = status
        self.pairingData = pairingData
    }

    public static let success = PAMResponse(result: "success")

    public static func failure(_ reason: String) -> PAMResponse {
        PAMResponse(result: "failure", reason: reason)
    }
}

/// Daemon status snapshot — returned by the `status` action.
public struct DaemonStatus: Codable, Sendable {
    public let pairedDevices: [PairedDeviceInfo]
    public let connectedDevices: [ConnectedDeviceInfo]
    public let isAdvertising: Bool
    public let isPairingActive: Bool

    public init(pairedDevices: [PairedDeviceInfo], connectedDevices: [ConnectedDeviceInfo], isAdvertising: Bool, isPairingActive: Bool) {
        self.pairedDevices = pairedDevices
        self.connectedDevices = connectedDevices
        self.isAdvertising = isAdvertising
        self.isPairingActive = isPairingActive
    }

    public struct PairedDeviceInfo: Codable, Sendable {
        public let deviceID: String
        public let displayName: String
        public let pairedAt: Date
        public let isConnected: Bool

        public init(deviceID: String, displayName: String, pairedAt: Date, isConnected: Bool) {
            self.deviceID = deviceID
            self.displayName = displayName
            self.pairedAt = pairedAt
            self.isConnected = isConnected
        }
    }

    public struct ConnectedDeviceInfo: Codable, Sendable {
        public let centralID: String
        public let deviceID: String?
        public let identified: Bool

        public init(centralID: String, deviceID: String?, identified: Bool) {
            self.centralID = centralID
            self.deviceID = deviceID
            self.identified = identified
        }
    }
}

/// Protocol for handling PAM authentication requests — enables testing without DaemonCoordinator.
public protocol PAMAuthHandler: AnyObject, Sendable {
    func authenticateFromPAM(user: String, service: String, pid: Int, timeout: TimeInterval) async -> (success: Bool, reason: String?)
}

/// Protocol for control actions (status, pairing, unpair) — enables testing without DaemonCoordinator.
public protocol DaemonControlHandler: AnyObject, Sendable {
    func getDaemonStatus() async -> DaemonStatus
    func startPairing() async throws -> Data
    func cancelPairing() async
    func unpairDevice(deviceID: String) async throws
}

/// Unix domain socket server for PAM module communication.
///
/// Listens on `~/Library/Application Support/TouchBridge/daemon.sock`.
/// Each PAM connection sends a JSON request line, receives a JSON response line.
public final class SocketServer: @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "SocketServer")

    private let socketPath: String
    private let authHandler: PAMAuthHandler
    private let controlHandler: DaemonControlHandler?
    private let policyEngine: PolicyEngine

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.touchbridge.socket", qos: .userInitiated)

    /// Whether the socket server is currently listening.
    public private(set) var isListening: Bool = false

    public init(
        authHandler: PAMAuthHandler,
        controlHandler: DaemonControlHandler? = nil,
        policyEngine: PolicyEngine = PolicyEngine(),
        socketPath: String? = nil
    ) {
        self.authHandler = authHandler
        self.controlHandler = controlHandler
        self.policyEngine = policyEngine

        if let path = socketPath {
            self.socketPath = path
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.socketPath = "\(home)/Library/Application Support/TouchBridge/daemon.sock"
        }
    }

    /// Start listening on the Unix domain socket.
    public func start() throws {
        // Ensure directory exists
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Remove stale socket
        unlink(socketPath)

        // Create socket
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw SocketServerError.socketCreationFailed(errno)
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(serverFD)
            serverFD = -1
            throw SocketServerError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(serverFD)
            serverFD = -1
            throw SocketServerError.bindFailed(err)
        }

        // Set socket permissions to owner-only
        chmod(socketPath, 0o600)

        // Listen
        guard listen(serverFD, 5) == 0 else {
            let err = errno
            close(serverFD)
            serverFD = -1
            throw SocketServerError.listenFailed(err)
        }

        // Accept connections via GCD
        let source = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverFD, fd >= 0 {
                close(fd)
                self?.serverFD = -1
            }
        }
        acceptSource = source
        source.resume()

        isListening = true
        logger.info("Socket server listening on \(self.socketPath)")
    }

    /// Stop the socket server.
    public func stop() {
        // FD cleanup is dispatched onto the serial queue so it's serialized
        // with the DispatchSource cancel handler — prevents a double-close
        // race where both stop() and the cancel handler close serverFD.
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            if serverFD >= 0 {
                close(serverFD)
                serverFD = -1
            }
        }
        unlink(socketPath)
        isListening = false
        logger.info("Socket server stopped")
    }

    /// The path of the Unix domain socket.
    public var path: String { socketPath }

    // MARK: - Private

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(serverFD, sockPtr, &addrLen)
            }
        }

        guard clientFD >= 0 else {
            logger.warning("Accept failed: \(errno)")
            return
        }

        // Handle each connection on a separate task
        Task {
            await handleConnection(fd: clientFD)
        }
    }

    private func handleConnection(fd: Int32) async {
        defer { close(fd) }

        // Read request (max 4KB, single line)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(fd, &buffer, buffer.count - 1, 0)

        guard bytesRead > 0 else {
            logger.warning("Empty read from PAM client")
            return
        }

        buffer[bytesRead] = 0
        let requestString = String(cString: buffer)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let requestData = requestString.data(using: .utf8) else {
            sendResponse(fd: fd, response: .failure("invalid_request"))
            return
        }

        // Parse request
        let request: PAMRequest
        do {
            request = try JSONDecoder().decode(PAMRequest.self, from: requestData)
        } catch {
            logger.warning("Failed to parse request: \(error.localizedDescription)")
            sendResponse(fd: fd, response: .failure("parse_error"))
            return
        }

        switch request.action {
        case "authenticate":
            await handleAuthenticate(fd: fd, request: request)
        case "status":
            await handleStatus(fd: fd)
        case "pair":
            await handlePair(fd: fd)
        case "cancelPairing":
            await handleCancelPairing(fd: fd)
        case "unpair":
            await handleUnpair(fd: fd, request: request)
        default:
            sendResponse(fd: fd, response: .failure("unknown_action"))
        }
    }

    private func handleAuthenticate(fd: Int32, request: PAMRequest) async {
        guard let user = request.user, let service = request.service, let pid = request.pid else {
            sendResponse(fd: fd, response: .failure("missing_fields"))
            return
        }

        logger.info("PAM auth request: user=\(user) service=\(service) pid=\(pid)")

        let timeout = policyEngine.authTimeout()
        let (success, reason) = await authHandler.authenticateFromPAM(
            user: user,
            service: service,
            pid: pid,
            timeout: timeout
        )

        let response = success ? PAMResponse.success : PAMResponse.failure(reason ?? "authentication_failed")
        sendResponse(fd: fd, response: response)

        logger.info("PAM auth result: user=\(user) service=\(service) result=\(response.result)")
    }

    private func handleStatus(fd: Int32) async {
        guard let controlHandler else {
            sendResponse(fd: fd, response: .failure("control_not_supported"))
            return
        }
        let status = await controlHandler.getDaemonStatus()
        sendResponse(fd: fd, response: PAMResponse(result: "success", status: status))
    }

    private func handlePair(fd: Int32) async {
        guard let controlHandler else {
            sendResponse(fd: fd, response: .failure("control_not_supported"))
            return
        }
        do {
            let qrData = try await controlHandler.startPairing()
            let jsonStr = String(data: qrData, encoding: .utf8) ?? ""
            sendResponse(fd: fd, response: PAMResponse(result: "success", pairingData: jsonStr))
        } catch {
            logger.error("Pairing start failed: \(error.localizedDescription)")
            sendResponse(fd: fd, response: .failure("pairing_failed"))
        }
    }

    private func handleCancelPairing(fd: Int32) async {
        guard let controlHandler else {
            sendResponse(fd: fd, response: .failure("control_not_supported"))
            return
        }
        await controlHandler.cancelPairing()
        sendResponse(fd: fd, response: .success)
    }

    private func handleUnpair(fd: Int32, request: PAMRequest) async {
        guard let controlHandler else {
            sendResponse(fd: fd, response: .failure("control_not_supported"))
            return
        }
        guard let deviceID = request.deviceID else {
            sendResponse(fd: fd, response: .failure("missing_device_id"))
            return
        }
        do {
            try await controlHandler.unpairDevice(deviceID: deviceID)
            sendResponse(fd: fd, response: .success)
        } catch {
            logger.error("Unpair failed: \(error.localizedDescription)")
            sendResponse(fd: fd, response: .failure("unpair_failed"))
        }
    }

    private func sendResponse(fd: Int32, response: PAMResponse) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(response)
            data.append(contentsOf: "\n".utf8)
            data.withUnsafeBytes { ptr in
                _ = send(fd, ptr.baseAddress!, ptr.count, 0)
            }
        } catch {
            logger.error("Failed to encode PAM response: \(error.localizedDescription)")
        }
    }
}

public enum SocketServerError: Error, Sendable {
    case socketCreationFailed(Int32)
    case pathTooLong
    case bindFailed(Int32)
    case listenFailed(Int32)
}
