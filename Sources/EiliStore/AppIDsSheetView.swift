import SwiftUI
import SideSign

/// App IDs 卡片頁（SideStore 樣式，只讀展示＋到期天數，青色主題）
struct AppIDsSheetView: View {
    @Environment(\.presentationMode) private var presentationMode
    @State private var appIDs: [SideSign.AppID] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("App IDs")
                        .font(.largeTitle)
                        .bold()

                    Text("Each app and app extension installed with EiliStore must register an App ID with Apple. Apple limits non-developer Apple IDs to 10 App IDs at a time.")
                        .foregroundColor(.secondary)

                    (Text("App IDs ") + Text("can't be deleted").bold() + Text(", but they do expire after one week. EiliStore will automatically renew App IDs for all active apps once they've expired."))
                        .foregroundColor(.secondary)

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else if let error = errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    } else {
                        ForEach(appIDs, id: \.identifier) { appID in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(appID.name)
                                        .font(.headline)
                                        .bold()
                                    Text(appID.bundleIdentifier)
                                        .font(.caption)
                                        .foregroundColor(.teal.opacity(0.75))
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("Expires in")
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .onAppear { loadAppIDs() }
    }

    private func daysUntil(_ date: Date?) -> Int? {
        guard let date = date else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        return max(0, days)
    }

    private func expiryText(for appID: SideSign.AppID) -> String {
        if let days = daysUntil(appID.expirationDate) {
            return "\(days) DAYS"
        }
        return "—"
    }

    private func expiryColor(for appID: SideSign.AppID) -> Color {
        guard let days = daysUntil(appID.expirationDate) else { return .gray }
        return EiliStore.expiryColor(days: days)
    }

    private func loadAppIDs() {
        Task {
            do {
                let teams = try await PaxSigningService.shared.fetchTeams()
                guard let team = teams.first else {
                    await MainActor.run {
                        self.errorMessage = "無可用 Team"
                        self.isLoading = false
                    }
                    return
                }
                let result = try await PaxSigningService.shared.fetchAppIDs(for: team)
                await MainActor.run {
                    self.appIDs = result
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}
