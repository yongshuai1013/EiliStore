import SwiftUI

/// On-Device Anisette device profile: the synthesized Android device data
/// the emulator presents to Apple's libraries while provisioning
/// (ro.product.model and friends). Empty fields keep the built-in defaults
/// shown as placeholders. Saving never touches an existing adi.pb — the
/// profile is read when a new identity is provisioned and when headers are
/// generated, so re-provision (Reset adi.pb) after changing it.
struct AnisetteDeviceProfileView: View {
    private struct Field: Identifiable {
        let id: String
        let label: String
        let placeholder: String
    }

    private static let fields: [Field] = [
        Field(id: "model", label: "型號 (ro.product.model)", placeholder: "Pixel 5"),
        Field(id: "brand", label: "品牌 (ro.product.brand)", placeholder: "google"),
        Field(id: "manufacturer", label: "製造商 (ro.product.manufacturer)", placeholder: "Google"),
        Field(id: "name", label: "產品名 (ro.product.name)", placeholder: "redfin"),
        Field(id: "device", label: "裝置名 (ro.product.device)", placeholder: "redfin"),
        Field(id: "release", label: "Android 版本 (ro.build.version.release)", placeholder: "11"),
        Field(id: "sdkVersion", label: "SDK 版本 (ro.build.version.sdk)", placeholder: "30"),
        Field(id: "fingerprint", label: "指紋 (ro.build.fingerprint)", placeholder: "google/redfin/redfin:11/RQ3A.211001.001/7641976:user/release-keys"),
    ]

    @State private var values: [String: String]
    @State private var message: String?

    init() {
        let defaults = UserDefaults.standard
        var loaded: [String: String] = [:]
        for field in Self.fields {
            loaded[field.id] = defaults.string(forKey: EiliDeviceProfileConfiguration.keyPrefix + field.id) ?? ""
        }
        _values = State(initialValue: loaded)
    }

    var body: some View {
        Form {
            Section(header: Text("DEVICE PROFILE"),
                    footer: Text("本機佈建時呈報給 Apple 函式庫的 Android 裝置資料；留空的欄位使用預設值（欄位內灰字）。改完請儲存，並 Reset adi.pb 重新佈建，讓新身份用新資料鑄造；已鑄好的 adi.pb 不會被改動。欄位之間應互相一致（例如型號與指紋描述的是同一台裝置）。")) {
                ForEach(Self.fields) { field in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(field.label).font(.subheadline)
                        TextField(field.placeholder, text: binding(for: field.id))
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .accessibilityIdentifier("deviceprofile-\(field.id)")
                    }
                }
                Button("儲存裝置資料") { save() }
                    .accessibilityIdentifier("deviceprofile-save")
                Button("恢復全部預設", role: .destructive) { resetAll() }
                    .accessibilityIdentifier("deviceprofile-reset")
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("本機裝置資料")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("anisette-device-profile-page")
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(get: { values[id] ?? "" }, set: { values[id] = $0 })
    }

    private func save() {
        let defaults = UserDefaults.standard
        for field in Self.fields {
            let value = (values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                defaults.removeObject(forKey: EiliDeviceProfileConfiguration.keyPrefix + field.id)
            } else {
                defaults.set(value, forKey: EiliDeviceProfileConfiguration.keyPrefix + field.id)
            }
        }
        message = "已儲存；下一次佈建與產生標頭時使用新資料。請 Reset adi.pb 後再登入。"
    }

    private func resetAll() {
        let defaults = UserDefaults.standard
        for field in Self.fields {
            defaults.removeObject(forKey: EiliDeviceProfileConfiguration.keyPrefix + field.id)
            values[field.id] = ""
        }
        message = "已恢復全部預設值。"
    }
}
