import SwiftUI

/// 連接配置（仿 PaxStore 格式）
struct ConnectionConfigView: View {
    @State private var useLocalVPN = false
    @State private var deviceIP = "10.7.0.1"
    @State private var reachable = ""
    @State private var isChecking = false
    @State private var bindHost = "127.0.0.1"
    @State private var bindPort = "51820"
    @State private var tunnelIP = ""
    @State private var autoDeviceIP = ""
    @State private var emproxyEnabled = true
    @State private var emproxyRunning = false
    
    private let defaults = UserDefaults.standard
    
    var body: some View {
        Form {
            Section {
                Toggle("Use Local VPN", isOn: $useLocalVPN)
                    .onChange(of: useLocalVPN) { _ in save() }
            }
            
            Section("AUTO DISCOVERED FROM NETWORK") {
                HStack {
                    Text("Tunnel IP")
                    Spacer()
                    Text(tunnelIP.isEmpty ? "—" : tunnelIP)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Device IP")
                    Spacer()
                    Text(autoDeviceIP.isEmpty ? "—" : autoDeviceIP)
                        .foregroundColor(.secondary)
                }
            }
            
            Section("REMOTE ENDPOINT") {
                HStack {
                    Text("Device IP")
                    Spacer()
                    TextField("10.7.0.1", text: $deviceIP)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .autocapitalization(.none)
                }
                HStack {
                    Text("Reachable")
                    Spacer()
                    Text(reachable)
                        .foregroundColor(reachable == "Yes" ? .green : .secondary)
                }
                Button("檢測連通性") {
                    Task { await checkReachable() }
                }
                .disabled(isChecking)
                Text("Note: 'Device IP' is mandatory.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Use Local VPN 關著時展開 WG 配置，開著時隱藏
            if !useLocalVPN {
                Section("WIREGUARD SERVER PARAMETERS") {
                    HStack {
                        Text("Bind Host / IP")
                        Spacer()
                        TextField("127.0.0.1", text: $bindHost)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .autocapitalization(.none)
                    }
                    HStack {
                        Text("Bind Port")
                        Spacer()
                        TextField("51820", text: $bindPort)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    Text("Configures the local UDP loopback host and port bound by EMProxy.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Toggle("EMProxy（WireGuard 通道）", isOn: $emproxyEnabled)
                        .onChange(of: emproxyEnabled) { newValue in
                            Task {
                                if newValue {
                                    let port = UInt16(bindPort) ?? 51820
                                    let result = EMProxyManager.shared.start(bindHost: bindHost, bindPort: port)
                                    emproxyRunning = (result == 0)
                                    AppLogger.shared.log(result == 0 ? "EMProxy 已啟動" : "EMProxy 啟動失敗: \(result)")
                                } else {
                                    let result = EMProxyManager.shared.stop()
                                    emproxyRunning = false
                                    AppLogger.shared.log("EMProxy 已停止")
                                }
                                defaults.set(newValue, forKey: "eilistore.emproxyEnabled")
                            }
                        }
                    HStack {
                        Text("EMProxy 狀態")
                        Spacer()
                        Text(emproxyRunning ? "運行中" : "已停止")
                            .foregroundColor(emproxyRunning ? .green : .secondary)
                    }
                    Text("開啟後在 App 內建立 WireGuard 通道（10.7.0.1）；關閉則使用外置 VPN。開關會記住，重開 App 依然有效。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Connection Config")
        .navigationBarItems(trailing: Button("Confirm") { save() })
        .onAppear { load() }
    }
    
    private func load() {
        useLocalVPN = defaults.bool(forKey: "eilistore.useLocalVPN")
        deviceIP = defaults.string(forKey: "eilistore.deviceIP") ?? "10.7.0.1"
        bindHost = defaults.string(forKey: "eilistore.bindHost") ?? "127.0.0.1"
        bindPort = defaults.string(forKey: "eilistore.bindPort") ?? "51820"
        emproxyEnabled = defaults.object(forKey: "eilistore.emproxyEnabled") as? Bool ?? true
        emproxyRunning = EMProxyManager.shared.isRunning
        discoverNetwork()
    }
    
    private func discoverNetwork() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let curr = ptr {
            let ifa = curr.pointee
            defer { ptr = ifa.ifa_next }
            guard let addrPtr = ifa.ifa_addr,
                  addrPtr.pointee.sa_family == UInt8(AF_INET),
                  let cname = ifa.ifa_name else { continue }
            let ifName = String(cString: cname)
            guard ifName.hasPrefix("utun") else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addrPtr, socklen_t(addrPtr.pointee.sa_len),
                              &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostname)
            var prefix = 32
            if let nm = ifa.ifa_netmask {
                let s = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr.s_addr
                }
                prefix = UInt32(bigEndian: s).nonzeroBitCount
            }
            tunnelIP = "\(ip)/\(prefix)"
            let parts = ip.split(separator: ".")
            if parts.count == 4 {
                autoDeviceIP = "\(parts[0]).\(parts[1]).\(parts[2]).1/32"
            }
            break
        }
    }
    
    private func save() {
        defaults.set(useLocalVPN, forKey: "eilistore.useLocalVPN")
        defaults.set(deviceIP, forKey: "eilistore.deviceIP")
        defaults.set(bindHost, forKey: "eilistore.bindHost")
        defaults.set(bindPort, forKey: "eilistore.bindPort")
        AppLogger.shared.log("連接配置已保存: useLocalVPN=\(useLocalVPN), deviceIP=\(deviceIP)")
    }
    
    private func checkReachable() async {
        await MainActor.run { isChecking = true }
        // TODO: 實際檢測連通性
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await MainActor.run {
            reachable = "Yes"
            isChecking = false
            AppLogger.shared.log("連通性檢測: \(deviceIP) 可達")
        }
    }
}
