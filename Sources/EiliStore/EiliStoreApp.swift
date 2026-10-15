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
    @State private var showAppIDsSheet = false
    @State private var showAppIDSelection = false
    @State private var showRefreshConfirm = false
    
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
                        Button {
                            Task {
                                await manager.refreshAll(includeExternal: false)
                            }
                        } label: {
                            if manager.isRefreshing {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Text("全部刷新")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.teal)
                        .disabled(manager.isRefreshing)
                    }
                    
                    // 刷新提示（緊湊，EiliStore 主題青色，最多兩行）
                    if !manager.refreshProgress.isEmpty {
                        Text(manager.refreshProgress)
                            .font(.caption2)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.teal)
                            .cornerRadius(10)
                            .lineLimit(2)
                    }
                    
                    // App 列表
                    if manager.installedApps.isEmpty {
                        Text("還沒有安裝 App")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        ForEach(manager.displayApps) { app in
                            AppRowView(app: app, manager: manager)
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
                    
                    // 外部 App（不在列表裡，但選中要刷新的）— 跟上面列表同樣的卡片樣式
                    if !manager.externalBundleIds.isEmpty {
                        // 標題行
                        HStack {
                            Text("外部 App")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            Spacer()
                            Button {
                                Task {
                                    await manager.refreshExternalOnly()
                                }
                            } label: {
                                if manager.isRefreshingExternal {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Text("全部刷新")
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.teal)
                            .disabled(manager.isRefreshingExternal || manager.isRefreshing)
                        }
                        ForEach(manager.externalBundleIds, id: \.self) { bid in
                            HStack(spacing: 12) {
                                // 嘗試從已安裝 App 拿圖標
                                if let uiImage = AppIconHelper.shared.icon(for: bid) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 52, height: 52)
                                        .cornerRadius(12)
                                } else {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.teal.opacity(0.18))
                                        .frame(width: 52, height: 52)
                                        .overlay(
                                            Image(systemName: "app.fill")
                                                .foregroundColor(.teal)
                                        )
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(manager.externalNames[bid] ?? bid)
                                        .font(.headline)
                                        .bold()
                                        .lineLimit(1)
                                    Text(bid)
                                        .font(.caption)
                                        .foregroundColor(.teal.opacity(0.6))
                                        .lineLimit(1)
                                    Text("外部")
                                        .font(.caption)
                                        .foregroundColor(.teal.opacity(0.75))
                                }
                                Spacer()
                                // 到期天數（跟已安裝一樣）
                                if let exp = manager.externalExpiry[bid] {
                                    let days = Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? 0
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text("剩餘")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text("\(days) 天")
                                            .font(.subheadline)
                                            .bold()
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(Color.yellow)
                                            .cornerRadius(20)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                                    .background((days <= 1 ? Color.red : Color.teal).opacity(0.15))
                                    .cornerRadius(16)
                                }
                            }
                            .padding()
                            .background(Color.teal.opacity(0.08))
                            .cornerRadius(20)
                        }
                    }
                    
                    // App ID 剩餘
                    VStack(spacing: 4) {
                        Text("\(manager.appIDsRemaining) 個 App ID 剩餘")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button("查看 App IDs") {
                            showAppIDsSheet = true
                        }
                        .font(.subheadline)
                        .foregroundColor(.teal)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .sheet(isPresented: $showAppIDsSheet) {
                        AppIDsSheetView()
                    }
                }
                .padding()
            }
            .navigationTitle("My Apps")
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                KeepAlive.shared.start()
                // 自動啟動常駐心跳（如果有配對檔）
                Task {
                    if let pairingURL = findPairingFileURL(),
                       await VPNConnectionChecker.shared.checkConnection() {
                        let host = VPNConnectionChecker.shared.effectiveGatewayHost
                        try? await HeartbeatManager.shared.start(pairingFileURL: pairingURL, host: host)
                    }
                }
                manager.refreshAppIDsRemaining()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showAppIDSelection = true }) {
                        Image(systemName: "plus")
                            .foregroundColor(.teal)
                    }
                }
            }
            .sheet(isPresented: $showAppIDSelection) {
                AppIDSelectionView()
            }
            .task {
                // App 啟動時檢查是否需要自動刷新
                await manager.checkAndAutoRefresh()
            }
        }
    }
    private func findPairingFileURL() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("PairingFiles")
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return files.first(where: { $0.pathExtension == "plist" })
    }

}

struct AppRowView: View {
    let app: InstalledApp
    @ObservedObject var manager: AppManager

    var body: some View {
        HStack(spacing: 12) {
            // App 圖標（安裝時從 IPA 解出；EiliStore 自身從 bundle 讀）
            if let iconPath = app.iconPath,
               let uiImage = UIImage(contentsOfFile: iconPath) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .cornerRadius(12)
            } else if app.bundleId == Bundle.main.bundleIdentifier,
                      let uiImage = UIImage(named: "EiliStoreIcon") {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .cornerRadius(12)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.teal.opacity(0.18))
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "app.fill")
                            .foregroundColor(.teal)
                    )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.headline)
                    .bold()
                Text(app.bundleId)
                    .font(.caption)
                    .foregroundColor(.teal.opacity(0.75))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("剩餘")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                // 天數膠囊（純色，像 SideStore；刷新時顯示轉圈）
                ZStack {
                    Text("\(app.daysRemaining) 天")
                        .font(.subheadline)
                        .bold()
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.yellow)
                        .cornerRadius(20)
                    if manager.currentlyRefreshingBundleId == app.bundleId {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(.white)
                    }
                }
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
    @State private var isLoggedIn = false
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("賬號")) {
                    if isLoggedIn {
                        NavigationLink(destination: AccountView(appleID: $appleID, isLoggedIn: $isLoggedIn)) {
                            Text("已登入: \(appleID)")
                        }
                    } else {
                        NavigationLink(destination: LoginView(appleID: $appleID, isLoggedIn: $isLoggedIn)) {
                            Text("Apple ID 登入")
                        }
                    }
                }
                
                Section(header: Text("證書")) {
                    NavigationLink(destination: CertificateView()) {
                        Text("證書管理")
                    }
                    NavigationLink(destination: AppIDsView()) {
                        Text("App ID 管理")
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
                   let savedID = KeychainHelper.loadString(forKey: "paxstore.auth.appleID"),
                   !savedID.isEmpty {
                    isLoggedIn = true
                    appleID = savedID
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