import Foundation
import IDevice

/// 用 Rust idevice 實現的真正心跳網關（Marco-Polo）
/// 直接調 FFI，不經過 Swift 的假實現
public class RustHeartbeatGateway: HeartbeatGateway {
    public let servicePort: UInt16 = 62078
    
    private var provider: OpaquePointer?
    private var heartbeatClient: OpaquePointer?
    private let host: String
    private let pairingFileURL: URL
    
    public init(host: String, pairingFileURL: URL) {
        self.host = host
        self.pairingFileURL = pairingFileURL
    }
    
    deinit {
        disconnect()
    }
    
    public func disconnect() {
        if let client = heartbeatClient {
            heartbeat_client_free(client)
            heartbeatClient = nil
        }
        if let prov = provider {
            idevice_provider_free(prov)
            provider = nil
        }
    }
    
    /// 確保已連接（懶加載）
    private func ensureConnected() throws {
        if heartbeatClient != nil { return }
        
        // 1. 載入配對檔
        let plistData = try Data(contentsOf: pairingFileURL)
        var pairingFile: OpaquePointer?
        let parseErr = plistData.withUnsafeBytes { ptr in
            idevice_pairing_file_from_bytes(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt(plistData.count),
                &pairingFile
            )
        }
        if let err = parseErr {
            let code = err.pointee.code
            idevice_error_free(err)
            throw NSError(domain: "RustHeartbeat", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "配對檔解析失敗"])
        }
        guard let pf = pairingFile else {
            throw NSError(domain: "RustHeartbeat", code: -1, userInfo: [NSLocalizedDescriptionKey: "配對檔為空"])
        }
        
        // 2. 創建 TCP provider（連 10.7.0.1:62078）
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(62078).bigEndian
        let ptonResult: Int32 = host.withCString { cstr in
            inet_pton(AF_INET, cstr, &addr.sin_addr)
        }
        guard ptonResult == 1 else {
            throw NSError(domain: "RustHeartbeat", code: -2, userInfo: [NSLocalizedDescriptionKey: "無效的目標地址"])
        }
        
        var provider: OpaquePointer?
        let label = "PaxHeartbeatTest"
        let providerErr = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                label.withCString { labelPtr in
                    idevice_tcp_provider_new(sockPtr, pf, labelPtr, &provider)
                }
            }
        }
        if let err = providerErr {
            let code = err.pointee.code
            idevice_error_free(err)
            throw NSError(domain: "RustHeartbeat", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Provider 創建失敗"])
        }
        guard let prov = provider else {
            throw NSError(domain: "RustHeartbeat", code: -3, userInfo: [NSLocalizedDescriptionKey: "Provider 為空"])
        }
        self.provider = prov
        
        // 3. 連接 heartbeat 服務
        var client: OpaquePointer?
        if let err = heartbeat_connect(prov, &client) {
            let code = err.pointee.code
            idevice_error_free(err)
            // 仿 minimuxer：connect 失敗立即 free provider
            idevice_provider_free(prov)
            self.provider = nil
            throw NSError(domain: "RustHeartbeat", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Heartbeat 連接失敗"])
        }
        guard let hc = client else {
            throw NSError(domain: "RustHeartbeat", code: -4, userInfo: [NSLocalizedDescriptionKey: "Heartbeat client 為空"])
        }
        self.heartbeatClient = hc
        print("[RustHeartbeat] 已連接（經 Rust FFI）")
    }
    
    /// 執行一次心跳：get_marco → send_polo
    public func performHeartbeat(interval: UInt64) async throws -> UInt64 {
        // FFI 是同步阻塞的，放後台線程
        return try await Task.detached(priority: .userInitiated) {
            RustFFILock.shared.heartbeatLock.lock()
            defer { RustFFILock.shared.heartbeatLock.unlock() }
            try self.ensureConnected()
            guard let client = self.heartbeatClient else {
                throw NSError(domain: "RustHeartbeat", code: -2, userInfo: [NSLocalizedDescriptionKey: "未連接"])
            }
            
            var newInterval: UInt64 = 0
            // get_marco 會阻塞直到收到 Marco 或超時
            if let err = heartbeat_get_marco(client, interval, &newInterval) {
                let code = err.pointee.code
                idevice_error_free(err)
                // 仿 minimuxer：失敗時丟棄連接，下次重建
                self.disconnect()
                throw NSError(domain: "RustHeartbeat", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "get_marco 失敗"])
            }
            
            // send_polo
            if let err = heartbeat_send_polo(client) {
                let code = err.pointee.code
                idevice_error_free(err)
                // 仿 minimuxer：失敗時丟棄連接，下次重建
                self.disconnect()
                throw NSError(domain: "RustHeartbeat", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "send_polo 失敗"])
            }
            
            return newInterval > 0 ? newInterval : interval
        }.value
    }
}
