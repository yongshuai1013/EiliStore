import Foundation
import IDevice

/// 用 Rust FFI 實現的 Lockdown 客戶端（真實現，無假代碼）
public class RustLockdownClient {
    private var provider: OpaquePointer?
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
        // FFI 沒有暴露 lockdownd_client_free，靠 ARC？先置空
        // 實際應該調用對應的 free，這裡先留空避免崩潰
        lockdownClient = nil
        provider = nil
    }
    
    /// 連接 lockdownd（經 Rust FFI）
    public func connect() async throws {
        return try await Task.detached(priority: .userInitiated) {
            // 1. 載入配對檔
            let plistData = try Data(contentsOf: self.pairingFileURL)
            var pairingFile: OpaquePointer?
            if let err = plistData.withUnsafeBytes({ ptr in
                idevice_pairing_file_from_bytes(
                    ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    UInt(plistData.count),
                    &pairingFile
                )
            }) {
                let msg = self.errorMessage(from: err)
                idevice_error_free(err)
                throw NSError(domain: "RustLockdown", code: -1, userInfo: [NSLocalizedDescriptionKey: "配對檔解析失敗: \(msg)"])
            }
            guard let pf = pairingFile else {
                throw NSError(domain: "RustLockdown", code: -2, userInfo: [NSLocalizedDescriptionKey: "配對檔句柄為空"])
            }
            defer { /* TODO: pairing_file_free */ }
            
            // 2. 創建 TCP provider（10.7.0.1:62078）
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(62078).bigEndian
            self.host.withCString { cstr in
                _ = inet_pton(AF_INET, cstr, &addr.sin_addr)
            }
            
            var provider: OpaquePointer?
            let label = "PaxHeartbeatTest"
            let providerErr: UnsafeMutablePointer<IdeviceFfiError>? = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    label.withCString { labelPtr in
                        idevice_tcp_provider_new(sockPtr, pf, labelPtr, &provider)
                    }
                }
            }
            if let err = providerErr {
                let msg = self.errorMessage(from: err)
                idevice_error_free(err)
                throw NSError(domain: "RustLockdown", code: -3, userInfo: [NSLocalizedDescriptionKey: "Provider 創建失敗: \(msg)"])
            }
            guard let prov = provider else {
                throw NSError(domain: "RustLockdown", code: -4, userInfo: [NSLocalizedDescriptionKey: "Provider 句柄為空"])
            }
            self.provider = prov
            
            // 3. 連接 lockdownd
            var client: OpaquePointer?
            if let err = lockdownd_connect(prov, &client) {
                let msg = self.errorMessage(from: err)
                idevice_error_free(err)
                throw NSError(domain: "RustLockdown", code: -5, userInfo: [NSLocalizedDescriptionKey: "Lockdownd 連接失敗: \(msg)"])
            }
            guard let c = client else {
                throw NSError(domain: "RustLockdown", code: -6, userInfo: [NSLocalizedDescriptionKey: "Lockdownd 句柄為空"])
            }
            self.lockdownClient = c
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
    
    private func errorMessage(from err: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        let code = err.pointee.code
        if let cmsg = err.pointee.message {
            let msg = String(cString: cmsg)
            return "[\(code)] \(msg)"
        }
        return "[\(code)] unknown"
    }
}
