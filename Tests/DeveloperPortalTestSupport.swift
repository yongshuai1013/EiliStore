import Foundation
import SideSign

// Test-only stand-ins: these compile the real model but do not validate an iOS build or SideSign wire behavior.
public enum PortalTestError: Error { case secretFailure }

public actor FakeDeveloperPortalService: DeveloperPortalServicing {
    public var teamResults: [SideSign.Team] = []
    public var appIDResults: [String: [SideSign.AppID]] = [:]
    public var profileResults: [String: [SideSign.ListedProvisioningProfile]] = [:]
    public var certificateResults: [String: [SideSign.X509Certificate]] = [:]
    public var groupResults: [String: [SideSign.AppGroup]] = [:]
    public var deviceResults: [String: [SideSign.Device]] = [:]
    public var failingSections: Set<String> = []
    public var blockedTeam: String?
    public var blockedContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    public var fetchTeamCount = 0
    public var sectionCalls: [String: Int] = [:]

    public init() {}
    public func fetchTeams() async throws -> [SideSign.Team] { fetchTeamCount += 1; return teamResults }
    private func check(_ section: String, _ team: SideSign.Team) async throws {
        sectionCalls[section, default: 0] += 1
        if blockedTeam == team.identifier && section == "appIDs" { await withCheckedContinuation { blockedContinuations[team.identifier + ":" + section] = $0 } }
        if failingSections.contains(section) { throw PortalTestError.secretFailure }
    }
    public func releaseBlockedFetch() { for (_, continuation) in blockedContinuations { continuation.resume() }; blockedContinuations.removeAll() }
    public func fetchAppIDs(for team: SideSign.Team) async throws -> [SideSign.AppID] { try await check("appIDs", team); return appIDResults[team.identifier] ?? [] }
    public func fetchProfiles(for team: SideSign.Team) async throws -> [SideSign.ListedProvisioningProfile] { try await check("profiles", team); return profileResults[team.identifier] ?? [] }
    public func fetchCertificates(for team: SideSign.Team) async throws -> [SideSign.X509Certificate] { try await check("certificates", team); return certificateResults[team.identifier] ?? [] }
    public func fetchAppGroups(for team: SideSign.Team) async throws -> [SideSign.AppGroup] { try await check("appGroups", team); return groupResults[team.identifier] ?? [] }
    public func fetchDevices(for team: SideSign.Team) async throws -> [SideSign.Device] { try await check("devices", team); return deviceResults[team.identifier] ?? [] }
}

// The production service protocol is extracted verbatim by the runner; these defaults keep the fake focused on reads.
extension DeveloperPortalServicing {
    public func createProfile(name: String, appID: SideSign.AppID, certificateIDs: [String], deviceIDs: [String], type: SideSign.ProfileType, for team: SideSign.Team) async throws -> SideSign.ProvisioningProfile { throw PortalTestError.secretFailure }
    public func updateProfile(_ profile: SideSign.ListedProvisioningProfile, name: String, appIDId: String, certificateIDs: [String], deviceIDs: [String], type: SideSign.ProfileType, for team: SideSign.Team) async throws -> SideSign.ProvisioningProfile { throw PortalTestError.secretFailure }
    public func downloadProfile(_ profile: SideSign.ListedProvisioningProfile, for team: SideSign.Team) async throws -> SideSign.ProvisioningProfile { throw PortalTestError.secretFailure }
    public func generateProfile(for appID: SideSign.AppID, type: SideSign.ProfileType, team: SideSign.Team) async throws -> SideSign.ProvisioningProfile { throw PortalTestError.secretFailure }
    public func deleteProfile(_ profile: SideSign.ListedProvisioningProfile, for team: SideSign.Team) async throws {}
    public func deleteAllProfiles(_ profiles: [SideSign.ListedProvisioningProfile], for team: SideSign.Team) async -> (deletedCount: Int, failedCount: Int) { (0, profiles.count) }
    public func createAppGroup(name: String, groupIdentifier: String, for team: SideSign.Team) async throws -> SideSign.AppGroup { throw PortalTestError.secretFailure }
    public func updateAppGroup(_ group: SideSign.AppGroup, name: String, for team: SideSign.Team) async throws -> SideSign.AppGroup { throw PortalTestError.secretFailure }
    public func deleteAppGroup(_ group: SideSign.AppGroup, for team: SideSign.Team) async throws {}
    public func assignAppGroups(_ groups: [SideSign.AppGroup], to appID: SideSign.AppID, for team: SideSign.Team) async throws -> SideSign.AppID { throw PortalTestError.secretFailure }
    public func registerDevice(name: String, identifier: String, type: SideSign.DeviceType, for team: SideSign.Team) async throws -> SideSign.Device { throw PortalTestError.secretFailure }
    public func updateDevice(_ device: SideSign.Device, name: String, for team: SideSign.Team) async throws -> SideSign.Device { throw PortalTestError.secretFailure }
    public func disableDevice(_ device: SideSign.Device, for team: SideSign.Team) async throws -> SideSign.Device { throw PortalTestError.secretFailure }
    public func deleteDevice(_ device: SideSign.Device, for team: SideSign.Team) async throws {}
}
