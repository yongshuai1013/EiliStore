import SwiftUI
import UniformTypeIdentifiers

struct AnisetteModeSection: View {
    @AppStorage(EiliAnisetteMode.preferenceKey) private var mode = EiliAnisetteMode.remote.rawValue
    @State private var importing = false
    @State private var resetting = false
    @State private var confirmingDownload = false
    @State private var working = false
    @State private var message: String?
    @State private var libraryStatus: EiliAnisetteLibraryStatus?

    private var selectedMode: Binding<String> {
        Binding(get: { EiliAnisetteMode(rawValue: mode)?.rawValue ?? EiliAnisetteMode.remote.rawValue },
                set: { mode = $0 })
    }

    private var localSelectionDisabled: Bool {
        if !EiliAnisetteMode.localBuildAvailable { return true }
        if let libraryStatus, case .incompatible = libraryStatus { return true }
        return false
    }

    var body: some View {
        Section(header: Text("On-Device Anisette"), footer: Text("遠端模式保留現有伺服器與自動輪換。本機模式只在裝置產生 Anisette，初次啟用仍須連線 Apple；失敗不會自動改用遠端。模式變更於下次登入生效，現有登入維持原模式。")) {
            Text("下次登入使用").font(.subheadline)
            Picker("下次登入使用", selection: selectedMode) {
                Text("遠端（預設）").tag(EiliAnisetteMode.remote.rawValue)
                Text("On-Device").tag(EiliAnisetteMode.onDevice.rawValue)
                    .disabled(localSelectionDisabled)
            }
            .pickerStyle(.segmented)
            .disabled(working)
            .accessibilityIdentifier("anisette-mode-picker")
            if !EiliAnisetteMode.localBuildAvailable {
                Text("此版本未包含本機引擎；需使用另行建置的相容性版本。")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Label("本機引擎已內置", systemImage: "cpu")
                    .font(.caption).foregroundColor(.secondary)
                libraryStatusView
                    .accessibilityIdentifier("anisette-library-status")
                Button("重新檢查檔案") {
                    Task {
                        working = true
                        await refreshLibraryStatus()
                        working = false
                    }
                }
                .disabled(working)
                .accessibilityIdentifier("anisette-library-recheck")
                .accessibilityHint("只讀取本機檔案，不啟動引擎或連線 Apple")
                Button("下載 ADI 函式庫（SideStore 方式）") { confirmingDownload = true }
                    .disabled(working)
                    .accessibilityIdentifier("anisette-library-download")
                Text("僅在確認後，從 https://zzz.haus/oda.json 取得第三方 ODA 中繼資料及其指定套件；不隨 App 打包。下載會核對中繼資料提供的 SHA-256，不符即拒絕；這不是獨立釘選，也不保證來源可信或已取得授權。")
                    .font(.caption).foregroundColor(.secondary)
                Button("匯入本機 ADI 函式庫") { importing = true }
                    .disabled(working)
                    .accessibilityIdentifier("anisette-library-import")
                Text("Apple 函式庫不隨 App 提供。舊版選取 libCoreADI.so 與 libstoreservicescore.so。新版（如 6.5.3）選取 libstoreapi.so、libCoreADI.so、libCoreFP.so、libCoreLSKD.so、libFPDIFor3P.so，保留原名、勿混用版本，且須有權取得及使用。")
                    .font(.caption).foregroundColor(.secondary)
                Text("新版五庫目前只提供匯入與離線相容性診斷；尚未支援其 Android ABI，不能用於本機登入。請保持遠端模式。靜態檢查不驗證來源、安全性、授權或實際登入；遠端不需要這些檔案。")
                    .font(.caption).foregroundColor(.secondary)
                Button("重設本機 Anisette", role: .destructive) { resetting = true }
                    .disabled(working)
                    .accessibilityIdentifier("anisette-local-reset")
                Text("本機資料與遠端身分分開保存。匯入或重設前請先登出使用本機模式的帳號；重設不會刪除遠端資料。")
                    .font(.caption).foregroundColor(.secondary)
            }
            if working { ProgressView() }
        }
        .task { await refreshLibraryStatus() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                working = true
                Task {
                    do {
                        let status = try await EiliAnisetteService.shared.importLibraries(urls)
                        if case .incompatible(let reason) = status {
                            message = "新版庫組已保存供離線檢查，目前不能用於本機登入。\n" + reason
                        } else {
                            message = "舊版函式庫已匯入並通過基本檢查；尚未驗證真機登入結果。"
                        }
                    } catch { message = safeMessage(error) }
                    await refreshLibraryStatus()
                    working = false
                }
            case .failure:
                message = "無法讀取選取的檔案，請重試。"
            }
        }
        .confirmationDialog("從第三方下載 ADI 函式庫？", isPresented: $confirmingDownload, titleVisibility: .visible) {
            Button("確認下載並替換本機函式庫") {
                working = true
                Task {
                    do {
                        let status = try await EiliAnisetteService.shared.downloadLibraries()
                        if case .incompatible(let reason) = status {
                            message = "函式庫已下載並保存，但目前不能用於本機登入。\n" + reason
                        } else {
                            message = "函式庫已下載，通過 SHA-256 與基本格式檢查；尚未驗證真機登入，遠端仍為預設。"
                        }
                    } catch { message = safeMessage(error) }
                    await refreshLibraryStatus()
                    working = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("來源：https://zzz.haus/oda.json。套件與雜湊均由第三方提供，並非獨立可信釘選；再散布授權尚未確認，請確認你有權取得及使用。成功後會替換現有本機函式庫；失敗保留原檔。下載不會切換模式、連線 Apple 或開始登入，新版五庫仍可能不相容。")
        }
        .confirmationDialog("重設本機 Anisette？", isPresented: $resetting, titleVisibility: .visible) {
            Button("重設本機資料", role: .destructive) {
                working = true
                Task {
                    do {
                        try await EiliAnisetteService.shared.resetLocal()
                        message = "已重設本機 Anisette；遠端身分及函式庫保留不變。"
                    } catch { message = safeMessage(error) }
                    await refreshLibraryStatus()
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

    @ViewBuilder private var libraryStatusView: some View {
        if let libraryStatus {
            switch libraryStatus {
            case .engineUnavailable:
                Label("此版本未包含本機引擎", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.secondary)
            case .missing:
                Label("ADI 函式庫尚未完整匯入", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
            case .invalid:
                Label("ADI 檔案格式不符或無法讀取，請重新匯入", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
            case .present:
                Label("ADI 檔案基本檢查通過", systemImage: "checkmark.circle")
                    .font(.caption).foregroundColor(.secondary)
            case .incompatible(let reason):
                Label("新版庫組已識別，但目前引擎不相容", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
                Text(reason).font(.caption).foregroundColor(.secondary)
            }
        } else {
            Text("正在檢查本機 ADI 檔案…")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    @MainActor private func refreshLibraryStatus() async {
        let status = await EiliAnisetteService.shared.localLibraryStatus()
        guard !Task.isCancelled else { return }
        libraryStatus = status
    }

    private func safeMessage(_ error: Error) -> String {
        if error is CancellationError { return "操作已取消。" }
        if let downloadError = error as? ADIRuntimeLibraryDownloader.DownloadError { return downloadError.localizedDescription }
        return (error as? EiliAnisetteError)?.localizedDescription ?? "本機資料操作未完成，請檢查檔案並重試。"
    }
}
