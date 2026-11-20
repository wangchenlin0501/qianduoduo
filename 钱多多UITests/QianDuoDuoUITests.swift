//
//  QianDuoDuoUITests.swift
//  钱多多UITests
//
//  Created by Mashiro on 2026/5/7.
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
