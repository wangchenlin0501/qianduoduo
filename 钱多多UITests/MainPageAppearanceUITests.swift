import XCTest

final class MainPageAppearanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMainPagesAndRepeatedThemeExpansion() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.navigationBars["汇总"].waitForExistence(timeout: 60))

        for name in ["汇总", "池子", "视频", "账本"] {
            let tab = app.tabBars.buttons[name].firstMatch
            if tab.exists && tab.isHittable {
                tab.tap()
            } else {
                app.buttons[name].firstMatch.tap()
            }
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10))
            let month = app.buttons.matching(NSPredicate(
                format: "label MATCHES %@", ".*20[0-9]{2}年[0-9]{1,2}月.*"
            )).firstMatch
            XCTAssertTrue(month.waitForExistence(timeout: 10), "月份入口：\(name)")
            capture("home-\(name)", app: app)
            month.tap()
            XCTAssertTrue(app.navigationBars["选择月份"].waitForExistence(timeout: 5))
            app.buttons["取消"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
        }

        let summaryTab = app.tabBars.buttons["汇总"].firstMatch
        if summaryTab.exists && summaryTab.isHittable {
            summaryTab.tap()
        } else {
            app.buttons["汇总"].firstMatch.tap()
        }
        app.buttons["设置"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        let fineTuning = app.buttons["精细调整"].firstMatch
        for _ in 0..<4 where !fineTuning.isHittable { app.swipeUp() }
        XCTAssertTrue(fineTuning.isHittable)
        for _ in 0..<5 {
            fineTuning.tap()
            XCTAssertTrue(app.textFields["六位颜色代码"].waitForExistence(timeout: 3))
            fineTuning.tap()
            XCTAssertTrue(app.textFields["六位颜色代码"].waitForNonExistence(timeout: 3))
        }
        fineTuning.tap()
        XCTAssertTrue(app.sliders["红色"].exists)
        XCTAssertTrue(app.sliders["绿色"].exists)
        XCTAssertTrue(app.sliders["蓝色"].exists)
        capture("theme-expanded", app: app)
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        // Allow List's cell insertion and the tab transition to finish drawing before visual QA.
        Thread.sleep(forTimeInterval: 1)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "ui-regression-failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }
}
