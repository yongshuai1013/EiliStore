import SwiftUI
import SideSign
import UIKit

/// Portal profile management, scoped to the currently selected team in the shared model.
@MainActor
struct PortalProfilesView: View {
    @ObservedObject var model: DeveloperPortalModel
    @State private var query = ""
    @State private var showingCreate = false
    @State private var pendingAlert: ProfileAlert?

    private enum ProfileAlert: Identifiable {
        case delete(ListedProvisioningProfile), deleteAll
        var id: String { switch self { case .delete(let profile): return "delete-\(profile.uuid.uuidString)"; case .deleteAll: return "delete-all" } }
    }

    private var rows: [ListedProvisioningProfile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.profiles }
        return model.profiles.filter {
            $0.name.localizedCaseInsensitiveContains(needle) ||
            ($0.bundleIdentifier?.localizedCaseInsensitiveContains(needle) ?? false) ||
            $0.uuid.uuidString.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        List {
            Section(header: Text("Provisioning Profiles (\(model.profiles.count))"), footer: Text("刪除 Developer Portal 上的描述檔會撤銷該遠端資源；請確認確實要移除。")) {
                if rows.isEmpty {
                    if model.isLoading { HStack { Spacer(); ProgressView(); Spacer() } }
                    else if let error = model.sectionErrors["profiles"] { Text("載入失敗：\(error)").foregroundColor(.secondary) }
                    else { Text(query.isEmpty ? "找不到 Provisioning Profile。" : "沒有符合的描述檔。").foregroundColor(.secondary) }
                } else {
                    ForEach(rows, id: \.uuid) { profile in
                        NavigationLink(destination: PortalProfileDetailView(profile: profile, model: model)) {
                            profileRow(profile)
                        }
                        .contextMenu {
                            Button(role: .destructive) { pendingAlert = .delete(profile) } label: { Label("刪除", systemImage: "trash") }
                                .disabled(model.isActing || model.isLoading)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingAlert = .delete(profile) } label: { Label("刪除", systemImage: "trash") }
                                .disabled(model.isActing || model.isLoading)
                        }.disabled(model.isActing || model.isLoading)
                    }
                }
            }
            if !model.profiles.isEmpty {
                Section {
                    Button(role: .destructive) { pendingAlert = .deleteAll } label: {
                        HStack { Spacer(); Image(systemName: "trash"); Text("刪除所有描述檔").bold(); Spacer() }
                    }.disabled(model.isActing || model.isLoading)
                } footer: {
                    Text("此動作會永久刪除目前團隊的所有描述檔；刪除結果會顯示成功與失敗數。")
                }
            }
            PortalStatusSection(model: model)
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜尋描述檔")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingCreate = true } label: { Image(systemName: "plus") }
                    .disabled(model.team == nil || model.isActing || model.isLoading)
            }
        }
        .refreshable { await model.refresh() }
        .sheet(isPresented: $showingCreate) { PortalProfileCreateView(model: model) }
        .alert(item: $pendingAlert) { alert in
            switch alert {
            case .delete(let profile):
                return Alert(title: Text("刪除 Provisioning Profile？"), message: Text("確定要從目前團隊移除「\(profile.name)」？此操作無法復原。"), primaryButton: .destructive(Text("刪除")) { Task { await delete(profile) } }, secondaryButton: .cancel())
            case .deleteAll:
                return Alert(title: Text("刪除全部 \(model.profiles.count) 個描述檔？"), message: Text("只會操作目前選取團隊的描述檔。完成後會回報已刪除與失敗數量。"), primaryButton: .destructive(Text("全部刪除")) { Task { await deleteAll() } }, secondaryButton: .cancel())
            }
        }
        .task { if model.team != nil && model.sectionErrors["profiles"] != nil { await model.refresh() } }
    }

    private func profileRow(_ p: ListedProvisioningProfile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(p.name).font(.headline)
                Spacer()
                if p.dateExpire < Date() { Text("已過期").font(.caption2).foregroundColor(.red) }
                Text(p.dateExpire, style: .date).font(.caption).foregroundColor(p.dateExpire < Date() ? .red : .secondary)
            }
            HStack {
                Text(p.bundleIdentifier ?? "無 App ID").font(.subheadline).foregroundColor(.secondary)
                Spacer()
                if let type = p.profileType { Text(type.displayName).font(.caption2).foregroundColor(.secondary) }
            }
            Text(p.uuid.uuidString).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
        }.padding(.vertical, 2)
    }

    private func delete(_ profile: ListedProvisioningProfile) async {
        guard let team = model.team, profile.provisioningProfileId != nil else { return }
        let teamID = team.identifier
        let success = await model.execute { current in
            guard current.identifier == teamID else { throw PortalProfileError.teamChanged }
            try await DeveloperPortalService.shared.deleteProfile(profile, for: current)
        }

    }

    private func deleteAll() async {
        guard let team = model.team else { return }
        let teamID = team.identifier
        var outcome: (deletedCount: Int, failedCount: Int)?
        let result = await model.execute { current in
            guard current.identifier == teamID else { throw PortalProfileError.teamChanged }
            outcome = await DeveloperPortalService.shared.deleteAllProfiles(model.profiles, for: current)
        }
        if result, let outcome {
            model.message = outcome.failedCount == 0
                ? "已刪除 \(outcome.deletedCount) 個描述檔。"
                : "部分完成：刪除 \(outcome.deletedCount) 個，失敗 \(outcome.failedCount) 個。"
        }
    }
}

