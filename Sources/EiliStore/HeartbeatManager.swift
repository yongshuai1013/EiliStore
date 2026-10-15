import Foundation

/// 常駐心跳管理器（仿 khanh8249/minimuxer 的 MinimuxerImpl 常駐模式）
/// App 啟動後連接一次，整個生命週期保活，退出時才斷開
public class HeartbeatManager {
    public static let shared = HeartbeatManager()
    private init() {}
    
    private var client: LockdownClient?
    private var heartbeat: PaxHeartbeatService?
    private let lock = NSLock()
    private var _isRunning = false
    
    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }
    
    /// 啟動常駐心跳（需要配對檔 URL 和設備 host）
    /// 使用 Rust FFI 的真正 Marco-Polo 協議
    public func start(pairingFileURL: URL, host: String) async throws {
        lock.lock()
        guard !_isRunning else { lock.unlock(); return }
        _isRunning = true
        lock.unlock()
        
        print("[HeartbeatManager] 正在啟動常駐心跳（Rust FFI）...")
        
        // 直接用 Rust 網關，不需要 Swift LockdownClient
        // Rust 內部會自己處理 provider + heartbeat 連接
        let gateway = RustHeartbeatGateway(host: host, pairingFileURL: pairingFileURL)
        let endpoint = SimpleHeartbeatEndpoint(host: host)
        let heartbeat = PaxHeartbeatService(gateway: gateway, endpoint: endpoint)
        self.heartbeat = heartbeat
        // 注意：不再需要 self.client，因為 Rust 自己管理連接
        
        await heartbeat.start()
        print("[HeartbeatManager] 心跳服務已啟動（常駐，Rust）")
        
        // 3. 等待第一次心跳成功
        let ready = await heartbeat.waitUntilReady(timeout: 10.0)
        if !ready {
            print("[HeartbeatManager] ⚠️ 首次心跳超時，但服務繼續運行")
        } else {
            print("[HeartbeatManager] ✅ 首次心跳成功，會話穩定")
        }
    }
    
    /// 停止常駐心跳
    public func stop() async {
        lock.lock()
        guard _isRunning else { lock.unlock(); return }
        _isRunning = false
        lock.unlock()
        
        print("[HeartbeatManager] 正在停止常駐心跳...")
        if let heartbeat = heartbeat {
            await heartbeat.stop()
        }
        client?.disconnect()
        client = nil
        heartbeat = nil
        print("[HeartbeatManager] 已停止")
    }
    
    /// 獲取當前的 lockdownd 客戶端（供其他功能復用，避免重複連接）
    public func currentClient() -> LockdownClient? {
        return client
    }
}
