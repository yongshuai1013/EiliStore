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
    /// 保存的 IPA 文件路徑（用於自動重簽）
    var ipaPath: String?
    
    init(id: UUID = UUID(), name: String, bundleId: String, team: String, installedDate: Date = Date(), expiresDate: Date, iconName: String = "app.fill", ipaPath: String? = nil) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
        self.team = team
        self.installedDate = installedDate
        self.expiresDate = expiresDate
        self.iconName = iconName
        self.ipaPath = ipaPath
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
        AppLogger.shared.log("已添加 App: \(app.name) (\(app.bundleId))")
    }
    
    func removeApp(bundleId: String) {
        if let app = installedApps.first(where: { $0.bundleId == bundleId }) {
            AppLogger.shared.log("已移除 App: \(app.name)")
        }
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
    
    /// 刷新所有即將過期的 App（真實邏輯）
    func refreshAll() async {
        let toRefresh = appsNeedingRefresh
        guard !toRefresh.isEmpty else {
            refreshProgress = "沒有需要刷新的 App"
            AppLogger.shared.log("刷新檢查：沒有需要刷新的 App")
            return
        }
        
        isRefreshing = true
        defer { isRefreshing = false }
        
        AppLogger.shared.log("開始刷新 \(toRefresh.count) 個 App...")
        
        for app in toRefresh {
            refreshProgress = "正在刷新 \(app.name)..."
            AppLogger.shared.log("正在刷新: \(app.name) (\(app.bundleId))")
            
            // 真實刷新需要：
            // 1. 該 App 的原始 IPA 文件（簽名時需要）
            // 2. 有效的 Apple ID 登入 + 證書
            // 3. 調用 SigningFlowView 的簽名邏輯重簽
            // 4. 調用 AppInstaller 重裝
            //
            // 目前 IPA 文件未持久化，無法自動重簽。
            // 需要先在安裝時保存 IPA，到時才能自動刷新。
            
            AppLogger.shared.log("⚠️ \(app.name): 需要原始 IPA 文件才能重簽，當前未保存，跳過")
            // 不修改 expiresDate，不假裝成功
        }
        
        save()
        refreshProgress = "刷新完成（部分跳過，需 IPA 文件）"
        AppLogger.shared.log("刷新完成：需要 IPA 文件才能真正重簽")
    }
    
    /// 檢查並自動刷新（App 啟動時調用）
    func checkAndAutoRefresh() async {
        AppLogger.shared.log("App 啟動，檢查 App 過期狀態...")
        if hasUpdates {
            AppLogger.shared.log("發現 \(appsNeedingRefresh.count) 個 App 需要刷新")
            await refreshAll()
        } else {
            AppLogger.shared.log("所有 App 簽名有效，無需刷新")
        }
    }
}
