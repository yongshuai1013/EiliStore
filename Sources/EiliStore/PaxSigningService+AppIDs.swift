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
            var featureParams: [String: Any] = [:]
            for (feature, value) in appID.features { featureParams[feature.rawValue] = value }
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
