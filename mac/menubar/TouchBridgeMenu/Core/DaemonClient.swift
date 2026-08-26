import Foundation

/// Client for the TouchBridge daemon's Unix domain socket.
///
/// Sends JSON requests and parses JSON responses for the control actions
/// (status, pair, unpair, cancelPairing). Also handles authenticate for testing.
final class DaemonClient {
    private let socketPath: String

    init(socketPath: String? = nil) {
        if let path = socketPath {
            self.socketPath = path
        } else {
            self.socketPath = "\(NSHomeDirectory())/Library/Application Support/TouchBridge/daemon.sock"
        }
    }

    /// Whether the daemon socket exists (daemon is running).
    var isSocketAvailable: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    // MARK: - Response types

    struct DaemonStatus: Codable {
        let pairedDevices: [PairedDeviceInfo]
        let connectedDevices: [ConnectedDeviceInfo]
        let isAdvertising: Bool
        let isPairingActive: Bool

        struct PairedDeviceInfo: Codable, Identifiable {
            let deviceID: String
            let displayName: String
            let pairedAt: Date
            let isConnected: Bool
            var id: String { deviceID }
        }

        struct ConnectedDeviceInfo: Codable {
            let centralID: String
            let deviceID: String?
            let identified: Bool
        }
    }

    enum DaemonError: Error {
        case socketUnavailable
        case connectionFailed
        case parseError
        case daemonError(String)
    }

    // MARK: - Actions

    /// Query daemon status (paired devices, connections, advertising, pairing state).
    func getStatus() async throws -> DaemonStatus {
        let response = try await sendRequest(["action": "status"])
        guard response.result == "success",
              let statusData = response.statusData,
              let status = try? JSONDecoder.iso8601.decode(DaemonStatus.self, from: statusData) else {
            throw DaemonError.parseError
        }
        return status
    }

    /// Start a pairing session. Returns the QR payload JSON string.
    func startPairing() async throws -> String {
        let response = try await sendRequest(["action": "pair"])
        guard response.result == "success", let pairingData = response.pairingData else {
            throw DaemonError.daemonError(response.reason ?? "unknown")
        }
        return pairingData
    }

    /// Cancel an active pairing session.
    func cancelPairing() async throws {
        let response = try await sendRequest(["action": "cancelPairing"])
        guard response.result == "success" else {
            throw DaemonError.daemonError(response.reason ?? "unknown")
        }
    }

    /// Unpair a device by ID.
    func unpairDevice(deviceID: String) async throws {
        let response = try await sendRequest(["action": "unpair", "deviceID": deviceID])
        guard response.result == "success" else {
            throw DaemonError.daemonError(response.reason ?? "unknown")
        }
    }

    // MARK: - Socket communication

    private struct RawResponse {
        let result: String
        let reason: String?
        let statusData: Data?
        let pairingData: String?
    }

    private func sendRequest(_ payload: [String: Any]) async throws -> RawResponse {
        guard isSocketAvailable else {
            throw DaemonError.socketUnavailable
        }

        // Encode via JSONSerialization so user-supplied values (e.g. deviceID)
        // are properly escaped — never raw-interpolated into a JSON string.
        let requestData: Data
        do {
            var data = try JSONSerialization.data(withJSONObject: payload)
            data.append(0x0A) // newline terminator expected by the daemon
            requestData = data
        } catch {
            throw DaemonError.parseError
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    continuation.resume(throwing: DaemonError.connectionFailed)
                    return
                }
                defer { close(fd) }

                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                let pathBytes = self.socketPath.utf8CString
                guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
                    continuation.resume(throwing: DaemonError.connectionFailed)
                    return
                }
                withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                        for i in 0..<pathBytes.count { dest[i] = pathBytes[i] }
                    }
                }

                let connectResult = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard connectResult == 0 else {
                    continuation.resume(throwing: DaemonError.connectionFailed)
                    return
                }

                // Send request
                _ = requestData.withUnsafeBytes { ptr in
                    send(fd, ptr.baseAddress!, ptr.count, 0)
                }

                // Receive response
                var buffer = [UInt8](repeating: 0, count: 8192)
                let bytesRead = recv(fd, &buffer, buffer.count - 1, 0)
                guard bytesRead > 0 else {
                    continuation.resume(throwing: DaemonError.connectionFailed)
                    return
                }

                buffer[bytesRead] = 0
                let responseStr = String(cString: buffer)
                guard let responseData = responseStr.data(using: .utf8) else {
                    continuation.resume(throwing: DaemonError.parseError)
                    return
                }

                // Parse the full response JSON to extract all fields
                struct FullResponse: Codable {
                    let result: String
                    let reason: String?
                    let status: DaemonStatus?
                    let pairingData: String?
                }

                let decoder = JSONDecoder.iso8601
                guard let parsed = try? decoder.decode(FullResponse.self, from: responseData) else {
                    continuation.resume(throwing: DaemonError.parseError)
                    return
                }

                // Re-encode status to Data for the RawResponse (if present)
                let statusData: Data? = parsed.status.flatMap { status in
                    try? JSONEncoder.iso8601.encode(status)
                }

                continuation.resume(returning: RawResponse(
                    result: parsed.result,
                    reason: parsed.reason,
                    statusData: statusData,
                    pairingData: parsed.pairingData
                ))
            }
        }
    }
}

// MARK: - JSON helpers

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
