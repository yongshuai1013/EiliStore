import SwiftUI
import SideSign

@MainActor
struct PortalAppGroupsView: View {
    @ObservedObject var model: DeveloperPortalModel
    @State private var search = ""
    @State private var creating = false
    @State private var editing: String?
    @State private var deleting: SideSign.AppGroup?
    private var filtered: [SideSign.AppGroup] {
        model.appGroups.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.identifier.localizedCaseInsensitiveContains(search) || $0.groupID.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            PortalStatusSection(model: model)
            Section("App Groups (\(model.appGroups.count))") {
                if filtered.isEmpty { Text(model.sectionErrors["appGroups"] == nil ? "沒有符合的 App Groups" : "App Groups 尚未成功載入").foregroundColor(.secondary) }
                ForEach(filtered, id: \.identifier) { group in
                    Button { editing = group.groupID } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name.isEmpty ? "App Group" : group.name).font(.headline).foregroundColor(.primary)
                            Text(group.identifier).font(.caption).foregroundColor(.secondary)
                            Text("Portal ID: \(group.groupID.isEmpty ? "未提供" : group.groupID)").font(.caption2).foregroundColor(.secondary)
                        }.padding(.vertical, 3)
                    }.disabled(group.groupID.isEmpty || !canManage)
                    .swipeActions(allowsFullSwipe: false) { Button("刪除", role: .destructive) { deleting = group }.disabled(group.groupID.isEmpty || !canManage) }
                }
            }
            Section(footer: Text("App Groups 供同一開發團隊的 App 與 extensions 分享資料。與 SideStore 相同，管理權限及限制交由 Apple Portal 判定，不預先假設免費帳戶一定不支援。")) { EmptyView() }
        }
        .navigationTitle("App Groups")
        .searchable(text: $search, prompt: "搜尋名稱或識別碼")
        .refreshable { await model.refresh() }
        .toolbar { Button { creating = true } label: { Image(systemName: "plus") }.disabled(!canManage || model.isLoading || model.isActing) }
        .sheet(isPresented: $creating) { PortalGroupEditor(model: model, group: nil) }
        .sheet(item: Binding(get: { editing.map(PortalGroupToken.init) }, set: { editing = $0?.key })) { token in
            if let group = model.appGroups.first(where: { $0.groupID == token.key }) {
                PortalGroupEditor(model: model, group: group)
            } else { Text("此群組已不在目前團隊中，請關閉後重新整理。") }
        }
        .alert("刪除 App Group？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("刪除", role: .destructive) {
                guard let target = deleting, let team = model.team, !target.groupID.isEmpty,
                      model.appGroups.contains(where: { $0.groupID == target.groupID && $0.identifier == target.identifier }) else { return }
                deleting = nil
                Task { _ = await model.execute { t in
                    guard t.identifier == team.identifier else { throw PortalResourceViewError.teamChanged }
                    try await DeveloperPortalService.shared.deleteAppGroup(target, for: t)
                } }
            }
        } message: { Text("將從 Developer Portal 永久刪除「\(deleting?.name ?? "App Group")」(\(deleting?.identifier ?? ""))，相關 App 的群組共享可能受影響。無法復原。") }
        .disabled(model.isLoading || model.isActing)
        .onChange(of: model.team?.identifier) { _ in editing = nil; deleting = nil; creating = false }
    }
    private var canManage: Bool { model.team?.identifier.isEmpty == false }
}

private struct PortalGroupToken: Identifiable { let key: String; var id: String { key }; init(_ key: String) { self.key = key } }

@MainActor
private struct PortalGroupEditor: View {
    @ObservedObject var model: DeveloperPortalModel
    let group: SideSign.AppGroup?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var identifier = "group."
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanIdentifier: String { identifier.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        (try? DeveloperPortalValidation.validateName(cleanName)) != nil &&
        (try? DeveloperPortalValidation.validateAppGroupIdentifier(cleanIdentifier)) != nil
    }
    var body: some View {
        NavigationView {
            Form {
                if !isCurrentGroup { Text("此群組不在目前團隊中，請關閉並重新整理。") }
                Section(header: Text("App Group Details"), footer: Text("識別碼使用 group.com.example 格式，建立後不可修改。名稱與權限限制仍以 Apple Portal 回應為準。")) {
                    TextField("名稱", text: $name)
                    if group == nil { TextField("Group Identifier", text: $identifier).textInputAutocapitalization(.never).disableAutocorrection(true) }
                    else { Text(group?.identifier ?? "").foregroundColor(.secondary) }
                }
                if let group = group { Section("Portal ID") { Text(group.groupID.isEmpty ? "未提供，已停用操作" : group.groupID).font(.caption).foregroundColor(.secondary) } }
                PortalStatusSection(model: model)
            }
            .navigationTitle(group == nil ? "建立 App Group" : "重新命名 App Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(model.isActing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(group == nil ? "建立" : "儲存") {
                        guard let team = model.team, !team.identifier.isEmpty else { return }
                        Task {
                            let succeeded = await model.execute { t in
                                guard t.identifier == team.identifier else { throw PortalResourceViewError.teamChanged }
                                if let group = group {
                                    _ = try await DeveloperPortalService.shared.updateAppGroup(group, name: cleanName, for: t)
                                } else {
                                    _ = try await DeveloperPortalService.shared.createAppGroup(name: cleanName, groupIdentifier: cleanIdentifier, for: t)
                                }
                            }
                            if succeeded { dismiss() }
                        }
                    }.disabled(!valid || !isCurrentGroup || unchanged || model.team == nil || model.isActing || model.isLoading)
                }
            }
            .onAppear { if let group = group { name = group.name; identifier = group.identifier } }
        }.interactiveDismissDisabled(model.isActing)
    }
    private var unchanged: Bool { if let group = group { return group.groupID.isEmpty || cleanName == group.name }; return false }
    private var isCurrentGroup: Bool { group == nil || model.appGroups.contains(where: { $0.groupID == group?.groupID && $0.identifier == group?.identifier }) }
}
