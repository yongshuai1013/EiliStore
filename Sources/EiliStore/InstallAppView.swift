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
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.init(filenameExtension: "ipa") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // 複製到 App 目錄（fileImporter 的 URL 是臨時的）
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
                }
            case .failure(let error):
                logger.log("❌ 選擇文件失敗: \(error.localizedDescription)")
            }
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
                // TODO: 需要從 IPA 解析真實的 name/bundleId，現在用文件名
                let appName = ipaURL.deletingPathExtension().lastPathComponent
                let newApp = InstalledApp(
                    name: appName,
                    bundleId: "unknown.\(appName)", // TODO: 從 IPA 解析
                    team: "未知",
                    expiresDate: Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date(),
                    ipaPath: savedIPA.path
                )
                await MainActor.run {
                    AppManager.shared.addApp(newApp)
                    progressMessage = "安裝完成"
                    progressPercent = 100
                    isInstalling = false
                }
                logger.log("✅ 安裝完成: \(appName)，已登記到 App 列表")
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