@MainActor
private struct PortalProfileCreateView: View {
    @ObservedObject var model: DeveloperPortalModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var name = ""
    @State private var appID = ""
    @State private var selectedType: ProfileType = .iOS
    @State private var manual = false
    @State private var certIDs = Set<String>()
    @State private var deviceIDs = Set<String>()
    @State private var customCert = ""
    @State private var customDevice = ""

    private var allowedTypes: [ProfileType] {
        guard model.team?.type == .free else { return ProfileType.allCases }
        return ProfileType.freeAccountCases
    }
    private var app: SideSign.AppID? { model.appIDs.first { $0.identifier == appID } }
    private var suitableDevices: [SideSign.Device] {
        model.devices.filter { selectedType.acceptedDeviceTypes.contains($0.type) }
    }
    private var canCreate: Bool {
        guard app != nil, model.team != nil, !model.isActing, !model.isLoading, allowedTypes.contains(selectedType) else { return false }
        return !manual || (!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !certIDs.isEmpty && (selectedType.acceptedDeviceTypes == SideSign.DeviceType.none || !deviceIDs.isEmpty))
    }

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text(manual ? "手動選擇允許使用的憑證與裝置；自訂 ID 可保留帳戶列表未顯示的關聯。" : "自動生成會交由 Apple 為所選 App ID 與平台配置有效資源。")) {
                    if model.appIDs.isEmpty { Text("目前團隊沒有 App ID。請先建立 App ID。") }
                    else {
                        Picker("App ID", selection: $appID) {
                            ForEach(model.appIDs, id: \.identifier) { item in
                                Text("\(item.name) (\(item.bundleIdentifier))").tag(item.identifier)
                            }
                        }.onChange(of: appID) { _ in updateName() }
                    }
                    Picker("Profile Type", selection: $selectedType) {
                        ForEach(allowedTypes, id: \.rawValue) { type in Text(type.displayName).tag(type) }
                    }.onChange(of: selectedType) { _ in
                        if selectedType.acceptedDeviceTypes == SideSign.DeviceType.none { deviceIDs.removeAll() }
                        else { deviceIDs = deviceIDs.intersection(Set(suitableDevices.compactMap(\.deviceID))) }
                        updateName()
                    }
                    if manual { TextField("描述檔名稱", text: $name) } else { Text("Apple 將自動命名此描述檔。請勿手動命名。想指定名稱時請開啟手動設定。") .font(.caption).foregroundColor(.secondary) }
                    Toggle("手動設定憑證與裝置", isOn: $manual.animation())
                }
                if manual {
                    Section("憑證 (\(certIDs.count))") {
                        ForEach(model.certificates.filter { $0.identifier != nil }, id: \.serialNumber) { cert in
                            let id = cert.identifier ?? ""
                            Button { toggle(id, in: &certIDs) } label: {
                                HStack { Text(cert.commonName ?? cert.name).foregroundColor(.primary); Spacer(); if certIDs.contains(id) { Image(systemName: "checkmark") } }
                            }
                        }
                        HStack {
                            TextField("自訂 Certificate ID", text: $customCert).font(.system(.subheadline, design: .monospaced))
                            Button("加入") { add(customCert, to: &certIDs); customCert = "" }
                                .disabled(customCert.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        ForEach(certIDs.subtracting(Set(model.certificates.compactMap(\.identifier))).sorted(), id: \.self) { id in removableIDChip(id, set: $certIDs) }
                    }
                    if selectedType.acceptedDeviceTypes != SideSign.DeviceType.none {
                        Section("裝置 (\(deviceIDs.count))") {
                            ForEach(suitableDevices.filter { $0.deviceID != nil }, id: \.identifier) { device in
                                let id = device.deviceID ?? ""
                                Button { toggle(id, in: &deviceIDs) } label: {
                                    HStack { VStack(alignment: .leading) { Text(device.name).foregroundColor(.primary); Text(device.identifier).font(.caption).foregroundColor(.secondary) }; Spacer(); if deviceIDs.contains(id) { Image(systemName: "checkmark") } }
                                }
                            }
                            HStack {
                                TextField("自訂 Device ID / Portal ID", text: $customDevice).font(.system(.subheadline, design: .monospaced))
                                Button("加入") { add(customDevice, to: &deviceIDs); customDevice = "" }
                                    .disabled(customDevice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            ForEach(deviceIDs.subtracting(Set(suitableDevices.compactMap(\.deviceID))).sorted(), id: \.self) { id in removableIDChip(id, set: $deviceIDs) }
                        }
                    }
                }
                PortalStatusSection(model: model)
            }
            .navigationTitle("新增描述檔")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button("取消") { presentationMode.wrappedValue.dismiss() }.disabled(model.isActing), trailing: Button("建立") { Task { await create() } }.disabled(!canCreate))
            .interactiveDismissDisabled(model.isActing)
            .onAppear {
                if appID.isEmpty { appID = model.appIDs.first?.identifier ?? "" }
                if certIDs.isEmpty { certIDs = Set(model.certificates.compactMap(\.identifier)) }
                if deviceIDs.isEmpty { deviceIDs = Set(suitableDevices.compactMap(\.deviceID)) }
                updateName()
            }
        }
    }

    private func create() async {
        guard let team = model.team else { return }
        let teamID = team.identifier
        let success = await model.execute { current in
            guard current.identifier == teamID else { throw PortalProfileError.teamChanged }
            if manual {
                guard let app else { throw PortalProfileError.missingAppID }
                _ = try await DeveloperPortalService.shared.createProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), appID: app, certificateIDs: Array(certIDs), deviceIDs: Array(deviceIDs), type: selectedType, for: current)
            } else if let app {
                _ = try await DeveloperPortalService.shared.generateProfile(for: app, type: selectedType, team: current)
            } else {
                throw PortalProfileError.missingAppID
            }
        }
        if success { presentationMode.wrappedValue.dismiss() }
    }
    private func updateName() {
        guard name.isEmpty, let app else { return }
        name = "\(app.name.isEmpty ? app.bundleIdentifier : app.name) - \(selectedType.rawValue)"
    }
    private func removableIDChip(_ id: String, set: Binding<Set<String>>) -> some View { HStack { Text(id).font(.system(.caption, design: .monospaced)); Spacer(); Button { set.wrappedValue.remove(id) } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("移除 ID") } }
    private func add(_ value: String, to set: inout Set<String>) { let v = value.trimmingCharacters(in: .whitespacesAndNewlines); if !v.isEmpty { set.insert(v) } }
    private func toggle(_ id: String, in set: inout Set<String>) { if set.contains(id) { set.remove(id) } else { set.insert(id) } }
}

