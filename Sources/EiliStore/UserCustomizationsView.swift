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
            Text("來源：https://zzz.haus/oda.json。套件與雜湊均由第三方提供，並非獨立可信釘選；SHA-256 不符會記錄警告並繼續嘗試解壓，其他安全檢查仍須通過；再散布授權尚未確認，請確認你有權取得及使用。成功後會替換現有本機函式庫；失敗保留原檔。下載不會切換模式、連線 Apple 或開始登入，新版五庫仍可能不相容。")
        }
        .confirmationDialog("重設本機 Anisette？", isPresented: $anisette.resetting, titleVisibility: .visible) {
            Button("重設本機資料", role: .destructive) { anisette.reset() }
            Button("取消", role: .cancel) {}
        } message: { Text("會刪除本機 provisioning 身分，下一次登入須重新向 Apple 佈建。") }
        .alert("本機 Anisette", isPresented: Binding(get: { anisette.message != nil }, set: { if !$0 { anisette.message = nil } })) {
            Button("好") { anisette.message = nil }
        } message: { Text(anisette.message ?? "") }
        .navigationTitle("用戶自定義")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("user-customizations-page")
    }
}
