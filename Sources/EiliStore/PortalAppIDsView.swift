import SwiftUI
import SideSign
import UIKit

@MainActor
struct PortalAppIDsView: View {
    @ObservedObject var model: DeveloperPortalModel
    @State private var search = ""
    @State private var showCreate = false
    @State private var deletion: SideSign.AppID?
    private var filtered: [SideSign.AppID] {
        model.appIDs.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleIdentifier.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            PortalStatusSection(model: model)
            Section("App IDs (\(model.appIDs.count))") {
                if filtered.isEmpty { Text(model.sectionErrors["appIDs"] == nil ? "沒有符合的 App IDs" : "App IDs 尚未成功載入").foregroundColor(.secondary) }
                ForEach(filtered, id: \.identifier) { app in
                    NavigationLink(destination: PortalAppIDDetailView(model: model, identifier: app.identifier)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name)
                            Text(app.bundleIdentifier).font(.caption).foregroundColor(.secondary)
                            if let expiry = app.expirationDate { Text(expiry, style: .date).font(.caption).foregroundColor(.secondary) }
                        }
                    }
                    .swipeActions { Button("刪除", role: .destructive) { deletion = app } }
                }
            }
            Section(footer: Text("App ID 的到期日由 Portal 回傳，與裝置描述檔的到期日不同。免費帳戶的新增數量受 Apple 限制。")) { EmptyView() }
        }
        .navigationTitle("App IDs")
        .searchable(text: $search, prompt: "名稱或 Bundle ID")
        .refreshable { await model.refresh() }
        .toolbar { Button { showCreate = true } label: { Image(systemName: "plus") }.disabled(model.team == nil || model.isLoading || model.isActing) }
        .sheet(isPresented: $showCreate) { PortalCreateAppIDView(model: model) }
        .alert("刪除 App ID？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("取消", role: .cancel) { deletion = nil }
            Button("刪除", role: .destructive) {
                guard let app = deletion, let expectedTeam = model.team?.identifier,
                      model.appIDs.contains(where: { $0.identifier == app.identifier }) else { return }
                deletion = nil
                Task { _ = await model.execute { team in
                    guard team.identifier == expectedTeam else { throw PortalResourceViewError.teamChanged }
                    try await PaxSigningService.shared.deleteAppID(app, for: team)
                } }
            }
        } message: { Text("將刪除 \(deletion?.bundleIdentifier ?? "")。相關描述檔可能需要重新建立，此操作無法復原。") }
        .disabled(model.isActing || model.isLoading)
    }
}

@MainActor
private struct PortalCreateAppIDView: View {
    @ObservedObject var model: DeveloperPortalModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bundleID = ""
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanID: String { bundleID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        (try? DeveloperPortalValidation.validateName(cleanName)) != nil &&
        (try? DeveloperPortalValidation.validateBundleIdentifier(cleanID)) != nil
    }
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("App ID"), footer: Text("Bundle ID 使用反向網域格式，例如 com.example.myapp。")) {
                    TextField("名稱", text: $name)
                    TextField("Bundle ID", text: $bundleID).textInputAutocapitalization(.never).disableAutocorrection(true)
                }
                PortalStatusSection(model: model)
            }
            .navigationTitle("註冊 App ID")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(model.isActing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("註冊") {
                        Task {
                            if await model.execute({ team in _ = try await PaxSigningService.shared.createAppID(name: cleanName, bundleIdentifier: cleanID, for: team) }) { dismiss() }
                        }
                    }.disabled(!valid || model.isActing || model.isLoading)
                }
            }
        }.interactiveDismissDisabled(model.isActing)
    }
}

