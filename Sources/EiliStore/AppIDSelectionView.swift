import SwiftUI

/// App IDs 選擇器：用戶選擇需要刷新簽名的
struct AppIDSelectionView: View {
    @ObservedObject var manager = AppManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var appIDs: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            List {
                Section(
                    header: Text("選擇需要自動刷新簽名的 App IDs"),
                    footer: Text("只有勾選的外部 App IDs 會加入刷新；未勾選的記錄不會刷新。")
                ) {
                    if isLoading {
                        ProgressView()
                    } else if let errorMessage {
                        Text("載入 App IDs 失敗：\(errorMessage)")
                            .font(.caption)
                            .foregroundColor(.red)
                    } else {
                        ForEach(appIDs.sorted(), id: \.self) { bid in
                            Button(action: { toggle(bid) }) {
                                HStack {
                                    Text(bid)
                                        .font(.caption)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if manager.selectedRefreshBundleIds.contains(bid) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.teal)
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("選擇 App IDs")
            .navigationBarItems(
                leading: Button("全選") { selectAll() },
                trailing: Button("完成") { dismiss() }
            )
            .onAppear { loadAppIDs() }
        }
    }

    private func loadAppIDs() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let result = try await manager.syncAppIDsFromApple()
                await MainActor.run {
                    appIDs = result.map(\.bundleIdentifier)
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

    private func toggle(_ bid: String) {
        if manager.selectedRefreshBundleIds.contains(bid) {
            manager.selectedRefreshBundleIds.remove(bid)
        } else {
            manager.selectedRefreshBundleIds.insert(bid)
        }
        UserDefaults.standard.set(Array(manager.selectedRefreshBundleIds), forKey: "selectedRefreshBundleIds")
    }

    private func selectAll() {
        if manager.selectedRefreshBundleIds.count == appIDs.count {
            manager.selectedRefreshBundleIds.removeAll()
        } else {
            manager.selectedRefreshBundleIds = Set(appIDs)
        }
        UserDefaults.standard.set(Array(manager.selectedRefreshBundleIds), forKey: "selectedRefreshBundleIds")
    }
}
