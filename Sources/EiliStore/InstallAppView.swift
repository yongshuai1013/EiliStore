import SwiftUI
import UniformTypeIdentifiers

/// 安裝 App 視圖：選擇 IPA，並選擇整包或解壓 .app 安裝模式。
struct InstallAppView: View {
    @AppStorage(AppInstaller.installationModeDefaultsKey)
    private var installationModeRawValue = AppInstallationMode.ipa.rawValue
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
            
            Section(header: Text("安裝方式")) {
                Picker("方式", selection: $installationModeRawValue) {
                    Text("整包 IPA").tag(AppInstallationMode.ipa.rawValue)
                    Text("解壓 .app").tag(AppInstallationMode.appBundle.rawValue)
                }
                .pickerStyle(.segmented)
                .disabled(isInstalling)

                Text(installationMode == .ipa
                     ? "直接傳送 IPA，由裝置安裝。這是預設方式；失敗時不會自動改用解壓模式。"
                     : "在本機解壓 IPA，再傳送 .app bundle 安裝。")
                    .font(.caption)
                    .foregroundColor(.secondary)
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

    private var installationMode: AppInstallationMode {
        AppInstallationMode(rawValue: installationModeRawValue) ?? .ipa
    }

    private func startInstall() {
        guard let ipaURL = selectedIPA else { return }
        guard !isInstalling else { return }
        
        isInstalling = true
        progressMessage = "開始安裝..."
        progressPercent = 0
        let mode = installationMode
        logger.log("開始安裝: \(ipaURL.lastPathComponent)（\(mode.title)）")
        
        Task {
            do {
                // 1. 先把 IPA 存到永久位置（用於以後自動重簽）
                let savedIPA = try saveIPAForFuture(ipaURL)
                logger.log("IPA 已保存: \(savedIPA.lastPathComponent)")
                
                // 2. 安裝
                try await AppInstaller.shared.install(ipaURL: ipaURL, mode: mode) { msg, pct in
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
                        iconData: nil,
                        expirationDate: nil
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

                let expiresDate = appInfo.expirationDate
                    ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())
                    ?? Date()
                if appInfo.expirationDate == nil {
                    logger.log("⚠️ IPA 沒有可讀取的內嵌 profile 到期日，沿用 7 天預設")
                } else {
                    logger.log("已讀取 profile 到期日: \(expiresDate)")
                }

                let newApp = InstalledApp(
                    name: appInfo.name,
                    bundleId: appInfo.bundleId,
                    team: "未知", // TODO: 從簽名信息獲取
                    expiresDate: expiresDate,
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
