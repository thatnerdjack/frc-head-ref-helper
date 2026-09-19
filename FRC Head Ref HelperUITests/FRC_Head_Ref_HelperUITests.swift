//
//  FRC_Head_Ref_HelperUITests.swift
//  FRC Head Ref HelperUITests
//
//  A smoke suite that proves the app renders.
//
//  This exists because every defect found on a real device in this project so
//  far has been VISUAL — ragged cell heights, a tap animation that never
//  fired, a cropped Dynamic Island region, a countdown that crashed the
//  widget. The unit suite is good and caught none of them, because none of
//  them are logic.
//
//  Two rules the assertions here follow:
//
//  1. Assert on content that is UNIQUE to the screen under test. `-refScreen`
//     FAILS OPEN — `applyDebugLaunchArguments` sends any unrecognised value to
//     the Now tab rather than erroring — so "the app launched" and "the right
//     screen appeared" are very different claims, and only the second is worth
//     making. `unknownScreenFallsBackToNow` documents that behaviour rather
//     than leaving it as a trap.
//
//  2. Never assert on a clock. `startClock()` ticks every second, so any
//     expectation involving a countdown is a flake waiting for a slow machine.
//

import XCTest

final class FRC_Head_Ref_HelperUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches straight to a screen. The app seeds sample entries on a fresh
    /// install, so every screen has content without any setup.
    @MainActor
    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-refScreen", screen]
        app.launch()
        return app
    }

    // MARK: - Screens

    @MainActor
    func testNowScreenShowsTheMatchOnTheField() {
        let app = launch("now")
        // The sample event has Q41 on the field with six teams on it.
        XCTAssertTrue(app.staticTexts["Q41"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["8341"].exists)
        XCTAssertTrue(app.staticTexts["Ridge Robotics"].exists)
    }

    @MainActor
    func testTeamsScreenListsTeams() {
        let app = launch("teams")
        XCTAssertTrue(app.navigationBars["Teams"].waitForExistence(timeout: 10))
        // The search field is unique to this screen.
        XCTAssertTrue(app.searchFields.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Gearhawks"].exists)
    }

    @MainActor
    func testTeamDetailShowsThatTeamsRecord() {
        let app = launch("team")
        // 8341 carries two warnings for G418 in the seeded data, so the
        // escalation card is the thing that proves this is the detail screen
        // and not the Now tab showing the same number.
        XCTAssertTrue(app.staticTexts["ESCALATION"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["THIS EVENT"].exists)
    }

    @MainActor
    func testSettingsShowsSourcesAndCoverage() {
        let app = launch("settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Event code"].exists)
        XCTAssertTrue(app.switches.firstMatch.exists, "the source toggles render")
    }

    @MainActor
    func testComposeSheetOpensOnASubject() {
        let app = launch("compose")
        XCTAssertTrue(app.navigationBars["New entry"].waitForExistence(timeout: 10))
        // The three ordered sections the sheet is built around.
        XCTAssertTrue(app.staticTexts["WHO"].exists)
        XCTAssertTrue(app.staticTexts["WHAT HAPPENED"].exists)
    }

    @MainActor
    func testDayCompleteShowsWhatCarriesIntoTomorrow() {
        let app = launch("day")
        XCTAssertTrue(app.staticTexts["CARRIES INTO TOMORROW"].waitForExistence(timeout: 10))
    }

    // MARK: - The fail-open trap

    @MainActor
    func testUnknownScreenFallsBackToNow() {
        // Documented rather than fixed: applyDebugLaunchArguments' default case
        // sends anything it does not recognise to the Now tab. A typo in a
        // screenshot script therefore produces a GREEN run of the wrong
        // screen, and anyone writing one should know that.
        let app = launch("notarealscreen")
        XCTAssertTrue(app.staticTexts["Q41"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Settings"].exists)
    }

    // MARK: - Layout regressions

    @MainActor
    func testNextMatchCellsShareOneHeight() {
        // The exact bug shipped and fixed in a previous round: the three team
        // cells in an alliance row are laid out independently, and a cell whose
        // conditional content collapsed rendered shorter than its siblings.
        // Tolerance is a point, not zero — these are floating-point frames.
        let app = launch("now")
        XCTAssertTrue(app.staticTexts["Q41"].waitForExistence(timeout: 10))

        let cells = ["3129", "8802", "6440"].map { app.staticTexts[$0] }
        for cell in cells {
            XCTAssertTrue(cell.exists, "next-match cell missing")
        }
        // 6440 is flagged as missing from the field and 3129 is not, which is
        // precisely the asymmetry that used to produce different heights.
        let heights = cells.map { $0.frame.height }
        guard let first = heights.first else { return XCTFail("no cells") }
        for height in heights {
            XCTAssertEqual(height, first, accuracy: 1.0,
                           "next-match cells must share one height")
        }
    }

    @MainActor
    func testTeamDetailStatTilesShareOneHeight() {
        // "Verbal warnings" wraps to two lines while "Cards" and "Notes" do
        // not, which used to make the first tile taller than its neighbours.
        let app = launch("team")
        XCTAssertTrue(app.staticTexts["THIS EVENT"].waitForExistence(timeout: 10))

        let labels = ["Verbal warnings", "Cards", "Notes"].map { app.staticTexts[$0] }
        for label in labels {
            XCTAssertTrue(label.exists, "stat tile label missing")
        }
        let tops = labels.map { $0.frame.minY }
        guard let first = tops.first else { return XCTFail("no tiles") }
        for top in tops {
            XCTAssertEqual(top, first, accuracy: 1.0,
                           "stat tile labels must sit on one baseline")
        }
    }
}
