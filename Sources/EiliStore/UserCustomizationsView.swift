import SwiftUI

/// Settings > User Customizations owns the On-Device controls. This page
/// reuses the existing service and preference instead of introducing a second toggle.
struct UserCustomizationsView: View {
    var body: some View {
        Form {
            AnisetteModeSection()
        }
        .navigationTitle("用戶自定義")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("user-customizations-page")
    }
}
