import Foundation
import SideSign

// MARK: - Signing Flow

extension PaxSigningService {
    /// 查找或創建 App ID
    public func findOrCreateAppID(bundleIdentifier: String, name: String, for team: SideSign.Team) async throws -> SideSign.AppID {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = SideSign.DeveloperPortal.shared
        
        let existing = try await portal.fetchAppIDs(for: team, session: session)
        if let found = existing.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
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
        let portal = SideSign.DeveloperPortal.shared
        
        var modified = appID.copy()
        modified.features = [SideSign.Feature.appGroups: "true"]
        return try await portal.updateAppID(modified, team: team, session: session)
    }
    
    /// 查找或創建 App Group
    public func findOrCreateAppGroup(identifier: String, name: String, for team: SideSign.Team) async throws -> SideSign.AppGroup {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = SideSign.DeveloperPortal.shared
        
        let existing = try await portal.fetchAppGroups(for: team, session: session)
        if let found = existing.first(where: { $0.identifier == identifier }) {
            return found
        }
        
        return try await portal.addAppGroup(name: name, groupIdentifier: identifier, team: team, session: session)
    }
    
    /// 指派 App Groups 到 App ID
    public func assignAppGroups(_ groups: [SideSign.AppGroup], to appID: SideSign.AppID, for team: SideSign.Team) async throws -> SideSign.AppID {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = SideSign.DeveloperPortal.shared
        return try await portal.assignAppGroups(groups, to: appID, team: team, session: session)
    }
    
    /// 獲取 provisioning profile（查找或創建，然後下載）
    public func provisioningProfile(for appID: SideSign.AppID, team: SideSign.Team) async throws -> SideSign.ProvisioningProfile {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = SideSign.DeveloperPortal.shared
        
        // 查找現有
        let existing = try await portal.listProvisioningProfiles(for: team, session: session)
        if let found = existing.first(where: { $0.bundleIdentifier == appID.bundleIdentifier }) {
            guard let profileID = found.identifier else { throw SigningError.profileFailed("Profile 缺少 ID") }
            return try await portal.downloadProvisioningProfile(profileID: profileID, team: team, session: session)
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
        
        let newProfile = try await portal.createProvisioningProfile(
            name: "PaxStore \(appID.bundleIdentifier)",
            appID: appID,
            certificateIDs: [certID],
            deviceIDs: deviceIDs,
            team: team,
            session: session
        )
        guard let newProfileID = newProfile.identifier else { throw SigningError.profileFailed("新 Profile 缺少 ID") }
        return try await portal.downloadProvisioningProfile(profileID: newProfileID, team: team, session: session)
    }
    
    /// 註冊設備
    public func registerDevice(udid: String, name: String, for team: SideSign.Team) async throws -> SideSign.Device {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = SideSign.DeveloperPortal.shared
        return try await portal.registerDevice(name: name, identifier: udid, type: .iPhone, team: team, session: session)
    }
    
    /// 獲取已註冊設備
    public func fetchDevices(for team: SideSign.Team) async throws -> [SideSign.Device] {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = SideSign.DeveloperPortal.shared
        return try await portal.fetchDevices(for: team, session: session)
    }
}
