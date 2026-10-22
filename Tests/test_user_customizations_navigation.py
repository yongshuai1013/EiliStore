#!/usr/bin/env python3
"""Source-level navigation contracts; not a substitute for SwiftUI device tests."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources" / "EiliStore"


class UserCustomizationsNavigationTests(unittest.TestCase):
    def test_settings_links_to_real_customizations_page(self):
        app = (SOURCES / "EiliStoreApp.swift").read_text()
        settings = app.split("struct SettingsView: View", 1)[1]
        self.assertIn("NavigationLink(destination: UserCustomizationsView())", settings)
        self.assertIn('Label("用戶自定義", systemImage: "slider.horizontal.3")', settings)
        self.assertIn('accessibilityIdentifier("settings-user-customizations")', settings)
        # Opening customizations must not require an Apple login.
        entry = settings.split("NavigationLink(destination: UserCustomizationsView())", 1)[1].split("Section(header:", 1)[0]
        self.assertNotIn(".disabled(", entry)

    def test_customizations_remains_reachable_when_list_is_scrolled(self):
        app = (SOURCES / "EiliStoreApp.swift").read_text()
        settings = app.split("struct SettingsView: View", 1)[1]
        toolbar = settings.split('.navigationTitle("設定")', 1)[1].split(".onAppear", 1)[0]
        self.assertIn(".toolbar", toolbar)
        self.assertIn("ToolbarItem(placement: .navigationBarTrailing)", toolbar)
        self.assertIn("NavigationLink(destination: UserCustomizationsView())", toolbar)
        self.assertIn('Text("用戶自定義")', toolbar)
        self.assertIn('accessibilityIdentifier("settings-user-customizations-shortcut")', toolbar)
        self.assertNotIn(".disabled(", toolbar)
        self.assertNotIn("if isLoggedIn", toolbar)

    def test_page_hosts_controls_directly_and_uses_parent_navigation(self):
        page = (SOURCES / "UserCustomizationsView.swift").read_text()
        self.assertIn("struct UserCustomizationsView: View", page)
        self.assertRegex(page, r"Form\s*\{\s*AnisetteModeSection\(\)")
        self.assertIn('.navigationTitle("用戶自定義")', page)
        self.assertIn('.navigationBarTitleDisplayMode(.inline)', page)
        self.assertNotIn("NavigationView {", page)
        self.assertNotIn("NavigationStack {", page)  # iOS 15 remains supported.
        self.assertNotIn("Button(", page)  # Not a placeholder that opens another page.

    def test_only_customizations_owns_mode_controls(self):
        owners = [p.name for p in SOURCES.glob("*.swift")
                  if re.search(r"\bAnisetteModeSection\s*\(\s*\)", p.read_text())]
        self.assertEqual(owners, ["UserCustomizationsView.swift"])
        server = (SOURCES / "AnisetteServerView.swift").read_text()
        self.assertIn('Text("AVAILABLE SERVERS")', server)
        self.assertIn('Text("Enable Auto Rotation")', server)

    def test_complete_controls_and_existing_service_actions_are_preserved(self):
        mode = (SOURCES / "AnisetteModeSection.swift").read_text()
        for identifier in ["anisette-mode-picker", "anisette-library-status",
                           "anisette-library-recheck", "anisette-library-download",
                           "anisette-library-import", "anisette-local-reset"]:
            self.assertIn(f'accessibilityIdentifier("{identifier}")', mode)
        for action in [".downloadLibraries()", ".importLibraries(urls)",
                       ".localLibraryStatus()", ".resetLocal()"]:
            self.assertIn(action, mode)
        self.assertIn('@AppStorage(EiliAnisetteMode.preferenceKey)', mode)
        self.assertIn('EiliAnisetteMode.remote.rawValue', mode)
        self.assertIn('.confirmationDialog("從第三方下載 ADI 函式庫？"', mode)
        self.assertIn('case .incompatible(let reason)', mode)

    def test_opening_page_does_not_enable_or_download_anything(self):
        page = (SOURCES / "UserCustomizationsView.swift").read_text()
        for forbidden in ["@AppStorage", "UserDefaults", ".onAppear", ".task",
                          "downloadLibraries", "fetch(", "PaxAuthService"]:
            self.assertNotIn(forbidden, page)
        mode = (SOURCES / "AnisetteModeSection.swift").read_text()
        self.assertIn('.task { await refreshLibraryStatus() }', mode)
        self.assertIn('Text("遠端（預設）")', mode)
        self.assertIn("尚未支援其 Android ABI，不能用於本機登入", mode)

    def test_new_view_is_in_app_source_tree_and_contract_runs_in_ci(self):
        project = (ROOT / "project.yml").read_text()
        self.assertIn("- Sources/EiliStore", project)
        workflow = (ROOT / ".github/workflows/build.yml").read_text()
        self.assertIn("python3 Tests/test_user_customizations_navigation.py", workflow)

    def test_both_client_configuration_pages_have_real_navigation(self):
        page = (SOURCES / "UserCustomizationsView.swift").read_text()
        for view, title in [("AnisetteClientConfigurationView", "Anisette Client Configuration"),
                            ("SideSignClientConfigurationView", "SideSign Client Configuration")]:
            self.assertIn(f"NavigationLink(destination: {view}())", page)
            self.assertIn(f'Label("{title}"', page)
            source = (SOURCES / f"{view}.swift").read_text()
            for action in [".fileImporter(", ".fileExporter(", ".confirmationDialog(",
                           "selection: modeSelection", ".shared.load()", ".shared.save(",
                           ".shared.reset()", "read(upToCount: 65_537)",
                           "startAccessingSecurityScopedResource()"]:
                self.assertIn(action, source)
            self.assertNotIn(".onChange(of: mode)", source)
            self.assertNotIn("Data(contentsOf:", source)
            self.assertNotIn(".autocorrectionDisabled", source)

    def test_anisette_overrides_reach_login_refresh_and_both_providers(self):
        auth = (SOURCES / "PaxAuthService.swift").read_text()
        signing = (SOURCES / "PaxSigningService.swift").read_text()
        for source in [auth, signing]:
            self.assertIn("EiliAnisetteClientConfigurationStore.shared.load()", source)
            self.assertIn("configuration: clientConfiguration", source)
            self.assertIn("clientConfiguration.resolvedXcodeVersion(", source)
        service = (SOURCES / "EiliAnisetteService.swift").read_text()
        self.assertEqual(service.count("headers: .init(rawHeaders: configuration.requestHeaderOverrides)"), 2)
        self.assertIn("configuration = try configuration.validated()", service)
        self.assertIn("configuration.applying(to: data)", service)
        self.assertIn("configuration.applying(to: try Self.convertHeaders(headers))", service)

    def test_sidesign_headers_are_snapshotted_for_all_production_operations(self):
        for name in ["PaxAuthService.swift", "PaxSigningService.swift",
                     "PaxSigningService+Signing.swift", "PaxSigningService+AppIDs.swift",
                     "DeveloperPortalService.swift"]:
            source = (SOURCES / name).read_text()
            self.assertNotIn("SideSign.DeveloperPortal.shared", source)
            self.assertIn("EiliSideSignClientConfigurationStore.shared.makePortal()", source)
        config = (SOURCES / "EiliSideSignClientConfiguration.swift").read_text()
        self.assertIn("SideSign.DeveloperPortal(customHeaders:try load().resolvedHeaders())", config)
        self.assertNotIn("DeveloperPortal.shared", config)

    def test_client_configuration_contract_suites_run_in_ci(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text()
        for script in ["run-anisette-client-config-tests.sh", "run-sidesign-client-config-tests.sh",
                       "run-developer-portal-service-tests.sh"]:
            self.assertIn(f"bash Tests/{script}", workflow)


if __name__ == "__main__":
    unittest.main()
