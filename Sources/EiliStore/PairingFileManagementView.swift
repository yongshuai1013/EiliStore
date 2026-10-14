import SwiftUI
import UniformTypeIdentifiers

struct PairingFileManagementView: View {
    @State private var lockdownFile: PairingFileInfo?
    @State private var remoteFile: PairingFileInfo?
    @State private var isPickingLockdown = false
    @State private var isPickingRemote = false
    @State private var errorMessage: String?
    
    var body: some View {
        List {
            // Active Protocol
            Section {
                HStack {
                    Text("Active Protocol")
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("lockdown")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(12)
                }
                HStack {
                    Text("Preferred Protocol")
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.gray)
                            .frame(width: 8, height: 8)
                        Text("None")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(12)
                }
            }
            
            // Pairing Files
            Section(header: Text("PAIRING FILES")) {
                // Lockdown
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                        VStack(alignment: .leading) {
                            Text("Lockdown")
                                .font(.headline)
                            Text("Pairing File")
                                .font(.headline)
                        }
                        Spacer()
                        if lockdownFile != nil {
                            Text("Configured")
                                .foregroundColor(.green)
                                .font(.subheadline)
                        } else {
                            Text("Missing")
                                .foregroundColor(.red)
                                .font(.subheadline)
                        }
                        Image(systemName: "chevron.right")
                            .foregroundColor(.gray)
                    }
                    
                    if let file = lockdownFile {
                        Divider()
                        PairingDetailRow(label: "File Name", value: file.fileName)
                        PairingDetailRow(label: "Status", value: "Active", isActive: true)
                        if let buid = file.systemBUID {
                            PairingDetailRow(label: "SystemBUID", value: buid)
                        }
                        if let hostID = file.hostID {
                            PairingDetailRow(label: "HostID", value: hostID)
                        }
                        if let udid = file.hardwareUDID {
                            PairingDetailRow(label: "Hardware UDID", value: udid)
                        }
                        if let mac = file.wifiMAC {
                            PairingDetailRow(label: "WiFi MAC", value: mac)
                        }
                        PairingDetailRow(label: "File Size", value: file.fileSize)
                        PairingDetailRow(label: "Date Created", value: file.dateCreated)
                        PairingDetailRow(label: "Date Modified", value: file.dateModified)
                    } else {
                        Button("導入 Lockdown 配對檔") {
                            isPickingLockdown = true
                        }
                    }
                }
                .padding(.vertical, 4)
                
