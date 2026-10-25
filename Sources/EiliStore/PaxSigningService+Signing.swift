import Foundation
import SideSign

// MARK: - Signing Flow

extension PaxSigningService {
    /// 查找或創建 App ID
    public func findOrCreateAppID(bundleIdentifier: String, name: String, for team: SideSign.Team) async throws -> SideSign.AppID {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        
        let existing = try await portal.fetchAppIDs(for: team, session: session)
        if let found = existing.first(where: { SigningBundleIdentifiers.matches($0.bundleIdentifier, bundleIdentifier) }) {
            return found
        }
        
        // Apple 要求名字只能含字母數字和空格，把 bundle ID 的點換成空格
        let sanitizedName = name.replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return try await portal.addAppID(withName: sanitizedName, bundleIdentifier: bundleIdentifier, team: team, session: session)
    }
    
    /// 只開啟 App Groups 單一開關（不重送整包 features，避免 4100）
    public func enableAppGroups(for appID: SideSign.AppID, team: SideSign.Team) async throws -> SideSign.AppID {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        
        var modified = appID.copy()
        modified.features = [SideSign.Feature.appGroups: "true"]
        return try await portal.updateAppID(modified, team: team, session: session)
    }
    
    /// 查找或創建 App Group
    public func findOrCreateAppGroup(identifier: String, name: String, for team: SideSign.Team) async throws -> SideSign.AppGroup {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        
        let existing = try await portal.fetchAppGroups(for: team, session: session)
        if let found = existing.first(where: { $0.identifier == identifier }) {
            return found
        }
        
        return try await portal.addAppGroup(name: name, groupIdentifier: identifier, team: team, session: session)
    }
    
    /// 指派 App Groups 到 App ID
    public func assignAppGroups(_ groups: [SideSign.AppGroup], to appID: SideSign.AppID, for team: SideSign.Team) async throws -> SideSign.AppID {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        return try await portal.assignAppGroups(groups, to: appID, team: team, session: session)
    }
    
