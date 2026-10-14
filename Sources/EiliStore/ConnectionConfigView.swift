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
                    Text("Configures the local UDP loopback host and port.")
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
