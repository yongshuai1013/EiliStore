# Settings navigation UI harness

This xcodegen-generated iOS 15+ simulator harness compiles `MainTabView` and `SettingsView` by extracting those complete declarations (balanced-brace scan) from the production `Sources/EiliStore/EiliStoreApp.swift` at test time. `UserCustomizationsView.swift` is compiled directly from its production path. The app entry point is harness-owned, and unrelated destinations plus `PaxAuthService` and `AnisetteModeSection` are inert stubs.

The XCTest exercises actual SwiftUI tab/list/toolbar navigation, checks that the original list link scrolls out while its toolbar shortcut remains hittable, verifies both routes, and records scrolled-settings and customization-page screenshots as xcresult attachments. It **does not test the native Anisette engine, native packages, device functionality, or Apple login/authentication**; no native packages are linked.

Run on macOS with Xcode, xcodegen and an available iOS simulator:

```sh
Tests/run-settings-navigation-ui-tests.sh
```
