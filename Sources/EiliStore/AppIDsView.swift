import SwiftUI
import SideSign

/// App ID 管理頁
struct AppIDsView: View {
    @State private var teams: [SideSign.Team] = []
    @State private var selectedTeamID: String?
    @State private var appIDs: [SideSign.AppID] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    @State private var showCreateSheet = false
    @State private var newName = ""
    @State private var newBundleID = ""
    
    @State private var appIDToDelete: SideSign.AppID?
    @State private var showDeleteAlert = false
    
    private var selectedTeam: SideSign.Team? {
        guard let id = selectedTeamID else { return nil }
        return teams.first(where: { $0.identifier == id })
    }
    
    var body: some View {
        List {
            Section(header: Text("TEAM")) {
                if teams.isEmpty {
                    Text(isLoading ? "載入中..." : "無")
                } else {
                    Picker("Team", selection: $selectedTeamID) {
                        ForEach(teams, id: \.identifier) { team in
                            Text(team.name).tag(team.identifier as String?)
                        }
                    }
                    .onChange(of: selectedTeamID) { newID in
                        if let id = newID,
                           let team = teams.first(where: { $0.identifier == id }) {
                            loadAppIDs(for: team)
                        }
                    }
                }
            }
            
            Section(header: Text("APP IDS (\(appIDs.count))")) {
                Button("創建新 App ID") {
                    showCreateSheet = true
                }
                .disabled(selectedTeam == nil || isLoading)
                
                ForEach(appIDs, id: \.identifier) { appID in
                    VStack(alignment: .leading) {
                        Text(appID.name)
                            .font(.headline)
                        Text(appID.bundleIdentifier)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .contextMenu {
                        Button("刪除", role: .destructive) {
                            appIDToDelete = appID
                            showDeleteAlert = true
                        }
                    }
                }
            }
            
            if let error = errorMessage {
                Section(header: Text("錯誤")) {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("App ID 管理")
        .onAppear { loadTeams() }
        // 原本用 .alert 夾 TextField 收輸入：iOS 15 的 SwiftUI 不渲染 alert 裡的
        // 輸入欄（真機實證：對話框只剩標題與按鈕），每次創建都送空值給 Apple、
        // 換來 35「appIdentifierString 未提供值」。改用與 PortalCreateAppIDView
        // 相同的 sheet 表單（該形狀在真機可用）。
        .sheet(isPresented: $showCreateSheet) {
            NavigationView {
                Form {
                    Section(header: Text("App ID"), footer: Text("Bundle ID 使用反向網域格式，例如 com.example.myapp。")) {
                        TextField("名稱", text: $newName)
                        TextField("Bundle ID", text: $newBundleID)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
                .navigationTitle("創建 App ID")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showCreateSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("創建") {
                            if let team = selectedTeam {
                                let name = newName
                                let bundleID = newBundleID
                                showCreateSheet = false
                                createAppID(name: name, bundleID: bundleID, for: team)
                            }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || selectedTeam == nil || isLoading)
                    }
                }
            }
        }
        .alert("刪除 App ID？", isPresented: $showDeleteAlert) {
            Button("刪除", role: .destructive) {
                if let appID = appIDToDelete, let team = selectedTeam {
                    deleteAppID(appID, for: team)
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            if let appID = appIDToDelete {
                Text("確定要刪除 \(appID.name) (\(appID.bundleIdentifier)) 嗎？")
            }
        }
    }
    
    private func loadTeams() {
        isLoading = true
        Task {
            do {
                let result = try await PaxSigningService.shared.fetchTeams()
                await MainActor.run {
                    self.teams = result
                    self.isLoading = false
                    if self.selectedTeamID == nil, let first = result.first {
                        self.selectedTeamID = first.identifier
                        self.loadAppIDs(for: first)
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    private func loadAppIDs(for team: SideSign.Team) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
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
    
    private func createAppID(name: String, bundleID: String, for team: SideSign.Team) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                _ = try await PaxSigningService.shared.createAppID(name: name, bundleIdentifier: bundleID, for: team)
                await MainActor.run {
                    self.isLoading = false
                    self.newName = ""
                    self.newBundleID = ""
                }
                loadAppIDs(for: team)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    private func deleteAppID(_ appID: SideSign.AppID, for team: SideSign.Team) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await PaxSigningService.shared.deleteAppID(appID, for: team)
                await MainActor.run {
                    self.isLoading = false
                }
                loadAppIDs(for: team)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}
