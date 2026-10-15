import Foundation
import Network

/// installation_proxy 服務客戶端
public class InstallationProxy {
    private let lockdown: LockdownClient
    private var serviceConnection: NWConnection?
    
    public init(lockdown: LockdownClient) {
        self.lockdown = lockdown
    }
    
    /// 連接到 installation_proxy 服務
    /// - Returns: 實際連上的服務地址（供 UI 顯示）
    public func connect() async throws -> String {
        let (port, sslEnabled) = try await lockdown.startService("com.apple.mobile.installation_proxy")
        // 動態服務端口不一定走 VPN 回環：先找一個 TCP 真正連得上的地址
        guard let svcHost = await VPNConnectionChecker.shared.resolveServiceHost(port: port) else {
            throw InstallationError.serviceUnreachable(port)
        }
        
        let params: NWParameters
        if sslEnabled {
            let tlsOptions = NWProtocolTLS.Options()
            if let id = lockdown.identity {
                sec_protocol_options_set_local_identity(
                    tlsOptions.securityProtocolOptions,
                    sec_identity_create(id)!
                )
            }
            sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, complete in
                complete(true)
            }, .global())
            params = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        } else {
            params = .tcp
        }
        serviceConnection = NWConnection(
            host: NWEndpoint.Host(svcHost),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            serviceConnection?.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: LockdownError.connectionCancelled)
                default:
                    break
                }
            }
            serviceConnection?.start(queue: .global())
        }
        return svcHost
    }
    
    /// 安裝 IPA（IPA 需先經 AFC 上傳到 /PublicStaging/）
    public func install(packagePath: String, progress: @escaping (Int) -> Void) async throws {
        guard let connection = serviceConnection else {
            throw LockdownError.notConnected
        }
        
        // 發送 Install 命令
        let command: [String: Any] = [
            "Command": "Install",
            "PackagePath": packagePath,
            "ClientOptions": [
                "CFBundleIdentifier": "PaxStore",
                "CloseOnInvalidate": true
            ] as [String: Any]
        ]
        
        try await sendPlist(command, over: connection)
        
        // 接收進度更新
        while true {
            let response = try await receivePlist(over: connection)
            
            if let status = response["Status"] as? String {
                switch status {
                case "Complete":
                    return
                case "Error":
                    let desc = response["ErrorDescription"] as? String ?? "未知錯誤"
                    throw InstallationError.installFailed(desc)
                default:
                    break
                }
            }
            
            if let percent = response["PercentComplete"] as? Int {
                progress(percent)
            }
        }
    }
    
    private func sendPlist(_ dict: [String: Any], over connection: NWConnection) async throws {
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,  // installation_proxy 用 XML
            options: 0
        )
        
        var length = UInt32(plistData.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: lengthData + plistData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    private func receivePlist(over connection: NWConnection) async throws -> [String: Any] {
        let lengthData = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: LockdownError.incompleteData)
                }
            }
        } as Data
        
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        let plistData = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: LockdownError.incompleteData)
                }
            }
        } as Data
        
        guard let dict = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw LockdownError.invalidResponse
        }
        
        return dict
    }
    
    public func disconnect() {
        serviceConnection?.cancel()
        serviceConnection = nil
    }
}

public enum InstallationError: Error, LocalizedError {
    case installFailed(String)
    case serviceUnreachable(UInt16)
    
    public var errorDescription: String? {
        switch self {
        case .installFailed(let desc): return "安裝失敗: \(desc)"
        case .serviceUnreachable(let port):
            return "安裝服務端口 \(port) 連不上（已試 127.0.0.1、Wi-Fi IP、VPN 地址）"
        }
    }
}

