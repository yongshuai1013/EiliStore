import SwiftUI

// Deliberately inert destination stubs: navigation coverage does not execute native services.
struct MyAppsView: View {
    @State private var opensIPA = false
    var body: some View {
        NavigationView {
            Button("Open IPA import") { opensIPA = true }
                .accessibilityIdentifier("harness-open-ipa-import")
                .sheet(isPresented: $opensIPA) {
                    NavigationView { SignIPAView() }
                        .navigationViewStyle(.stack)
                }
        }
    }
}
struct SourcesView: View { var body: some View { NavigationView { Text("Sources") } } }
struct SignInstallView: View { var body: some View { NavigationView { Text("Sign") } } }
struct AccountView: View { let appleID: Binding<String>; let isLoggedIn: Binding<Bool>; var body: some View { Text("Account") } }
struct LoginView: View { let appleID: Binding<String>; let isLoggedIn: Binding<Bool>; var body: some View { Text("Login") } }
struct DeveloperPortalView: View { var body: some View { Text("Developer Portal") } }
struct CertificateView: View { var body: some View { Text("Certificates") } }
struct AppIDsView: View { var body: some View { Text("App IDs") } }
struct AnisetteServerView: View { var body: some View { Text("Anisette Servers") } }
struct ConnectionConfigView: View { var body: some View { Text("Connection") } }
struct PairingFileManagementView: View { var body: some View { Text("Pairing") } }
struct FileBrowserView: View { let directory: URL; var body: some View { Text("Files") } }
struct LogView: View { var body: some View { Text("Logs") } }
struct AnisetteClientConfigurationView: View { var body: some View { Text("Anisette Client Configuration") } }
struct SideSignClientConfigurationView: View { var body: some View { Text("SideSign Client Configuration") } }

enum IPAParser {
    struct AppInfo: Sendable { let name: String; let bundleId: String; let version: String }
    enum SyntheticError: Error { case parsingUnavailable }
    static func parse(ipaURL: URL, requireInstallableMetadata: Bool) throws -> AppInfo {
        throw SyntheticError.parsingUnavailable
    }
}
@MainActor final class SourceAppInstaller: ObservableObject {
    static let shared = SourceAppInstaller()
    @Published var isWorking = false
    @Published var statusMessage = ""
    @Published var progress: Double = -1
    func installImportedIPA(at url: URL) async { /* Deliberately inert. */ }
}

enum EiliAnisetteMode: String { case remote, onDevice; static let preferenceKey = "anisette.mode"; static let localBuildAvailable = true }
enum EiliLoginMethod: String { case sideSign, rust; static let preferenceKey = "login.method" }
enum EiliAnisetteLibraryStatus { case engineUnavailable, missing, invalid, present, incompatible(String) }
enum EiliAnisetteError: LocalizedError { case unavailable; var errorDescription: String? { "Unavailable" } }
struct ADIRuntimeLibraryDownloader { enum DownloadError: LocalizedError { case unavailable; var errorDescription: String? { "Unavailable" } } }
final class EiliAnisetteService {
    static let shared = EiliAnisetteService()
    func localLibraryStatus() async -> EiliAnisetteLibraryStatus { .missing }
    func localStorageStatus() async -> EiliAnisetteStorageStatus { .init(cache: .missing, provisioningPresent: false, automaticAcquisition: false) }
    func ensureLibraries(force: Bool = false) async throws -> EiliAnisetteLibraryStatus { .missing }
    func importLibraries(_ urls: [URL]) async throws -> EiliAnisetteLibraryStatus { .missing }
    func downloadLibraries() async throws -> EiliAnisetteLibraryStatus { .missing }
    func resetLocal() async throws {}
}
final class PaxAuthService {
    static let shared = PaxAuthService()
    var hasSavedSession = false
    var currentAppleID: String? = nil
}

struct EiliODASourceConfiguration: Sendable {
    static let catalogURLKey = "paxstore.anisette.catalogURL"
    static let sourceURLKey = "eilistore.anisette.oda.sourceURL"
    static let fallbackURLKey = "eilistore.anisette.oda.fallbackURL"
    static let automaticAcquisitionKey = "eilistore.anisette.oda.automaticAcquisition"
    static let defaultCatalogURLString = "https://servers.sidestore.io/servers.json"
    static let defaultFallbackURLString = "https://zzz.haus/oda.json"
    let sourceURL: URL
    let fallbackURL: URL?
    let automaticAcquisition: Bool
    enum ValidationError: LocalizedError { case insecureSource, insecureFallback
        var errorDescription: String? { switch self { case .insecureSource: return "ODA 來源必須是沒有帳號密碼的 HTTPS 網址。"; case .insecureFallback: return "ODA 備援來源必須是沒有帳號密碼的 HTTPS 網址。" } }
    }
    static var selected: Self {
        let defaults = UserDefaults.standard
        let catalog = defaults.string(forKey: catalogURLKey) ?? defaultCatalogURLString
        let source = defaults.string(forKey: sourceURLKey) ?? catalog
        let fallback = defaults.string(forKey: fallbackURLKey) ?? defaultFallbackURLString
        return Self(sourceURL: URL(string: source) ?? URL(string: "invalid:")!, fallbackURL: URL(string: fallback) ?? URL(string: "invalid:")!, automaticAcquisition: defaults.bool(forKey: automaticAcquisitionKey))
    }
    func validated() throws -> Self {
        guard Self.secure(sourceURL) else { throw ValidationError.insecureSource }
        if let fallbackURL, !Self.secure(fallbackURL) { throw ValidationError.insecureFallback }
        return self
    }
    private static func secure(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty && url.user == nil && url.password == nil }
}
struct EiliAnisetteStorageStatus: Sendable {
    let cache: EiliAnisetteLibraryStatus
    let provisioningPresent: Bool
    let automaticAcquisition: Bool
}

struct ODALibraryView: View { var body: some View { Text("Library Source") } }
struct RustLoginSettingsView: View { var body: some View { Text("Rust Login Settings") } }

struct AnisetteDeviceProfileView: View { var body: some View { Text("Device Profile") } }
