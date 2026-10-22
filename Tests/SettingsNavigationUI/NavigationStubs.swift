import SwiftUI

// Deliberately inert destination stubs: navigation coverage does not execute native services.
struct MyAppsView: View { var body: some View { NavigationView { Text("Home") } } }
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
enum EiliAnisetteMode: String { case remote, onDevice; static let preferenceKey = "anisette.mode"; static let localBuildAvailable = true }
enum EiliAnisetteLibraryStatus { case engineUnavailable, missing, invalid, present, incompatible(String) }
enum EiliAnisetteError: LocalizedError { case unavailable; var errorDescription: String? { "Unavailable" } }
struct ADIRuntimeLibraryDownloader { enum DownloadError: LocalizedError { case unavailable; var errorDescription: String? { "Unavailable" } } }
final class EiliAnisetteService {
    static let shared = EiliAnisetteService()
    func localLibraryStatus() async -> EiliAnisetteLibraryStatus { .missing }
    func importLibraries(_ urls: [URL]) async throws -> EiliAnisetteLibraryStatus { .missing }
    func downloadLibraries() async throws -> EiliAnisetteLibraryStatus { .missing }
    func resetLocal() async throws {}
}
final class PaxAuthService {
    static let shared = PaxAuthService()
    var hasSavedSession = false
    var currentAppleID: String? = nil
}
