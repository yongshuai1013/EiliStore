import SwiftUI

/// Settings > User Customizations, laid out after SideStore's page: an
/// ANISETTE section (on-device toggle, client configuration, adi.pb reset)
/// and a SIDESIGN section. Mode changes apply at the next login; the existing
/// session keeps its mode.
struct UserCustomizationsView: View {
    @AppStorage(EiliAnisetteMode.preferenceKey) private var anisetteModeRawValue = EiliAnisetteMode.remote.rawValue
    @State private var showingResetConfirmation = false
    @State private var isResetting = false
    @State private var resultMessage: String?

    private var onDeviceBinding: Binding<Bool> {
        Binding(
            get: { EiliAnisetteMode(rawValue: anisetteModeRawValue) == .onDevice },
            set: { anisetteModeRawValue = ($0 ? EiliAnisetteMode.onDevice : .remote).rawValue }
        )
    }

    private var resultPresented: Binding<Bool> {
        Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })
    }

    var body: some View {
        Form {
            Section(header: Text("ANISETTE"),
                    footer: Text("遠端模式保留現有伺服器與自動輪換。本機模式只在裝置產生 Anisette，初次啟用仍須連線 Apple；失敗不會自動改用遠端。模式變更於下次登入生效，現有登入維持原模式。")) {
                Toggle(isOn: onDeviceBinding) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("On-Device Anisette")
                            Text("Run ADI emulation directly on device instead of remote servers")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "cpu")
                    }
                }
                .disabled(!EiliAnisetteMode.localBuildAvailable || isResetting)
                .accessibilityIdentifier("anisette-ondevice-toggle")

                if !EiliAnisetteMode.localBuildAvailable {
                    Text("此版本未包含本機 Anisette 引擎，只能使用遠端模式。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                NavigationLink(destination: AnisetteClientConfigurationView()) {
                    Label("Anisette Client Configuration", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("customizations-anisette-client-config")

                NavigationLink(destination: ODALibraryView()) {
                    Label("On-Device Library Source", systemImage: "arrow.down.doc")
                }
                .accessibilityIdentifier("customizations-oda-library")

                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    HStack {
                        if isResetting {
                            ProgressView()
                        } else {
                            Image(systemName: "trash")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reset adi.pb")
                            Text("清除本機 provisioning 資料；函式庫與遠端資料保留。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .disabled(isResetting)
                .accessibilityIdentifier("anisette-local-reset")
            }

            Section(header: Text("SIDESIGN")) {
                NavigationLink(destination: SideSignClientConfigurationView()) {
                    Label("SideSign Client Configuration", systemImage: "network")
                }
                .accessibilityIdentifier("customizations-sidesign-client-config")
            }
        }
        .confirmationDialog("重設本機 Anisette？", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
            Button("重設本機資料", role: .destructive) { resetLocal() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只會刪除本機 adi.pb／provisioning 身分及其 routing 資料；函式庫、Client Configuration、遠端資料與憑證保留。若正使用本機帳號，須先自行登出；本操作不會自動登出。下一次本機登入須重新向 Apple 佈建。")
        }
        .alert("本機 Anisette", isPresented: resultPresented) {
            Button("好") { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
        .navigationTitle("用戶自定義")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("user-customizations-page")
    }

    private func resetLocal() {
        guard !isResetting else { return }
        isResetting = true
        Task {
            do {
                try await EiliAnisetteService.shared.resetLocal()
                resultMessage = "本機 Anisette provisioning 資料已重設；下一次本機登入須重新向 Apple 佈建。"
            } catch {
                resultMessage = error.localizedDescription
            }
            isResetting = false
        }
    }
}