                // Remote
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "waveform.circle")
                            .foregroundColor(.gray)
                            .font(.title2)
                        Text("Remote Pairing File")
                            .font(.headline)
                        Spacer()
                        if remoteFile != nil {
                            Text("Configured")
                                .foregroundColor(.green)
                                .font(.subheadline)
                        } else {
                            Text("Missing")
                                .foregroundColor(.red)
                                .font(.subheadline)
                        }
                        Button(action: { isPickingRemote = true }) {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    
                    if let file = remoteFile {
                        Divider()
                        PairingDetailRow(label: "File Name", value: file.fileName)
                    } else {
                        PairingDetailRow(label: "File Name", value: "PairingFile_RemoteRP.plist")
                    }
                }
                .padding(.vertical, 4)
            }
            
            // Pairing Methods
            Section(header: Text("PAIRING METHODS")) {
                NavigationLink(destination: Text("Wireless Pairing - 待實作")) {
                    HStack {
                        Image(systemName: "wifi")
                        Text("Wireless Pairing")
                    }
                }
            }
            
            // Management
            Section(header: Text("MANAGEMENT")) {
                Button(role: .destructive, action: resetPairingFiles) {
                    HStack {
                        Image(systemName: "exclamationmark.circle")
                        Text("Reset Pairing Files")
                    }
                }
                Text("Resetting pairing files removes stored Lockdown and Remote Pairing credentials. You will need to re-pair or re-import a pairing file and restart the app.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            if let err = errorMessage {
                Section {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Pairing File Management")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadPairingFiles() }
        .sheet(isPresented: $isPickingLockdown) {
            DocumentPicker { url in
                importPairingFile(from: url, type: .lockdown)
                isPickingLockdown = false
            } onCancel: {
                isPickingLockdown = false
            }
        }
        .sheet(isPresented: $isPickingRemote) {
            DocumentPicker { url in
                importPairingFile(from: url, type: .remote)
                isPickingRemote = false
            } onCancel: {
                isPickingRemote = false
            }
        }
    }
    
    private func pairingDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("PairingFiles")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private func loadPairingFiles() {
        let dir = pairingDirectory()
        let lockdownURL = dir.appendingPathComponent("PairingFile_Lockdown.plist")
        let remoteURL = dir.appendingPathComponent("PairingFile_RemoteRP.plist")
        
        if FileManager.default.fileExists(atPath: lockdownURL.path) {
            lockdownFile = PairingFileInfo(from: lockdownURL)
        }
        if FileManager.default.fileExists(atPath: remoteURL.path) {
            remoteFile = PairingFileInfo(from: remoteURL)
        }
    }
    
    private func importPairingFile(from url: URL, type: PairingType) {
        let dir = pairingDirectory()
        let filename = type == .lockdown ? "PairingFile_Lockdown.plist" : "PairingFile_RemoteRP.plist"
        let dest = dir.appendingPathComponent(filename)
        
        do {
            _ = url.startAccessingSecurityScopedResource()
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            url.stopAccessingSecurityScopedResource()
            // 驗證私鑰：結構＋p×q=n 數學驗算，壞的直接拒收
            if let badReason = validatePairingPrivateKey(at: dest) {
                try? FileManager.default.removeItem(at: dest)
                errorMessage = "配對檔私鑰無效，已拒收：\(badReason)\n請重新生成配對檔再導入。"
                loadPairingFiles()
                return
            }
            loadPairingFiles()
        } catch {
            errorMessage = "導入失敗: \(error.localizedDescription)"
        }
    }
    
    /// 驗證配對檔私鑰，返回 nil 表示通過，否則返回原因
    private func validatePairingPrivateKey(at url: URL) -> String? {
        guard let plistData = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return "無法解析 plist"
        }
        let hostKeyPEM = (plist["HostPrivateKey"] as? Data).flatMap({ String(data: $0, encoding: .utf8) })
            ?? (plist["HostPrivateKey"] as? String)
        guard let pem = hostKeyPEM, let der = LockdownClient.derFromPEM(pem) else {
            return "HostPrivateKey 不是有效的 PEM"
        }
        var diag: [String] = []
        guard LockdownClient.validatePKCS8(der, diag: &diag) != nil else {
            return "PKCS#8 結構無效：" + diag.joined(separator: "；")
        }
        if diag.contains(where: { $0.contains("p×q≠n") }) {
            return "私鑰參數數學驗算失敗（p×q≠n），文件在複製時已損壞"
        }
        return nil
    }
    
    private func resetPairingFiles() {
        let dir = pairingDirectory()
        try? FileManager.default.removeItem(at: dir)
        lockdownFile = nil
        remoteFile = nil
        loadPairingFiles()
    }
}

enum PairingType {
    case lockdown, remote
}

struct PairingFileInfo {
    let fileName: String
    let fileSize: String
    let dateCreated: String
    let dateModified: String
    var systemBUID: String?
    var hostID: String?
    var hardwareUDID: String?
    var wifiMAC: String?
    
    init(from url: URL) {
        self.fileName = url.lastPathComponent
        
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int {
            self.fileSize = size > 1024 ? "\(size/1024) KB" : "\(size) B"
        } else {
            self.fileSize = "Unknown"
        }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if let created = attrs?[.creationDate] as? Date {
            self.dateCreated = formatter.string(from: created)
        } else {
            self.dateCreated = "Unknown"
        }
        if let modified = attrs?[.modificationDate] as? Date {
            self.dateModified = formatter.string(from: modified)
        } else {
            self.dateModified = "Unknown"
        }
        
        // 解析 plist
        if let dict = NSDictionary(contentsOf: url) as? [String: Any] {
            self.systemBUID = dict["SystemBUID"] as? String
            self.hostID = dict["HostID"] as? String
            // UDID 可能在不同 key 下
            self.hardwareUDID = (dict["UDID"] as? String) ?? (dict["HardwareUDID"] as? String)
            self.wifiMAC = dict["WiFiMACAddress"] as? String ?? dict["WifiMAC"] as? String
        }
    }
}

struct PairingDetailRow: View {
    let label: String
    let value: String
    var isActive: Bool = false
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.gray)
            Spacer()
            if isActive {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text(value)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.15))
                .cornerRadius(12)
            } else {
                Text(value)
                    .multilineTextAlignment(.trailing)
            }
        }
        .font(.subheadline)
    }
}
