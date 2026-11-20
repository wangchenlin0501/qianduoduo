import XCTest

final class TodoCompletionOrderUITests: XCTestCase {
    @MainActor
    func testCompletionGroupsBelowPendingAndRestoresOriginalOrder() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-todoShowCompleted", "YES", "-todoSort", "手动"
        ]
        app.launch()
        let todoTab = app.buttons["待办"].firstMatch
        XCTAssertTrue(todoTab.waitForExistence(timeout: 60))
        todoTab.tap()

        let titles = ["验证第一项", "验证中间项", "验证最后项"]
        for title in titles {
            app.buttons["添加待办"].tap()
            let draft = app.textFields.matching(NSPredicate(format: "value == '' OR value == '待办事项'")).firstMatch
            XCTAssertTrue(draft.waitForExistence(timeout: 5))
            draft.tap()
            draft.typeText(title)
            app.buttons["完成输入"].tap()
        }

        func titleField(_ title: String) -> XCUIElement {
            app.textFields.matching(NSPredicate(format: "value == %@", title)).firstMatch
        }
        func completionButton(_ label: String, title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label == %@ AND value == %@", label, title)).firstMatch
        }
        func expectOrder(_ orderedTitles: [String]) {
            let settled = NSPredicate { _, _ in
                let fields = orderedTitles.map(titleField)
                return fields.allSatisfy(\.exists)
                    && zip(fields, fields.dropFirst()).allSatisfy { $0.frame.minY < $1.frame.minY }
            }
            expectation(for: settled, evaluatedWith: app)
            waitForExpectations(timeout: 8)
        }

        expectOrder(titles)
        completionButton("标记完成", title: titles[1]).tap()
        expectOrder([titles[0], titles[2], titles[1]])
        completionButton("标记完成", title: titles[0]).tap()
        expectOrder([titles[2], titles[0], titles[1]])

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "todo-pending-above-completed"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.terminate()
        app.launch()
        app.buttons["待办"].firstMatch.tap()
        expectOrder([titles[2], titles[0], titles[1]])
        completionButton("恢复待办", title: titles[1]).tap()
        expectOrder([titles[1], titles[2], titles[0]])
        completionButton("恢复待办", title: titles[0]).tap()
        expectOrder(titles)
    }
}
