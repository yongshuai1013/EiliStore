import Foundation
import SwiftUI

/// 已安裝 App 的數據模型
struct InstalledApp: Identifiable, Codable {
    let id: UUID
    var name: String
    var bundleId: String
    var team: String
    var installedDate: Date
    var expiresDate: Date
    var iconName: String
    
    init(id: UUID = UUID(), name: String, bundleId: String, team: String, installedDate: Date = Date(), expiresDate: Date, iconName: String = "app.fill") {
        self.id = id
        self.name = name
        self.bundleId = bundleId
        self.team = team
        self.installedDate = installedDate
        self.expiresDate = expiresDate
        self.iconName = iconName
    }
    
    /// 剩餘天數
    var daysRemaining: Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: Date(), to: expiresDate)
        return max(0, components.day ?? 0)
    }
    
    /// 是否即將過期（2天內）
    var isExpiringSoon: Bool {
        daysRemaining <= 2
    }
}

/// App 管理器：追蹤已安裝 App，支援刷新
class AppManager: ObservableObject {
    static let shared = AppManager()
    
    @Published var installedApps: [InstalledApp] = []
    @Published var appIDsRemaining: Int = 10
    @Published var isRefreshing: Bool = false
    @Published var refreshProgress: String = ""
    
    private let storageKey = "EiliStore.InstalledApps"
    
    private init() {
        load()
        // 如果是空的，加個示例（僅首次）
        if installedApps.isEmpty {
            // 不加假數據，保持空
        }
    }
    
    // MARK: - 持久化
    
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let apps = try? JSONDecoder().decode([InstalledApp].self, from: data) else {
            return
        }
        installedApps = apps
    }
    
    private func save() {
        if let data = try? JSONEncoder().encode(installedApps) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    // MARK: - App 管理
    
    func addApp(_ app: InstalledApp) {
        // 如果已存在同 bundleId，先移除
        installedApps.removeAll { $0.bundleId == app.bundleId }
        installedApps.append(app)
        save()
    }
    
    func removeApp(bundleId: String) {
        installedApps.removeAll { $0.bundleId == bundleId }
        save()
    }
    
    /// 需要刷新的 App（2天內過期）
    var appsNeedingRefresh: [InstalledApp] {
        installedApps.filter { $0.isExpiringSoon }
    }
    
    /// 是否有可用更新（有 App 需要刷新）
    var hasUpdates: Bool {
        !appsNeedingRefresh.isEmpty
    }
    
    // MARK: - 刷新
    
    /// 刷新所有即將過期的 App
    func refreshAll() async {
        let toRefresh = appsNeedingRefresh
        guard !toRefresh.isEmpty else {
            refreshProgress = "沒有需要刷新的 App"
            return
        }
        
        isRefreshing = true
        defer { isRefreshing = false }
        
        for app in toRefresh {
            refreshProgress = "正在刷新 \(app.name)..."
            // TODO: 實際的重簽名+重裝邏輯
            // 1. 用保存的證書重簽 IPA
            // 2. 用 .app 上傳路線重裝
            // 3. 更新 expiresDate
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            
            // 臨時：直接延長7天（演示）
            if let index = installedApps.firstIndex(where: { $0.id == app.id }) {
                installedApps[index].expiresDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
                installedApps[index].installedDate = Date()
            }
        }
        
        save()
        refreshProgress = "刷新完成"
    }
    
    /// 檢查並自動刷新（App 啟動時調用）
    func checkAndAutoRefresh() async {
        if hasUpdates {
            await refreshAll()
        }
    }
}
