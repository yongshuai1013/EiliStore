import Foundation
import SideSign

// These declarations are compiled in the test executable; framework modules are temporary stubs.
struct SourceApp { let name: String; let bundleId: String; let downloadURL: String }
struct IPAParser {
    struct AppInfo: Sendable { let name: String; let bundleId: String; let version: String = "1"; let iconData: Data? = nil; let expirationDate: Date? = nil }
    static var shouldFail = false
    static var requireMetadataCalls = 0
    static func parse(ipaURL: URL, requireInstallableMetadata: Bool = false) throws -> AppInfo {
        if requireInstallableMetadata { requireMetadataCalls += 1 }
        if shouldFail { throw NSError(domain: "parse", code: 1) }
        return AppInfo(name: "Fixture App", bundleId: ProcessInfo.processInfo.environment["IPA_TEST_BUNDLE_ID"]!)
    }
}
struct InstalledApp {
    let name: String; let bundleId: String; let team: String; let expiresDate: Date; let ipaPath: String; let iconPath: String?
    init(name: String, bundleId: String, team: String, expiresDate: Date, ipaPath: String, iconPath: String?) { self.name=name; self.bundleId=bundleId; self.team=team; self.expiresDate=expiresDate; self.ipaPath=ipaPath; self.iconPath=iconPath }
}
final class AppManager { static let shared=AppManager(); var count=0; func addApp(_ app: InstalledApp) { count += 1 } }
final class AppLogger { static let shared=AppLogger(); func log(_ message: String) {} }
final class AppInstaller {
    static let shared=AppInstaller(); var count=0; var shouldFail=false
    func install(ipaURL: URL, progress: (String, Int) -> Void) async throws { count += 1; progress("installing", 50); if shouldFail { throw NSError(domain:"install",code:1) } }
}
final class PaxSigningService {
    static let shared=PaxSigningService(); var events:[String]=[]; var failAt:String?
    var pause: DispatchSemaphore?; var resume: DispatchSemaphore?
    func fetchTeams() async throws -> [SideSign.Team] { events.append("fetchTeams"); if let pause { pause.signal(); try await Task.sleep(nanoseconds: 300_000_000); _ = resume }; if failAt == "fetchTeams" { throw NSError(domain:"sign",code:1) }; return [SideSign.Team()] }
    func loadActiveCertificate() -> SideSign.KeyStore? { events.append("loadActiveCert"); return failAt == "loadActiveCert" ? nil : SideSign.KeyStore() }
    func findOrCreateAppID(bundleIdentifier:String,name:String,for team:SideSign.Team) async throws -> String { events.append("findOrCreateAppID"); if failAt == "findOrCreateAppID" { throw NSError(domain:"sign",code:1) }; return bundleIdentifier }
    func provisioningProfile(for appID:String,team:SideSign.Team) async throws -> SideSign.ProvisioningProfile { events.append("profile"); if failAt == "profile" { throw NSError(domain:"sign",code:1) }; return SideSign.ProvisioningProfile(bundleIdentifier:appID) }
}
