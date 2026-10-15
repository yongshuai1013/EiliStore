import Foundation
import SwiftUI
import SideSign

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
    /// 解出的 App 圖標路徑（Documents/AppIcons/）
    var iconPath: String?
    
    init(id: UUID = UUID(), name: String, bundleId: String, team: String, installedDate: Date = Date(), expiresDate: Date, iconName: String = "app.fill", ipaPath: String? = nil, iconPath: String? = nil) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
        self.team = team
        self.installedDate = installedDate
        self.expiresDate = expiresDate
        self.iconName = iconName
        self.ipaPath = ipaPath
        self.iconPath = iconPath
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
    
    /// 已註冊的 Bundle ID 白名單（從 Apple App IDs 獲取）
    @Published var registeredBundleIds: Set<String> = []
    
    /// 用戶選擇的需要刷新簽名的 Bundle ID（空 = 全部）
    @Published var selectedRefreshBundleIds: Set<String> = []
    
    /// 是否允許自動刷新外部 App
    @Published var enableExternalAutoRefresh: Bool = false
    
    /// 外部選中的 Bundle IDs（不在數據庫裡的）
    var externalBundleIds: [String] {
        let dbIds = Set(installedApps.map { $0.bundleId })
        return selectedRefreshBundleIds.subtracting(dbIds).sorted()
    } {
        didSet {
            UserDefaults.standard.set(Array(selectedRefreshBundleIds), forKey: "selectedRefreshBundleIds")
        }
    }
    
    /// 顯示用的 App 列表：用 App IDs 白名單過濾簽名
    /// - 白名單為空時顯示全部（未同步或斷網）
    /// - EiliStore 自己永遠顯示
    var displayApps: [InstalledApp] {
        guard !registeredBundleIds.isEmpty else { return installedApps }
        let selfBid = Bundle.main.bundleIdentifier ?? ""
        return installedApps.filter {
            $0.bundleId == selfBid || registeredBundleIds.contains($0.bundleId)
        }
    }
    
    /// 從 Apple App IDs 同步到期日＋白名單（以 Apple 的數據為準）
    func syncExpiryFromAppIDs() async {
        do {
            let teams = try await PaxSigningService.shared.fetchTeams()
            guard let team = teams.first else { return }
            let appIDs = try await PaxSigningService.shared.fetchAppIDs(for: team)
            var updated = false
            var bundleIds = Set<String>()
            for appID in appIDs {
                let bid = appID.bundleIdentifier
                bundleIds.insert(bid)
                if let idx = installedApps.firstIndex(where: { $0.bundleId == bid }),
                   let exp = appID.expirationDate {
                    if installedApps[idx].expiresDate != exp {
                        installedApps[idx].expiresDate = exp
                        updated = true
                    }
                }
            }
            // 更新白名單
            if bundleIds != registeredBundleIds {
                await MainActor.run {
                    self.registeredBundleIds = bundleIds
                }
                updated = true
            }
            if updated {
                save()
            }
        } catch {
            // 靜默失敗，保持本地數據
        }
    }
    @Published var refreshProgress: String = ""
    
    private let storageKey = "EiliStore.InstalledApps"
    
    private init() {
        self.selectedRefreshBundleIds = Set(UserDefaults.standard.stringArray(forKey: "selectedRefreshBundleIds") ?? [])
        self.enableExternalAutoRefresh = UserDefaults.standard.bool(forKey: "enableExternalAutoRefresh")
        self.selectedRefreshBundleIds = Set(UserDefaults.standard.stringArray(forKey: "selectedRefreshBundleIds") ?? [])
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
    
    // MARK: - App ID 剩餘名額

    /// 從 Apple 獲取真實 App ID 數量，更新剩餘名額（免費帳號上限 10 個）
    func refreshAppIDsRemaining() {
        Task {
            do {
                let teams = try await PaxSigningService.shared.fetchTeams()
                guard let team = teams.first else { return }
                let appIDs = try await PaxSigningService.shared.fetchAppIDs(for: team)
                await MainActor.run {
                    self.appIDsRemaining = max(0, 10 - appIDs.count)
                    AppLogger.shared.log("App ID 剩餘名額: \(self.appIDsRemaining)（已用 \(appIDs.count)/10）")
                }
            } catch {
                AppLogger.shared.log("❌ 獲取 App ID 數量失敗: \(error.localizedDescription)")
            }
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
    
    /// 刷新所有即將過期的 App（正確路線：只換 provisioning profile，不重裝）
    /// 參考 SideStore PR #846：refresh should only renew provisioning profiles
    func refreshAll(includeExternal: Bool = false) async {
        // 刷新列表裡所有 App（不只過期的）
        let toRefresh = displayApps
        // 外部選中的 Bundle IDs（由調用方決定是否包含）
        let dbBundleIds = Set(installedApps.map { $0.bundleId })
        let externalBids: Set<String> = includeExternal ? selectedRefreshBundleIds.subtracting(dbBundleIds) : []
        // 外部選中的 Bundle IDs（不在列表裡的）
        let dbBundleIds = Set(installedApps.map { $0.bundleId })
        let externalBids = selectedRefreshBundleIds.subtracting(dbBundleIds)
        
        guard !toRefresh.isEmpty || !externalBids.isEmpty else {
            refreshProgress = "沒有可刷新的 App"
            AppLogger.shared.log("刷新檢查：列表為空")
            return
        }
        
        isRefreshing = true
        defer { isRefreshing = false }
        
        AppLogger.shared.log("開始刷新 \(toRefresh.count) 個 App（只換 profile，不重裝）...")
        
        // 1. 檢查登入
        // TODO: 檢查 PaxAuthService 是否已登入
        
        // 2. 獲取 Team
        // TODO: 需要用戶選擇或記住 Team，現在先嘗試獲取第一個
        let teams: [SideSign.Team]
        do {
            teams = try await PaxSigningService.shared.fetchTeams()
        } catch {
            AppLogger.shared.log("❌ 獲取 Team 失敗: \(error.localizedDescription)")
            refreshProgress = "獲取 Team 失敗"
            return
        }
        guard let team = teams.first else {
            AppLogger.shared.log("❌ 沒有可用的 Team")
            refreshProgress = "沒有可用的 Team"
            return
        }
        AppLogger.shared.log("使用 Team: \(team.name)")
        
        // 3. 找配對檔
        guard let pairingFile = findPairingFile() else {
            AppLogger.shared.log("❌ 找不到配對檔，需要先配對設備")
            refreshProgress = "找不到配對檔"
            return
        }
        
        // 4. 連接 misagent
        let misagent = RustMisagentClient(host: "10.7.0.1", pairingFileURL: pairingFile)
        do {
            try await misagent.connect()
            AppLogger.shared.log("✅ Misagent 已連接")
        } catch {
            AppLogger.shared.log("❌ Misagent 連接失敗: \(error.localizedDescription)")
            refreshProgress = "連接設備失敗"
            return
        }
        
        // 5. 對每個 App：拉新 profile → 裝到設備
        for app in toRefresh {
            refreshProgress = "正在刷新 \(app.name)..."
            AppLogger.shared.log("正在刷新: \(app.name) (\(app.bundleId))")
            
            do {
                // 找或創建 App ID
                let appID = try await PaxSigningService.shared.findOrCreateAppID(
                    bundleIdentifier: app.bundleId,
                    name: app.name,
                    for: team
                )
                AppLogger.shared.log("  App ID: \(appID.name)")
                
                // 下載新的 provisioning profile
                let profile = try await PaxSigningService.shared.provisioningProfile(for: appID, team: team)
                AppLogger.shared.log("  新 profile 已下載 (\(profile.data.count) bytes)")
                
                // 裝到設備（這就是刷新的核心，3-5 秒）
                try await misagent.installProfile(profile.data)
                AppLogger.shared.log("  ✅ Profile 已安裝到設備")
                
                // 更新過期時間
                if let index = installedApps.firstIndex(where: { $0.id == app.id }) {
                    installedApps[index].expiresDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
                    AppLogger.shared.log("  ✅ \(app.name) 刷新完成，有效期延長7天")
                }
            } catch {
                AppLogger.shared.log("  ❌ \(app.name) 刷新失敗: \(error.localizedDescription)")
                // 繼續下一個，不中斷
            }
        }
        
        // 刷新外部選中的 Bundle IDs（不在列表裡的）
        for bid in externalBids {
            refreshProgress = "正在刷新 \(bid)..."
            AppLogger.shared.log("正在刷新外部: \(bid)")
            do {
                let appID = try await PaxSigningService.shared.findOrCreateAppID(
                    bundleIdentifier: bid,
                    name: bid,
                    for: team
                )
                let profile = try await PaxSigningService.shared.provisioningProfile(for: appID, team: team)
                AppLogger.shared.log("  新 profile 已下載 (\(profile.data.count) bytes)")
                try await misagent.installProfile(profile.data)
                AppLogger.shared.log("  ✅ 外部 \(bid) 刷新完成")
            } catch {
                AppLogger.shared.log("  ❌ 外部 \(bid) 刷新失敗: \(error.localizedDescription)")
            }
        }
        
        misagent.disconnect()
        save()
        refreshProgress = "刷新完成"
        AppLogger.shared.log("全部刷新完成")
    }
    
    /// 查找配對檔
    private func findPairingFile() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        // 1. 先找 PairingFiles/PairingFile_Lockdown.plist
        let preferred = docs.appendingPathComponent("PairingFiles/PairingFile_Lockdown.plist")
        if FileManager.default.fileExists(atPath: preferred.path) {
            return preferred
        }
        // 2. 找 PairingFiles/ 下第一個 .plist
        let dir = docs.appendingPathComponent("PairingFiles", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            return files.first(where: { $0.pathExtension == "plist" })
        }
        return nil
    }
    
    /// 檢查並自動刷新（App 啟動時調用）
    /// 檢查外部選中的 App 是否快過期（1天內）
    private func checkExternalExpiry() async -> Bool {
        do {
            let teams = try await PaxSigningService.shared.fetchTeams()
            guard let team = teams.first else { return false }
            let appIDs = try await PaxSigningService.shared.fetchAppIDs(for: team)
            let calendar = Calendar.current
            for appID in appIDs {
                if externalBundleIds.contains(appID.bundleIdentifier),
                   let exp = appID.expirationDate {
                    let days = calendar.dateComponents([.day], from: Date(), to: exp).day ?? 999
                    if days <= 1 {
                        return true
                    }
                }
            }
        } catch {
        }
        return false
    }
    
    func checkAndAutoRefresh() async {
        // 1. 確保 EiliStore 自己在列表裡（用於自刷新）
        ensureSelfRegistered()
        
        AppLogger.shared.log("App 啟動，檢查 App 過期狀態...")
        var externalNeedsRefresh = false
        if enableExternalAutoRefresh && !externalBundleIds.isEmpty {
            externalNeedsRefresh = await checkExternalExpiry()
        }
        if hasUpdates || externalNeedsRefresh {
            if hasUpdates {
                AppLogger.shared.log("發現過期 App，開始刷新")
            }
            if externalNeedsRefresh {
                AppLogger.shared.log("外部 App 快過期，觸發刷新")
            }
            await refreshAll(includeExternal: enableExternalAutoRefresh)
        } else {
            AppLogger.shared.log("所有 App 簽名有效，無需刷新")
        }
    }
    
    /// 確保 EiliStore 自己在 App 列表裡（用於自刷新）
    private func ensureSelfRegistered() {
        let selfBundleId = Bundle.main.bundleIdentifier ?? "com.eili.eilistore"
        
        // 如果已經在列表裡，不重複添加
        if installedApps.contains(where: { $0.bundleId == selfBundleId }) {
            return
        }
        
        // 嘗試從 embedded provisioning profile 讀真實過期時間
        var expiresDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        if let profilePath = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
           let profileData = try? Data(contentsOf: URL(fileURLWithPath: profilePath)),
           let expiry = extractExpiry(from: profileData) {
            expiresDate = expiry
            AppLogger.shared.log("從 profile 讀到 EiliStore 過期時間: \(expiry)")
        }
        
        let selfApp = InstalledApp(
            name: "EiliStore",
            bundleId: selfBundleId,
            team: "自己",
            expiresDate: expiresDate,
            iconName: "app.fill"
        )
        installedApps.append(selfApp)
        save()
        AppLogger.shared.log("已登記 EiliStore 自己到刷新列表")
    }
    
    /// 從 mobileprovision 提取過期時間
    private func extractExpiry(from data: Data) -> Date? {
        // mobileprovision 是 CMS 簽名的 plist，找 ExpirationDate
        // 簡化：轉成字符串搜索
        guard let str = String(data: data, encoding: .ascii) else { return nil }
        // 找 <key>ExpirationDate</key> 後面的 <date>
        guard let keyRange = str.range(of: "<key>ExpirationDate</key>") else { return nil }
        let afterKey = str[keyRange.upperBound...]
        guard let dateStart = afterKey.range(of: "<date>"),
              let dateEnd = afterKey.range(of: "</date>") else { return nil }
        let dateStr = String(afterKey[dateStart.upperBound..<dateEnd.lowerBound])
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: dateStr)
    }
}