@MainActor
private struct PortalAppIDDetailView: View {
    @ObservedObject var model: DeveloperPortalModel
    let identifier: String
    @State private var selectedGroups: Set<String> = []
    @State private var groupsModified = false
    @State private var confirmGroups = false
    @State private var shareURL: URL?
    @State private var isVisible = false
    private var app: SideSign.AppID? { model.appIDs.first { $0.identifier == identifier } }
    var body: some View {
        List {
            PortalStatusSection(model: model)
            if let app = app {
                Section("App ID Metadata") {
                    PortalInfoRow(title: "Name", value: app.name)
                    PortalInfoRow(title: "Bundle ID", value: app.bundleIdentifier)
                    PortalInfoRow(title: "App ID", value: app.identifier)
                    if let date = app.expirationDate { Text("到期日：\(date.formatted(date: .abbreviated, time: .omitted))") }
                }
                Section("Capabilities & Features") {
                    if app.features.isEmpty { Text("沒有回傳功能資訊").foregroundColor(.secondary) }
                    ForEach(app.features.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { feature in
                        PortalInfoRow(title: feature.rawValue, value: app.features[feature] ?? "")
                    }
                }
                Section(header: Text("Associated App Groups"), footer: Text("Portal 的 App ID 清單不提供既有群組的完整關聯；這裡不會把所有群組誤當成已關聯。儲存會以你明確選取的群組取代關聯，空選擇會解除全部。")) {
                    if model.appGroups.isEmpty { Text("此團隊沒有可用的群組").foregroundColor(.secondary) }
                    ForEach(model.appGroups, id: \.groupID) { group in
                        Toggle(isOn: Binding(get: { selectedGroups.contains(group.groupID) }, set: { selected in
                            if selected { selectedGroups.insert(group.groupID) } else { selectedGroups.remove(group.groupID) }
                            groupsModified = true
                        })) {
                            VStack(alignment: .leading) { Text(group.name); Text(group.identifier).font(.caption).foregroundColor(.secondary) }
                        }
                    }
                    Button("儲存群組關聯") { confirmGroups = true }
                        .disabled(!groupsModified || model.sectionErrors["appGroups"] != nil)
                }
                Section("描述檔") {
                    Button("生成並分享此 App ID 的 iOS 描述檔") {
                        Task { await generateAndShare(app) }
                    }
                    NavigationLink("生成、建立或管理 Provisioning Profiles", destination: PortalProfilesView(model: model))
                }
            } else {
                Text("此 App ID 已移除或尚未載入，請返回列表重新整理。")
            }
        }
        .navigationTitle(app?.name ?? "App ID")
        .refreshable { await model.refresh() }
        .disabled(model.isActing || model.isLoading)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; cleanupShare() }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { cleanupShare() } })) {
            if let url = shareURL { PortalAppIDProfileShareSheet(url: url) { cleanupShare() } }
        }
        .alert("取代 App Group 關聯？", isPresented: $confirmGroups) {
            Button("取消", role: .cancel) { }
            Button("儲存") {
                guard let app = app, let expectedTeam = model.team?.identifier else { return }
                let groups = model.appGroups.filter { selectedGroups.contains($0.groupID) }
                Task {
                    if await model.execute({ team in
                        guard team.identifier == expectedTeam else { throw PortalResourceViewError.teamChanged }
                        _ = try await DeveloperPortalService.shared.assignAppGroups(groups, to: app, for: team)
                    }) { groupsModified = false }
                }
            }
        } message: { Text("將以目前選取的 \(selectedGroups.count) 個群組取代此 App ID 的群組關聯。相關 App 可能需要重新簽名。") }
    }

    private func generateAndShare(_ app: SideSign.AppID) async {
        guard let expectedTeam = model.team?.identifier else { return }
        var staged: URL?
        let success = await model.execute { team in
            guard team.identifier == expectedTeam else { throw PortalResourceViewError.teamChanged }
            let profile = try await DeveloperPortalService.shared.generateProfile(for: app, type: .iOS, team: team)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mobileprovision")
            try profile.data.write(to: url, options: [.atomic, .completeFileProtection])
            staged = url
        }
        if success, isVisible { cleanupShare(); shareURL = staged }
        else if let url = staged { try? FileManager.default.removeItem(at: url) }
    }
    private func cleanupShare() {
        if let url = shareURL { try? FileManager.default.removeItem(at: url) }
        shareURL = nil
    }
}

private struct PortalAppIDProfileShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in DispatchQueue.main.async { onDismiss() } }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