@MainActor
private struct PortalProfileDetailView: View {
    let profile: ListedProvisioningProfile
    @ObservedObject var model: DeveloperPortalModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var name = ""
    @State private var appID = ""
    @State private var selectedType: ProfileType = .iOS
    @State private var certIDs = Set<String>()
    @State private var deviceIDs = Set<String>()
    @State private var certInput = ""
    @State private var deviceInput = ""
    @State private var confirmedCompleteCertificates = false
    @State private var shareURL: URL?
    @State private var confirmDelete = false
    @State private var isVisible = false

    private var originalAppID: String { profile.appId?.appIdId ?? profile.appId?.identifier ?? "" }
    private var editableTypes: [ProfileType] {
        let supported = model.team?.type == .free ? ProfileType.freeAccountCases : ProfileType.allCases
        return supported.contains(selectedType) ? supported : supported + [selectedType]
    }
    private var hasChanges: Bool { name != profile.name || appID != originalAppID || deviceIDs != Set(profile.deviceIds ?? []) || !certIDs.isEmpty }
    private var canSave: Bool { guard profile.provisioningProfileId?.isEmpty == false, model.team != nil, !model.isActing, !model.isLoading, profile.profileType != nil else { return false }; return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !appID.isEmpty && !certIDs.isEmpty && confirmedCompleteCertificates && (selectedType.acceptedDeviceTypes == SideSign.DeviceType.none || !deviceIDs.isEmpty) }

