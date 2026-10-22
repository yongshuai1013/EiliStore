import Foundation
import SideSign

// MARK: - App IDs

extension PaxSigningService {
    /// 獲取 App ID 列表
    public func fetchAppIDs(for team: SideSign.Team) async throws -> [SideSign.AppID] {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        return try await portal.fetchAppIDs(for: team, session: session)
    }
    
    /// 創建 App ID
    public func createAppID(name: String, bundleIdentifier: String, for team: SideSign.Team) async throws -> SideSign.AppID {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        return try await portal.addAppID(withName: name, bundleIdentifier: bundleIdentifier, team: team, session: session)
    }
    
    /// 刪除 App ID
    public func deleteAppID(_ appID: SideSign.AppID, for team: SideSign.Team) async throws {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        guard try await portal.deleteAppID(appID, for: team, session: session) else {
            throw SigningError.signingFailed("Apple 未確認 App ID 已刪除，請重新整理後檢查。")
        }
    }
}
