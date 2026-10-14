import SwiftUI

@main
struct EiliStoreApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            MyAppsView()
                .tabItem {
                    Label("主頁", systemImage: "house.fill")
                }
            
            SourcesView()
                .tabItem {
                    Label("軟體源", systemImage: "link")
                }
            
            SignInstallView()
                .tabItem {
                    Label("簽名", systemImage: "signature")
                }
            
            SettingsView()
                .tabItem {
                    Label("設定", systemImage: "gearshape.fill")
                }
        }
        .accentColor(.teal)
    }
}

// MARK: - 主頁（My Apps 風格，不顯示 Apple ID）
struct MyAppsView: View {
    @StateObject private var manager = AppManager.shared
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 更新橫幅
                    Text(manager.hasUpdates ? "有 \(manager.appsNeedingRefresh.count) 個 App 需要刷新" : "沒有可用更新")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.teal.opacity(0.12))
                        .cornerRadius(16)
                    
                    // 已安裝標題行
                    HStack {
                        Text("已安裝")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Button(manager.isRefreshing ? "刷新中..." : "全部刷新") {
                            Task {
                                await manager.refreshAll()
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.teal)
                        .disabled(manager.isRefreshing || !manager.hasUpdates)
                    }
                    
                    // 刷新進度
                    if !manager.refreshProgress.isEmpty {
                        Text(manager.refreshProgress)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // App 列表
                    if manager.installedApps.isEmpty {
                        Text("還沒有安裝 App")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        ForEach(manager.installedApps) { app in
                            AppRowView(app: app)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let app = manager.installedApps[index]
                                // 刪除保存的 IPA 文件
                                if let ipaPath = app.ipaPath {
                                    try? FileManager.default.removeItem(atPath: ipaPath)
                                    AppLogger.shared.log("已刪除 IPA: \(ipaPath)")
                                }
                                manager.removeApp(bundleId: app.bundleId)
                            }
                        }
                    }
                    
                    // App ID 剩餘
                    VStack(spacing: 4) {
                        Text("\(manager.appIDsRemaining) 個 App ID 剩餘")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button("查看 App IDs") {}
                            .font(.subheadline)
                            .foregroundColor(.teal)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("My Apps")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {}) {
                        Image(systemName: "plus")
                            .foregroundColor(.teal)
                    }
                }
            }
            .task {
                // App 啟動時檢查是否需要自動刷新
                await manager.checkAndAutoRefresh()
            }
        }
    }
}

struct AppRowView: View {
    let app: InstalledApp
    
    var body: some View {
        HStack(spacing: 12) {
            // 圖標
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: app.iconName)
                        .foregroundColor(.white)
                        .font(.title2)
                )
            
            // 名稱和團隊
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.headline)
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.teal)
                        .font(.caption)
                }
                Text(app.team)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // 到期徽章
            VStack(alignment: .trailing, spacing: 2) {
                Text("過期於")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(app.daysRemaining) 天後")
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(expiryColor(days: app.daysRemaining))
                    .cornerRadius(20)
            }
        }
        .padding()
        .background(Color.teal.opacity(0.08))
        .cornerRadius(20)
    }
    
    private func expiryColor(days: Int) -> Color {
        if days <= 2 { return .red }
        if days <= 5 { return .orange }
        return .teal
    }
}

// MARK: - 軟體源（已移至 SourcesView.swift）

// MARK: - 簽名
struct SignInstallView: View {
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("簽名")) {
                    NavigationLink(destination: SigningFlowView()) {
                        Text("簽名 IPA")
                    }
                }
                
                Section(header: Text("安裝")) {
                    NavigationLink(destination: InstallAppView()) {
                        Text("安裝 App")
                    }
                }
            }
            .navigationTitle("簽名")
        }
    }
}

// MARK: - 設定
struct SettingsView: View {
    @State private var appleID = ""
    @State private var password = ""
    @State private var isLoggedIn = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("賬號")) {
                    if isLoggedIn {
                        HStack {
                            Spacer()
                            Text("已登入: \(appleID)")
                                .foregroundColor(.teal)
                            Spacer()
                        }
                        Button("登出", role: .destructive) {
                            PaxAuthService.shared.logout()
                            isLoggedIn = false
                            appleID = ""
                            password = ""
                        }
                    } else {
                        TextField("Apple ID", text: $appleID)
                            .autocapitalization(.none)
                            .keyboardType(.emailAddress)
                            .disabled(isLoading)
                        SecureField("密碼", text: $password)
                            .disabled(isLoading)
                        if let error = errorMessage {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                        Button(action: doLogin) {
                            HStack {
                                Spacer()
                                if isLoading {
                                    ProgressView()
                                } else {
                                    Text("登入")
                                }
                                Spacer()
                            }
                        }
                        .disabled(isLoading || appleID.isEmpty || password.isEmpty)
                    }
                }
                
                Section(header: Text("證書")) {
                    NavigationLink(destination: CertificateView()) {
                        Text("證書管理")
                    }
                }
                
                Section(header: Text("調試")) {
                    NavigationLink(destination: AnisetteServerView()) {
                        Text("Anisette 伺服器")
                    }
                    NavigationLink(destination: ConnectionConfigView()) {
                        Text("連接配置")
                    }
                    NavigationLink(destination: PairingFileManagementView()) {
                        Text("配對檔管理")
                    }
                    NavigationLink(destination: FileBrowserView(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!)) {
                        Text("檔案管理")
                    }
                }
                
                Section(header: Text("關於")) {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0")
                            .foregroundColor(.secondary)
                    }
                    NavigationLink(destination: LogView()) {
                        Text("日誌")
                    }
                }
            }
            .navigationTitle("設定")
            .onAppear {
                if KeychainHelper.loadString(forKey: "paxstore.auth.session") != nil,
                   let savedID = KeychainHelper.loadString(forKey: "paxstore.apple.id"),
                   !savedID.isEmpty {
                    isLoggedIn = true
                    appleID = savedID
                }
            }
        }
    }
    
    private func doLogin() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await PaxAuthService.shared.login(appleID: appleID, password: password)
                await MainActor.run {
                    isLoggedIn = true
                    isLoading = false
                    // 保存 Apple ID
                    KeychainHelper.saveString(appleID, forKey: "paxstore.apple.id")
                    AppLogger.shared.log("登入成功: \(appleID)")
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                    AppLogger.shared.log("登入失敗: \(error.localizedDescription)")
                }
            }
        }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
