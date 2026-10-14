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
    // 假數據，UI 先行
    @State private var installedApps: [InstalledApp] = [
        InstalledApp(name: "SideStore", team: "SideStore Team", expiresInDays: 5, iconName: "app.fill"),
    ]
    @State private var appIDsRemaining = 6
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 無更新橫幅
                    Text("沒有可用更新")
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
                        Button("全部刷新") {}
                            .font(.caption)
                            .foregroundColor(.teal)
                    }
                    
                    // App 列表
                    ForEach(installedApps) { app in
                        AppRowView(app: app)
                    }
                    
                    // App ID 剩餘
                    VStack(spacing: 4) {
                        Text("\(appIDsRemaining) 個 App ID 剩餘")
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
        }
    }
}

struct InstalledApp: Identifiable {
    let id = UUID()
    let name: String
    let team: String
    let expiresInDays: Int
    let iconName: String
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
                Text("\(app.expiresInDays) 天後")
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(expiryColor(days: app.expiresInDays))
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

// MARK: - 軟體源（佔位）
struct SourcesView: View {
    var body: some View {
        NavigationView {
            Text("軟體源（待實作）")
                .foregroundColor(.secondary)
                .navigationTitle("軟體源")
        }
    }
}

// MARK: - 簽名
struct SignInstallView: View {
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("簽名")) {
                    NavigationLink(destination: Text("簽名 IPA（待實作）")) {
                        Text("簽名 IPA")
                    }
                }
                
                Section(header: Text("安裝")) {
                    NavigationLink(destination: Text("安裝 App（待實作）")) {
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
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("證書")) {
                    NavigationLink(destination: Text("證書管理（待實作）")) {
                        Text("證書管理")
                    }
                }
                
                Section(header: Text("關於")) {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("設定")
        }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