    var body: some View {
        List {
            Section("描述檔資訊") {
                TextField("名稱", text: $name)
                PortalInfoRow(title: "UUID", value: profile.uuid.uuidString)
                PortalInfoRow(title: "Profile ID", value: profile.provisioningProfileId ?? "")
                PortalInfoRow(title: "App ID", value: profile.bundleIdentifier ?? "")
                PortalInfoRow(title: "類型", value: profile.profileType?.displayName ?? profile.type ?? profile.platform ?? "未知")
                PortalInfoRow(title: "狀態", value: profile.dateExpire < Date() ? "已過期" : (profile.status ?? "有效"))
                PortalInfoRow(title: "到期日", value: profile.dateExpire.formatted(date: .abbreviated, time: .omitted))
            }
            Section("App ID 關聯") {
                Picker("Profile Type", selection: $selectedType) {
                    ForEach(editableTypes, id: \.rawValue) { type in Text(type.displayName).tag(type) }
                }
                if !model.appIDs.isEmpty { Picker("App ID", selection: $appID) { ForEach(model.appIDs, id: \.identifier) { item in Text("\(item.name) (\(item.bundleIdentifier))").tag(item.identifier) } } }
                TextField("App ID ID／自訂 ID", text: $appID).font(.system(.subheadline, design: .monospaced))
            }
            Section("憑證 ID (\(certIDs.count))") {
                Text("API 的清單資料未包含此描述檔原有的憑證關聯。為避免清除未知關聯，請提供完整 Certificate ID 清單後才能儲存更新。")
                    .font(.caption).foregroundColor(.secondary)
                Toggle("我已輸入此描述檔完整的憑證 ID 清單", isOn: $confirmedCompleteCertificates)
                ForEach(model.certificates.filter { $0.identifier != nil }, id: \.serialNumber) { cert in
                    let id = cert.identifier ?? ""
                    Button { toggle(id, in: &certIDs) } label: { HStack { Text(cert.commonName ?? cert.name).foregroundColor(.primary); Spacer(); if certIDs.contains(id) { Image(systemName: "checkmark") } } }
                }
                HStack { TextField("自訂 Certificate ID", text: $certInput).font(.system(.caption, design: .monospaced)); Button("加入") { add(certInput, to: &certIDs); certInput = "" }.disabled(certInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                ForEach(certIDs.subtracting(Set(model.certificates.compactMap(\.identifier))).sorted(), id: \.self) { id in removableIDChip(id, set: $certIDs) }
            }
            Section("裝置 ID (\(deviceIDs.count))") {
                ForEach(model.devices.filter { $0.deviceID != nil }, id: \.identifier) { device in
                    let id = device.deviceID ?? ""
                    Button { toggle(id, in: &deviceIDs) } label: { HStack { Text(device.name).foregroundColor(.primary); Spacer(); if deviceIDs.contains(id) { Image(systemName: "checkmark") } } }
                }
                HStack { TextField("自訂 Device ID / Portal ID", text: $deviceInput).font(.system(.caption, design: .monospaced)); Button("加入") { add(deviceInput, to: &deviceIDs); deviceInput = "" }.disabled(deviceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                ForEach(deviceIDs.subtracting(Set(model.devices.compactMap(\.deviceID))).sorted(), id: \.self) { id in removableIDChip(id, set: $deviceIDs) }
            }
            if hasChanges {
                Section {
                    Button("更新並重新生成描述檔") { Task { await save() } }
                        .disabled(!canSave)
                } footer: { Text("更新會重新生成描述檔。清單未提供的憑證 ID 不會自動猜測；必須手動補齊完整關聯。") }
            }
            Section {
                Button { Task { await download() } } label: { Label("下載並分享 .mobileprovision", systemImage: "square.and.arrow.down") }
                    .disabled(model.isActing || profile.provisioningProfileId == nil)
                Button(role: .destructive) { confirmDelete = true } label: { Label("從 Portal 刪除", systemImage: "trash") }
            }
            PortalStatusSection(model: model)
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(profile.name).navigationBarTitleDisplayMode(.inline)
        .disabled(model.isActing || model.isLoading)
        .onDisappear { isVisible = false; cleanupShareFile() }
        .onAppear {
            isVisible = true
            if name.isEmpty { name = profile.name }
            if appID.isEmpty { appID = originalAppID }
            if let type = profile.profileType { selectedType = type }
            if deviceIDs.isEmpty { deviceIDs = Set(profile.deviceIds ?? []) }
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { cleanupShareFile() } })) {
            if let url = shareURL { PortalProfileShareSheet(items: [url]) { cleanupShareFile() } }
        }
        .alert(isPresented: $confirmDelete) {
            Alert(title: Text("刪除描述檔？"), message: Text("確定要從目前團隊移除「\(profile.name)」？"), primaryButton: .destructive(Text("刪除")) { Task { await delete() } }, secondaryButton: .cancel())
        }
    }

    private func save() async {
        guard canSave, let team = model.team else { return }
        let teamID = team.identifier
        let success = await model.execute { current in
            guard current.identifier == teamID else { throw PortalProfileError.teamChanged }
            _ = try await DeveloperPortalService.shared.updateProfile(profile, name: name.trimmingCharacters(in: .whitespacesAndNewlines), appIDId: appID.trimmingCharacters(in: .whitespacesAndNewlines), certificateIDs: Array(certIDs), deviceIDs: Array(deviceIDs), type: selectedType, for: current)
        }
        if success { presentationMode.wrappedValue.dismiss() }
    }
    private func download() async {
        guard let team = model.team, profile.provisioningProfileId != nil else { return }
        let teamID = team.identifier
        var staged: URL?
        let result = await model.execute { current in
            guard current.identifier == teamID else { throw PortalProfileError.teamChanged }
            let downloaded = try await DeveloperPortalService.shared.downloadProfile(profile, for: current)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mobileprovision")
            try downloaded.data.write(to: url, options: [.atomic, .completeFileProtection])
            staged = url
        }
        if result, isVisible { cleanupShareFile(); shareURL = staged }
        else if let url = staged { try? FileManager.default.removeItem(at: url) }
    }
    private func delete() async {
        guard let team = model.team else { return }
        let teamID = team.identifier
        let success = await model.execute { current in
            guard current.identifier == teamID else { throw PortalProfileError.teamChanged }
            try await DeveloperPortalService.shared.deleteProfile(profile, for: current)
        }
        if success { presentationMode.wrappedValue.dismiss() }
    }
    private func cleanupShareFile() {
        if let url = shareURL { try? FileManager.default.removeItem(at: url) }
        shareURL = nil
    }
    private func removableIDChip(_ id: String, set: Binding<Set<String>>) -> some View { HStack { Text(id).font(.system(.caption, design: .monospaced)); Spacer(); Button { set.wrappedValue.remove(id) } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("移除 ID") } }
    private func add(_ value: String, to set: inout Set<String>) { let v = value.trimmingCharacters(in: .whitespacesAndNewlines); if !v.isEmpty { set.insert(v) } }
    private func toggle(_ id: String, in set: inout Set<String>) { if set.contains(id) { set.remove(id) } else { set.insert(id) } }
}

private enum PortalProfileError: LocalizedError {
    case teamChanged
    case missingAppID
    var errorDescription: String? {
        switch self {
        case .teamChanged: return "目前團隊已變更，為避免操作錯誤團隊，請重新開啟描述檔頁面。"
        case .missingAppID: return "請先選擇 App ID。"
        }
    }
}

/// Kept private and uniquely named to avoid collisions with other share sheet wrappers.
private struct PortalProfileShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onDismiss: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in DispatchQueue.main.async { onDismiss() } }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: UIActivityViewController, coordinator: ()) {
        // File cleanup is also performed by the sheet binding when dismissed.
    }
}
