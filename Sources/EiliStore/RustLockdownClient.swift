import Foundation
import IDevice

/// 用 Rust FFI 實現的 Lockdown 客戶端（真實現，無假代碼）
public class RustLockdownClient {
    private let transport = RustDeviceTransport()
    private var lockdownClient: OpaquePointer?
    
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
        if let client = lockdownClient { lockdownd_client_free(client); lockdownClient = nil }
        transport.disconnect()
    }
    
    /// 連接 lockdownd（經 Rust FFI）
    public func connect() async throws {
        return try await Task.detached(priority: .userInitiated) {
            self.disconnect()
            self.lockdownClient = try self.transport.connect(.lockdown, host: self.host, pairingFileURL: self.pairingFileURL)
            print("[RustLockdown] 已連接（經 Rust FFI）")
        }.value
    }
    
    /// 啟動服務，返回 (端口, 是否需要SSL)
    public func startService(_ serviceName: String) async throws -> (UInt16, Bool) {
        guard let client = lockdownClient else {
            throw NSError(domain: "RustLockdown", code: -10, userInfo: [NSLocalizedDescriptionKey: "未連接"])
        }
        
        return try await Task.detached(priority: .userInitiated) {
            var port: UInt16 = 0
            var ssl: Bool = false
            
            let err: UnsafeMutablePointer<IdeviceFfiError>? = serviceName.withCString { cstr in
                lockdownd_start_service(client, cstr, &port, &ssl)
            }
            
            if let err = err {
                let msg = self.errorMessage(from: err)
                idevice_error_free(err)
                throw NSError(domain: "RustLockdown", code: -11, userInfo: [NSLocalizedDescriptionKey: "StartService 失敗 (\(serviceName)): \(msg)"])
            }
            
            print("[RustLockdown] StartService \(serviceName) → port=\(port) ssl=\(ssl)")
            return (port, ssl)
        }.value
    }
    
    /// 診斷專用：對已連線的 lockdown client 試開一次 session（StartSession）。
    /// 成功回傳 nil；失敗回傳 FFI 的 (code, subCode)。僅供連線檢查的判別槍使用；
    /// 一般連線／安裝流程不呼叫此方法、維持不開 session。
    public func startSessionDiagnostic() async -> (code: Int32, subCode: Int32)? {
        guard let client = lockdownClient else { return (-10, 0) }
        return await Task.detached(priority: .userInitiated) {
            self.transport.attemptStartSession(client: client, pairingFileURL: self.pairingFileURL)
        }.value
    }
    
    private func errorMessage(from err: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        // Do not forward Rust's Debug-formatted payload, which can contain pairing values.
        return "[\(err.pointee.code):\(err.pointee.sub_code)] 裝置服務錯誤"
    }
}
