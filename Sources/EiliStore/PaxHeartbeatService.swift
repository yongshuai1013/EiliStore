import Foundation

/// 獨立心跳服務（參考 khanh8249/minimuxer 的修復版，重構為不依賴 Minimuxer 模塊）
/// 用於保活 lockdown 會話，防止 AFC 連接斷開
/// 修復：確保成功和失敗路徑都 sleep，間隔鉗在 [5,60] 秒，按 75% 回應（最少 4 秒）

/// 心跳網關協議（調用方需實現）
public protocol HeartbeatGateway: AnyObject {
    /// 服務端口（用於 TCP 連通性檢測）
    var servicePort: UInt16 { get }
    /// 執行一次心跳，返回下次心跳間隔（秒）
    func performHeartbeat(interval: UInt64) async throws -> UInt64
}

/// 設備端點（提供設備 IP）
public protocol HeartbeatEndpoint: AnyObject {
    func ip() async throws -> String
}

public final class PaxHeartbeatService {
    private let gateway: any HeartbeatGateway
    private let endpoint: any HeartbeatEndpoint
    
    public init(gateway: any HeartbeatGateway, endpoint: any HeartbeatEndpoint) {
        self.gateway = gateway
        self.endpoint = endpoint
    }
    
    private actor MutableState {
        var running = false
        var taskActive = false

        func tryStart() -> Bool {
            if taskActive {
                running = true
                return false
            }
            running = true
            taskActive = true
            return true
        }

        func stop() {
            running = false
        }

        func terminate() {
            taskActive = false
            running = false
        }
    }

    private let state = MutableState()
    private var lastErrorDescription: String?
    private var heartbeatTask: Task<Void, Never>?
    
    /// 最後一次心跳是否成功（單寫者：心跳任務；讀者輪詢）
    public private(set) var lastBeatSuccessful = false

    /// 啟動心跳循環，多次調用安全（已啟動則忽略）
    public func start() async {
        guard await state.tryStart() else { return }
        print("[PaxHeartbeat] Starting heartbeat task...")
        let task = Task.detached { [weak self] in
            guard let self = self else { return }
            await self.heartbeatLoop()
            await self.state.terminate()
            self.lastBeatSuccessful = false
            print("[PaxHeartbeat] heartbeat-task stopped")
        }
        self.heartbeatTask = task
    }

    /// 請求停止心跳並等待任務乾淨退出
    public func stop() async {
        await state.stop()
        lastBeatSuccessful = false
        let task = heartbeatTask
        heartbeatTask = nil
        task?.cancel()
        _ = await task?.value
        await state.terminate()
        print("[PaxHeartbeat] stop completed")
    }
    
    /// 重啟心跳循環，可選等待首次心跳成功
    @discardableResult
    public func restart(timeout: TimeInterval = 8.0) async -> Bool {
        print("[PaxHeartbeat] restarting...")
        await stop()
        try? await Task.sleep(nanoseconds: 200_000_000)
        await start()
        return await waitUntilReady(timeout: timeout)
    }
    
    /// 等待首次心跳成功，超時返回 false
    @discardableResult
    public func waitUntilReady(timeout: TimeInterval = 10.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !lastBeatSuccessful {
            if Task.isCancelled { return false }
            if Date() >= deadline {
                print("[PaxHeartbeat] waitUntilReady timed out after \(timeout)s")
                return false
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    private func logIfNeeded(_ message: String) {
        if message != lastErrorDescription {
            print("[PaxHeartbeat] \(message)")
            lastErrorDescription = message
        }
    }

    private func heartbeatLoop() async {
        // 初始間隔 5 秒（khanh8249 修復版用 MinimuxerConstants.heartbeatInterval）
        var currentInterval: UInt64 = 5

        while await state.running && !Task.isCancelled {
            let deviceIp: String
            do {
                deviceIp = try await self.endpoint.ip()
            } catch {
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            
            // 先驗證 TCP 可達
            if !Self.testTCP(ip: deviceIp, port: gateway.servicePort) {
                logIfNeeded("device not reachable (\(deviceIp):\(gateway.servicePort)), waiting...")
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }

            do {
                currentInterval = try await self.gateway.performHeartbeat(interval: currentInterval)
                lastBeatSuccessful = true
                lastErrorDescription = nil
            } catch {
                logIfNeeded("Heartbeat failed: \(error)")
                lastBeatSuccessful = false
                currentInterval = 5 // 重置為默認間隔
            }
            
            // FIX (khanh8249): 成功和失敗路徑都要 sleep
            // 間隔鉗在 [5, 60] 秒，按 75% 回應（最少 4 秒），確保在設備 10 秒看門狗超時前回應
            let clampedInterval = min(max(currentInterval, 5), 60)
            let sleepSeconds = max(Double(clampedInterval) * 0.75, 4.0)
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }
    }
    
    /// 簡單 TCP 連通性檢測
    private static func testTCP(ip: String, port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        
        // 設置超時
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                connect(sock, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
