import XCTest

final class CurrentUITests: XCTestCase {
    @MainActor func testDemoQueuePlaybackFeedbackAndLogout() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        let demo = app.buttons["enterDemo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        // Semantic recommendations consume the pool, so prepare it through the real management flow.
        app.tabBars.buttons["我的"].tap()
        app.buttons["歌曲池"].tap()
        app.buttons["加入歌曲"].tap()
        app.buttons["原创演示曲库"].tap()
        XCTAssertTrue(app.buttons["全部加入"].waitForExistence(timeout: 5))
        app.buttons["全部加入"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["完成"].tap()
        let toggle = app.buttons["poolToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(app.staticTexts["8 首已分析"].waitForExistence(timeout: 120))
        app.tabBars.buttons["此刻"].tap()
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
