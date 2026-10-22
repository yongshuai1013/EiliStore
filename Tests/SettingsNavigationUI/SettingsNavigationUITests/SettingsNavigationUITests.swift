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

    private func assertCustomizationPage() {
        XCTAssertTrue(app.descendants(matching: .any)["user-customizations-page"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Anisette Client Configuration"].exists)
        XCTAssertTrue(app.staticTexts["SideSign Client Configuration"].exists)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
