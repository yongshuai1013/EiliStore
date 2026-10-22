import XCTest

final class SettingsNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testSettingsShortcutSurvivesDeepScrollAndBothRoutesWork() {
        let settingsTab = app.tabBars.buttons["設定"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()

        let listRoute = app.buttons["settings-user-customizations"]
        let toolbarRoute = app.buttons["settings-user-customizations-shortcut"]
        XCTAssertTrue(listRoute.waitForExistence(timeout: 5))
        XCTAssertTrue(toolbarRoute.waitForExistence(timeout: 5))

        // Scroll by content landmarks rather than assuming a fixed screen distance.
        let about = app.staticTexts["關於"]
        attachScreenshot(named: "settings-top")
        for _ in 0..<12 where listRoute.isHittable || !about.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(about.waitForExistence(timeout: 3), "About section should be reachable by scrolling")
        XCTAssertFalse(listRoute.isHittable, "The list route should have scrolled out of the viewport")
        XCTAssertTrue(toolbarRoute.isHittable, "The navigation-bar shortcut must remain reachable")
        attachScreenshot(named: "settings-scrolled")

        toolbarRoute.tap()
        assertCustomizationPage()
        attachScreenshot(named: "customizations-page")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Verify the original list route remains present and functional after returning.
        let restoredListRoute = app.buttons["settings-user-customizations"]
        for _ in 0..<12 where !restoredListRoute.isHittable { app.swipeDown() }
        XCTAssertTrue(restoredListRoute.isHittable)
        restoredListRoute.tap()
        assertCustomizationPage()
    }

    private func assertCustomizationPage() {
        XCTAssertTrue(app.otherElements["user-customizations-page"].waitForExistence(timeout: 5)
            || app.descendants(matching: .any)["user-customizations-page"].waitForExistence(timeout: 1))
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
