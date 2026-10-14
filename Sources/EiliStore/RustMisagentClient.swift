import Foundation
import IDevice

/// 用 SideStore/idevice Rust FFI 實現的 Misagent（provisioning profile 管理）
/// 用於自動刷新：只換 profile，不重裝 App
public class RustMisagentClient {
    private var provider: OpaquePointer?
    private var misagentClient: OpaquePointer?
    
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
        if let client = misagentClient {
            misagent_client_free(client)
            misagentClient = nil
        }
        if let prov = provider {
            idevice_provider_free(prov)
            provider = nil
        }
    }
    
    /// 連接 misagent
    public func connect() async throws {
        let maxAttempts = 3
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await connectOnce()
            } catch {
                guard attempt < maxAttempts, RustFFILock.isTransportError(error) else { throw error }
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000 * attempt))
            }
        }
    }
    
    private func connectOnce() async throws {
        return try await Task.detached(priority: .userInitiated) {
            RustFFILock.shared.lock.lock()
            defer { RustFFILock.shared.lock.unlock() }
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
                throw NSError(domain: "RustMisagent", code: -1, userInfo: [NSLocalizedDescriptionKey: "配對檔解析失敗: \(msg)"])
            }
            guard let pf = pairingFile else {
                throw NSError(domain: "RustMisagent", code: -2, userInfo: [NSLocalizedDescriptionKey: "配對檔句柄為空"])
            }
            
            // 2. 創建 Provider
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(62078).bigEndian
            let ptonResult: Int32 = self.host.withCString { cstr in
                inet_pton(AF_INET, cstr, &addr.sin_addr)
            }
            guard ptonResult == 1 else {
                throw NSError(domain: "RustMisagent", code: -2, userInfo: [NSLocalizedDescriptionKey: "無效的目標地址"])
            }
            
            var provider: OpaquePointer?
            let label = "EiliStore-Misagent"
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
                throw NSError(domain: "RustMisagent", code: -3, userInfo: [NSLocalizedDescriptionKey: "Provider 創建失敗: \(msg)"])
            }
            guard let prov = provider else {
                throw NSError(domain: "RustMisagent", code: -4, userInfo: [NSLocalizedDescriptionKey: "Provider 句柄為空"])
            }
            self.provider = prov
            
            // 3. 連接 misagent
            var client: OpaquePointer?
            if let err = misagent_connect(prov, &client) {
                let msg = self.errorMessage(from: err)
                idevice_error_free(err)
                throw NSError(domain: "RustMisagent", code: -5, userInfo: [NSLocalizedDescriptionKey: "Misagent 連接失敗: \(msg)"])
            }
            guard let c = client else {
                throw NSError(domain: "RustMisagent", code: -6, userInfo: [NSLocalizedDescriptionKey: "Misagent 句柄為空"])
            }
            self.misagentClient = c
            print("[RustMisagent] 已連接（經 Rust FFI）")
        }.value
    }
    
    /// 把 provisioning profile 裝到設備（自動刷新的核心）
    public func installProfile(_ profileData: Data) async throws {
        guard let client = misagentClient else {
            throw NSError(domain: "RustMisagent", code: -10, userInfo: [NSLocalizedDescriptionKey: "未連接"])
        }
        try await Task.detached(priority: .userInitiated) {
            RustFFILock.shared.lock.lock()
            defer { RustFFILock.shared.lock.unlock() }
            let err: UnsafeMutablePointer<IdeviceFfiError>? = profileData.withUnsafeBytes { ptr in
                misagent_install(
                    client,
                    ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    profileData.count
                )
            }
            if let e = err {
                let msg = self.errorMessage(from: e)
                idevice_error_free(e)
                throw NSError(domain: "RustMisagent", code: -11, userInfo: [NSLocalizedDescriptionKey: "安裝 profile 失敗: \(msg)"])
            }
        }.value
        print("[RustMisagent] Profile 已安裝")
    }
    
    private func errorMessage(from err: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        // 復用 InstallationProxy 的錯誤提取邏輯
        // 簡化：直接返回通用信息
        return "FFI error"
    }
}
