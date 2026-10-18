import Foundation
import SideSign

/// Narrow API boundary so portal state can be exercised with deterministic fakes.
public protocol DeveloperPortalServicing: Sendable {
    func fetchTeams() async throws -> [SideSign.Team]
    func fetchAppIDs(for team: SideSign.Team) async throws -> [SideSign.AppID]
    func fetchProfiles(for team: SideSign.Team) async throws -> [SideSign.ListedProvisioningProfile]
    func fetchCertificates(for team: SideSign.Team) async throws -> [SideSign.X509Certificate]
    func fetchAppGroups(for team: SideSign.Team) async throws -> [SideSign.AppGroup]
    func fetchDevices(for team: SideSign.Team) async throws -> [SideSign.Device]
    func createProfile(name: String, appID: SideSign.AppID, certificateIDs: [String], deviceIDs: [String], type: SideSign.ProfileType, for team: SideSign.Team) async throws -> SideSign.ProvisioningProfile
    func updateProfile(_ profile: SideSign.ListedProvisioningProfile, name: String, appIDId: String, certificateIDs: [String], deviceIDs: [String], type: SideSign.ProfileType, for team: SideSign.Team) async throws -> SideSign.ProvisioningProfile
    func downloadProfile(_ profile: SideSign.ListedProvisioningProfile, for team: SideSign.Team) async throws -> SideSign.ProvisioningProfile
    func generateProfile(for appID: SideSign.AppID, type: SideSign.ProfileType, team: SideSign.Team) async throws -> SideSign.ProvisioningProfile
    func deleteProfile(_ profile: SideSign.ListedProvisioningProfile, for team: SideSign.Team) async throws
    func deleteAllProfiles(_ profiles: [SideSign.ListedProvisioningProfile], for team: SideSign.Team) async -> (deletedCount: Int, failedCount: Int)
    func createAppGroup(name: String, groupIdentifier: String, for team: SideSign.Team) async throws -> SideSign.AppGroup
    func updateAppGroup(_ group: SideSign.AppGroup, name: String, for team: SideSign.Team) async throws -> SideSign.AppGroup
    func deleteAppGroup(_ group: SideSign.AppGroup, for team: SideSign.Team) async throws
    func assignAppGroups(_ groups: [SideSign.AppGroup], to appID: SideSign.AppID, for team: SideSign.Team) async throws -> SideSign.AppID
    func registerDevice(name: String, identifier: String, type: SideSign.DeviceType, for team: SideSign.Team) async throws -> SideSign.Device
    func updateDevice(_ device: SideSign.Device, name: String, for team: SideSign.Team) async throws -> SideSign.Device
    func disableDevice(_ device: SideSign.Device, for team: SideSign.Team) async throws -> SideSign.Device
    func deleteDevice(_ device: SideSign.Device, for team: SideSign.Team) async throws
}

/// 直接重用釘選 SideSign DeveloperPortal API，不另造 Apple 端點或認證流程。
public final class DeveloperPortalService: DeveloperPortalServicing, Sendable {
    public static let shared = DeveloperPortalService()
    private let portal: any SideSign.DeveloperPortalAPI
    private let sessionProvider: @Sendable () async throws -> (SideSign.Account, SideSign.Session)

