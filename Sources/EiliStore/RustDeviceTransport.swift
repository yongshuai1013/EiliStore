import Foundation
import IDevice
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owns the provider/tunnel for one service client. Free the service client before this object.
/// Never starts pair-setup, persists pairing credentials, or forwards Rust diagnostic payloads.
final class RustDeviceTransport {
    enum Service {
        case afc, installationProxy, misagent, heartbeat, lockdown

        fileprivate var label: String {
            switch self {
            case .afc: return "afc"
            case .installationProxy: return "installation-proxy"
            case .misagent: return "misagent"
            case .heartbeat: return "heartbeat"
            case .lockdown: return "lockdown"
            }
        }
    }

    private enum FailureCategory: String {
        case initialization
        case pairingData = "pairing-data"
        case pairingParse = "pairing-parse"
        case invalidHost = "invalid-host"
        case lockdownTransport = "lockdown-transport"
        case remoteVerification = "remote-verification"
        case serviceConnection = "service-connection"
        case transport
    }

    private static let safeCategoryKey = "rustDeviceSafeCategory"

    private var provider: OpaquePointer?
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private let store: PairingFileStore

    init(store: PairingFileStore = .shared) { self.store = store }

    deinit { disconnect() }

    func disconnect() {
        if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
        if let adapter {
            if let error = adapter_close(adapter) { idevice_error_free(error) }
            adapter_free(adapter)
            self.adapter = nil
        }
        if let provider { idevice_provider_free(provider); self.provider = nil }
    }

    func connect(_ service: Service, host: String, pairingFileURL: URL) throws -> OpaquePointer {
        disconnect()
        do {
            do {
                try RustLoggingPrivacy.ensureConfigured()
            } catch {
                throw Self.failure("無法初始化安全裝置記錄。", category: .initialization)
            }
            let typeAndData: (PairingType, Data)
            do {
                typeAndData = try store.validatedConnectionData(at: pairingFileURL)
            } catch {
                throw Self.failure("無法驗證已選取的配對資料。", category: .pairingData)
            }
            let (type, data) = typeAndData
            if type == .remote {
                try createRemote(host: host, data: data)
            } else {
                try createLockdown(host: host, data: data)
            }
            var client: OpaquePointer?
            let error: UnsafeMutablePointer<IdeviceFfiError>?
            if let adapter, let handshake {
                switch service {
                case .afc: error = afc_client_connect_rsd(adapter, handshake, &client)
                case .installationProxy: error = installation_proxy_connect_rsd(adapter, handshake, &client)
                case .misagent: error = misagent_connect_rsd(adapter, handshake, &client)
                case .heartbeat: error = heartbeat_connect_rsd(adapter, handshake, &client)
                case .lockdown: error = lockdownd_connect_rsd(adapter, handshake, &client)
                }
            } else if let provider {
                switch service {
                case .afc: error = afc_client_connect(provider, &client)
                case .installationProxy: error = installation_proxy_connect(provider, &client)
                case .misagent: error = misagent_connect(provider, &client)
                case .heartbeat: error = heartbeat_connect(provider, &client)
                case .lockdown: error = lockdownd_connect(provider, &client)
                }
            } else { throw Self.failure("無法建立配對傳輸。", category: .transport) }
            try Self.check(error, message: "無法連接裝置服務；請確認配對仍有效及服務可用。", category: .serviceConnection)
            guard let client else { throw Self.failure("裝置服務未返回連線。", category: .serviceConnection) }
            return client
        } catch {
            disconnect()
            print("[RustDeviceTransport] connection failed \(Self.safeFailureSummary(error, service: service))")
            throw error
        }
    }

    /// Returns only allowlisted fields; never formats localized descriptions or Rust error payloads.
    static func safeFailureSummary(_ error: Error, service: Service) -> String {
        let value = error as NSError
        guard value.domain == "RustDeviceTransport" else {
            return "service=\(service.label) category=unclassified code=unavailable"
        }
        let rawCategory = value.userInfo[safeCategoryKey] as? String
        let category = rawCategory.flatMap { FailureCategory(rawValue: $0) }?.rawValue ?? FailureCategory.transport.rawValue
        return "service=\(service.label) category=\(category) code=\(value.code)"
    }

    private func address(host: String, port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw Self.failure("目標必須是有效的 IPv4 地址。", category: .invalidHost)
        }
        return address
    }

    private func createLockdown(host: String, data: Data) throws {
        var address = try address(host: host, port: 62078)
        var pairing: OpaquePointer?
        try Self.check(data.withUnsafeBytes {
            idevice_pairing_file_from_bytes($0.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt(data.count), &pairing)
        }, message: "無法解析 Lockdown 配對檔。", category: .pairingParse)
        guard let pairing else { throw Self.failure("Lockdown 配對檔無效。", category: .pairingParse) }
        var consumed = false
        defer { if !consumed { idevice_pairing_file_free(pairing) } }
        let error = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socket in
                "EiliStore".withCString { label in
                    idevice_tcp_provider_new(socket, pairing, label, &provider)
                }
            }
        }
        // The pinned implementation consumes the pairing handle only on success.
        consumed = error == nil
        try Self.check(error, message: "無法建立 Lockdown 傳輸。", category: .lockdownTransport)
    }

    private func createRemote(host: String, data: Data) throws {
        var address = try address(host: host, port: Self.remotePort)
        var pairing: OpaquePointer?
        try Self.check(data.withUnsafeBytes {
            rp_pairing_file_from_bytes($0.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt(data.count), &pairing)
        }, message: "無法解析已匯入的 Remote 配對檔。", category: .pairingParse)
        guard let pairing else { throw Self.failure("Remote 配對檔無效。", category: .pairingParse) }
        defer { rp_pairing_file_free(pairing) }
        let error = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socket in
                "EiliStore".withCString { hostname in
                    // false is essential: a failed pair-verify must NEVER initiate first-time pairing.
                    tunnel_create_rppairing_with_options(socket, UInt32(MemoryLayout<sockaddr_in>.size), hostname,
                        pairing, false, nil, nil, &adapter, &handshake)
                }
            }
        }
        try Self.check(error, message: "Remote 驗證或隧道建立失敗；請確認服務端口及既有配對。未開始首次配對。", category: .remoteVerification)
    }

    static var remotePort: UInt16 {
        let value = UserDefaults.standard.integer(forKey: "pairing.remotePort")
        return UInt16(exactly: value).flatMap { $0 == 0 ? nil : $0 } ?? 49152
    }

    private static func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?, message: String, category: FailureCategory) throws {
        guard let error else { return }
        let code = error.pointee.code
        idevice_error_free(error)
        // Rust error messages may embed decoded plist values. Keep only the numeric error code.
        throw NSError(domain: "RustDeviceTransport", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: message,
            safeCategoryKey: category.rawValue
        ])
    }

    private static func failure(_ message: String, category: FailureCategory) -> NSError {
        NSError(domain: "RustDeviceTransport", code: -1, userInfo: [
            NSLocalizedDescriptionKey: message,
            safeCategoryKey: category.rawValue
        ])
    }
}
