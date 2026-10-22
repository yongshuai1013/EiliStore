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
                Label(model.provisioningPresent ? "本機 adi.pb：已保存" : "本機 adi.pb：尚未佈建",
                      systemImage: "key")
                    .font(.caption).foregroundColor(.secondary)
                    .accessibilityIdentifier("anisette-provisioning-status")
                NavigationLink(destination: ODAAcquisitionSettingsView(model: model)) {
                    Label("ODA 來源與快取管理", systemImage: "externaldrive")
                }
                .accessibilityIdentifier("anisette-oda-management")
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
                Text("僅在確認下載或明確允許自動取得後，從所選來源清單解析 ODA；只有缺少 ODA 時才用備援來源。套件不隨 App 打包。SHA-256 不符會記錄警告並繼續嘗試解壓；ZIP、CRC、大小與格式檢查仍須通過。這不是獨立釘選，也不保證來源可信或已取得授權。")
                    .font(.caption).foregroundColor(.secondary)
                Button("匯入本機 ADI 函式庫") { model.importing = true }
                    .disabled(model.working)
                    .accessibilityIdentifier("anisette-library-import")
                Text("Apple 函式庫不隨 App 提供。舊版選取 libCoreADI.so 與 libstoreservicescore.so。新版（如 6.5.3）選取 libstoreapi.so、libCoreADI.so、libCoreFP.so、libCoreLSKD.so、libFPDIFor3P.so，保留原名、勿混用版本，且須有權取得及使用。")
                    .font(.caption).foregroundColor(.secondary)
                Text("舊版兩庫也須通過相依庫與符號檢查，不能僅憑檔名判定可用。不相容匯入不會覆蓋原有通過檢查的庫組。新版五庫目前只提供離線相容性診斷，尚未支援其 Android ABI，不能用於本機登入。靜態檢查不驗證來源、安全性、授權或實際登入；遠端不需要這些檔案。")
                    .font(.caption).foregroundColor(.secondary)
                Button("重設 adi.pb（本機 Anisette）", role: .destructive) { model.resetting = true }
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

/// Settings only: opening this screen never acquires libraries or provisions an identity.
struct ODAAcquisitionSettingsView: View {
    @ObservedObject var model: AnisettePresentationModel
    @State private var source = UserDefaults.standard.string(forKey: EiliODASourceConfiguration.sourceURLKey) ?? ""
    @State private var fallback = UserDefaults.standard.string(forKey: EiliODASourceConfiguration.fallbackURLKey) ?? ""
    @AppStorage(EiliODASourceConfiguration.automaticAcquisitionKey) private var automaticAcquisition = false
    @State private var confirmingAutomatic = false
    @State private var confirmingPreparation = false
    @State private var notice: String?

    private var catalogSource: String {
        UserDefaults.standard.string(forKey: EiliODASourceConfiguration.catalogURLKey)
            ?? EiliODASourceConfiguration.defaultCatalogURLString
    }

    var body: some View {
        Form {
            Section(header: Text("ODA 來源"), footer: Text("留空沿用 Anisette 伺服器清單來源。支援直接 ODA、清單內 oda 物件或中繼資料路徑；伺服器失敗不會自動換成備援來源。僅接受 HTTPS。")) {
                TextField("來源清單或 ODA HTTPS 網址", text: $source)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .keyboardType(.URL)
                    .accessibilityIdentifier("oda-source-url")
                Text("沿用來源：\(catalogSource)")
                    .font(.caption).foregroundColor(.secondary)
                TextField("備援：\(EiliODASourceConfiguration.defaultFallbackURLString)", text: $fallback)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .keyboardType(.URL)
                    .accessibilityIdentifier("oda-fallback-url")
                Button("儲存來源設定") { saveSources() }
                    .disabled(model.working)
                    .accessibilityIdentifier("oda-save-sources")
            }
            Section(header: Text("函式庫快取"), footer: Text("已有通過檢查的快取時直接重用，不重下載、不改 adi.pb。缺少時才取得；損毀或不相容的庫不會被自動替換。手動匯入與下載共用安裝交易，失敗保留原檔。")) {
                Toggle("本機模式缺少函式庫時自動取得", isOn: Binding(
                    get: { automaticAcquisition },
                    set: { value in
                        if value { confirmingAutomatic = true }
                        else { automaticAcquisition = false }
                    }))
                    .disabled(model.working)
                    .accessibilityIdentifier("oda-automatic-acquisition")
                Button("檢查快取／缺少時取得") { confirmingPreparation = true }
                    .disabled(model.working)
                    .accessibilityIdentifier("oda-ensure-cache")
                Text(model.provisioningPresent ? "本機 adi.pb 已保存；內容不在此顯示。" : "本機尚無 provisioning 資料。")
                    .font(.caption)
                Text("自動取得預設關閉；只在選擇本機模式且已明確同意後生效。遠端模式不會因此下載或啟動本機引擎。取得函式庫本身不會連線 Apple；之後的本機登入佈建仍可能需要 Apple 連線。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .navigationTitle("ODA 來源與快取")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("oda-management-page")
        .confirmationDialog("允許自動取得第三方函式庫？", isPresented: $confirmingAutomatic, titleVisibility: .visible) {
            Button("確認允許自動取得") {
                do {
                    _ = try EiliODASourceConfiguration.selected.validated()
                    automaticAcquisition = true
                } catch { notice = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會使用已儲存的來源清單與備援設定；只在本機模式缺少函式庫時下載並快取。請先儲存來源，並確認你有權取得及使用。雜湊不符僅警告；來源、授權與真機登入均未獲保證。")
        }
        .confirmationDialog("檢查快取並在缺少時下載？", isPresented: $confirmingPreparation, titleVisibility: .visible) {
            Button("確認檢查／取得") { model.prepareLibraries() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("使用已儲存的來源；可用快取會原樣保留。缺少時才下載第三方 ODA 套件，不啟動引擎或登入 Apple。")
        }
        .alert("ODA 設定", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func saveSources() {
        let sourceText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackText = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedSource = sourceText.isEmpty ? catalogSource : sourceText
        let selectedFallback = fallbackText.isEmpty ? EiliODASourceConfiguration.defaultFallbackURLString : fallbackText
        guard let sourceURL = URL(string: selectedSource), let fallbackURL = URL(string: selectedFallback) else {
            notice = "來源與備援必須是有效的 HTTPS 網址。"
            return
        }
        do {
            _ = try EiliODASourceConfiguration(sourceURL: sourceURL, fallbackURL: fallbackURL, automaticAcquisition: false).validated()
            let defaults = UserDefaults.standard
            if sourceText.isEmpty { defaults.removeObject(forKey: EiliODASourceConfiguration.sourceURLKey) }
            else { defaults.set(sourceText, forKey: EiliODASourceConfiguration.sourceURLKey) }
            if fallbackText.isEmpty { defaults.removeObject(forKey: EiliODASourceConfiguration.fallbackURLKey) }
            else { defaults.set(fallbackText, forKey: EiliODASourceConfiguration.fallbackURLKey) }
            // Re-consent for this source before any later automatic acquisition.
            automaticAcquisition = false
            notice = "來源已儲存；如需自動取得，請重新明確允許。既有函式庫與 provisioning 資料未變更。"
        } catch { notice = error.localizedDescription }
    }
}
