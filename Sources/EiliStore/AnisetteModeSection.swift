import SwiftUI
import UniformTypeIdentifiers

struct AnisetteModeSection: View {
    @AppStorage(EiliAnisetteMode.preferenceKey) private var mode = EiliAnisetteMode.remote.rawValue
    @ObservedObject var model: AnisettePresentationModel

    private var selectedMode: Binding<String> {
        Binding(get: { EiliAnisetteMode(rawValue: mode)?.rawValue ?? EiliAnisetteMode.remote.rawValue },
                set: { mode = $0 })
    }

    private var localSelectionDisabled: Bool {
        if !EiliAnisetteMode.localBuildAvailable { return true }
        if let libraryStatus = model.libraryStatus, case .incompatible = libraryStatus { return true }
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
            .disabled(model.working)
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
                        model.working = true
                        await model.refreshLibraryStatus()
                        model.working = false
                    }
                }
                .disabled(model.working)
                .accessibilityIdentifier("anisette-library-recheck")
                .accessibilityHint("只讀取本機檔案，不啟動引擎或連線 Apple")
                Button("下載 ADI 函式庫（SideStore 方式）") { model.confirmingDownload = true }
                    .disabled(model.working)
                    .accessibilityIdentifier("anisette-library-download")
                Text("僅在確認後，從 https://zzz.haus/oda.json 取得第三方 ODA 中繼資料及其指定套件；不隨 App 打包。下載會核對中繼資料提供的 SHA-256，不符會記錄警告並繼續嘗試解壓；ZIP、CRC、大小與格式檢查仍須通過。這不是獨立釘選，也不保證來源可信或已取得授權。")
                    .font(.caption).foregroundColor(.secondary)
                Button("匯入本機 ADI 函式庫") { model.importing = true }
                    .disabled(model.working)
                    .accessibilityIdentifier("anisette-library-import")
                Text("Apple 函式庫不隨 App 提供。舊版選取 libCoreADI.so 與 libstoreservicescore.so。新版（如 6.5.3）選取 libstoreapi.so、libCoreADI.so、libCoreFP.so、libCoreLSKD.so、libFPDIFor3P.so，保留原名、勿混用版本，且須有權取得及使用。")
                    .font(.caption).foregroundColor(.secondary)
                Text("舊版兩庫也須通過相依庫與符號檢查，不能僅憑檔名判定可用。不相容匯入不會覆蓋原有通過檢查的庫組。新版五庫目前只提供離線相容性診斷，尚未支援其 Android ABI，不能用於本機登入。靜態檢查不驗證來源、安全性、授權或實際登入；遠端不需要這些檔案。")
                    .font(.caption).foregroundColor(.secondary)
                Button("重設本機 Anisette", role: .destructive) { model.resetting = true }
                    .disabled(model.working)
                    .accessibilityIdentifier("anisette-local-reset")
                Text("本機資料與遠端身分分開保存。匯入或重設前請先登出使用本機模式的帳號；重設不會刪除遠端資料。")
                    .font(.caption).foregroundColor(.secondary)
            }
            if model.working { ProgressView() }
        }
        .task { await model.refreshLibraryStatus() }
    }

    @ViewBuilder private var libraryStatusView: some View {
        if let libraryStatus = model.libraryStatus {
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
                Label("ADI 庫組與目前引擎不相容", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
                Text(reason).font(.caption).foregroundColor(.secondary)
            }
        } else {
            Text("正在檢查本機 ADI 檔案…")
                .font(.caption).foregroundColor(.secondary)
        }
    }

}
