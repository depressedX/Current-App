import XCTest

final class CurrentUITests: XCTestCase {
    @MainActor func testDemoQueuePlaybackFeedbackAndLogout() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        let demo = app.buttons["enterDemo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        let input = app.textFields["promptInput"].exists ? app.textFields["promptInput"] : app.textViews["promptInput"]
        input.tap(); input.typeText("Evening rock")
        let done = app.buttons["完成"]
        if done.exists { done.tap() }
        app.buttons["generateQueue"].tap()
        let mini = app.buttons["miniPlayer"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        mini.tap()
        XCTAssertTrue(app.buttons["playerNext"].waitForExistence(timeout: 5))
        app.buttons["likeTrack"].tap()
        app.buttons["openFeedback"].tap()
        app.buttons["feedback-wrongMood"].tap()
        app.buttons["收起播放器"].tap()
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.staticTexts["情绪不太对"].waitForExistence(timeout: 3))
        app.swipeUp()
        app.buttons["signOut"].tap()
        app.buttons["退出"].tap()
        XCTAssertTrue(app.staticTexts["尚未登录"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["miniPlayer"].exists)
    }
}
