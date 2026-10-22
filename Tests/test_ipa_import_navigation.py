#!/usr/bin/env python3
"""Source contracts for moving IPA import to the Home plus menu, not a UI test."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class IPAImportNavigationTests(unittest.TestCase):
    def setUp(self):
        self.app = (ROOT / 'Sources/EiliStore/EiliStoreApp.swift').read_text()
        self.home = self.app.split('struct MyAppsView: View', 1)[1].split('// MARK: - 軟體源', 1)[0]
        self.sign = self.app.split('struct SignInstallView: View', 1)[1].split('// MARK: - 設定', 1)[0]

    def test_plus_menu_routes_to_full_ipa_import(self):
        menu = self.home.split('Menu {', 1)[1].split('.sheet(item: $activeHomeSheet)', 1)[0]
        self.assertIn('activeHomeSheet = .importIPA', menu)
        self.assertIn('Label("匯入 IPA 並簽名安裝", systemImage: "square.and.arrow.down")', menu)
        self.assertIn('.accessibilityIdentifier("home-import-ipa")', menu)
        self.assertIn('Image(systemName: "plus")', menu)

    def test_ipa_sheet_uses_existing_flow_with_navigation_and_dismissal(self):
        sheet = self.home.split('case .importIPA:', 1)[1].split('case .importIcon:', 1)[0]
        self.assertIn('NavigationView {', sheet)
        self.assertIn('SignIPAView()', sheet)
        self.assertIn('Button("完成") { activeHomeSheet = nil }', sheet)
        self.assertIn('.navigationViewStyle(.stack)', sheet)
        self.assertNotIn('installImportedIPA', sheet)

    def test_signing_tab_does_not_duplicate_moved_entry(self):
        self.assertNotIn('SignIPAView()', self.sign)
        self.assertNotIn('匯入 IPA 並簽名安裝', self.sign)
        self.assertIn('SigningFlowView()', self.sign)
        self.assertIn('InstallAppView()', self.sign)

    def test_icon_import_and_app_id_actions_are_preserved(self):
        for token in ['case importIcon', 'case importIPA', 'activeHomeSheet = .importIcon',
                      'activeHomeSheet = .appIDSelection', 'Label("從 IPA 匯入圖示"',
                      'case .importIcon:', 'importExternalIcon(from: url)']:
            self.assertIn(token, self.home)
        source = (ROOT / 'Sources/EiliStore/SignViews.swift').read_text()
        self.assertIn('Button("選擇 IPA") { showFilePicker = true }', source)
        self.assertIn('Button(installer.isWorking ? "正在處理..." : "開始簽名並安裝", action: startInstall)', source)


if __name__ == '__main__':
    unittest.main()
