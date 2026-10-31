import Foundation
import SideSign

// MARK: - App IDs

extension PaxSigningService {
    /// 獲取 App ID 列表
    public func fetchAppIDs(for team: SideSign.Team) async throws -> [SideSign.AppID] {
        let (_, session) = try await sessionWithFreshAnisette()
        if isRustSession {
            let result = try await rustDevOp("list_app_ids", params: ["team_id": team.identifier], session: session)
            return (result["app_ids"] as? [[String: Any]] ?? []).map(rustMapAppID)
        }
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        return try await portal.fetchAppIDs(for: team, session: session)
    }
    
    /// 創建 App ID
    public func createAppID(name: String, bundleIdentifier: String, for team: SideSign.Team) async throws -> SideSign.AppID {
        // 空名稱／空 Bundle ID 送到 Apple 只會換來一句看不懂的 35
        // （'appIdentifierString' 未提供值），在本地先擋下並講清。
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SigningError.signingFailed("App 名稱是空的，請先輸入名稱再創建 App ID")
        }
        guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SigningError.signingFailed("Bundle ID 是空的，請先輸入 Bundle ID 再創建 App ID")
        }
        let (_, session) = try await sessionWithFreshAnisette()
        if isRustSession {
            let result = try await rustDevOp("add_app_id", params: [
                "team_id": team.identifier,
                "name": name,
                "identifier": bundleIdentifier,
            ], session: session)
            guard let dict = result["app_id"] as? [String: Any] else {
                throw SigningError.signingFailed("Rust Portal 未回傳 App ID")
            }
            return rustMapAppID(dict)
        }
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        return try await portal.addAppID(withName: name, bundleIdentifier: bundleIdentifier, team: team, session: session)
    }

    /// 更新 App ID（features）——syncAppGroups／enableAppGroups 啟用功能用
    public func updateAppID(_ appID: SideSign.AppID, for team: SideSign.Team) async throws -> SideSign.AppID {
        let (_, session) = try await sessionWithFreshAnisette()
        if isRustSession {
            // 只送要啟用的功能、值用 Boolean：重送 Portal 回傳的整包
            // features（字串值）會被 Apple 以 4100 拒絕；isideload
            // ensure_group_feature 只送要開的那個功能、Boolean true。
            // 本函式現行呼叫方（syncAppGroups／enableAppGroups）只啟用、不關閉。
            var featureParams: [String: Any] = [:]
            for (feature, value) in appID.features where value == "true" {
                featureParams[feature.rawValue] = true
            }
            let result = try await rustDevOp("update_app_id", params: [
                "team_id": team.identifier,
                "app_id_id": appID.identifier,
                "identifier": appID.bundleIdentifier,
                "name": appID.name,
                "features": featureParams,
            ], session: session)
            guard let dict = result["app_id"] as? [String: Any] else {
                throw SigningError.signingFailed("Rust Portal 未回傳 App ID")
            }
            return rustMapAppID(dict)
        }
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        return try await portal.updateAppID(appID, team: team, session: session)
    }
    
    /// 刪除 App ID
    public func deleteAppID(_ appID: SideSign.AppID, for team: SideSign.Team) async throws {
        let (_, session) = try await sessionWithFreshAnisette()
        if isRustSession {
            _ = try await rustDevOp("delete_app_id", params: [
                "team_id": team.identifier,
                "app_id_id": appID.identifier,
            ], session: session)
            return
        }
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        guard try await portal.deleteAppID(appID, for: team, session: session) else {
            throw SigningError.signingFailed("Apple 未確認 App ID 已刪除，請重新整理後檢查。")
        }
    }
}
