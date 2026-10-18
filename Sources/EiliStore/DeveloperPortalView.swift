import SwiftUI
import SideSign

enum PortalResourceViewError: Error { case teamChanged }

/// 對照 SideStore DeveloperServicesView；所有資料由同一個團隊範圍的 model 提供。
@MainActor
struct DeveloperPortalView: View {
    @StateObject private var model = DeveloperPortalModel()

    var body: some View {
        List {
            Section("Developer Account") {
                if let team = model.team {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 36)).foregroundColor(.teal)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(team.name).font(.headline)
                            Text("Team ID: \(team.identifier)").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(team.portalAccountType).font(.caption)
                            .padding(6).background(Color.secondary.opacity(0.12)).cornerRadius(6)
                    }
                    if model.teams.count > 1 {
                        Picker("開發者團隊", selection: Binding(
                            get: { model.team?.identifier ?? "" },
                            set: { identifier in
                                guard let selected = model.teams.first(where: { $0.identifier == identifier }) else { return }
                                Task { await model.selectTeam(selected) }
                            }
                        )) {
                            ForEach(model.teams, id: \.identifier) { item in
                                Text("\(item.name) (\(item.identifier))").tag(item.identifier)
                            }
                        }
                        .disabled(model.isLoading || model.isActing)
                    }
                } else {
                    Text(model.isLoading ? "正在連接 Developer Portal…" : "尚未載入開發者團隊")
                        .foregroundColor(.secondary)
                }
            }
            Section("Developer Portal Services") {
                NavigationLink(destination: PortalAppIDsView(model: model).id(model.team?.identifier)) {
                    portalRow("App IDs", icon: "app.badge.checkmark", color: .blue, count: model.appIDs.count, key: "appIDs")
                }
                NavigationLink(destination: PortalProfilesView(model: model).id(model.team?.identifier)) {
                    portalRow("Provisioning Profiles", icon: "doc.plaintext", color: .orange, count: model.profiles.count, key: "profiles")
                }
                NavigationLink(destination: PortalCertificatesView(model: model).id(model.team?.identifier)) {
                    portalRow("Certificates", icon: "rosette", color: .red, count: model.certificates.count, key: "certificates")
                }
                NavigationLink(destination: PortalAppGroupsView(model: model).id(model.team?.identifier)) {
                    portalRow("App Groups", icon: "person.2", color: .green, count: model.appGroups.count, key: "appGroups")
                }
                NavigationLink(destination: PortalDevicesView(model: model).id(model.team?.identifier)) {
                    portalRow("Registered Devices", icon: "iphone", color: .purple, count: model.devices.count, key: "devices")
                }
            }
            .disabled(model.team == nil || model.isLoading || model.isActing)
            PortalStatusSection(model: model)
            Section(footer: Text("這裡管理 Apple Developer Portal 的遠端資源，不是裝置上已安裝的描述檔。刪除、撤銷或停用可能影響現有 App 的簽名與安裝。")) {
                Button("重新載入") { Task { await model.load() } }
                    .disabled(model.isLoading || model.isActing)
            }
        }
        .navigationTitle("Developer Portal")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.refresh() }
    }

    private func portalRow(_ title: String, icon: String, color: Color, count: Int, key: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundColor(color).font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(model.sectionErrors[key] == nil ? "\(count) 個項目" : "載入失敗，請重試")
                    .font(.caption).foregroundColor(model.sectionErrors[key] == nil ? .secondary : .red)
            }
        }.padding(.vertical, 4)
    }
}

extension SideSign.Team {
    var portalAccountType: String {
        switch type {
        case .free: return "免費帳戶"
        case .individual: return "個人帳戶"
        case .organization: return "組織帳戶"
        case .unknown: return "未知帳戶"
        }
    }
}

/// 每個子頁也顯示狀態，避免錯誤只留在上一層而被忽略。
@MainActor
struct PortalStatusSection: View {
    @ObservedObject var model: DeveloperPortalModel
    var body: some View {
        if model.isLoading || model.isActing {
            Section { HStack { ProgressView(); Text(model.isActing ? "正在處理…" : "正在載入…") } }
        }
        if let error = model.errorMessage {
            Section("操作未完成") { Text(error).foregroundColor(.red) }
        }
        if !model.sectionErrors.isEmpty {
            Section("部分資源未載入") {
                ForEach(model.sectionErrors.keys.sorted(), id: \.self) { key in
                    Text("\(resourceTitle(key))：\(model.sectionErrors[key] ?? "請重試")")
                        .font(.caption).foregroundColor(.red)
                }
            }
        }
        if let message = model.message {
            Section { Text(message).font(.callout).foregroundColor(.secondary) }
        }
    }
    private func resourceTitle(_ key: String) -> String {
        ["appIDs": "App IDs", "profiles": "Provisioning Profiles", "certificates": "Certificates",
         "appGroups": "App Groups", "devices": "Registered Devices"][key] ?? key
    }
}

struct PortalInfoRow: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value.isEmpty ? "—" : value).textSelection(.enabled)
        }.padding(.vertical, 2)
    }
}
