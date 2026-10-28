import SwiftUI

/// Settings > User Customizations > Rust 登入設定。
/// 目前只有一項：Rust (isideload) 登入用的安卓標籤（client info），用戶可改；
/// 留空即用預設值。token 段的 Mac 自稱由 Rust 內部切換，不在此列。
struct RustLoginSettingsView: View {
    @AppStorage(EiliRustLoginSettings.androidClientInfoKey) private var androidClientInfo = ""
    @AppStorage(EiliRustAnisetteSource.preferenceKey) private var anisetteSource = EiliRustAnisetteSource.appProvided.rawValue

    var body: some View {
        Form {
            Section(
                header: Text("ANISETTE 來源（RUST 登入）"),
                footer: Text("App 現行：anisette 沿用 EiliStore 現行那套（本機 ODA／遠端伺服器），免 JIT。原生引擎：ODATest 實證成功的那套 Apparition 引擎，在進程內直接執行 Android 運行庫生成 anisette，adi.pb 存 App 文件夾的 NativeAnisette 區；使用前須先以 TrollStore 的 JIT 模式開啟本 App，安卓標籤由引擎固定（Pixel 8），下方標籤欄位不適用於它。")
            ) {
                Picker("Anisette 來源", selection: $anisetteSource) {
                    Text("App 現行（免 JIT）").tag(EiliRustAnisetteSource.appProvided.rawValue)
                    Text("原生引擎（需 JIT）").tag(EiliRustAnisetteSource.nativeEngine.rawValue)
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("rust-login-anisette-source-picker")
            }

            Section(
                header: Text("安卓標籤（CLIENT INFO）"),
                footer: Text("Rust 登入在 SRP 段向 Apple 自稱的 Android 身份字串。isideload 的自稱由 provider 決定、函式庫沒有現成設定；這裡的值會在登入時傳給 Rust provider。留空使用預設：\(EiliRustLoginSettings.defaultAndroidClientInfo)")
            ) {
                TextField("Android Client Info", text: $androidClientInfo)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .accessibilityIdentifier("rust-login-android-client-info")
                if !androidClientInfo.isEmpty {
                    Button("還原預設") { androidClientInfo = "" }
                        .accessibilityIdentifier("rust-login-android-client-info-reset")
                }
                HStack {
                    Text("目前生效")
                    Spacer()
                    Text(EiliRustLoginSettings.androidClientInfo)
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .lineLimit(2)
                }
            }

            Section(footer: Text("登入段（bag／SRP）用上面的安卓標籤；領 Xcode token 與 developer 請求由 Rust 自動改報 Mac；SMS 驗證的電話端點同樣由 Rust 改報 Mac。")) {
                EmptyView()
            }
        }
        .navigationTitle("Rust 登入設定")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("rust-login-settings-page")
    }
}
