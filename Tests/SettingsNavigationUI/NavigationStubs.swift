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
struct AnisetteModeSection: View { var body: some View { Section(header: Text("ANISETTE MODE")) { Text("Stub") } } }
final class PaxAuthService {
    static let shared = PaxAuthService()
    var hasSavedSession = false
    var currentAppleID: String? = nil
}
