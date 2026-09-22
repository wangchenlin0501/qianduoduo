//
//  QianDuoDuoUITests.swift
//  钱多多UITests
//
//

import XCTest

final class QianDuoDuoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesToDashboard() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["钱多多"].waitForExistence(timeout: 3))
    }
}
