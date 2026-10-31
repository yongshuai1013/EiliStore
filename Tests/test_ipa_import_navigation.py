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

    def test_ipa_picker_uses_native_picker_and_import_still_validates(self):
        source = (ROOT / 'Sources/EiliStore/SignViews.swift').read_text()
        self.assertIn('.sheet(isPresented: $showFilePicker)', source)
        self.assertIn('DocumentPicker(', source)
        self.assertIn('allowedContentTypes: [.item]', source)
        self.assertNotIn('.fileImporter(', source)
        self.assertNotIn('UTType(filenameExtension: "ipa")', source)
        for identifier in ['ipa-file-picker', 'ipa-import-page', 'ipa-start-install']:
            self.assertIn(f'accessibilityIdentifier("{identifier}")', source)
        self.assertIn('IPAImportStore.stage(url)', source)
        self.assertIn('requireInstallableMetadata: true', source)
        store = (ROOT / 'Sources/EiliStore/IPAImportStore.swift').read_text()
        for guard in ['sourceURL.isFileURL', 'sourceURL.pathExtension.lowercased() == "ipa"',
                      'values.isSymbolicLink != true', 'values.isRegularFile == true',
                      'startAccessingSecurityScopedResource()']:
            self.assertIn(guard, store)

    def test_pairing_picker_accepts_provider_items_and_keeps_scoped_validation(self):
        source = (ROOT / 'Sources/EiliStore/PairingFileManagementView.swift').read_text()
        self.assertIn('.sheet(isPresented: $isPickingLockdown)', source)
        self.assertIn('DocumentPicker(', source)
        self.assertIn('allowedContentTypes: [.item]', source)
        self.assertNotIn('.fileImporter(', source)
        self.assertIn('try store.importLockdown(from: url)', source)
        self.assertIn('let scoped = url.startAccessingSecurityScopedResource()', source)
        self.assertIn('defer { if scoped { url.stopAccessingSecurityScopedResource() } }', source)
        signing_flow = (ROOT / 'Sources/EiliStore/SigningFlowView.swift').read_text()
        pairing_picker = signing_flow.split('.sheet(isPresented: $isPickingPairing)', 1)[1].split('.sheet(isPresented: $isPickingIPA)', 1)[0]
        self.assertIn('allowedContentTypes: [.item]', pairing_picker)
        self.assertIn('deviceUDID = filename', pairing_picker)

    def test_shared_document_picker_uses_configurable_types_and_copy(self):
        source = (ROOT / 'Sources/EiliStore/SigningFlowView.swift').read_text()
        self.assertIn('var allowedContentTypes: [UTType] = [.data]', source)
        self.assertIn('forOpeningContentTypes: allowedContentTypes, asCopy: true', source)
        runner = (ROOT / 'Tests/run-settings-navigation-ui-tests.sh').read_text()
        self.assertIn("extract(picker_source, 'struct DocumentPicker: UIViewControllerRepresentable')", runner)

if __name__ == '__main__':
    unittest.main()
