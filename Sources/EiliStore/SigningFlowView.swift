import SwiftUI
import SideSign
import UniformTypeIdentifiers
import ZIPFoundation

struct SigningFlowView: View {
    @State private var teams: [SideSign.Team] = []
    @State private var selectedTeam: SideSign.Team?
    @State private var ipaURL: URL?
    @State private var customBundleId: String = ""
    @State private var isPickingIPA = false
    @State private var isSigning = false
    @State private var progressLog = ""
    @State private var signedIPAURL: URL?
    @State private var errorMessage: String?
    @State private var showingShare = false
    @State private var deviceUDID = ""
    @State private var deviceName = "iPhone"
    @State private var showDeviceRegistration = false
    @State private var isPickingPairing = false
    @State private var deviceCount = 0
    
    private let signingService = PaxSigningService.shared
    
    private func log(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        progressLog += "[\(ts)] \(msg)\n"
    }
    
    var body: some View {
        Form {
            Section(header: Text("1. 選擇 IPA")) {
                if let url = ipaURL {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                } else {
                    Text("尚未選擇")
                        .foregroundColor(.secondary)
                }
                Button("選擇 IPA 文件") {
                    isPickingIPA = true
                }
                .disabled(isSigning)
            }
            
            Section(header: Text("Bundle ID（可選）")) {
                TextField("留空使用原始 Bundle ID", text: $customBundleId)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .disabled(isSigning)
                Text("如果 Apple 報 9401（Bundle ID 被佔用），在這裡改個新的")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("2. 選擇 Team")) {
                if teams.isEmpty {
                    Text("載入中...")
                } else {
                    Picker("Team", selection: $selectedTeam) {
                        ForEach(teams, id: \.identifier) { team in
                            Text(team.name).tag(team as SideSign.Team?)
                        }
                    }
                }
            }
            
            Section(header: Text("設備")) {
                if deviceCount > 0 {
                    Text("已註冊 \(deviceCount) 個設備")
                        .font(.caption)
                        .foregroundColor(.gray)
                } else {
                    Text("團隊沒有註冊的設備，創建 profile 需要至少一個")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Button("從配對檔導入 UDID") {
                    isPickingPairing = true
                }
                TextField("設備 UDID", text: $deviceUDID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("設備名稱", text: $deviceName)
                Button("註冊設備") {
                    Task { await registerDevice() }
                }
                .disabled(deviceUDID.isEmpty || selectedTeam == nil)
            }
            
            Section(header: Text("3. 簽名")) {
                Button(isSigning ? "簽名中..." : "開始簽名") {
                    Task { await startSigning() }
                }
                .disabled(ipaURL == nil || selectedTeam == nil || isSigning)
                
                if let err = errorMessage {
                    Text(err).foregroundColor(.red)
                }
            }
            
            if !progressLog.isEmpty {
                Section(header: Text("進度")) {
                    ScrollView {
                        Text(progressLog)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 200)
                }
            }
            
            if let signedURL = signedIPAURL {
                Section(header: Text("完成")) {
                    Text(signedURL.lastPathComponent)
                    Button("分享已簽名 IPA") {
                        showingShare = true
                    }
                    .sheet(isPresented: $showingShare) {
                        ShareSheet(url: signedURL)
                    }
                    // 簽完後可去「安裝 App」頁手動安裝
                    Text("簽名完成，請到「安裝 App」頁安裝")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("簽名 IPA")
        .onChange(of: selectedTeam) { _ in
            Task { await checkDevices() }
        }
        .sheet(isPresented: $isPickingPairing) {
            DocumentPicker { url in
                // 從檔名提取 UDID（格式：{UDID}.plist）
                let filename = url.deletingPathExtension().lastPathComponent
                // UDID 通常是 40 位 hex（iOS 8+）或 24 位
                if filename.count >= 24 {
                    deviceUDID = filename
                    log("已從配對檔提取 UDID")
                } else {
                    errorMessage = "無法從檔名提取 UDID"
                }
                isPickingPairing = false
            } onCancel: {
                isPickingPairing = false
            }
        }
        .sheet(isPresented: $isPickingIPA) {
            DocumentPicker { url in
                // 複製到沙盒內
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                do {
                    _ = url.startAccessingSecurityScopedResource()
                    try FileManager.default.copyItem(at: url, to: dest)
                    url.stopAccessingSecurityScopedResource()
                    ipaURL = dest
                    log("已選擇: \(url.lastPathComponent)")
                } catch {
                    errorMessage = "複製文件失敗: \(error.localizedDescription)"
                }
                isPickingIPA = false
            } onCancel: {
                isPickingIPA = false
            }
        }
        .task {
            await loadTeams()
        }
    }
    
    private func loadTeams() async {
        do {
            teams = try await signingService.fetchTeams()
            selectedTeam = teams.first
            await checkDevices()
        } catch {
            errorMessage = "載入 Team 失敗: \(error.localizedDescription)"
        }
    }
    
    private func startSigning() async {
        guard let ipaURL = ipaURL, let team = selectedTeam else { return }
        isSigning = true
        errorMessage = nil
        signedIPAURL = nil
        progressLog = ""
        
        do {
            log("開始簽名流程...")
            
            // 解包 IPA
            log("解包 IPA...")
            let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try await unzip(ipaURL, to: workDir)
            
            // 找到 .app
            let payload = workDir.appendingPathComponent("Payload")
            let contents = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
                throw SigningError.signingFailed("找不到 .app")
            }
            log("找到 App: \(appURL.lastPathComponent)")
            
            // 如果用戶指定了自定義 Bundle ID，先更新 Info.plist
            if !customBundleId.isEmpty {
                log("更新 Bundle ID 為: \(customBundleId)")
                try updateBundleId(appURL, newId: customBundleId)
            }
            
            // 解析 Bundle ID（主 App + extensions）
            let bundleIDs = try await extractBundleIDs(from: appURL)
            log("Bundle IDs: \(bundleIDs.joined(separator: ", "))")
            
            // 為每個 Bundle ID 找／建 App ID，下載 profile
            var profiles: [SideSign.ProvisioningProfile] = []
            for bundleID in bundleIDs {
                log("處理 \(bundleID)...")
                let appID = try await signingService.findOrCreateAppID(
                    bundleIdentifier: bundleID,
                    name: bundleID,
                    for: team
                )
                log("  App ID: \(appID.name)")
                
                let profile = try await signingService.provisioningProfile(for: appID, team: team)
                profiles.append(profile)
                log("  Profile 已下載 (\(profile.data.count) bytes)")
            }
            
            // 嵌入 profiles 到 .app 和 .appex
            log("嵌入 provisioning profiles...")
            try embedProfiles(profiles, into: appURL)
            log("  嵌入完成")
            
            // 獲取 KeyStore（從 P12 還原）
            guard let keyStore = signingService.loadActiveCertificate() else {
                throw SigningError.certificateFailed("沒有激活的證書，請先在簽名管理中激活一個證書")
            }
            log("KeyStore 已還原")
            
            // 簽名
            log("開始簽名...")
            let signer = SideSign.AppBundleSigner(team: team, keyStore: keyStore)
            try await signer.signApp(at: appURL, provisioningProfiles: profiles)
            log("簽名完成")
            
            // 重打包為 IPA（ZIPFoundation 手動打包，指定壓縮）
            log("重打包 IPA...")
            let payloadSize = directorySize(payload)
            log("Payload 未壓縮大小: \(String(format: "%.1f", Double(payloadSize) / 1024 / 1024)) MB")
            let signedIPA = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(appURL.deletingPathExtension().lastPathComponent)-signed.ipa")
            try? FileManager.default.removeItem(at: signedIPA)
            try zipPayload(payload, to: signedIPA)
            let ipaSize = (try? FileManager.default.attributesOfItem(atPath: signedIPA.path)[.size] as? Int64) ?? 0
            log("簽名後 IPA 大小: \(String(format: "%.1f", Double(ipaSize) / 1024 / 1024)) MB")
            signedIPAURL = signedIPA
            log("完成: \(signedIPA.lastPathComponent)")
            
            // 清理工作目錄（保留 signed IPA）
            try? FileManager.default.removeItem(at: workDir)
            
        } catch {
            errorMessage = "簽名失敗: \(error.localizedDescription)"
            log("錯誤: \(error)")
        }
        
        isSigning = false
    }
    
    private func registerDevice() async {
        guard let team = selectedTeam else { return }
        log("註冊設備...")
        do {
            let device = try await signingService.registerDevice(udid: deviceUDID, name: deviceName, for: team)
            log("設備已註冊: \(device.name)")
            showDeviceRegistration = false
            deviceUDID = ""
        } catch {
            errorMessage = "註冊失敗: \(error.localizedDescription)"
        }
    }
    
    private func checkDevices() async {
        guard let team = selectedTeam else { return }
        do {
            let devices = try await signingService.fetchDevices(for: team)
            deviceCount = devices.count
            if devices.isEmpty {
                log("團隊沒有註冊的設備，需要先註冊")
            } else {
                log("找到 \(devices.count) 個已註冊設備")
            }
        } catch {
            log("檢查設備失敗: \(error.localizedDescription)")
        }
    }
    
    private func unzip(_ src: URL, to dest: URL) async throws {
        try FileManager.default.unzipItem(at: src, to: dest)
    }

    private func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in enumerator {
                total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
            }
        }
        return total
    }

    private func updateBundleId(_ appURL: URL, newId: String) throws {
        let fm = FileManager.default
        // 更新主 App 的 Info.plist
        let infoPlist = appURL.appendingPathComponent("Info.plist")
        guard let dict = NSMutableDictionary(contentsOf: infoPlist) else {
            throw SigningError.signingFailed("無法讀取 Info.plist")
        }
        let oldId = dict["CFBundleIdentifier"] as? String ?? ""
        dict["CFBundleIdentifier"] = newId
        guard dict.write(to: infoPlist, atomically: true) else {
            throw SigningError.signingFailed("無法寫入 Info.plist")
        }
        // 更新 extensions 的 Bundle ID（保持後綴）
        if let plugins = fm.enumerator(at: appURL.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil) {
            for case let url as URL in plugins {
                if url.pathExtension == "appex" {
                    let extInfo = url.appendingPathComponent("Info.plist")
                    if let extDict = NSMutableDictionary(contentsOf: extInfo),
                       let extOldId = extDict["CFBundleIdentifier"] as? String {
                        // 保留 extension 的後綴部分
                        let suffix = extOldId.replacingOccurrences(of: oldId, with: "")
                        extDict["CFBundleIdentifier"] = newId + suffix
                        extDict.write(to: extInfo, atomically: true)
                    }
                }
            }
        }
    }
    
    private func zipPayload(_ payload: URL, to dest: URL) throws {
        guard let archive = Archive(url: dest, accessMode: .create) else {
            throw SigningError.signingFailed("無法創建 ZIP")
        }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: payload, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw SigningError.signingFailed("無法遍歷 Payload")
        }
        let emptyProvider: (Int64, Int) throws -> Data = { _, _ in Data() }
        try archive.addEntry(with: "Payload", type: .directory, uncompressedSize: 0, modificationDate: Date(), permissions: 0o755, provider: emptyProvider)
        for case let url as URL in enumerator {
            let rel = "Payload/" + url.path.replacingOccurrences(of: payload.path + "/", with: "")
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if vals?.isSymbolicLink == true {
                // 軟鏈：保留鏈接目標
                let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                let destData = (dest ?? "").data(using: .utf8) ?? Data()
                let provider: (Int64, Int) throws -> Data = { pos, size in
                    let start = Int(pos)
                    let end = min(start + size, destData.count)
                    guard start < end else { return Data() }
                    return destData[start..<end]
                }
                try archive.addEntry(with: rel, type: .symlink, uncompressedSize: Int64(destData.count), modificationDate: Date(), permissions: 0o777, provider: provider)
            } else if vals?.isDirectory == true {
                try archive.addEntry(with: rel, type: .directory, uncompressedSize: 0, modificationDate: Date(), permissions: 0o755, provider: emptyProvider)
            } else {
                try archive.addEntry(with: rel, relativeTo: payload.deletingLastPathComponent(), compressionMethod: .deflate)
            }
        }
    }
    
    private func embedProfiles(_ profiles: [SideSign.ProvisioningProfile], into appURL: URL) throws {
        // 主 App
        for profile in profiles {
            let target: URL
            if profile.bundleIdentifier == (NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String) {
                target = appURL
            } else {
                // 查找對應的 .appex
                let plugIns = appURL.appendingPathComponent("PlugIns")
                guard let extensions = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil) else { continue }
                guard let ext = extensions.first(where: { extURL in
                    let plist = extURL.appendingPathComponent("Info.plist")
                    return (NSDictionary(contentsOf: plist)?["CFBundleIdentifier"] as? String) == profile.bundleIdentifier
                }) else { continue }
                target = ext
            }
            let dest = target.appendingPathComponent("embedded.mobileprovision")
            try profile.data.write(to: dest)
        }
    }
    
    private func extractBundleIDs(from appURL: URL) async throws -> [String] {
        var ids: [String] = []
        
        // 主 App
        let infoPlist = appURL.appendingPathComponent("Info.plist")
        if let dict = NSDictionary(contentsOf: infoPlist),
           let bid = dict["CFBundleIdentifier"] as? String {
            ids.append(bid)
        }
        
        // Extensions
        let plugIns = appURL.appendingPathComponent("PlugIns")
        if let extensions = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil) {
            for ext in extensions where ext.pathExtension == "appex" {
                let extPlist = ext.appendingPathComponent("Info.plist")
                if let dict = NSDictionary(contentsOf: extPlist),
                   let bid = dict["CFBundleIdentifier"] as? String {
                    ids.append(bid)
                }
            }
        }
        
        guard !ids.isEmpty else {
            throw SigningError.signingFailed("無法解析 Bundle ID")
        }
        return ids
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: () -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (URL) -> Void
        var onCancel: () -> Void
        
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(url)
            }
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
