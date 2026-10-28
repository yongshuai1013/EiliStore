import SideSign
public final class PaxSigningService: @unchecked Sendable {
    public static let shared = PaxSigningService()
    public var isRustSession: Bool { false }
    public func sessionWithFreshAnisette() async throws -> (SideSign.Account, SideSign.Session) { throw SideSign.StubError.unconfigured }
    public func rustTeams(account: SideSign.Account, session: SideSign.Session) async throws -> [SideSign.Team] { throw SideSign.StubError.unconfigured }
    public func rustListAppIDs(team: SideSign.Team, session: SideSign.Session) async throws -> [SideSign.AppID] { throw SideSign.StubError.unconfigured }
    public func rustListProfiles(team: SideSign.Team, session: SideSign.Session) async throws -> [SideSign.ListedProvisioningProfile] { throw SideSign.StubError.unconfigured }
    public func rustFetchCertificates(team: SideSign.Team, session: SideSign.Session) async throws -> [SideSign.X509Certificate] { throw SideSign.StubError.unconfigured }
    public func rustListAppGroups(team: SideSign.Team, session: SideSign.Session) async throws -> [SideSign.AppGroup] { throw SideSign.StubError.unconfigured }
    public func rustListDevices(team: SideSign.Team, session: SideSign.Session) async throws -> [SideSign.Device] { throw SideSign.StubError.unconfigured }
    public func rustCreateProfile(name: String, appID: SideSign.AppID, certificateIDs: [String], deviceIDs: [String], team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.ProvisioningProfile { throw SideSign.StubError.unconfigured }
    public func rustUpdateProfile(profileID: String, name: String, appIDId: String, certificateIDs: [String], deviceIDs: [String], team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.ProvisioningProfile { throw SideSign.StubError.unconfigured }
    public func rustDownloadProfile(profileID: String, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.ProvisioningProfile { throw SideSign.StubError.unconfigured }
    public func rustGenerateProfile(appID: SideSign.AppID, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.ProvisioningProfile { throw SideSign.StubError.unconfigured }
    public func rustDeleteProfile(profileID: String, team: SideSign.Team, session: SideSign.Session) async throws { throw SideSign.StubError.unconfigured }
    public func rustCreateAppGroup(name: String, groupIdentifier: String, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.AppGroup { throw SideSign.StubError.unconfigured }
    public func rustUpdateAppGroup(_ group: SideSign.AppGroup, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.AppGroup { throw SideSign.StubError.unconfigured }
    public func rustDeleteAppGroup(_ group: SideSign.AppGroup, team: SideSign.Team, session: SideSign.Session) async throws { throw SideSign.StubError.unconfigured }
    public func rustAssignAppGroups(_ groups: [SideSign.AppGroup], to appID: SideSign.AppID, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.AppID { throw SideSign.StubError.unconfigured }
    public func rustRegisterDevice(name: String, identifier: String, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.Device { throw SideSign.StubError.unconfigured }
    public func rustUpdateDevice(_ device: SideSign.Device, name: String, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.Device { throw SideSign.StubError.unconfigured }
    public func rustDisableDevice(_ device: SideSign.Device, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.Device { throw SideSign.StubError.unconfigured }
    public func rustDeleteDevice(_ device: SideSign.Device, team: SideSign.Team, session: SideSign.Session) async throws { throw SideSign.StubError.unconfigured }
}
