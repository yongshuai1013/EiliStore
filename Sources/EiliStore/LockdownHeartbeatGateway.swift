import Foundation

/// 真正的 Lockdown 心跳網關：實現 Marco-Polo 協議
/// 1. 經 lockdownd StartService("com.apple.mobile.heartbeat") 拿端口
/// 2. 直連心跳服務（TCP）
/// 3. 循環：讀 Marco（{"Interval": N}）→ 回 Polo（{"Command": "Polo"}）
public class LockdownHeartbeatGateway: HeartbeatGateway {
    private let lockdownClient: LockdownClient
    private let host: String
    public let servicePort: UInt16
    
    private var heartbeatFD: Int32 = -1
    private var heartbeatPort: UInt16 = 0
    
    public init(client: LockdownClient, host: String, servicePort: UInt16 = 62078) {
        self.lockdownClient = client
        self.host = host
        self.servicePort = servicePort
    }
    
    /// 確保心跳服務已連接
    private func ensureConnected() async throws {
        if heartbeatFD >= 0 { return }
        
        // 1. 經 lockdownd 啟動 heartbeat 服務
        print("[Heartbeat] StartService com.apple.mobile.heartbeat...")
        let (port, _) = try await lockdownClient.startService("com.apple.mobile.heartbeat")
        self.heartbeatPort = port
        print("[Heartbeat] 服務端口: \(port)")
        
        // 2. 直連（TCP 明文，heartbeat 服務通常不用 SSL）
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "Heartbeat", code: -1, userInfo: [NSLocalizedDescriptionKey: "socket 創建失敗"]) }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        host.withCString { cstr in
            inet_pton(AF_INET, cstr, &addr.sin_addr)
        }
        
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        guard result == 0 else {
            close(fd)
            throw NSError(domain: "Heartbeat", code: -2, userInfo: [NSLocalizedDescriptionKey: "連接心跳服務失敗"])
        }
        
        self.heartbeatFD = fd
        print("[Heartbeat] 已連接心跳服務")
    }
    
    /// 執行一次心跳：讀 Marco → 回 Polo
    public func performHeartbeat(interval: UInt64) async throws -> UInt64 {
        try await ensureConnected()
        
        // 讀 Marco（4 字節長度 + plist）
        // 用傳入的 interval 做超時
        let marco = try await readPlist(timeoutSeconds: Double(interval))
        
        // 檢查 SleepyTime
        if let command = marco["Command"] as? String, command == "SleepyTime" {
            print("[Heartbeat] 設備即將休眠")
            throw NSError(domain: "Heartbeat", code: -3, userInfo: [NSLocalizedDescriptionKey: "Device sleepy"])
        }
        
        // 取設備建議的間隔
        var newInterval = interval
        if let v = marco["Interval"] as? Int {
            newInterval = UInt64(v)
        } else if let v = marco["Interval"] as? UInt64 {
            newInterval = v
        }
        
        // 回 Polo
        try await sendPlist(["Command": "Polo"])
        print("[Heartbeat] Marco → Polo (interval: \(newInterval)s)")
        
        return newInterval
    }
    
    private func readPlist(timeoutSeconds: Double) async throws -> [String: Any] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    // 設置讀超時
                    var tv = timeval()
                    tv.tv_sec = Int(timeoutSeconds)
                    tv.tv_usec = 0
                    setsockopt(self.heartbeatFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                    
                    // 讀 4 字節長度
                    var lengthBuf = [UInt8](repeating: 0, count: 4)
                    var totalRead = 0
                    while totalRead < 4 {
                        let n = recv(self.heartbeatFD, &lengthBuf[totalRead], 4 - totalRead, 0)
                        if n <= 0 { throw NSError(domain: "Heartbeat", code: -4, userInfo: [NSLocalizedDescriptionKey: "讀取長度失敗"]) }
                        totalRead += n
                    }
                    let length = UInt32(bigEndian: Data(lengthBuf).withUnsafeBytes { $0.load(as: UInt32.self) })
                    
                    // 讀 plist 數據
                    var plistData = Data()
                    var remaining = Int(length)
                    while remaining > 0 {
                        var buf = [UInt8](repeating: 0, count: min(remaining, 4096))
                        let n = recv(self.heartbeatFD, &buf, buf.count, 0)
                        if n <= 0 { throw NSError(domain: "Heartbeat", code: -5, userInfo: [NSLocalizedDescriptionKey: "讀取 plist 失敗"]) }
                        plistData.append(contentsOf: buf[0..<n])
                        remaining -= n
                    }
                    
                    guard let dict = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
                        throw NSError(domain: "Heartbeat", code: -6, userInfo: [NSLocalizedDescriptionKey: "plist 解析失敗"])
                    }
                    continuation.resume(returning: dict)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func sendPlist(_ dict: [String: Any]) async throws {
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        var length = UInt32(plistData.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        let payload = lengthData + plistData
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                var totalSent = 0
                let bytes = [UInt8](payload)
                while totalSent < bytes.count {
                    let n = bytes.withUnsafeBytes { ptr in
                        send(self.heartbeatFD, ptr.baseAddress!.advanced(by: totalSent), bytes.count - totalSent, 0)
                    }
                    if n <= 0 {
                        continuation.resume(throwing: NSError(domain: "Heartbeat", code: -7, userInfo: [NSLocalizedDescriptionKey: "發送失敗"]))
                        return
                    }
                    totalSent += n
                }
                continuation.resume()
            }
        }
    }
    
    deinit {
        if heartbeatFD >= 0 {
            close(heartbeatFD)
        }
    }
}

/// 簡單的設備端點實現
public class SimpleHeartbeatEndpoint: HeartbeatEndpoint {
    private let host: String
    
    public init(host: String) {
        self.host = host
    }
    
    public func ip() async throws -> String {
        return host
    }
}
