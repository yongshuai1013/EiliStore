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
                try await AppInstaller.shared.install(ipaURL: ipaURL) { msg, pct in
                    Task { @MainActor in
                        progressMessage = msg
                        progressPercent = pct
                    }
                    logger.log("[\(pct)%] \(msg)")
                }
                await MainActor.run {
                    progressMessage = "安裝完成"
                    progressPercent = 100
                    isInstalling = false
                }
                logger.log("✅ 安裝完成: \(ipaURL.lastPathComponent)")
            } catch {
                await MainActor.run {
                    progressMessage = "安裝失敗: \(error.localizedDescription)"
                    isInstalling = false
                }
                logger.log("❌ 安裝失敗: \(error.localizedDescription)")
            }
        }
    }
}
