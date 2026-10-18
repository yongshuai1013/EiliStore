import SwiftUI
import SideSign

@MainActor
struct PortalDevicesView: View {
    @ObservedObject var model: DeveloperPortalModel
    @State private var search = ""
    @State private var registering = false
    @State private var editing: String?
    @State private var pending: DeviceAction?
    private var filtered: [SideSign.Device] {
        model.devices.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.identifier.localizedCaseInsensitiveContains(search) || $0.type.displayName.localizedCaseInsensitiveContains(search) || ($0.deviceID ?? "").localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            PortalStatusSection(model: model)
            Section("Registered Devices (\(model.devices.count))") {
                if filtered.isEmpty { Text(model.sectionErrors["devices"] == nil ? "沒有符合的裝置" : "裝置清單尚未成功載入").foregroundColor(.secondary) }
                ForEach(filtered, id: \.identifier) { device in
                    Button { editing = device.identifier } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(device.name.isEmpty ? "Device" : device.name).font(.headline).foregroundColor(.primary)
                                Spacer()
                                Text(portalDeviceStatus(device.status)).font(.caption2).foregroundColor(device.status == "d" ? .red : .secondary)
                                Text(device.type.displayName).font(.caption2).foregroundColor(.secondary)
                            }
                            Text("UDID: \(device.identifier.isEmpty ? "Unavailable" : device.identifier)").font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                            Text("Portal ID: \(device.deviceID?.isEmpty == false ? device.deviceID! : "Unavailable")").font(.caption2).foregroundColor(.secondary)
                        }.padding(.vertical, 3)
                    }.disabled(device.identifier.isEmpty || device.deviceID?.isEmpty != false)
                    .swipeActions {
                        Button("刪除", role: .destructive) { pending = .delete(device, model.team?.identifier ?? "") }.disabled(device.identifier.isEmpty || device.deviceID?.isEmpty != false)
                        if device.status != "d" { Button("停用", role: .destructive) { pending = .disable(device, model.team?.identifier ?? "") }.disabled(device.deviceID?.isEmpty != false) }
                    }
                }
            }
            Section(footer: Text("註冊裝置會影響 Developer Portal 資源與佈建描述檔，不會對本機裝置執行 Apple 操作。免費帳戶的裝置上限由 Apple 限制。")) { EmptyView() }
        }
        .navigationTitle("Devices")
        .searchable(text: $search, prompt: "搜尋名稱、UDID、類型或 Portal ID")
        .refreshable { await model.refresh() }
        .toolbar { Button { registering = true } label: { Image(systemName: "plus") }.disabled(!hasTeam || model.isLoading || model.isActing) }
        .sheet(isPresented: $registering) { DeviceEditor(model: model, device: nil) }
        .sheet(item: Binding(get: { editing.map(DeviceToken.init) }, set: { editing = $0?.key })) { token in
            DeviceEditor(model: model, device: model.devices.first { $0.identifier == token.key })
        }
        .alert(item: $pending) { action in
            switch action {
            case .disable(let d, let teamID): return Alert(title: Text("停用裝置？"), message: Text("停用「\(d.name)」後不會納入新建立的佈建描述檔。"), primaryButton: .destructive(Text("停用")) { operate(d, teamID: teamID, delete: false, disable: true) }, secondaryButton: .cancel())
            case .delete(let d, let teamID): return Alert(title: Text("刪除裝置？"), message: Text("將永久從 Developer Portal 刪除「\(d.name)」(\(d.identifier))，無法復原。"), primaryButton: .destructive(Text("刪除")) { operate(d, teamID: teamID, delete: true, disable: false) }, secondaryButton: .cancel())
            }
        }
        .disabled(model.isActing || model.isLoading)
        .onChange(of: model.team?.identifier) { _ in editing = nil; pending = nil; registering = false }
    }
    private var hasTeam: Bool { model.team?.identifier.isEmpty == false }
    private func operate(_ device: SideSign.Device, teamID: String, delete: Bool, disable: Bool) {
        guard let team = model.team, !team.identifier.isEmpty, team.identifier == teamID, !device.identifier.isEmpty, device.deviceID?.isEmpty == false,
              model.devices.contains(where: { $0.identifier == device.identifier && $0.deviceID == device.deviceID }) else { return }
        pending = nil
        Task { _ = await model.execute { t in guard t.identifier == team.identifier else { throw PortalResourceViewError.teamChanged }; if delete { try await DeveloperPortalService.shared.deleteDevice(device, for: t) } else if disable { _ = try await DeveloperPortalService.shared.disableDevice(device, for: t) } } }
    }
}

