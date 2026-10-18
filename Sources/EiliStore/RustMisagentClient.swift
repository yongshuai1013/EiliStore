import Foundation
import IDevice

/// 用 SideStore/idevice Rust FFI 實現的 Misagent（provisioning profile 管理）
/// 用於自動刷新：只換 profile，不重裝 App
public class RustMisagentClient {
    private let transport = RustDeviceTransport()
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
        transport.disconnect()
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
            self.disconnect()
            self.misagentClient = try self.transport.connect(.misagent, host: self.host, pairingFileURL: self.pairingFileURL)
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
        // Do not forward Rust's Debug-formatted payload, which can contain pairing values.
        return "[\(err.pointee.code):\(err.pointee.sub_code)] 裝置服務錯誤"
    }
}
