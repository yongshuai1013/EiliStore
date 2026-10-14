import Foundation
import Network
import Darwin

/// 檢測外置 VPN 隧道是否暢通
/// 策略仿 SideStore minimuxer：掃描 utun 接口，自動發現隧道對端 IP，並行 TCP 探測
public class VPNConnectionChecker {
    public static let shared = VPNConnectionChecker()

    /// VPN 網關地址（自動發現的值；手動設置會覆蓋）
    public var gatewayHost = "10.7.0.1"
    public var gatewayPort: UInt16 = 62078

    /// 手動設置的 Device IP（UserDefaults 持久化；設置後優先於自動發現）
    public var manualGatewayHost: String? {
        get { UserDefaults.standard.string(forKey: "manualDeviceIP") }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: "manualDeviceIP")
            } else {
                UserDefaults.standard.removeObject(forKey: "manualDeviceIP")
            }
        }
    }

    /// 實際使用的網關地址：手動優先，否則用自動發現的
    public var effectiveGatewayHost: String {
        manualGatewayHost ?? gatewayHost
    }

    public var lastDiagnostic: String = ""

    private init() {}

    public struct TunnelInfo {
        public let ifName: String
        public let localIP: String
        public let peerIP: String   // 點對點對端地址；非點對點時為空
        public let netmask: String
    }

    private func ipv4String(_ sa: UnsafePointer<sockaddr>) -> String? {
        var copy = sa.pointee
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(&copy, socklen_t(copy.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(validatingUTF8: buf)
    }

    private func ipv4Raw(_ ip: String) -> UInt32? {
        var a = in_addr()
        guard inet_pton(AF_INET, ip, &a) == 1 else { return nil }
        return a.s_addr.bigEndian
    }

    private func rawToIPv4(_ raw: UInt32) -> String? {
        var addr = in_addr(s_addr: raw.bigEndian)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }

    /// 掃描所有啟用中的 utun 接口
    public func discoverTunnels() -> [TunnelInfo] {
        var result: [TunnelInfo] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let e = p.pointee
            defer { cursor = e.ifa_next }
            guard let namePtr = e.ifa_name else { continue }
            let name = String(cString: namePtr)
            guard name.lowercased().hasPrefix("utun") else { continue }
            let flags = Int32(e.ifa_flags)
            guard (flags & IFF_UP) != 0 else { continue }
            guard let addrPtr = e.ifa_addr, addrPtr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard let localIP = ipv4String(addrPtr) else { continue }
            if result.contains(where: { $0.ifName == name }) { continue }

            var peerIP = ""
            if (flags & IFF_POINTOPOINT) != 0,
               let dstPtr = e.ifa_dstaddr,
               let dst = ipv4String(dstPtr) {
                peerIP = dst
            }
            var mask = ""
            if let maskPtr = e.ifa_netmask, let m = ipv4String(maskPtr) {
                mask = m
            }
            result.append(TunnelInfo(ifName: name, localIP: localIP, peerIP: peerIP, netmask: mask))
        }
        return result.sorted { $0.ifName < $1.ifName }
    }

    /// 獲取 Wi-Fi (en0) 接口的 IPv4 地址（排除 link-local）
    public func discoverWiFiIP() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let e = p.pointee
            defer { cursor = e.ifa_next }
            guard let namePtr = e.ifa_name, String(cString: namePtr) == "en0" else { continue }
            let flags = Int32(e.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0 else { continue }
            guard let addrPtr = e.ifa_addr, addrPtr.pointee.sa_family == UInt8(AF_INET) else { continue }
            if let ip = ipv4String(addrPtr), !ip.hasPrefix("169.254.") {
                return ip
            }
        }
        return nil
    }

    /// 獲取 Wi-Fi (en0) 接口的公網 IPv6 地址（排除 link-local fe80::/10）
    public func discoverWiFiIPv6() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let e = p.pointee
            defer { cursor = e.ifa_next }
            guard let namePtr = e.ifa_name, String(cString: namePtr) == "en0" else { continue }
            let flags = Int32(e.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0 else { continue }
            guard let addrPtr = e.ifa_addr, addrPtr.pointee.sa_family == UInt8(AF_INET6) else { continue }
            if let ip = ipv4String(addrPtr), !ip.lowercased().hasPrefix("fe80") {
                return ip
            }
        }
        return nil
    }

    /// 診斷用：試綁定 0.0.0.0:port；若 EADDRINUSE 說明已有服務在監聽該端口
    private func isPortInUse(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r == 0 { return false }
        return errno == EADDRINUSE
    }

    public func tcpProbe(host: String, port: UInt16, timeoutMs: Int) async -> Bool {
        await probe(host: host, port: port, timeout: TimeInterval(timeoutMs) / 1000.0)
    }

    private func probe(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            guard let p = NWEndpoint.Port(rawValue: port) else {
                cont.resume(returning: false)
                return
            }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let lock = NSLock()
            var done = false
            func finish(_ r: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !done else { return }
                done = true
                conn.cancel()
                cont.resume(returning: r)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }

    /// 自動發現隧道對端並並行探測；成功時 gatewayHost 更新為實際可用的地址
    public func checkConnection(timeout: TimeInterval = 5) async -> Bool {
        let tunnels = discoverTunnels()

        var candidates: [String] = []
        var seen = Set<String>()
        func add(_ ip: String) {
            let t = ip.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !seen.contains(t),
                  t != "0.0.0.0",
                  !t.hasPrefix("127."),
                  !t.hasPrefix("224."),
                  !t.hasPrefix("239.") else { return }
            seen.insert(t)
            candidates.append(t)
        }

        // 候選 1：點對點對端地址（LocalDevVPN 這類 /32 隧道）
        for t in tunnels { add(t.peerIP) }
        // 候選 2：接口所在子網的 .1（WireGuard App 那種 /24 配置，設備端常用 .1；/32 跳過）
        for t in tunnels {
            if t.netmask != "255.255.255.255",
               let localRaw = ipv4Raw(t.localIP), let maskRaw = ipv4Raw(t.netmask),
               let first = rawToIPv4((localRaw & maskRaw) + 1) {
                add(first)
            }
        }
        // 候選 3：Wi-Fi 直連（lockdownd 在 Wi-Fi 下監聽 62078，不一定需要經過 VPN）
        let wifiIP = discoverWiFiIP()
        if let wifiIP = wifiIP { add(wifiIP) }
        // 候選 3b：localhost（若 lockdownd 綁 0.0.0.0，127.0.0.1 直達；沙盒對 localhost 無回環限制）
        // 注意：127.0.0.1 會被上面的本機地址過濾掉，這裡直接加入
        if !candidates.contains("127.0.0.1") { candidates.append("127.0.0.1") }
        // 候選 4：手動輸入的地址
        add(gatewayHost)
        // 候選 5：IPv6（之前只掃了 v4；若 lockdownd 綁 [::]，v6 環回可能通）
        if !candidates.contains("::1") { candidates.append("::1") }
        let wifiIP6 = discoverWiFiIPv6()
        if let w6 = wifiIP6, !candidates.contains(w6) { candidates.append(w6) }

        // 排除接口自己的地址
        let localIPs = Set(tunnels.map { $0.localIP })
        candidates.removeAll { localIPs.contains($0) }

        var diag: String
        if tunnels.isEmpty {
            diag = "未發現啟用的 utun 接口（VPN 隧道可能沒開）。"
        } else {
            diag = tunnels.map {
                "\($0.ifName)(本端\($0.localIP)/\($0.netmask.isEmpty ? "?" : $0.netmask) 對端\($0.peerIP.isEmpty ? "無" : $0.peerIP))"
            }.joined(separator: " ")
        }
        if let wifiIP = wifiIP {
            diag += " Wi-Fi直連候選:\(wifiIP)"
        }
        if let w6 = wifiIP6 {
            diag += " Wi-Fi v6候選:\(w6)"
        }
        diag += isPortInUse(port: gatewayPort) ? " [bind:端口被佔用，有服務在聽]" : " [bind:端口空閒]" 
        if candidates.isEmpty {
            lastDiagnostic = diag + " 無候選地址可探測。"
            return false
        }
        diag += " 探測 " + candidates.map { "\($0):\(gatewayPort)" }.joined(separator: ", ")

        // 同時探測 lockdown(62078) 與 remote pairing(49152)
        let ports: [UInt16] = [gatewayPort, 49152]
        diag += " 端口:" + ports.map { String($0) }.joined(separator: ",")
        var winner: String?
        var winnerPort: UInt16 = 0
        await withTaskGroup(of: (String, UInt16, Bool).self) { group in
            for c in candidates {
                for pt in ports {
                    group.addTask { (c, pt, await self.probe(host: c, port: pt, timeout: timeout)) }
                }
            }
            for await (ip, pt, ok) in group {
                if ok {
                    winner = ip
                    winnerPort = pt
                    group.cancelAll()
                    break
                }
            }
        }

        if let ip = winner {
            gatewayHost = ip
            lastDiagnostic = diag + " → \(ip):\(winnerPort) 連通"
            return true
        } else {
            lastDiagnostic = diag + " → 全部無回應"
            return false
        }
    }

    /// 為 lockdownd 動態啟動的服務端口（AFC / installation_proxy）找一個 TCP 連得上的地址。
    ///
    /// 背景：VPN 回環地址（如 10.7.0.1）通常只轉發 lockdownd 的 62078，
    /// StartService 返回的動態端口（如 AFC 的 49152）走回環地址連不上，
    /// 必須用設備本機直連地址（127.0.0.1 / Wi-Fi IP）。並行探測，先通先用。
    /// - Returns: 連得上的 host；全部不通時回 nil
    public func resolveServiceHost(port: UInt16, timeout: TimeInterval = 3) async -> String? {
        var candidates: [String] = []
        var seen = Set<String>()
        func add(_ ip: String) {
            let t = ip.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !seen.contains(t) else { return }
            seen.insert(t)
            candidates.append(t)
        }
        // 本機回環最優先：不依賴 Wi-Fi，沙盒無回環限制
        add("127.0.0.1")
        // Wi-Fi 直連 IP（服務若只綁 Wi-Fi 接口時需要）
        if let wifiIP = discoverWiFiIP() { add(wifiIP) }
        // VPN 回環地址放最後（通常只轉發 62078）
        add(gatewayHost)

        var winner: String?
        await withTaskGroup(of: (String, Bool).self) { group in
            for c in candidates {
                group.addTask { (c, await self.probe(host: c, port: port, timeout: timeout)) }
            }
            for await (ip, ok) in group {
                if ok {
                    winner = ip
                    group.cancelAll()
                    break
                }
            }
        }
        return winner
    }
}

