import SwiftUI
import UniformTypeIdentifiers

/// Settings > User Customizations owns the On-Device controls. This page
/// reuses the existing service and preference instead of introducing a second toggle.
struct UserCustomizationsView: View {
    @StateObject private var anisette = AnisettePresentationModel()

    var body: some View {
        Form {
            AnisetteModeSection(model: anisette)

            Section(header: Text("ANISETTE")) {
                NavigationLink(destination: AnisetteClientConfigurationView()) {
                    Label("Anisette Client Configuration", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("customizations-anisette-client-config")
            }

            Section(header: Text("SIDESIGN")) {
                NavigationLink(destination: SideSignClientConfigurationView()) {
                    Label("SideSign Client Configuration", systemImage: "network")
                }
                .accessibilityIdentifier("customizations-sidesign-client-config")
            }
        }
        .fileImporter(isPresented: $anisette.importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { anisette.handleImport($0) }
        .confirmationDialog("從第三方下載 ADI 函式庫？", isPresented: $anisette.confirmingDownload, titleVisibility: .visible) {
            Button("確認下載並替換本機函式庫") { anisette.download() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("來源：\(anisette.sourceSummary)。來源清單缺少 ODA 才會使用備援，網路或驗證失敗不會盲目換源。套件與雜湊均由第三方提供，並非獨立可信釘選；SHA-256 不符會記錄警告並繼續嘗試解壓，其他安全檢查仍須通過；再散布授權尚未確認，請確認你有權取得及使用。成功後會替換現有本機函式庫；失敗保留原檔。下載不會切換模式、連線 Apple 或開始登入，新版五庫仍可能不相容。")
        }
        .confirmationDialog("重設本機 Anisette？", isPresented: $anisette.resetting, titleVisibility: .visible) {
            Button("重設本機資料", role: .destructive) { anisette.reset() }
            Button("取消", role: .cancel) {}
        } message: { Text("只會刪除本機 adi.pb／provisioning 身分及其 routing 資料；函式庫、Client Configuration、遠端資料與憑證保留。若正使用本機帳號，須先自行登出；本操作不會自動登出。下一次本機登入須重新向 Apple 佈建。") }
        .alert("本機 Anisette", isPresented: Binding(get: { anisette.message != nil }, set: { if !$0 { anisette.message = nil } })) {
            Button("好") { anisette.message = nil }
        } message: { Text(anisette.message ?? "") }
        .navigationTitle("用戶自定義")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("user-customizations-page")
    }
}
