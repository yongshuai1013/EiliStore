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
        for name in ["HarnessApp.swift", "NavigationStubs.swift", "../../Sources/EiliStore/UserCustomizationsView.swift"]:
            self.assertIn(f"- path: {name}", spec)
            self.assertTrue((ROOT / "Tests/SettingsNavigationUI" / name).is_file())
        self.assertNotIn("AnisetteModeSection.swift", spec)
        self.assertNotIn("AnisettePresentationModel.swift", spec)

    def test_page_hosts_controls_directly_and_uses_parent_navigation(self):
        page = (SOURCES / "UserCustomizationsView.swift").read_text()
        self.assertIn("struct UserCustomizationsView: View", page)
        self.assertRegex(page, r"Form\s*\{\s*Section\(header: Text\(\"ANISETTE\"\)")
        self.assertIn('.navigationTitle("用戶自定義")', page)
        self.assertIn('.navigationBarTitleDisplayMode(.inline)', page)
        self.assertNotIn("NavigationView {", page)
        self.assertNotIn("NavigationStack {", page)  # iOS 15 remains supported.
        self.assertIn("NavigationLink(destination: AnisetteClientConfigurationView())", page)
        self.assertIn("NavigationLink(destination: SideSignClientConfigurationView())", page)
        self.assertNotIn(".fileImporter(", page)
        self.assertNotIn("AnisetteModeSection", page)
        self.assertNotIn("AnisettePresentationModel", page)

    def test_only_customizations_owns_mode_controls(self):
        owners = [p.name for p in SOURCES.glob("*.swift")
                  if "anisette-ondevice-toggle" in p.read_text()]
        self.assertEqual(owners, ["UserCustomizationsView.swift"])
        server = (SOURCES / "AnisetteServerView.swift").read_text()
        self.assertIn('Text("AVAILABLE SERVERS")', server)
        self.assertIn('Text("Enable Auto Rotation")', server)

    def test_customizations_page_structure_and_reset_action(self):
        page = (SOURCES / "UserCustomizationsView.swift").read_text()
        for identifier in ["anisette-ondevice-toggle", "customizations-anisette-client-config",
                           "customizations-sidesign-client-config", "anisette-local-reset",
                           "user-customizations-page"]:
            self.assertIn(f'accessibilityIdentifier("{identifier}")', page)
        self.assertIn('@AppStorage(EiliAnisetteMode.preferenceKey)', page)
        self.assertIn('EiliAnisetteMode.remote.rawValue', page)
        self.assertIn('Text("ANISETTE")', page)
        self.assertIn('Text("SIDESIGN")', page)
        self.assertIn('Text("On-Device Anisette")', page)
        self.assertIn('Text("Reset adi.pb")', page)
        self.assertIn("EiliAnisetteService.shared.resetLocal()", page)
        self.assertIn(".confirmationDialog(", page)
        self.assertIn('.alert("本機 Anisette"', page)
        for gone in ["AnisetteModeSection", "AnisettePresentationModel", "下載 ADI",
                     "匯入 ADI", "ODA 來源", "anisette-library-import", "anisette-oda-management"]:
            self.assertNotIn(gone, page)
        self.assertFalse((SOURCES / "AnisetteModeSection.swift").exists())
        self.assertFalse((SOURCES / "AnisettePresentationModel.swift").exists())

    def test_library_import_guards_remain_in_service(self):
        # The picker UI is gone with the ODA management page, but the manual
        # import path it fed remains available at the service layer.
        service = (SOURCES / "EiliAnisetteService.swift").read_text()
        for guard in ["startAccessingSecurityScopedResource()", "isSymbolicLink", "isRegularFile", "installLibraries(urls)"]:
            self.assertIn(guard, service)

    def test_opening_page_does_not_download_or_fetch(self):
        page = (SOURCES / "UserCustomizationsView.swift").read_text()
        for forbidden in [".onAppear", ".task", "downloadLibraries",
                          "localStorageStatus", "PaxAuthService", "fetch("]:
            self.assertNotIn(forbidden, page)
        # The only persisted state the page owns is the mode preference itself.
        self.assertIn('@AppStorage(EiliAnisetteMode.preferenceKey)', page)

    def test_oda_management_surface_is_removed(self):
        page = (SOURCES / "UserCustomizationsView.swift").read_text()
        for gone in ["anisette-oda-management", "anisette-provisioning-status", "oda-source-url",
                     "oda-fallback-url", "oda-save-sources", "oda-automatic-acquisition",
                     "oda-ensure-cache", "自動取得"]:
            self.assertNotIn(gone, page)
        # Reset keeps the old honest wording: libraries and remote data stay,
        # and the user must sign out themselves first.
        self.assertIn("本操作不會自動登出", page)
        self.assertIn("函式庫、Client Configuration、遠端資料與憑證保留", page)

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
        self.assertEqual(service.count("fetchAnisetteDataWithFailover("), 1)
        self.assertIn("existingAdiBlob: blob", service)
        self.assertIn("Self.isNotProvisioned(error)", service)
        self.assertIn("var requestHeaders = configuration.requestHeaderOverrides", service)
        self.assertEqual(service.count("headers: .init(rawHeaders: requestHeaders)"), 1)
        self.assertIn("if !explicitRoutingOverride, let routingInfo", service)
        self.assertIn('requestHeaders["X-Apple-I-MD-RINFO"] = routingInfo', service)
        self.assertIn("configuration = try configuration.validated()", service)
        self.assertEqual(service.count("configuration.applying(to: data)"), 2)
        # The on-device path is the ODATest-verified SideSign manager call;
        # the retired vendored AnisetteClient path must not reappear.
        self.assertIn("mode: .remoteODA(sourceURL: odaConfig.sourceURL, fallbackURL: odaConfig.fallbackURL ?? odaConfig.sourceURL)", service)
        self.assertIn('defaultFallbackURLString = "https://zzz.haus/oda.json"', service)
        self.assertNotIn("AnisetteClient(", service)
        self.assertNotIn("configuration.applying(to: try Self.convertHeaders(headers))", service)
        self.assertNotIn("resetLocalAnisetteEngine", service)

    def test_sidesign_headers_are_snapshotted_for_all_production_operations(self):
        for name in ["PaxSigningService.swift",
                     "PaxSigningService+Signing.swift", "PaxSigningService+AppIDs.swift",
                     "DeveloperPortalService.swift"]:
            source = (SOURCES / name).read_text()
            self.assertNotIn("SideSign.DeveloperPortal.shared", source)
            self.assertIn("EiliSideSignClientConfigurationStore.shared.makePortal()", source)
        auth = (SOURCES / "PaxAuthService.swift").read_text()
        self.assertNotIn("SideSign.DeveloperPortal.shared", auth)
        # Login builds its portal after the anisette fetch so the GSA
        # identity can follow the anisette identity (see store method).
        self.assertIn("EiliSideSignClientConfigurationStore.shared.resolvedLoginHeaders(", auth)
        self.assertIn("SideSign.DeveloperPortal(customHeaders: loginHeaders)", auth)
        config = (SOURCES / "EiliSideSignClientConfiguration.swift").read_text()
        self.assertIn("SideSign.DeveloperPortal(customHeaders:try load().resolvedHeaders())", config)
        self.assertIn("func resolvedLoginHeaders(anisetteClientInfo:", config)
        self.assertNotIn("DeveloperPortal.shared", config)

    def test_client_configuration_contract_suites_run_in_ci(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text()
        for script in ["run-anisette-client-config-tests.sh", "run-sidesign-client-config-tests.sh",
                       "run-developer-portal-service-tests.sh", "run-anisette-remote-sync-tests.sh"]:
            self.assertIn(f"bash Tests/{script}", workflow)

    def test_anisette_remote_server_sync_is_remote_only_and_saves_explicitly(self):
        view = (SOURCES / "AnisetteClientConfigurationView.swift").read_text()
        sync = (SOURCES / "EiliAnisetteRemoteServerSync.swift").read_text()
        self.assertIn("if EiliAnisetteMode.selected == .remote", view)
        for contract in ["anisette-remote-sync-fetch", "isFetchingRemote",
                         "ProgressView()", "remoteSyncNotice", "remoteServerHeadersJSON",
                         "anisette-remote-sync-save-overrides", "mergingServerHeaders"]:
            self.assertIn(contract, view)
        self.assertIn("Capsule().fill(remoteSyncNoticeIsError ? Color.red : Color.teal)", view)
        self.assertIn("showSyncToastIfNeeded()", view)
        self.assertIn('appendingPathComponent("v3"', sync)
        self.assertIn('appendingPathComponent("client_info"', sync)
        self.assertIn("timeoutInterval: 10", sync)
        self.assertIn("data.count <= 65_536", sync)

    def test_remote_sync_uses_original_layout_and_separate_controls(self):
        view = (SOURCES / "AnisetteClientConfigurationView.swift").read_text()
        remote = view.split("if EiliAnisetteMode.selected == .remote {", 1)[1].split('Section("注意事項")', 1)[0]
        self.assertIn('Section("REMOTE SERVER SYNC")', remote)
        self.assertIn('Button(action: fetchRemoteServerConfiguration)', remote)
        self.assertIn('accessibilityIdentifier("anisette-remote-sync-fetch")', remote)
        self.assertIn('accessibilityIdentifier("anisette-remote-sync-toggle")', remote)
        self.assertIn("isRemoteSyncExpanded.toggle()", remote)
        self.assertNotIn("Capsule()", remote)
        self.assertIn('Text(isFetchingRemote ? "刷新中" : "刷新")', remote)
        self.assertIn('accessibilityIdentifier("anisette-remote-sync-save-overrides")', remote)
        self.assertNotIn("DisclosureGroup", remote)
        self.assertNotIn("anisette-remote-server-sync-card", remote)
        self.assertNotIn(".tint(.purple)", remote)

    def test_login_server_catalog_refresh_does_not_reset_navigation_or_selection(self):
        server = (SOURCES / "AnisetteServerView.swift").read_text()
        login = (SOURCES / "LoginView.swift").read_text()
        refresh = server.split("private func refreshCatalog()", 1)[1].split("\n    }", 1)[0]
        self.assertIn("NavigationLink(destination: AnisetteServerView())", login)
        self.assertNotIn("isActive: $showingAnisetteServers", login)
        self.assertNotIn(".constant(refreshError != nil)", server)
        self.assertIn("get: { refreshError != nil }", server)
        self.assertIn("Task { @MainActor in", refresh)
        self.assertIn("servers = manager.allServers", refresh)
        self.assertNotIn("selectedID =", refresh)
        self.assertNotIn("refresh()", refresh)


if __name__ == "__main__":
    unittest.main()
