import Foundation
import IDevice

/// 用 Rust idevice 實現的真正心跳網關（Marco-Polo）
/// 直接調 FFI，不經過 Swift 的假實現
public class RustHeartbeatGateway: HeartbeatGateway {
    public var servicePort: UInt16 {
        pairingFileURL.lastPathComponent == PairingType.remote.fileName ? RustDeviceTransport.remotePort : 62078
    }
    
    private let transport = RustDeviceTransport()
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
        transport.disconnect()
    }
    
    /// 確保已連接（懶加載）
    private func ensureConnected() throws {
        if heartbeatClient != nil { return }
        
        self.heartbeatClient = try transport.connect(.heartbeat, host: host, pairingFileURL: pairingFileURL)
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
