import XCTest

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

    func testAnisetteImportOpensDocumentPickerAndCanBeCancelled() {
        let route = app.buttons["settings-user-customizations-shortcut"]
        XCTAssertTrue(route.waitForExistence(timeout: 20))
        route.tap()
        let importButton = app.buttons["anisette-library-import"]
        XCTAssertTrue(app.descendants(matching: .any)["user-customizations-page"].waitForExistence(timeout: 30))
        let list = settingsList
        for _ in 0..<10 { if importButton.isHittable { break }; list.swipeUp() }
        XCTAssertTrue(importButton.isHittable)
        importButton.tap()
        let picker = app.otherElements["Document Browser"]
        let visiblePicker = picker.waitForExistence(timeout: 8) || app.navigationBars["Browse"].exists || app.buttons["Browse"].exists || app.buttons["Cancel"].exists
        XCTAssertTrue(visiblePicker, "The system document picker should open without supplying any Apple files")
        attachScreenshot(named: "anisette-document-picker")
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
    }

    func testODAManagementNavigationAndAutomaticAcquisitionConsent() {
        let route = app.buttons["settings-user-customizations-shortcut"]
        XCTAssertTrue(route.waitForExistence(timeout: 20))
        route.tap()
        let management = app.buttons["anisette-oda-management"]
        XCTAssertTrue(management.waitForExistence(timeout: 20))
        for _ in 0..<8 { if management.isHittable { break }; settingsList.swipeUp() }
        XCTAssertTrue(management.isHittable)
        management.tap()
        XCTAssertTrue(app.textFields["oda-source-url"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["oda-fallback-url"].exists)
        let automatic = app.switches["oda-automatic-acquisition"]
        for _ in 0..<8 { if automatic.isHittable { break }; settingsList.swipeUp() }
        XCTAssertTrue(automatic.isHittable)
        XCTAssertEqual(automatic.value as? String, "0")
        // SwiftUI on recent iOS exposes a row-sized Switch containing a native
        // Switch. Tapping the row midpoint hits its non-interactive text label.
        let nativeSwitch = automatic.switches.firstMatch
        XCTAssertTrue(nativeSwitch.exists)
        nativeSwitch.tap()
        let consent = app.alerts.firstMatch
        XCTAssertTrue(consent.waitForExistence(timeout: 10))
        XCTAssertTrue(consent.buttons["確認允許自動取得"].exists)
        let cancel = consent.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertEqual(automatic.value as? String, "0")
        attachScreenshot(named: "oda-management-consent-cancelled")
        nativeSwitch.tap()
        let confirm = app.alerts.buttons["確認允許自動取得"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertEqual(automatic.value as? String, "1")
        nativeSwitch.tap()
        XCTAssertEqual(automatic.value as? String, "0")
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
