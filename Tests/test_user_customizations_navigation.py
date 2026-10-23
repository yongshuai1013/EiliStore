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

    def test_ui_harness_project_root_matches_relative_source_paths(self):
        runner = (ROOT / "Tests/run-settings-navigation-ui-tests.sh").read_text()
        self.assertIn('PROJECT="$TEST_DIR/SettingsNavigationUI.xcodeproj"', runner)
        self.assertIn('xcodegen generate --spec "$TEST_DIR/project.yml" --project "$TEST_DIR"', runner)
        spec = (ROOT / "Tests/SettingsNavigationUI/project.yml").read_text()
        for name in ["HarnessApp.swift", "NavigationStubs.swift", "../../Sources/EiliStore/UserCustomizationsView.swift", "../../Sources/EiliStore/AnisetteModeSection.swift", "../../Sources/EiliStore/AnisettePresentationModel.swift"]:
            self.assertIn(f"- path: {name}", spec)
            self.assertTrue((ROOT / "Tests/SettingsNavigationUI" / name).is_file())

    def test_page_hosts_controls_directly_and_uses_parent_navigation(self):
        page = (SOURCES / "UserCustomizationsView.swift").read_text()
        self.assertIn("struct UserCustomizationsView: View", page)
        self.assertRegex(page, r"Form\s*\{\s*AnisetteModeSection\(model: anisette\)")
        self.assertIn('.navigationTitle("用戶自定義")', page)
        self.assertIn('.navigationBarTitleDisplayMode(.inline)', page)
        self.assertNotIn("NavigationView {", page)
        self.assertNotIn("NavigationStack {", page)  # iOS 15 remains supported.
        self.assertIn("NavigationLink(destination: AnisetteClientConfigurationView())", page)
        self.assertIn("NavigationLink(destination: SideSignClientConfigurationView())", page)
        self.assertIn(".fileImporter(isPresented: $anisette.importing", page)

    def test_only_customizations_owns_mode_controls(self):
        owners = [p.name for p in SOURCES.glob("*.swift")
                  if re.search(r"\bAnisetteModeSection\s*\(\s*model:\s*anisette\s*\)", p.read_text())]
        self.assertEqual(owners, ["UserCustomizationsView.swift"])
        server = (SOURCES / "AnisetteServerView.swift").read_text()
        self.assertIn('Text("AVAILABLE SERVERS")', server)
        self.assertIn('Text("Enable Auto Rotation")', server)

    def test_complete_controls_and_existing_service_actions_are_preserved(self):
        mode = (SOURCES / "AnisetteModeSection.swift").read_text()
        model = (SOURCES / "AnisettePresentationModel.swift").read_text()
        page = (SOURCES / "UserCustomizationsView.swift").read_text()
        for identifier in ["anisette-mode-picker", "anisette-library-status",
                           "anisette-library-recheck", "anisette-library-download",
                           "anisette-library-import", "anisette-local-reset"]:
            self.assertIn(f'accessibilityIdentifier("{identifier}")', mode)
        for action in [".downloadLibraries()", ".importLibraries(urls)",
                       ".localStorageStatus()", ".resetLocal()"]:
            self.assertIn(action, model)
        self.assertIn(".fileImporter(isPresented: $anisette.importing", page)
        self.assertIn(".confirmationDialog(", page)
        self.assertIn('.alert("本機 Anisette"', page)
        self.assertNotIn(".fileImporter(", mode)
        self.assertIn('@AppStorage(EiliAnisetteMode.preferenceKey)', mode)
        self.assertIn('EiliAnisetteMode.remote.rawValue', mode)
        self.assertIn('case .incompatible(let reason)', mode)

    def test_library_picker_does_not_depend_on_provider_data_uti(self):
        page = (SOURCES / "UserCustomizationsView.swift").read_text()
        self.assertIn("allowedContentTypes: [.item], allowsMultipleSelection: true", page)
        self.assertNotIn("allowedContentTypes: [.data]", page)
        self.assertIn("anisette.handleImport($0)", page)
        service = (SOURCES / "EiliAnisetteService.swift").read_text()
        for guard in ["startAccessingSecurityScopedResource()", "isSymbolicLink", "isRegularFile", "installLibraries(urls)"]:
            self.assertIn(guard, service)

    def test_opening_page_does_not_enable_or_download_anything(self):
        page = (SOURCES / "UserCustomizationsView.swift").read_text()
        for forbidden in ["@AppStorage", "UserDefaults", ".onAppear", ".task",
                          "downloadLibraries", "fetch(", "PaxAuthService"]:
            self.assertNotIn(forbidden, page)
        mode = (SOURCES / "AnisetteModeSection.swift").read_text()
        self.assertIn('.task { await model.refreshLibraryStatus() }', mode)
        self.assertIn('Text("遠端（預設）")', mode)
        self.assertIn("新版五庫仍只供離線診斷，不能用於本機登入", mode)
        self.assertIn("未知函式回傳 0", mode)
        self.assertIn("256 位元組零填充占位", mode)
        self.assertIn("TLS 符號、PT_TLS 與未支援重定位僅供診斷", mode)
        self.assertIn("缺少必要入口、依賴庫、SONAME 或未支援格式僅列為診斷", mode)
        self.assertIn("結構損毀或無法讀取仍會阻擋", mode)
        self.assertIn("檢查通過不代表來源可信、安全、已授權或登入成功", mode)

    def test_oda_management_has_explicit_consent_and_read_only_status(self):
        mode = (SOURCES / "AnisetteModeSection.swift").read_text()
        model = (SOURCES / "AnisettePresentationModel.swift").read_text()
        page = (SOURCES / "UserCustomizationsView.swift").read_text()
        for identifier in ["anisette-oda-management", "anisette-provisioning-status", "oda-source-url", "oda-fallback-url", "oda-save-sources", "oda-automatic-acquisition", "oda-ensure-cache"]:
            self.assertIn(f'accessibilityIdentifier("{identifier}")', mode)
        self.assertIn("confirmingAutomatic = true", mode)
        self.assertIn('Button("確認允許自動取得")', mode)
        self.assertIn("automaticAcquisition = false", mode)
        self.assertIn(".validated()", mode)
        self.assertIn(".ensureLibraries()", model)
        self.assertIn(".localStorageStatus()", model)
        self.assertIn("status.provisioningPresent", model)
        self.assertIn("anisette.sourceSummary", page)
        self.assertIn("本操作不會自動登出", page)

    def test_session_check_errors_are_not_reported_as_invalid_or_logged_out(self):
        login = (SOURCES / "LoginView.swift").read_text()
        account = login.split("private func checkSession()", 1)[1]
        catch = account.split("} catch {", 1)[1].split("\n            }", 1)[0]
        self.assertIn("sessionValid = nil", catch)
        self.assertNotIn("Session 已失效:", catch)
        self.assertNotRegex(catch, r"logout\s*\(|delete")

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
        # Local requests merge persisted routing info into a copy of the overrides;
        # only the remote provider still receives the original dictionary directly.
        self.assertEqual(service.count("headers: .init(rawHeaders: configuration.requestHeaderOverrides)"), 1)
        self.assertIn("var requestHeaders = configuration.requestHeaderOverrides", service)
        self.assertEqual(service.count("headers: .init(rawHeaders: requestHeaders)"), 1)
        self.assertIn("if !explicitRoutingOverride, let routingInfo", service)
        self.assertIn('requestHeaders["X-Apple-I-MD-RINFO"] = routingInfo', service)
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
