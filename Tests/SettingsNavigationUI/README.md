# Settings navigation UI harness

This xcodegen-generated iOS 15+ simulator harness compiles `MainTabView` and `SettingsView` by extracting those complete declarations (balanced-brace scan) from the production `Sources/EiliStore/EiliStoreApp.swift` at test time. It also extracts only `ImportedIPASelection` and the `SignIPAView` declaration from production `SignViews.swift`, avoiding unrelated SideSign declarations, and compiles production `IPAImportStore.swift` and `UserCustomizationsView.swift` directly. The home destination is replaced by an inert launcher; the harness app entry point is harness-owned.

The XCTest exercises actual SwiftUI tab/list/toolbar navigation, checks that the original list link scrolls out while its toolbar shortcut remains hittable, verifies both routes, and opens/cancels the system file picker from both the existing `.so` import route and production IPA import view. A system `UTType` check covers `ipa`, `so`, and `unknown` when the SDK resolves them as `public.item` subtypes; it does not assume any such extension is a dynamic type or `public.data`. The IPA parser and installer are synthetic/inert stubs, so the tests do not select a file or invoke parsing, Apple login, signing, provisioning, or installation. No native packages are linked.

Run on macOS with Xcode, xcodegen and an available iOS simulator:

```sh
Tests/run-settings-navigation-ui-tests.sh
```
