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
    /// 傳輸層錯誤（線斷了）時自動重連並重試一次：整批共用一條連線時，
    /// 第一份撞上死線不應拖垮後面全部（SideStore 是每次操作新建連線）。
    public func installProfile(_ profileData: Data) async throws {
        do {
            try await installOnce(profileData)
        } catch let firstError as NSError {
            guard let code = firstError.userInfo["ideviceCode"] as? Int32,
                  Self.transportCodes.contains(code) else { throw firstError }
            print("[RustMisagent] 安裝撞傳輸錯誤，重連後重試: \(firstError.localizedDescription)")
            try await connect()
            try await installOnce(profileData)
        }
    }

    private func installOnce(_ profileData: Data) async throws {
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
                let code = e.pointee.code
                let subCode = e.pointee.sub_code
                let msg = self.errorMessage(code: code, subCode: subCode)
                idevice_error_free(e)
                throw NSError(domain: "RustMisagent", code: -11, userInfo: [
                    NSLocalizedDescriptionKey: "安裝 profile 失敗: \(msg)",
                    "ideviceCode": code,
                    "ideviceSubCode": subCode
                ])
            }
        }.value
        print("[RustMisagent] Profile 已安裝")
    }

    /// idevice 傳輸層錯誤碼（與 RustFFILock.isTransportError 對 RustDeviceTransport 的集合一致）
    private static let transportCodes: Set<Int32> = [1, 3, 17, 19, 109]

    private func kindLabel(for code: Int32) -> String {
        switch code {
        case 1: return "連線中斷"
        case 3, 4: return "TLS 錯誤"
        case 5: return "資料格式錯誤"
        case 13: return "設備回應異常"
        case 17: return "工作階段失效"
        case 19: return "連線未建立"
        case 23: return "設備已鎖定"
        case 109: return "連線逾時"
        case 200: return "設備拒絕安裝"
        default: return "裝置服務錯誤"
        }
    }

    private func errorMessage(code: Int32, subCode: Int32) -> String {
        // Do not forward Rust's Debug-formatted payload, which can contain pairing values.
        // 只保留錯誤碼與粗分類，讓日誌能判讀（例如 [1:0] 連線中斷 vs [200:0] 設備拒絕安裝）。
        return "[\(code):\(subCode)] \(kindLabel(for: code))"
    }
}