private func portalDeviceStatus(_ status: String?) -> String {
    switch status?.lowercased() {
    case "d", "disabled": return "已停用"
    case "c", "e", "enabled", "active": return "已啟用"
    default: return status ?? "狀態未知"
    }
}

private struct DeviceToken: Identifiable { let key: String; var id: String { key }; init(_ key: String) { self.key = key } }
private enum DeviceAction: Identifiable { case disable(SideSign.Device, String), delete(SideSign.Device, String); var id: String { switch self { case .disable(let d, let team): return "disable-\(team)-\(d.identifier)"; case .delete(let d, let team): return "delete-\(team)-\(d.identifier)" } } }

@MainActor
private struct DeviceEditor: View {
    @ObservedObject var model: DeveloperPortalModel
    let device: SideSign.Device?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var udid = ""
    @State private var selectedType: SideSign.DeviceType = .iPhone
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanUDID: String { udid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    private var validUDID: Bool { (try? DeveloperPortalValidation.validateDeviceIdentifier(cleanUDID)) != nil }
    private var validName: Bool { !cleanName.isEmpty && !cleanName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    var body: some View {
        NavigationView {
            Form {
                if let device {
                    Section("Device Name") { TextField("Name", text: $name) }
                    Section("Device Details") {
                        PortalInfoRow(title: "UDID", value: device.identifier)
                        PortalInfoRow(title: "Type", value: device.type.displayName)
                        PortalInfoRow(title: "Status", value: portalDeviceStatus(device.status))
                        PortalInfoRow(title: "Portal ID", value: device.deviceID ?? "Unavailable")
                        if let version = device.osVersion {
                            PortalInfoRow(title: "系統版本", value: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
                        }
                    }
                } else {
                    Section(header: Text("Register Device"), footer: Text("支援舊式 40 位十六進位 UDID、現代 8-16 位格式，以及 Mac UUID。")) {
                        TextField("Device Name", text: $name)
                        TextField("UDID", text: $udid).textInputAutocapitalization(.characters).disableAutocorrection(true)
                        Picker("Device Type", selection: $selectedType) {
                            Text("iPhone").tag(SideSign.DeviceType.iPhone); Text("iPad").tag(SideSign.DeviceType.iPad)
                            Text("Apple TV").tag(SideSign.DeviceType.appleTV); Text("Apple Watch").tag(SideSign.DeviceType.appleWatch)
                            Text("Mac").tag(SideSign.DeviceType.mac); Text("Vision Pro").tag(SideSign.DeviceType.visionPro)
                        }
                    }
                }
                if device != nil && !isCurrentDevice { Text("此裝置不在目前團隊中，請關閉並重新整理。") }
                PortalStatusSection(model: model)
            }
            .navigationTitle(device == nil ? "Register Device" : "Rename Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.isActing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(device == nil ? "Register" : "Save") {
                        guard let team = model.team, !team.identifier.isEmpty else { return }
                        Task {
                            let success: Bool
                            if let device {
                                guard !device.identifier.isEmpty, device.deviceID?.isEmpty == false else { return }
                                success = await model.execute { t in guard t.identifier == team.identifier else { throw PortalResourceViewError.teamChanged }; _ = try await DeveloperPortalService.shared.updateDevice(device, name: cleanName, for: t) }
                            } else {
                                success = await model.execute { t in guard t.identifier == team.identifier else { throw PortalResourceViewError.teamChanged }; _ = try await DeveloperPortalService.shared.registerDevice(name: cleanName, identifier: cleanUDID, type: selectedType, for: t) }
                            }
                            if success { dismiss() }
                        }
                    }.disabled(!validName || !isCurrentDevice || (device == nil && !validUDID) || (device != nil && (device?.deviceID?.isEmpty != false || cleanName == device?.name)) || !hasTeam || model.isActing || model.isLoading)
                }
            }.onAppear { if let device { name = device.name } }
        }.interactiveDismissDisabled(model.isActing)
    }
    private var hasTeam: Bool { model.team?.identifier.isEmpty == false }
    private var isCurrentDevice: Bool { device == nil || model.devices.contains(where: { $0.identifier == device?.identifier && $0.deviceID == device?.deviceID }) }
}
