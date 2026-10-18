import Foundation

/// 全局 Rust FFI 串行鎖（仿 minimuxer 的 lockdownLock）
/// 所有經 lockdownd 的 TCP 服務操作必須串行，避免併發衝突
public class RustFFILock {
    public static let shared = RustFFILock()
    /// AFC/安裝用（仿 minimuxer 的 lockdownLock）
    public let lock = NSRecursiveLock()
    /// 心跳專用（仿 minimuxer 的 heartbeatLock）
    public let heartbeatLock = NSLock()
    private init() {}
    
    /// 傳輸進行中標誌（仿 minimuxer 的 isTransferActive）
    /// AppInstaller 安裝時設為 true，心跳檢測到後跳過本次
    private var _isTransferActive: Bool = false
    private let flagLock = NSLock()
    public var isTransferActive: Bool {
        get { flagLock.lock(); defer { flagLock.unlock() }; return _isTransferActive }
        set { flagLock.lock(); defer { flagLock.unlock() }; _isTransferActive = newValue }
    }
    
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
    
    public func withLockAsync<T>(_ body: () async throws -> T) async rethrows -> T {
        // NSLock 不能跨 await，用信號量或直接同步
        // 簡化：直接執行（調用方保證在 Task.detached 內）
        lock.lock()
        defer { lock.unlock() }
        return try await body()
    }
    
    /// 判斷是否為 transport 錯誤（仿 minimuxer 的 isTransportErrorText）
    public static func isTransportError(_ error: Error) -> Bool {
        let failure = error as NSError
        if failure.domain == "RustDeviceTransport" {
            // Pinned idevice: socket, TLS, inactive/no connection, timeout.
            return [1, 3, 17, 19, 109].contains(failure.code)
        }
        let text = "\(error)".lowercased() + error.localizedDescription.lowercased()
        let keywords = [
            "unexpectedeof", "close_notify", "early eof",
            "brokenpipe", "broken pipe",
            "connectionreset", "connection reset",
            "connectionaborted", "notconnected"
        ]
        return keywords.contains { text.contains($0) }
    }
}
