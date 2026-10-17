import Foundation
import IDevice

/// 用 SideStore/idevice Rust FFI 實現的 AFC 客戶端（真實現）
/// 經 Provider 直連，Rust 內部處理 StartService
public class RustAFCClient {
    private var provider: OpaquePointer?
    private var afcClient: OpaquePointer?
    
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
        if let client = afcClient {
            afc_client_free(client)
            afcClient = nil
        }
        if let prov = provider {
            idevice_provider_free(prov)
            provider = nil
        }
    }
    
    /// 連接 AFC（經 Rust Provider，帶重試）
    public func connect() async throws {
        let maxAttempts = 3
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await connectOnce()
            } catch {
                guard attempt < maxAttempts, RustFFILock.isTransportError(error) else { throw error }
                // 退避 sleep（仿 minimuxer：第1次1秒、第2次2秒）
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000 * attempt))
            }
        }
    }
    
    private func connectOnce() async throws {
        return try await Task.detached(priority: .userInitiated) {
            try RustFFILock.shared.withLock {
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
                throw NSError(domain: "RustAFC", code: -1, userInfo: [NSLocalizedDescriptionKey: "配對檔解析失敗: \(msg)"])
            }
            guard let pf = pairingFile else {
                throw NSError(domain: "RustAFC", code: -2, userInfo: [NSLocalizedDescriptionKey: "配對檔句柄為空"])
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
                throw NSError(domain: "RustAFC", code: -2, userInfo: [NSLocalizedDescriptionKey: "無效的目標地址"])
            }
            
            var provider: OpaquePointer?
            let label = "PaxHeartbeatTest-AFC"
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
                throw NSError(domain: "RustAFC", code: -3, userInfo: [NSLocalizedDescriptionKey: "Provider 創建失敗: \(msg)"])
            }
            guard let prov = provider else {
                throw NSError(domain: "RustAFC", code: -4, userInfo: [NSLocalizedDescriptionKey: "Provider 句柄為空"])
            }
            self.provider = prov
            
            // 3. 連接 AFC（Rust 內部會 StartService）
            var client: OpaquePointer?
            if let err = afc_client_connect(prov, &client) {
                let msg = self.errorMessage(from: err)
                idevice_error_free(err)
                throw NSError(domain: "RustAFC", code: -5, userInfo: [NSLocalizedDescriptionKey: "AFC 連接失敗: \(msg)"])
            }
            guard let c = client else {
                throw NSError(domain: "RustAFC", code: -6, userInfo: [NSLocalizedDescriptionKey: "AFC 句柄為空"])
            }
            self.afcClient = c
            print("[RustAFC] 已連接（經 Rust FFI）")
            } // withLock
        }.value
    }
    
    /// 創建目錄（經 Rust FFI）
    public func makeDirectory(_ path: String) async throws {
        guard let client = afcClient else {
            throw NSError(domain: "RustAFC", code: -20, userInfo: [NSLocalizedDescriptionKey: "未連接"])
        }
        
        return try await Task.detached(priority: .userInitiated) {
            RustFFILock.shared.withLock {
                let err: UnsafeMutablePointer<IdeviceFfiError>? = path.withCString { cstr in
                    afc_make_directory(client, cstr)
                }
                // 目錄已存在也算成功，忽略錯誤
                if let err = err {
                    idevice_error_free(err)
                }
                print("[RustAFC] 建目錄: \(path)")
            }
        }.value
    }
    
    /// 上傳文件到 /PublicStaging/
    public func uploadFile(localURL: URL, remotePath: String, progress: @escaping (Int64, Int64) -> Void) async throws {
        guard let client = afcClient else {
            throw NSError(domain: "RustAFC", code: -10, userInfo: [NSLocalizedDescriptionKey: "未連接"])
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let total = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        return try await Task.detached(priority: .userInitiated) {
            let input = try FileHandle(forReadingFrom: localURL)
            defer { try? input.close() }

            try RustFFILock.shared.withLock {
                // 1. 打開遠程文件（寫模式：AfcWr = 4）
                var remoteHandle: OpaquePointer?
                if let err = remotePath.withCString({ cstr in
                    afc_file_open(client, cstr, AfcWr, &remoteHandle)
                }) {
                    let msg = self.errorMessage(from: err)
                    idevice_error_free(err)
                    throw NSError(domain: "RustAFC", code: -11, userInfo: [NSLocalizedDescriptionKey: "打開遠程文件失敗: \(msg)"])
                }
                guard let handle = remoteHandle else {
                    throw NSError(domain: "RustAFC", code: -12, userInfo: [NSLocalizedDescriptionKey: "文件句柄為空"])
                }

                var remoteHandleOpen = true
                defer {
                    if remoteHandleOpen { _ = afc_file_close(handle) }
                }

                // 2. 從本機檔案串流讀取，每次最多上傳 64 KB。
                let chunkSize = 1024 * 64
                var sent: Int64 = 0
                while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                    let writeError = chunk.withUnsafeBytes { bytes -> UnsafeMutablePointer<IdeviceFfiError>? in
                        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                            return nil
                        }
                        return afc_file_write(handle, base, bytes.count)
                    }
                    if let err = writeError {
                        let msg = self.errorMessage(from: err)
                        idevice_error_free(err)
                        throw NSError(domain: "RustAFC", code: -14, userInfo: [NSLocalizedDescriptionKey: "寫入失敗 at \(sent): \(msg)"])
                    }
                    sent += Int64(chunk.count)
                    progress(sent, total)
                }

                // 3. 關閉文件，確保已寫入設備。
                if let err = afc_file_close(handle) {
                    remoteHandleOpen = false
                    let msg = self.errorMessage(from: err)
                    idevice_error_free(err)
                    throw NSError(domain: "RustAFC", code: -14, userInfo: [NSLocalizedDescriptionKey: "關閉文件失敗: \(msg)"])
                }
                remoteHandleOpen = false

                print("[RustAFC] 上傳完成: \(remotePath) (\(sent) bytes)")
            } // withLock
        }.value
    }
    
    /// 獲取遠端文件大小（用於上傳後驗證）
    public func getRemoteFileSize(remotePath: String) async throws -> Int64 {
        guard let client = afcClient else {
            throw NSError(domain: "RustAFC", code: -20, userInfo: [NSLocalizedDescriptionKey: "未連接"])
        }
        
        return try await Task.detached(priority: .userInitiated) {
            try RustFFILock.shared.withLock {
                var info = AfcFileInfo()
                let err = remotePath.withCString { cstr in
                    afc_get_file_info(client, cstr, &info)
                }
                if let err = err {
                    let msg = self.errorMessage(from: err)
                    idevice_error_free(err)
                    throw NSError(domain: "RustAFC", code: -21, userInfo: [NSLocalizedDescriptionKey: "獲取文件信息失敗: \(msg)"])
                }
                defer { afc_file_info_free(&info) }
                return Int64(info.size)
            }
        }.value
    }
    
    /// 讀取遠端文件內容（用於上傳後驗證 hash）
    public func readRemoteFile(remotePath: String) async throws -> Data {
        guard let client = afcClient else {
            throw NSError(domain: "RustAFC", code: -20, userInfo: [NSLocalizedDescriptionKey: "未連接"])
        }
        
        return try await Task.detached(priority: .userInitiated) {
            try RustFFILock.shared.withLock {
                // 以讀模式打開
                var handle: OpaquePointer?
                let openErr = remotePath.withCString { cstr in
                    afc_file_open(client, cstr, AfcFopenMode(rawValue: 1), &handle)
                }
                if let err = openErr {
                    let msg = self.errorMessage(from: err)
                    idevice_error_free(err)
                    throw NSError(domain: "RustAFC", code: -22, userInfo: [NSLocalizedDescriptionKey: "打開讀取失敗: \(msg)"])
                }
                guard let h = handle else {
                    throw NSError(domain: "RustAFC", code: -23, userInfo: [NSLocalizedDescriptionKey: "文件句柄為空"])
                }
                defer { afc_file_close(h) }
                
                // 讀取整個文件
                var dataPtr: UnsafeMutablePointer<UInt8>?
                var length: Int = 0
                if let err = afc_file_read_entire(h, &dataPtr, &length) {
                    let msg = self.errorMessage(from: err)
                    idevice_error_free(err)
                    throw NSError(domain: "RustAFC", code: -24, userInfo: [NSLocalizedDescriptionKey: "讀取失敗: \(msg)"])
                }
                guard let ptr = dataPtr, length > 0 else {
                    throw NSError(domain: "RustAFC", code: -25, userInfo: [NSLocalizedDescriptionKey: "讀取到空數據"])
                }
                defer { afc_file_read_data_free(ptr, length) }
                
                return Data(bytes: ptr, count: length)
            }
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
