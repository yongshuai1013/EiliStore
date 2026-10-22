import SwiftUI

/// Settings > User Customizations owns the On-Device controls. This page
/// reuses the existing service and preference instead of introducing a second toggle.
struct UserCustomizationsView: View {
    var body: some View {
        Form {
            AnisetteModeSection()

            Section(header: Text("ANISETTE")) {
                NavigationLink(destination: AnisetteClientConfigurationView()) {
                    Label("Anisette Client Configuration", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("customizations-anisette-client-config")
            }

            Section(header: Text("SIDESIGN")) {
                NavigationLink(destination: SideSignClientConfigurationView()) {
                    Label("SideSign Client Configuration", systemImage: "network")
                }
                .accessibilityIdentifier("customizations-sidesign-client-config")
            }
        }
        .navigationTitle("用戶自定義")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("user-customizations-page")
    }
}
