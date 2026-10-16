import SwiftUI
import SideSign

/// Apple Developer Portal App IDs 清單（唯讀；日期與裝置 profile 到期日分開顯示）
struct AppIDsSheetView: View {
    @Environment(\.presentationMode) private var presentationMode
    @State private var appIDs: [SideSign.AppID] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var sortedAppIDs: [SideSign.AppID] {
        appIDs.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder == .orderedSame {
                return $0.bundleIdentifier.localizedCaseInsensitiveCompare($1.bundleIdentifier) == .orderedAscending
            }
            return nameOrder == .orderedAscending
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("App IDs (\(appIDs.count))")
                        .font(.largeTitle)
                        .bold()

                    Text("這裡列出 Apple Developer Portal 回傳的 App ID 記錄。免費 Apple 帳戶通常受每 7 天最多註冊 10 個 App IDs 的限制。")
                        .foregroundColor(.secondary)

                    Text("此處的日期是 Apple App ID 記錄的到期日，與「我的 App」顯示的已安裝 provisioning profile 簽名效期不同；刷新簽名時會以新取得的 profile 到期日更新主頁。")
                        .foregroundColor(.secondary)

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }

                    if let errorMessage {
                        Text("同步失敗：\(errorMessage)")
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    if appIDs.isEmpty {
                        if !isLoading && errorMessage == nil {
                            Text("目前沒有 App IDs")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                    } else {
                        ForEach(sortedAppIDs, id: \.identifier) { appID in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(appID.name)
                                        .font(.headline)
                                        .bold()
                                        .lineLimit(1)
                                    Text(appID.bundleIdentifier)
                                        .font(.caption)
                                        .foregroundColor(.teal.opacity(0.75))
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 10)
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("Apple App ID 到期")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(expiryText(for: appID))
                                        .font(.subheadline)
                                        .bold()
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(expiryColor(for: appID))
                                        .cornerRadius(20)
                                }
                            }
                            .padding()
                            .background(Color.teal.opacity(0.08))
                            .cornerRadius(20)
                        }
                    }
                }
                .padding()
            }
            .refreshable { await loadAppIDs() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .onAppear { Task { await loadAppIDs() } }
    }

    private func expiryText(for appID: SideSign.AppID) -> String {
        guard let date = appID.expirationDate else { return "未知" }
        guard date > Date() else { return "已到期" }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.includesApproximationPhrase = false
        formatter.includesTimeRemainingPhrase = false
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        return formatter.string(from: Date(), to: date) ?? "未知"
    }

    private func expiryColor(for appID: SideSign.AppID) -> Color {
        guard let date = appID.expirationDate else { return .gray }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        return EiliStore.expiryColor(days: days)
    }

    private func loadAppIDs() async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        do {
            let result = try await AppManager.shared.syncAppIDsFromApple()
            await MainActor.run {
                appIDs = result
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}
