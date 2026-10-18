import Foundation
import IDevice

public enum InstallationPackageType: Equatable {
    case ipa
    case developerApp
}

/// 用 SideStore/idevice Rust FFI 實現的 InstallationProxy（真實現）
public class RustInstallationProxy {
    private let transport = RustDeviceTransport()
    private var proxyClient: OpaquePointer?
    
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
        if let client = proxyClient {
            installation_proxy_client_free(client)
            proxyClient = nil
        }
        transport.disconnect()
    }
    
    /// 連接 installation_proxy
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
            self.proxyClient = try self.transport.connect(.installationProxy, host: self.host, pairingFileURL: self.pairingFileURL)
            print("[RustInstall] 已連接（經 Rust FFI）")
        }.value
    }
    
    /// 安裝設備上的 IPA 檔案，或已解壓的 .app bundle。
    public func install(
        packagePath: String,
        packageType: InstallationPackageType = .developerApp,
        progress: @escaping (String, Int) -> Void
    ) async throws {
        guard let client = proxyClient else {
            throw NSError(domain: "RustInstall", code: -10, userInfo: [NSLocalizedDescriptionKey: "未連接"])
        }
        
        await MainActor.run {
            progress("正在安裝...", 85)
        }
        
        return try await Task.detached(priority: .userInitiated) {
            try RustFFILock.shared.withLock {
            // Developer 僅適用於直接安裝 .app 目錄；IPA 使用一般 package install。
            let options = packageType == .developerApp ? plist_new_dict() : nil
            if let options {
                "Developer".withCString { valPtr in
                    let val = plist_new_string(valPtr)
                    "PackageType".withCString { keyPtr in
                        plist_dict_set_item(options, keyPtr, val)
                    }
                }
            }
            defer {
                if let options {
                    plist_free(options)
                }
            }
            
            // 調用 install（傳 options）
            let err: UnsafeMutablePointer<IdeviceFfiError>? = packagePath.withCString { cstr in
                installation_proxy_install(client, cstr, options)
            }
            
            if let err = err {
                let msg = self.errorMessage(from: err)
                idevice_error_free(err)
                throw NSError(domain: "RustInstall", code: -11, userInfo: [NSLocalizedDescriptionKey: "安裝失敗: \(msg)"])
            }
            
            print("[RustInstall] 安裝完成: \(packagePath)")
            } // withLock
        }.value
        
        await MainActor.run {
            progress("安裝完成", 100)
        }
    }
    
    private func errorMessage(from err: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        // Do not forward Rust's Debug-formatted payload, which can contain pairing values.
        return "[\(err.pointee.code):\(err.pointee.sub_code)] 裝置服務錯誤"
    }
}
// sync
