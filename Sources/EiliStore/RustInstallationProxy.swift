import Foundation
import IDevice

public enum InstallationPackageType: Equatable {
    case ipa
    case developerApp
}

/// 用 SideStore/idevice Rust FFI 實現的 InstallationProxy（真實現）
public class RustInstallationProxy {
    private var provider: OpaquePointer?
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
        if let prov = provider {
            idevice_provider_free(prov)
            provider = nil
        }
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
                throw NSError(domain: "RustInstall", code: -1, userInfo: [NSLocalizedDescriptionKey: "配對檔解析失敗: \(msg)"])
            }
            guard let pf = pairingFile else {
                throw NSError(domain: "RustInstall", code: -2, userInfo: [NSLocalizedDescriptionKey: "配對檔句柄為空"])
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
                throw NSError(domain: "RustInstall", code: -2, userInfo: [NSLocalizedDescriptionKey: "無效的目標地址"])
            }
            
            var provider: OpaquePointer?
            let label = "PaxHeartbeatTest-Install"
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
                throw NSError(domain: "RustInstall", code: -3, userInfo: [NSLocalizedDescriptionKey: "Provider 創建失敗: \(msg)"])
            }
            guard let prov = provider else {
                throw NSError(domain: "RustInstall", code: -4, userInfo: [NSLocalizedDescriptionKey: "Provider 句柄為空"])
            }
            self.provider = prov
            
            // 3. 連接 installation_proxy
            var client: OpaquePointer?
            if let err = installation_proxy_connect(prov, &client) {
                let msg = self.errorMessage(from: err)
                idevice_error_free(err)
                throw NSError(domain: "RustInstall", code: -5, userInfo: [NSLocalizedDescriptionKey: "InstallationProxy 連接失敗: \(msg)"])
            }
            guard let c = client else {
                throw NSError(domain: "RustInstall", code: -6, userInfo: [NSLocalizedDescriptionKey: "InstallationProxy 句柄為空"])
            }
            self.proxyClient = c
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
        let code = err.pointee.code
        if let cmsg = err.pointee.message {
            let msg = String(cString: cmsg)
            return "[\(code)] \(msg)"
        }
        return "[\(code)] unknown"
    }
}
// sync