    public init(portal: any SideSign.DeveloperPortalAPI = SideSign.DeveloperPortal.shared) {
        self.portal = portal
        self.sessionProvider = {
            try await PaxSigningService.shared.sessionWithFreshAnisette()
        }
    }
    init(portal: any SideSign.DeveloperPortalAPI,
         sessionProvider: @escaping @Sendable () async throws -> (SideSign.Account, SideSign.Session)) {
        self.portal = portal
        self.sessionProvider = sessionProvider
    }
    private func fresh(for team: SideSign.Team? = nil) async throws -> (SideSign.Account, SideSign.Session) {
        if let team = team { try DeveloperPortalValidation.requireIdentifier(team.identifier) }
        try Task.checkCancellation()
        let value = try await sessionProvider()
        try Task.checkCancellation()
        return value
    }
    public func fetchTeams() async throws -> [SideSign.Team] {
        let (account, session) = try await fresh()
        return try await portal.fetchTeams(for: account, session: session)
    }
    public func fetchAppIDs(for team: SideSign.Team) async throws -> [SideSign.AppID] {
        let (_, session) = try await fresh(for: team)
        return try await portal.fetchAppIDs(for: team, session: session)
    }
    public func fetchProfiles(for team: SideSign.Team) async throws -> [SideSign.ListedProvisioningProfile] {
        let (_, session) = try await fresh(for: team)
        return try await portal.listProvisioningProfiles(for: team, session: session)
    }
    public func fetchCertificates(for team: SideSign.Team) async throws -> [SideSign.X509Certificate] {
        let (_, session) = try await fresh(for: team)
        return try await portal.fetchCertificates(for: team, session: session)
    }
    public func fetchAppGroups(for team: SideSign.Team) async throws -> [SideSign.AppGroup] {
        let (_, session) = try await fresh(for: team)
        return try await portal.fetchAppGroups(for: team, session: session)
    }
    public func fetchDevices(for team: SideSign.Team) async throws -> [SideSign.Device] {
        let (_, session) = try await fresh(for: team)
        return try await portal.fetchDevices(for: team, types: .all, session: session)
    }
    private func validateProfile(name: String, appID: String, certificateIDs: [String], deviceIDs: [String], type: SideSign.ProfileType, team: SideSign.Team) throws {
        try DeveloperPortalValidation.validateName(name)
        try DeveloperPortalValidation.requireIdentifier(appID)
        guard SideSign.ProfileType.allCases.contains(type), !(team.type == .free && type.isPaidOnly),
              !certificateIDs.isEmpty,
              type.acceptedDeviceTypes == SideSign.DeviceType.none || !deviceIDs.isEmpty else {
            throw DeveloperPortalValidationError.invalidProfileConfiguration
        }
        for value in certificateIDs + deviceIDs { try DeveloperPortalValidation.requireIdentifier(value) }
    }
    public func createProfile(name: String, appID: SideSign.AppID, certificateIDs: [String], deviceIDs: [String], type: SideSign.ProfileType, for team: SideSign.Team) async throws -> SideSign.ProvisioningProfile {
        try validateProfile(name: name, appID: appID.identifier, certificateIDs: certificateIDs, deviceIDs: deviceIDs, type: type, team: team)
        let (_, session) = try await fresh(for: team)
        return try await portal.createProvisioningProfile(name: name, appID: appID, certificateIDs: certificateIDs, deviceIDs: deviceIDs, type: type, team: team, session: session)
    }
    public func updateProfile(_ profile: SideSign.ListedProvisioningProfile, name: String, appIDId: String, certificateIDs: [String], deviceIDs: [String], type: SideSign.ProfileType, for team: SideSign.Team) async throws -> SideSign.ProvisioningProfile {
        guard let id = profile.identifier, !id.isEmpty else { throw DeveloperPortalValidationError.missingProfileIdentifier }
        try DeveloperPortalValidation.requireIdentifier(id)
        try validateProfile(name: name, appID: appIDId, certificateIDs: certificateIDs, deviceIDs: deviceIDs, type: type, team: team)
        let (_, session) = try await fresh(for: team)
        return try await portal.updateProvisioningProfile(profileID: id, name: name, appIDId: appIDId, certificateIDs: certificateIDs, deviceIDs: deviceIDs, type: type, team: team, session: session)
    }
    private func profileIdentifier(_ profile: SideSign.ListedProvisioningProfile) throws -> String {
        guard let id = profile.identifier, !id.isEmpty else { throw DeveloperPortalValidationError.missingProfileIdentifier }
        try DeveloperPortalValidation.requireIdentifier(id)
        return id
    }
    public func downloadProfile(_ profile: SideSign.ListedProvisioningProfile, for team: SideSign.Team) async throws -> SideSign.ProvisioningProfile {
        let id = try profileIdentifier(profile)
        let (_, session) = try await fresh(for: team)
        return try await portal.downloadProvisioningProfile(profileID: id, team: team, session: session)
    }
    public func generateProfile(for appID: SideSign.AppID, type: SideSign.ProfileType = .iOS, team: SideSign.Team) async throws -> SideSign.ProvisioningProfile {
        try DeveloperPortalValidation.requireIdentifier(appID.identifier)
        guard SideSign.ProfileType.allCases.contains(type), !(team.type == .free && type.isPaidOnly) else { throw DeveloperPortalValidationError.invalidProfileConfiguration }
        let (_, session) = try await fresh(for: team)
        return try await portal.downloadProvisioningProfile(for: appID, type: type, team: team, session: session)
    }
    public func deleteProfile(_ profile: SideSign.ListedProvisioningProfile, for team: SideSign.Team) async throws {
        let id = try profileIdentifier(profile)
        let (_, session) = try await fresh(for: team)
        guard try await portal.deleteProvisioningProfile(profileID: id, team: team, session: session) else { throw DeveloperPortalValidationError.operationFailed }
    }
    public func deleteAllProfiles(_ profiles: [SideSign.ListedProvisioningProfile], for team: SideSign.Team) async -> (deletedCount: Int, failedCount: Int) {
        var deleted = 0
        var failed = 0
        for (index, profile) in profiles.enumerated() {
            if Task.isCancelled { failed += profiles.count - index; break }
            do { try await deleteProfile(profile, for: team); deleted += 1 }
            catch is CancellationError { failed += profiles.count - index; break }
            catch { failed += 1 }
        }
        return (deleted, failed)
    }
    public func createAppGroup(name: String, groupIdentifier: String, for team: SideSign.Team) async throws -> SideSign.AppGroup {
        try DeveloperPortalValidation.validateName(name)
        try DeveloperPortalValidation.validateAppGroupIdentifier(groupIdentifier)
        let (_, session) = try await fresh(for: team)
        return try await portal.addAppGroup(name: name, groupIdentifier: groupIdentifier, team: team, session: session)
    }
    public func updateAppGroup(_ group: SideSign.AppGroup, name: String, for team: SideSign.Team) async throws -> SideSign.AppGroup {
        try DeveloperPortalValidation.validateName(name)
        try DeveloperPortalValidation.requireIdentifier(group.groupID)
        var updated = group
        updated.name = name
        let (_, session) = try await fresh(for: team)
        return try await portal.updateAppGroup(updated, team: team, session: session)
    }
    public func deleteAppGroup(_ group: SideSign.AppGroup, for team: SideSign.Team) async throws {
        try DeveloperPortalValidation.requireIdentifier(group.groupID)
        let (_, session) = try await fresh(for: team)
        guard try await portal.deleteAppGroup(group, team: team, session: session) else { throw DeveloperPortalValidationError.operationFailed }
    }
    public func assignAppGroups(_ groups: [SideSign.AppGroup], to appID: SideSign.AppID, for team: SideSign.Team) async throws -> SideSign.AppID {
        try DeveloperPortalValidation.requireIdentifier(appID.identifier)
        for group in groups { try DeveloperPortalValidation.requireIdentifier(group.groupID) }
        let (_, enablingSession) = try await fresh(for: team)
        var enabled = appID.copy()
        // 僅送 App Groups 功能，避免重送 Portal 回傳的整包 features 引發 4100。
        enabled.features = [.appGroups: "true"]
        let updated = try await portal.updateAppID(enabled, team: team, session: enablingSession)
        let (_, assignmentSession) = try await fresh(for: team)
        return try await portal.assignAppGroups(groups, to: updated, team: team, session: assignmentSession)
    }
    public func registerDevice(name: String, identifier: String, type: SideSign.DeviceType, for team: SideSign.Team) async throws -> SideSign.Device {
        try DeveloperPortalValidation.validateName(name)
        try DeveloperPortalValidation.validateDeviceIdentifier(identifier)
        guard [SideSign.DeviceType.iPhone, .iPad, .appleTV, .appleWatch, .mac, .visionPro].contains(type) else { throw DeveloperPortalValidationError.invalidDeviceIdentifier }
        let (_, session) = try await fresh(for: team)
        return try await portal.registerDevice(name: name, identifier: identifier, type: type, team: team, session: session)
    }
    public func updateDevice(_ device: SideSign.Device, name: String, for team: SideSign.Team) async throws -> SideSign.Device {
        try DeveloperPortalValidation.validateName(name)
        try DeveloperPortalValidation.requireIdentifier(device.identifier)
        var updated = device
        updated.name = name
        let (_, session) = try await fresh(for: team)
        return try await portal.updateDevice(updated, team: team, session: session)
    }
    public func disableDevice(_ device: SideSign.Device, for team: SideSign.Team) async throws -> SideSign.Device {
        try DeveloperPortalValidation.requireIdentifier(device.identifier)
        let (_, session) = try await fresh(for: team)
        return try await portal.disableDevice(device, team: team, session: session)
    }
    public func deleteDevice(_ device: SideSign.Device, for team: SideSign.Team) async throws {
        try DeveloperPortalValidation.requireIdentifier(device.identifier)
        let (_, session) = try await fresh(for: team)
        guard try await portal.deleteDevice(device, team: team, session: session) else { throw DeveloperPortalValidationError.operationFailed }
    }
}
