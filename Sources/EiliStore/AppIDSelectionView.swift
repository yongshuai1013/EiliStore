import SwiftUI

/// App IDs 選擇器：用戶選擇需要刷新簽名的
struct AppIDSelectionView: View {
    @ObservedObject var manager = AppManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var appIDs: [String] = []
    @State private var isLoading = false

    var body: some View {
        NavigationView {
            List {
                Section(
                    header: Text("選擇需要自動刷新簽名的 App IDs"),
                    footer: Text("未選中的不會刷新。不選 = 全部刷新。")
                ) {
                    if isLoading {
                        ProgressView()
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
        if manager.registeredBundleIds.isEmpty {
            isLoading = true
            Task {
                await manager.syncExpiryFromAppIDs()
                await MainActor.run {
                    appIDs = Array(manager.registeredBundleIds)
                    isLoading = false
                }
            }
        } else {
            appIDs = Array(manager.registeredBundleIds)
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