    /// 獲取 provisioning profile（查找或創建，然後下載）
    public func provisioningProfile(for appID: SideSign.AppID, team: SideSign.Team) async throws -> SideSign.ProvisioningProfile {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        
        // 查找現有
        let existing = try await portal.listProvisioningProfiles(for: team, session: session)
        AppLogger.shared.log("現有 profile 數量: \(existing.count)，目標: \(appID.bundleIdentifier)")
        for p in existing {
            AppLogger.shared.log("  - \(p.name ?? "?") [\(p.bundleIdentifier ?? "?")]")
        }
        let matches = existing.filter { $0.bundleIdentifier == appID.bundleIdentifier }
        if let found = matches.first {
            // 如果有多個重複的，刪掉多餘的只留一個
            if matches.count > 1 {
                for dup in matches.dropFirst() {
                    if let dupID = dup.identifier {
                        try? await portal.deleteProvisioningProfile(profileID: dupID, team: team, session: session)
                    }
                }
            }
            guard let profileID = found.identifier else { throw SigningError.profileFailed("Profile 缺少 ID") }
            return try await portal.downloadProvisioningProfile(profileID: profileID, team: team, session: session)
        }
        // 創建前清掉所有重複：同 bundleID、同名、或名字包含 bundleID 的都刪（避免 Apple 報 duplicate 35）
        let profileName = "EiliStore \(appID.bundleIdentifier)"
        for p in existing where p.bundleIdentifier == appID.bundleIdentifier || p.name == profileName {
            if let pid = p.identifier {
                AppLogger.shared.log("刪除重複 profile: \(p.name ?? "") (\(pid))")
                do {
                    try await portal.deleteProvisioningProfile(profileID: pid, team: team, session: session)
                    AppLogger.shared.log("已刪除: \(pid)")
                } catch {
                    AppLogger.shared.log("刪除失敗 \(pid): \(error.localizedDescription)")
                }
            } else {
                AppLogger.shared.log("profile 無 ID，跳過: \(p.name ?? "")")
            }
        }
        // 重新拉取列表確認（清不乾淨也不硬擋，交給下方 create 的 duplicate 恢復處理）
        let existing2 = try await portal.listProvisioningProfiles(for: team, session: session)
        let stillDup = existing2.filter { $0.name == profileName }
        if !stillDup.isEmpty {
            AppLogger.shared.log("警告: 清理後仍有 \(stillDup.count) 份同名 profile，繼續嘗試創建（失敗會走 duplicate 恢復）")
        }

        // 需要證書 ID 來創建 profile
        let certs = try await portal.fetchCertificates(for: team, session: session)
        guard let cert = certs.first, let certID = cert.identifier else {
            throw SigningError.certificateFailed("沒有可用證書")
        }

        var deviceIDs = try await portal.fetchDevices(for: team, session: session).compactMap { $0.deviceID }
        if deviceIDs.isEmpty {
            // 沒有設備，拋出明確錯誤（需要用戶提供 UDID 註冊）
            throw SigningError.profileFailed("團隊沒有註冊的設備，請先在下方輸入設備 UDID 註冊")
        }

        func isDuplicateError(_ error: Error) -> Bool {
            let text = error.localizedDescription + " " + String(describing: error)
            return text.contains("Multiple profiles") || text.contains("(35)") || text.localizedCaseInsensitiveContains("duplicate")
        }
        func createProfile(name: String) async throws -> SideSign.ProvisioningProfile {
            try await portal.createProvisioningProfile(
                name: name,
                appID: appID,
                certificateIDs: [certID],
                deviceIDs: deviceIDs,
                team: team,
                session: session
            )
        }
        let newProfile: SideSign.ProvisioningProfile
        do {
            newProfile = try await createProfile(name: profileName)
        } catch {
            guard isDuplicateError(error) else { throw error }
            AppLogger.shared.log("創建撞 duplicate(35)，重新拉清單強力清理後重試: \(profileName)")
            let latest = try await portal.listProvisioningProfiles(for: team, session: session)
            for p in latest where p.name == profileName || p.name.hasPrefix(profileName) || p.bundleIdentifier == appID.bundleIdentifier {
                if let pid = p.identifier {
                    try? await portal.deleteProvisioningProfile(profileID: pid, team: team, session: session)
                }
            }
            do {
                newProfile = try await createProfile(name: profileName)
            } catch {
                guard isDuplicateError(error) else { throw error }
                // 清單看不到的殘留同名 profile：換上帶時間戳的唯一名，保證能建出來
                let stamp = DateFormatter()
                stamp.dateFormat = "MMddHHmmss"
                let fallbackName = "\(profileName) \(stamp.string(from: Date()))"
                AppLogger.shared.log("同名仍撞，改用唯一名稱創建: \(fallbackName)")
                newProfile = try await createProfile(name: fallbackName)
            }
        }
        guard let newProfileID = newProfile.identifier else { throw SigningError.profileFailed("新 Profile 缺少 ID") }
        return try await portal.downloadProvisioningProfile(profileID: newProfileID, team: team, session: session)
    }

    /// 刷新已安裝 App 時，使用 Apple 的 team profile API 取得新 profile。
    /// 這和一般簽 IPA 時重用／建立 portal 手動 profile 的流程分開；不會刪除 Apple 端資料。
    public func refreshProvisioningProfile(for appID: SideSign.AppID, team: SideSign.Team) async throws -> SideSign.ProvisioningProfile {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        return try await portal.downloadProvisioningProfile(
            for: appID,
            isTeamProfile: true,
            team: team,
            session: session
        )
    }
    
    /// 註冊設備
    public func registerDevice(udid: String, name: String, for team: SideSign.Team) async throws -> SideSign.Device {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        return try await portal.registerDevice(name: name, identifier: udid, type: .iPhone, team: team, session: session)
    }
    
    /// 獲取已註冊設備
    public func fetchDevices(for team: SideSign.Team) async throws -> [SideSign.Device] {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        return try await portal.fetchDevices(for: team, session: session)
    }
}
