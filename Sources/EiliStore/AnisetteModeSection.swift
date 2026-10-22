import SwiftUI
import UniformTypeIdentifiers

struct AnisetteModeSection: View {
    @AppStorage(EiliAnisetteMode.preferenceKey) private var mode = EiliAnisetteMode.remote.rawValue
    @State private var importing = false
    @State private var resetting = false
    @State private var working = false
    @State private var message: String?

    private var selectedMode: Binding<String> {
        Binding(get: { EiliAnisetteMode(rawValue: mode)?.rawValue ?? EiliAnisetteMode.remote.rawValue },
                set: { mode = $0 })
    }

    var body: some View {
        Section(header: Text("Anisette 模式"), footer: Text("遠端模式保留現有伺服器與自動輪換。本機模式只在裝置產生 Anisette，初次啟用仍須連線 Apple；失敗不會自動改用遠端。模式變更於下次登入生效，現有登入維持原模式。")) {
            Text("下次登入使用").font(.subheadline)
            Picker("下次登入使用", selection: selectedMode) {
                Text("遠端（預設）").tag(EiliAnisetteMode.remote.rawValue)
                Text("On-Device").tag(EiliAnisetteMode.onDevice.rawValue)
                    .disabled(!EiliAnisetteMode.localBuildAvailable)
            }
            .pickerStyle(.segmented)
            .disabled(working)
            .accessibilityIdentifier("anisette-mode-picker")
            if !EiliAnisetteMode.localBuildAvailable {
                Text("此版本未包含本機引擎；需使用另行建置的相容性版本。")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Button("匯入本機 ADI 函式庫") { importing = true }
                    .disabled(working)
                Text("同時選取 libCoreADI.so 及 libstoreservicescore.so（ARM64 ELF）。請使用可信來源的原始檔案；檔頭檢查不是來源或安全性驗證。")
                    .font(.caption).foregroundColor(.secondary)
                Button("重設本機 Anisette", role: .destructive) { resetting = true }
                    .disabled(working)
                Text("本機資料與遠端身分分開保存。匯入或重設前請先登出使用本機模式的帳號；重設不會刪除遠端資料。")
                    .font(.caption).foregroundColor(.secondary)
            }
            if working { ProgressView() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                working = true
                Task {
                    do {
                        try await EiliAnisetteService.shared.importLibraries(urls)
                        message = "本機函式庫已匯入。可選擇 On-Device 後重新登入；尚未驗證真機登入結果。"
                    } catch { message = safeMessage(error) }
                    working = false
                }
            case .failure:
                message = "無法讀取選取的檔案，請重試。"
            }
        }
        .confirmationDialog("重設本機 Anisette？", isPresented: $resetting, titleVisibility: .visible) {
            Button("重設本機資料", role: .destructive) {
                working = true
                Task {
                    do {
                        try await EiliAnisetteService.shared.resetLocal()
                        message = "已重設本機 Anisette；遠端身分及函式庫保留不變。"
                    } catch { message = safeMessage(error) }
                    working = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會刪除本機 provisioning 身分，下一次登入須重新向 Apple 佈建。")
        }
        .alert("本機 Anisette", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func safeMessage(_ error: Error) -> String {
        if error is CancellationError { return "操作已取消。" }
        return (error as? EiliAnisetteError)?.localizedDescription ?? "本機資料操作未完成，請檢查檔案並重試。"
    }
}
