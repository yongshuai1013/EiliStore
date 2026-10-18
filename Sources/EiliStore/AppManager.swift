import Foundation
import SwiftUI
import SideSign
import ZIPFoundation

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
    
    /// 用戶選擇的需要自動刷新簽名的外部 Bundle ID。
    @Published var selectedRefreshBundleIds: Set<String> = []
    /// 外部 App 的到期時間 (bundleId -> expiresDate)
    @Published var externalExpiry: [String: Date] = [:]
    /// 外部 App 的名稱 (bundleId -> name，從 Apple App IDs 來)
    @Published var externalNames: [String: String] = [:]
    /// 從 IPA 匯入的外部 App 圖示路徑（以 Bundle ID 關聯）。
    @Published var externalIconPaths: [String: String] = [:]
    
    /// 是否允許自動刷新外部 App
    @Published var enableExternalAutoRefresh: Bool = false
    
    /// Apple 上註冊的 Bundle IDs
    @Published var registeredBundleIds: Set<String> = []
    
    /// 外部選中的 Bundle IDs（不在數據庫裡的）
    var externalBundleIds: [String] {
        guard !selectedRefreshBundleIds.isEmpty else { return [] }
        let dbIds = Set(installedApps.flatMap { bundleIdentifiersForRefresh($0) })
        return selectedRefreshBundleIds.subtracting(dbIds).sorted()
    }

    /// 可供 IPA 圖標手動配對的目標：只包含既有外部項目，不包含已安裝 APP。
    var externalIconTargetBundleIds: [String] {
        let installedBundleIds = installedApps.flatMap { bundleIdentifiersForRefresh($0) }
        return externalBundleIds.filter { bundleId in
            !installedBundleIds.contains {
                $0.caseInsensitiveCompare(bundleId) == .orderedSame
            }
        }
    }

    /// 首頁顯示的外部 App：包含已選擇刷新的 ID，以及只匯入圖示的 ID。
    /// 匯入圖示本身不會把 App 加入簽名刷新清單。
    var externalDisplayBundleIds: [String] {
        let dbIds = installedApps.flatMap { bundleIdentifiersForRefresh($0) }
        return Set(externalBundleIds).union(externalIconPaths.keys)
            .filter { bundleId in
                !dbIds.contains { $0.caseInsensitiveCompare(bundleId) == .orderedSame }
            }
            .sorted()
    }
    @Published var appIDsRemaining: Int = 10
    @Published var isRefreshing: Bool = false
    @Published var isRefreshingExternal = false
    @Published var refreshFraction: Double = 0.0
    @Published var currentlyRefreshingBundleId: String? = nil
    @Published var refreshTitle: String = ""
    @Published var isRefreshError: Bool = false
    
    /// 顯示用的 App 列表：目前直接顯示全部
    /// 數據庫裡的都是 EiliStore 自己安裝的，不需要過濾
    var displayApps: [InstalledApp] {
        installedApps
    }
    @Published var refreshProgress: String = ""
    
    private let storageKey = "EiliStore.InstalledApps"
    private let appIDSnapshotKey = "EiliStore.AppIDSnapshot.v1"
    @Published private var appIDSnapshot: AppIDSnapshot?
    private var appIDSyncTask: Task<[SideSign.AppID], Error>?
    private var refreshBundleIDCache: [UUID: [String]] = [:]

    private var appIDAccountIdentifier: String? {
        KeychainHelper.loadCodable(SideSign.AuthSession.self, forKey: "paxstore.auth.session")?.account.identifier
    }

    /// 只呈現目前登入帳戶的快取，不讓另一個帳戶的記錄出現在清單。
    var cachedAppIDs: [SideSign.AppID] {
        guard let snapshot = appIDSnapshot,
              snapshot.accountIdentifier == appIDAccountIdentifier else { return [] }
        return snapshot.appIDs
    }

    var appIDsLastSyncedAt: Date? {
        guard let snapshot = appIDSnapshot,
              snapshot.accountIdentifier == appIDAccountIdentifier else { return nil }
        return snapshot.syncedAt
    }
    
    private init() {
        self.selectedRefreshBundleIds = Set(UserDefaults.standard.stringArray(forKey: "selectedRefreshBundleIds") ?? [])
        self.enableExternalAutoRefresh = UserDefaults.standard.bool(forKey: "enableExternalAutoRefresh")
        if let data = UserDefaults.standard.data(forKey: appIDSnapshotKey),
           let snapshot = try? JSONDecoder().decode(AppIDSnapshot.self, from: data) {
            self.appIDSnapshot = snapshot
            if snapshot.accountIdentifier == appIDAccountIdentifier {
                self.registeredBundleIds = Set(snapshot.records.map(\.bundleIdentifier))
                self.appIDsRemaining = max(0, 10 - snapshot.records.count)
            }
        }
        // 載入外部 App 數據
        if let data = UserDefaults.standard.data(forKey: "externalExpiry"),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            self.externalExpiry = decoded
        }
        if let data = UserDefaults.standard.data(forKey: "externalNames"),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.externalNames = decoded
        }
        if let data = UserDefaults.standard.data(forKey: "externalIconPaths"),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.externalIconPaths = decoded
        }
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

    private func saveExternalMetadata() {
        if let data = try? JSONEncoder().encode(externalExpiry) {
            UserDefaults.standard.set(data, forKey: "externalExpiry")
        }
        if let data = try? JSONEncoder().encode(externalNames) {
            UserDefaults.standard.set(data, forKey: "externalNames")
        }
    }

    /// 保存 IPA 中解析出的圖示，僅以 Bundle ID 關聯，不安裝或簽名 IPA。
    func saveExternalIcon(bundleId: String, iconData: Data, removingSourceBundleId: String? = nil) throws {
        guard !bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bundleId != "unknown" else {
            throw ExternalIconError.invalidBundleIdentifier
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let iconsDirectory = documents.appendingPathComponent("AppIcons", isDirectory: true)
        try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)

        let iconURL = iconsDirectory.appendingPathComponent("external-\(UUID().uuidString).png")
        try iconData.write(to: iconURL, options: .atomic)

        let appIndex = installedApps.firstIndex {
            $0.bundleId.caseInsensitiveCompare(bundleId) == .orderedSame
        }
        let sourceBundleId = removingSourceBundleId.flatMap {
            $0.caseInsensitiveCompare(bundleId) == .orderedSame ? nil : $0
        }
        let matchingIconKeys = externalIconPaths.keys.filter { key in
            key.caseInsensitiveCompare(bundleId) == .orderedSame ||
            sourceBundleId.map { key.caseInsensitiveCompare($0) == .orderedSame } == true
        }
        var obsoletePaths = matchingIconKeys.compactMap { externalIconPaths[$0] }
        if let appIndex {
            if let previousPath = installedApps[appIndex].iconPath {
                obsoletePaths.append(previousPath)
            }
            installedApps[appIndex].iconPath = iconURL.path
            save()
        }
        // 移除目標／來源的舊映射，避免大小寫變體或舊匯入來源留下重複卡片。
        for key in matchingIconKeys {
            externalIconPaths.removeValue(forKey: key)
        }
        if appIndex == nil {
            externalIconPaths[bundleId] = iconURL.path
        }

        for path in Set(obsoletePaths) {
            let previousURL = URL(fileURLWithPath: path).standardizedFileURL
            guard previousURL.deletingLastPathComponent() == iconsDirectory.standardizedFileURL,
                  !installedApps.contains(where: { $0.iconPath == path }),
                  !externalIconPaths.values.contains(path) else { continue }
            try? FileManager.default.removeItem(at: previousURL)
        }

        if let data = try? JSONEncoder().encode(externalIconPaths) {
            UserDefaults.standard.set(data, forKey: "externalIconPaths")
        }
        AppLogger.shared.log("已匯入外部 App 圖示: \(bundleId)")
    }

    /// 供舊版已匯入資料與 Bundle ID 大小寫不同時，既有 APP 卡片仍能顯示圖示。
    func externalIconPath(for bundleId: String) -> String? {
        if let exactPath = externalIconPaths[bundleId] {
            return exactPath
        }
        return externalIconPaths.first {
            $0.key.caseInsensitiveCompare(bundleId) == .orderedSame
        }?.value
    }

    /// 自動匹配只認已安裝 APP 或既有外部刷新項目，不把舊版匯入圖標所建立的孤立列視為 APP。
    func existingIconTargetBundleId(for bundleId: String) -> String? {
        if let installedApp = installedApps.first(where: {
            $0.bundleId.caseInsensitiveCompare(bundleId) == .orderedSame
        }) {
            return installedApp.bundleId
        }
        return externalIconTargetBundleIds.first {
            $0.caseInsensitiveCompare(bundleId) == .orderedSame
        }
    }

    enum ExternalIconError: LocalizedError {
        case invalidBundleIdentifier

        var errorDescription: String? {
            "IPA 中找不到有效的 Bundle ID"
        }
    }
    
    // MARK: - App ID 剩餘名額

    /// 從 Apple 獲取真實 App ID 數量，更新剩餘名額（免費帳號上限 10 個）
    func refreshAppIDsRemaining() {
        Task {
            do {
                let appIDs = try await syncAppIDsFromApple()
                AppLogger.shared.log("App ID 剩餘名額: \(self.appIDsRemaining)（已用 \(appIDs.count)/10）")
            } catch {
                AppLogger.shared.log("❌ 獲取 App ID 數量失敗: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - App 管理
    
    func addApp(_ app: InstalledApp) {
        // 如果已存在同 bundleId，先移除
        installedApps.removeAll { $0.bundleId == app.bundleId }
        refreshBundleIDCache.removeAll()
        installedApps.append(app)
        save()
        AppLogger.shared.log("已添加 App: \(app.name) (\(app.bundleId))")
    }
    
    func removeApp(bundleId: String) {
        if let app = installedApps.first(where: { $0.bundleId == bundleId }) {
            AppLogger.shared.log("已移除 App: \(app.name)")
        }
        installedApps.removeAll { $0.bundleId == bundleId }
        refreshBundleIDCache.removeAll()
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
    
    /// 同步 Apple Developer Portal 的 App ID 記錄；不會覆寫裝置 profile 的簽名到期日。
    /// 合併同時發起的同步，避免較舊回應覆寫新快照。失敗時不清除快取。
    @MainActor
    func syncAppIDsFromApple() async throws -> [SideSign.AppID] {
        if let task = appIDSyncTask { return try await task.value }
        guard let accountIdentifier = appIDAccountIdentifier else { throw SigningError.notLoggedIn }

        let task = Task { @MainActor () async throws -> [SideSign.AppID] in
            let teams = try await PaxSigningService.shared.fetchTeams()
            guard let team = teams.first else { throw SigningError.noTeamFound }
            let appIDs = try await PaxSigningService.shared.fetchAppIDs(for: team)
            guard self.appIDAccountIdentifier == accountIdentifier else { throw AppIDSyncError.accountChanged }

            let snapshot = try AppIDSnapshot(
                appIDs: appIDs,
                accountIdentifier: accountIdentifier,
                teamIdentifier: team.identifier
            )
            // 先完成編碼，再一起套用：只取代本地 Portal 記錄，絕不呼叫遠端刪除。
            let data = try JSONEncoder().encode(snapshot)
            UserDefaults.standard.set(data, forKey: self.appIDSnapshotKey)
            self.appIDSnapshot = snapshot
            self.registeredBundleIds = Set(appIDs.map { $0.bundleIdentifier })
            self.appIDsRemaining = max(0, 10 - appIDs.count)

            // 名稱可供所有既有外部項目使用，但不自動加入首頁或刷新選擇。
            for appID in appIDs {
                self.externalNames[appID.bundleIdentifier] = appID.name
            }
            self.saveExternalMetadata()
            return appIDs
        }
        appIDSyncTask = task
        defer { appIDSyncTask = nil }
        return try await task.value
    }
    
    // MARK: - 刷新
    
    /// 刷新單一已安裝 App，供有效期按鈕直接呼叫。
    func refreshApp(_ app: InstalledApp) async {
        await refreshAll(includeExternal: false, onlyBundleId: app.bundleId)
    }

    /// 刷新單一外部 App，供外部 App 的到期膠囊直接呼叫。
    func refreshExternalApp(bundleId: String) async {
        await refreshAll(includeExternal: true, onlyBundleId: bundleId)
    }

    /// 刷新 App（正確路線：只換 provisioning profile，不重裝）
    /// 參考 SideStore PR #846：refresh should only renew provisioning profiles
    /// - Parameters:
    ///   - includeExternal: 是否包含外部 App
    ///   - onlyNeedingRefresh: true=只刷即將過期的（自動刷新用），false=刷全部（手動用）
    ///   - onlyBundleId: 指定只刷新一個已安裝 App；nil 時維持批次刷新
    func refreshAll(includeExternal: Bool = false, onlyNeedingRefresh: Bool = false, onlyBundleId: String? = nil) async {
        var failCount = 0
        let appsToConsider = onlyNeedingRefresh ? appsNeedingRefresh : installedApps
        let toRefresh = onlyBundleId.map { bundleId in
            appsToConsider.filter { $0.bundleId == bundleId }
        } ?? appsToConsider
        refreshFraction = 0.0
        // 外部選中的 Bundle IDs（由調用方決定是否包含）
        let selectedExternalBids = Set(externalBundleIds)
        let externalBids: Set<String>
        if includeExternal {
            if let onlyBundleId {
                externalBids = selectedExternalBids.contains(onlyBundleId) ? [onlyBundleId] : []
            } else {
                externalBids = selectedExternalBids
            }
        } else {
            externalBids = []
        }
        guard !toRefresh.isEmpty || !externalBids.isEmpty else {
            AppLogger.shared.log("刷新檢查：沒有需要刷新的 App")
            refreshTitle = ""
            isRefreshError = false
            refreshProgress = "沒有需要刷新的 App"
            return
        }
        
        isRefreshing = true
        refreshTitle = ""
        isRefreshError = false
        if let onlyBundleId {
            currentlyRefreshingBundleId = onlyBundleId
        }
        defer {
            isRefreshing = false
            if onlyBundleId != nil {
                currentlyRefreshingBundleId = nil
            }
        }
        
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
            refreshTitle = "刷新失敗"
            isRefreshError = true
            refreshProgress = "獲取 Team 失敗"
            return
        }
        guard let team = teams.first else {
            AppLogger.shared.log("❌ 沒有可用的 Team")
            refreshTitle = "刷新失敗"
            isRefreshError = true
            refreshProgress = "沒有可用的 Team"
            return
        }
        AppLogger.shared.log("使用 Team: \(team.name)")
        
        // 3. 找配對檔
        guard let pairingFile = findPairingFile() else {
            AppLogger.shared.log("❌ 找不到配對檔，需要先配對設備")
            refreshTitle = "刷新失敗"
            isRefreshError = true
            refreshProgress = "找不到配對檔"
            return
        }
        
        // 4. 連接 misagent
        let misagent = RustMisagentClient(host: VPNConnectionChecker.shared.effectiveGatewayHost, pairingFileURL: pairingFile)
        do {
            try await misagent.connect()
            AppLogger.shared.log("✅ Misagent 已連接")
        } catch {
            AppLogger.shared.log("❌ Misagent 連接失敗: \(error.localizedDescription)")
            refreshTitle = "刷新失敗"
            isRefreshError = true
            refreshProgress = "連接設備失敗"
            return
        }
        
        // 5. 對每個 App：拉新 profile → 裝到設備
        for app in toRefresh {
            currentlyRefreshingBundleId = app.bundleId
            refreshFraction = 0.0
            refreshProgress = "正在刷新 \(app.name)..."
            AppLogger.shared.log("正在刷新: \(app.name) (\(app.bundleId))")

            let bundleIDs = bundleIdentifiersForRefresh(app)
            for (index, bundleID) in bundleIDs.enumerated() {
                let progressBase = Double(index) / Double(max(bundleIDs.count, 1))
                let progressSpan = 1.0 / Double(max(bundleIDs.count, 1))
                refreshFraction = progressBase
                AppLogger.shared.log("  更新 profile: \(bundleID)")
                do {
                    // 找或創建 App ID
                    let appID = try await PaxSigningService.shared.findOrCreateAppID(
                        bundleIdentifier: bundleID,
                        name: bundleID == app.bundleId ? app.name : bundleID,
                        for: team
                    )
                    refreshFraction = progressBase + progressSpan * 0.3
                    AppLogger.shared.log("  App ID: \(appID.name)")

                    // 使用 Apple team profile API 取得新 profile，再只安裝 profile，不重裝 App。
                    let profile = try await PaxSigningService.shared.refreshProvisioningProfile(for: appID, team: team)
                    refreshFraction = progressBase + progressSpan * 0.7
                    AppLogger.shared.log("  新 profile 已取得 (\(profile.data.count) bytes)")

                    try await misagent.installProfile(profile.data)
                    refreshFraction = progressBase + progressSpan
                    AppLogger.shared.log("  ✅ Profile 已安裝: \(bundleID)")

                    // 主頁顯示的是主 App 已安裝 profile 的日期，不是 Apple App ID 的日期。
                    if bundleID == app.bundleId,
                       let installedIndex = installedApps.firstIndex(where: { $0.id == app.id }) {
                        installedApps[installedIndex].expiresDate = profile.expirationDate
                        save()
                        let days = Calendar.current.dateComponents([.day], from: Date(), to: profile.expirationDate).day ?? 0
                        AppLogger.shared.log("  ✅ \(app.name) profile 有效期更新為 \(days) 天")
                    }
                } catch {
                    AppLogger.shared.log("  ❌ Profile 刷新失敗 \(bundleID): \(error.localizedDescription)")
                    failCount += 1
                    // 某個 extension 失敗時仍繼續刷新其餘 profiles 和 App。
                }
            }
        }
        
        // 刷新外部選中的 Bundle IDs（只換 profile，不重裝）
        for bid in externalBids {
            AppLogger.shared.log("正在刷新外部: " + bid)
            currentlyRefreshingBundleId = bid
            refreshFraction = 0.0
            do {
                let appID = try await PaxSigningService.shared.findOrCreateAppID(
                    bundleIdentifier: bid,
                    name: bid,
                    for: team
                )
                refreshFraction = 0.35
                let profile = try await PaxSigningService.shared.refreshProvisioningProfile(for: appID, team: team)
                refreshFraction = 0.7
                try await misagent.installProfile(profile.data)
                self.externalExpiry[bid] = profile.expirationDate
                saveExternalMetadata()
                let days = Calendar.current.dateComponents([.day], from: Date(), to: profile.expirationDate).day ?? 0
                AppLogger.shared.log("外部刷新成功 \(bid)，profile 有效期 \(days) 天")
                refreshFraction = 1.0
            } catch {
                AppLogger.shared.log("外部刷新失敗 " + bid + ": " + error.localizedDescription)
                failCount += 1
            }
        }
        
        misagent.disconnect()
        save()
        currentlyRefreshingBundleId = nil
        refreshTitle = ""
        isRefreshError = failCount > 0
        if failCount > 0 {
            refreshProgress = "刷新完成，\(failCount) 個失敗"
        } else {
            refreshProgress = "刷新完成"
        }
        AppLogger.shared.log("全部刷新完成")
    }
    
    /// 只刷新外部 App（不碰列表）
    func refreshExternalOnly() async {
        var failCount = 0
        let bids = externalBundleIds
        guard !bids.isEmpty else { return }
        
        isRefreshingExternal = true
        refreshFraction = 0.0
        refreshTitle = ""
        isRefreshError = false
        defer {
            isRefreshingExternal = false
            currentlyRefreshingBundleId = nil
        }
        
        AppLogger.shared.log("開始刷新外部 App...")
        
        let teams: [SideSign.Team]
        do {
            teams = try await PaxSigningService.shared.fetchTeams()
        } catch {
            AppLogger.shared.log("獲取 Team 失敗: " + error.localizedDescription)
            refreshTitle = "刷新失敗"
            isRefreshError = true
            refreshProgress = "獲取 Team 失敗"
            return
        }
        guard let team = teams.first else {
            refreshTitle = "刷新失敗"
            isRefreshError = true
            refreshProgress = "沒有可用的 Team"
            return
        }
        
        guard let pairingFile = findPairingFile() else {
            refreshTitle = "刷新失敗"
            isRefreshError = true
            refreshProgress = "找不到配對檔"
            return
        }
        
        let misagent = RustMisagentClient(host: VPNConnectionChecker.shared.effectiveGatewayHost, pairingFileURL: pairingFile)
        do {
            try await misagent.connect()
        } catch {
            AppLogger.shared.log("misagent 連接失敗: " + error.localizedDescription)
            refreshTitle = "刷新失敗"
            isRefreshError = true
            refreshProgress = "連接設備失敗"
            return
        }
        
        for bid in bids {
            currentlyRefreshingBundleId = bid
            refreshFraction = 0.0
            refreshProgress = "正在刷新 \(externalNames[bid] ?? bid)..."
            AppLogger.shared.log("正在刷新外部: " + bid)
            do {
                let appID = try await PaxSigningService.shared.findOrCreateAppID(
                    bundleIdentifier: bid,
                    name: bid,
                    for: team
                )
                refreshFraction = 0.35
                let profile = try await PaxSigningService.shared.refreshProvisioningProfile(for: appID, team: team)
                refreshFraction = 0.7
                try await misagent.installProfile(profile.data)
                externalExpiry[bid] = profile.expirationDate
                saveExternalMetadata()
                let days = Calendar.current.dateComponents([.day], from: Date(), to: profile.expirationDate).day ?? 0
                AppLogger.shared.log("外部刷新成功 \(bid)，profile 有效期 \(days) 天")
                refreshFraction = 1.0
            } catch {
                AppLogger.shared.log("外部刷新失敗: " + error.localizedDescription)
                failCount += 1
            }
        }
        
        misagent.disconnect()
        saveExternalMetadata()
        currentlyRefreshingBundleId = nil
        refreshTitle = ""
        isRefreshError = failCount > 0
        if failCount > 0 {
            refreshProgress = "刷新完成，\(failCount) 個失敗"
        } else {
            refreshProgress = "刷新完成"
        }
        AppLogger.shared.log("外部刷新完成")
    }

    /// 讀出已保存 IPA 的主 App 與巢狀 App/appex Bundle IDs；失敗時至少刷新主 App。
    private func bundleIdentifiersForRefresh(_ app: InstalledApp) -> [String] {
        if let cachedBundleIDs = refreshBundleIDCache[app.id] { return cachedBundleIDs }
        guard let ipaPath = app.ipaPath else {
            refreshBundleIDCache[app.id] = [app.bundleId]
            return [app.bundleId]
        }
        let ipaURL = URL(fileURLWithPath: ipaPath)
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            refreshBundleIDCache[app.id] = [app.bundleId]
            return [app.bundleId]
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EiliStore-Refresh-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDirectory) }
            try FileManager.default.unzipItem(at: ipaURL, to: workDirectory)

            let payloadURL = workDirectory.appendingPathComponent("Payload", isDirectory: true)
            let rootApps = try FileManager.default.contentsOfDirectory(at: payloadURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "app" }
            guard let rootApp = rootApps.first else {
                refreshBundleIDCache[app.id] = [app.bundleId]
                return [app.bundleId]
            }

            var bundleIDs: Set<String> = [app.bundleId]
            if let enumerator = FileManager.default.enumerator(at: rootApp, includingPropertiesForKeys: nil) {
                for case let bundleURL as URL in enumerator
                where bundleURL.pathExtension == "app" || bundleURL.pathExtension == "appex" {
                    let infoURL = bundleURL.appendingPathComponent("Info.plist")
                    guard let data = try? Data(contentsOf: infoURL),
                          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                          let bundleID = plist["CFBundleIdentifier"] as? String,
                          !bundleID.isEmpty else { continue }
                    bundleIDs.insert(bundleID)
                }
            }
            let resolvedBundleIDs = bundleIDs.sorted()
            refreshBundleIDCache[app.id] = resolvedBundleIDs
            return resolvedBundleIDs
        } catch {
            AppLogger.shared.log("無法從 IPA 解析擴充套件 Bundle IDs，改為只刷新主 App：\(error.localizedDescription)")
            refreshBundleIDCache[app.id] = [app.bundleId]
            return [app.bundleId]
        }
    }
    
    /// 查找配對檔
    private func findPairingFile() -> URL? {
        PairingFileStore.shared.selectedPairingFileURL()
    }
    
    /// 檢查並自動刷新（App 啟動時調用）
    /// 檢查外部選中的 App 是否快過期（1天內）
    private func checkExternalExpiry() -> Bool {
        let calendar = Calendar.current
        for bid in externalBundleIds {
            guard let expiry = externalExpiry[bid] else {
                // 首次刷新尚無本地 profile 日期時，允許自動刷新取得一份。
                return true
            }
            let days = calendar.dateComponents([.day], from: Date(), to: expiry).day ?? 999
            if days <= 1 {
                return true
            }
        }
        return false
    }
    
    func checkAndAutoRefresh() async {
        // 1. 確保 EiliStore 自己在列表裡（用於自刷新）
        ensureSelfRegistered()
        
        // 同步外部 App 名稱；到期日以已安裝 profile 的本地記錄為準。
        do {
            _ = try await syncAppIDsFromApple()
        } catch {
            AppLogger.shared.log("同步 Apple App IDs 失敗，保留本機資料: \(error.localizedDescription)")
        }
        
        AppLogger.shared.log("App 啟動，檢查 App 過期狀態...")
        var externalNeedsRefresh = false
        if enableExternalAutoRefresh && !externalBundleIds.isEmpty {
            externalNeedsRefresh = checkExternalExpiry()
        }
        if hasUpdates || externalNeedsRefresh {
            // 自動只刷1天內快過期的（內部＋外部）
            await refreshAll(includeExternal: enableExternalAutoRefresh, onlyNeedingRefresh: true)
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
