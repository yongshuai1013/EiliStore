import SwiftUI
import UniformTypeIdentifiers

/// 安裝 App 視圖：選擇 IPA → 經 .app 上傳安裝
struct InstallAppView: View {
    @State private var selectedIPA: URL?
    @State private var isInstalling = false
    @State private var progressMessage = ""
    @State private var progressPercent = 0
    @State private var showFilePicker = false
    @StateObject private var logger = AppLogger.shared
    
    var body: some View {
        List {
            Section(header: Text("IPA 文件")) {
                Button(action: { showFilePicker = true }) {
                    HStack {
                        Text("選擇 IPA")
                        Spacer()
                        Text(selectedIPA?.lastPathComponent ?? "未選擇")
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            
            Section(header: Text("安裝")) {
                Button(action: startInstall) {
                    HStack {
                        Spacer()
                        Text(isInstalling ? "安裝中..." : "開始安裝")
                            .foregroundColor(isInstalling ? .secondary : .teal)
                        Spacer()
                    }
                }
                .disabled(isInstalling || selectedIPA == nil)
            }
            
            if !progressMessage.isEmpty {
                Section(header: Text("進度")) {
                    Text("[\(progressPercent)%] \(progressMessage)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("安裝 App")
        .sheet(isPresented: $showFilePicker) {
            // 用跟簽名頁相同的 DocumentPicker（asCopy: true，系統先複製到臨時目錄，App 直接可讀）
            DocumentPicker(
                onPick: { url in
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    let dest = docs.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        selectedIPA = dest
                        logger.log("已選擇 IPA: \(url.lastPathComponent)")
                    } catch {
                        logger.log("❌ 複製 IPA 失敗: \(error.localizedDescription)")
                    }
                    showFilePicker = false
                },
                onCancel: {
                    showFilePicker = false
                }
            )
        }
    }

    private func startInstall() {
        guard let ipaURL = selectedIPA else { return }
        guard !isInstalling else { return }
        
        isInstalling = true
        progressMessage = "開始安裝..."
        progressPercent = 0
        logger.log("開始安裝: \(ipaURL.lastPathComponent)")
        
        Task {
            do {
                // 1. 先把 IPA 存到永久位置（用於以後自動重簽）
                let savedIPA = try saveIPAForFuture(ipaURL)
                logger.log("IPA 已保存: \(savedIPA.lastPathComponent)")
                
                // 2. 安裝
                try await AppInstaller.shared.install(ipaURL: ipaURL) { msg, pct in
                    Task { @MainActor in
                        progressMessage = msg
                        progressPercent = pct
                    }
                    logger.log("[\(pct)%] \(msg)")
                }
                
                // 3. 登記到 AppManager（帶 IPA 路徑）
                // 從 IPA 解析真實信息
                let appInfo: IPAParser.AppInfo
                do {
                    appInfo = try IPAParser.parse(ipaURL: savedIPA)
                    logger.log("解析 IPA: \(appInfo.name) (\(appInfo.bundleId))")
                } catch {
                    logger.log("⚠️ IPA 解析失敗，用文件名: \(error.localizedDescription)")
                    appInfo = IPAParser.AppInfo(
                        name: ipaURL.deletingPathExtension().lastPathComponent,
                        bundleId: "unknown.\(ipaURL.deletingPathExtension().lastPathComponent)",
                        version: "1.0",
                        iconData: nil
                    )
                }
                
                // 保存圖標到 Documents/AppIcons/
                var iconPath: String? = nil
                if let iconData = appInfo.iconData, !iconData.isEmpty {
                    let iconsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                        .appendingPathComponent("AppIcons")
                    try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
                    let iconFile = iconsDir.appendingPathComponent("\(appInfo.bundleId).png")
                    if (try? iconData.write(to: iconFile)) != nil {
                        iconPath = iconFile.path
                        logger.log("圖標已保存: \(iconFile.lastPathComponent)")
                    }
                }

                let newApp = InstalledApp(
                    name: appInfo.name,
                    bundleId: appInfo.bundleId,
                    team: "未知", // TODO: 從簽名信息獲取
                    expiresDate: Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date(),
                    ipaPath: savedIPA.path,
                    iconPath: iconPath
                )
                await MainActor.run {
                    AppManager.shared.addApp(newApp)
                    progressMessage = "安裝完成"
                    progressPercent = 100
                    isInstalling = false
                }
                logger.log("✅ 安裝完成: \(appInfo.name)，已登記到 App 列表")
            } catch {
                await MainActor.run {
                    progressMessage = "安裝失敗: \(error.localizedDescription)"
                    isInstalling = false
                }
                logger.log("❌ 安裝失敗: \(error.localizedDescription)")
            }
        }
    }
    
    /// 把 IPA 存到 Documents/IPAs/ 永久保存
    private func saveIPAForFuture(_ url: URL) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let ipaDir = docs.appendingPathComponent("IPAs", isDirectory: true)
        try FileManager.default.createDirectory(at: ipaDir, withIntermediateDirectories: true)
        
        let dest = ipaDir.appendingPathComponent(url.lastPathComponent)
        // 如果已存在，先刪
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}
