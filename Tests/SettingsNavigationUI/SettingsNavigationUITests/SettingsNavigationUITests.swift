import XCTest
import UniformTypeIdentifiers

final class SettingsNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        let settingsTab = app.tabBars.buttons["設定"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()
    }

    private var settingsList: XCUIElement {
        if app.collectionViews.firstMatch.exists { return app.collectionViews.firstMatch }
        if app.tables.firstMatch.exists { return app.tables.firstMatch }
        return app.scrollViews.firstMatch
    }

    func testOriginalListRouteOpensCustomizations() {
        let route = app.buttons["settings-user-customizations"]
        let list = settingsList
        XCTAssertTrue(list.exists)
        for _ in 0..<6 {
            if route.isHittable { break }
            list.swipeUp()
        }
        XCTAssertTrue(route.isHittable)
        route.tap()
        assertCustomizationPage()
        attachScreenshot(named: "customizations-from-list")
    }

    func testSettingsShortcutSurvivesDeepScroll() {
        let listRoute = app.buttons["settings-user-customizations"]
        let toolbarRoute = app.buttons["settings-user-customizations-shortcut"]
        XCTAssertTrue(listRoute.waitForExistence(timeout: 5))
        XCTAssertTrue(toolbarRoute.waitForExistence(timeout: 5))
        attachScreenshot(named: "settings-top")

        let list = settingsList
        XCTAssertTrue(list.exists)
        let about = app.staticTexts["關於"]
        for _ in 0..<12 {
            if !listRoute.isHittable && about.isHittable { break }
            list.swipeUp()
        }
        XCTAssertTrue(about.isHittable, "About section should be visible after scrolling")
        XCTAssertFalse(listRoute.isHittable, "The list route should have scrolled out of the viewport")
        XCTAssertTrue(toolbarRoute.isHittable, "The navigation-bar shortcut must remain reachable")
        attachScreenshot(named: "settings-scrolled")
        toolbarRoute.tap()
        assertCustomizationPage()
        attachScreenshot(named: "customizations-from-toolbar")
    }

    func testOnDeviceToggleAndResetConfirmation() {
        let route = app.buttons["settings-user-customizations-shortcut"]
        XCTAssertTrue(route.waitForExistence(timeout: 20))
        route.tap()
        XCTAssertTrue(app.descendants(matching: .any)["user-customizations-page"].waitForExistence(timeout: 30))
        let toggle = app.switches["anisette-ondevice-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0")
        // SwiftUI exposes a row-sized Switch containing a native Switch.
        // Tapping the row midpoint hits its non-interactive text label.
        let nativeSwitch = toggle.switches.firstMatch
        XCTAssertTrue(nativeSwitch.exists)
        nativeSwitch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        attachScreenshot(named: "anisette-ondevice-enabled")
        nativeSwitch.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        let reset = app.buttons["anisette-local-reset"]
        let list = settingsList
        for _ in 0..<8 { if reset.isHittable { break }; list.swipeUp() }
        XCTAssertTrue(reset.isHittable)
        reset.tap()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(sheet.buttons["重設本機資料"].waitForExistence(timeout: 10))
        // The sheet's cancel button is not reliably matched by its localized
        // label; in an action sheet it is always the last button.
        let cancel = sheet.buttons.element(boundBy: sheet.buttons.count - 1)
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        attachScreenshot(named: "anisette-reset-cancelled")
    }

    func testIPAImportOpensSystemDocumentPickerAndCanBeCancelled() {
        // These are system UTType checks only; no sample file is selected.
        for ext in ["ipa", "so", "unknown"] {
            let type = UTType(filenameExtension: ext, conformingTo: .item)
            XCTAssertNotNil(type, "UTType should resolve \(ext) when public.item conformance is requested")
            XCTAssertTrue(type?.conforms(to: .item) == true, "\(ext) should be a subtype of public.item")
        }
        app.tabBars.buttons["主頁"].tap()
        let launcher = app.buttons["harness-open-ipa-import"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 10))
        launcher.tap()

        let page = app.descendants(matching: .any)["ipa-import-page"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        let importButton = app.buttons["ipa-file-picker"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ipa-start-install"].exists)
        XCTAssertFalse(app.buttons["ipa-start-install"].isEnabled)
        importButton.tap()

        let picker = app.otherElements["Document Browser"]
        let visiblePicker = picker.waitForExistence(timeout: 8)
            || app.navigationBars["Browse"].exists
            || app.buttons["Browse"].exists
            || app.buttons["Cancel"].exists
        XCTAssertTrue(visiblePicker, "The system document picker should open without selecting an IPA")
        attachScreenshot(named: "ipa-document-picker")
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["ipa-start-install"].isEnabled)
    }

    func testClientConfigurationLinksNavigate() {
        let route = app.buttons["settings-user-customizations-shortcut"]
        XCTAssertTrue(route.waitForExistence(timeout: 20))
        route.tap()
        XCTAssertTrue(app.descendants(matching: .any)["user-customizations-page"].waitForExistence(timeout: 30))
        let list = settingsList
        let anisetteLink = app.buttons["customizations-anisette-client-config"]
        for _ in 0..<8 { if anisetteLink.isHittable { break }; list.swipeUp() }
        XCTAssertTrue(anisetteLink.isHittable)
        anisetteLink.tap()
        XCTAssertTrue(app.staticTexts["Anisette Client Configuration"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let sideSignLink = app.buttons["customizations-sidesign-client-config"]
        for _ in 0..<8 { if sideSignLink.isHittable { break }; list.swipeUp() }
        XCTAssertTrue(sideSignLink.isHittable)
        sideSignLink.tap()
        XCTAssertTrue(app.staticTexts["SideSign Client Configuration"].waitForExistence(timeout: 10))
        attachScreenshot(named: "client-configuration-links")
    }

    private func assertCustomizationPage() {
        XCTAssertTrue(app.descendants(matching: .any)["user-customizations-page"].waitForExistence(timeout: 30))
        let list = settingsList
        let anisetteLink = app.buttons["customizations-anisette-client-config"]
        let sideSignLink = app.buttons["customizations-sidesign-client-config"]
        for _ in 0..<12 {
            if anisetteLink.isHittable && sideSignLink.isHittable { break }
            list.swipeUp()
        }
        XCTAssertTrue(anisetteLink.exists)
        XCTAssertTrue(sideSignLink.exists)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
