import XCTest

final class CurrentUITests: XCTestCase {
    @MainActor func testDemoPoolRequiresPersonalOpenRouterKey() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.tabBars.buttons["我的"].tap()
        app.buttons["openAISettings"].tap()
        if app.buttons["clearOpenRouterKey"].exists { app.buttons["clearOpenRouterKey"].tap() }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["此刻"].tap()
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
        XCTAssertTrue(app.alerts["暂时无法完成"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["请先在我的 → AI 设置填写个人 OpenRouter Key。"].exists)
        XCTAssertFalse(app.buttons["miniPlayer"].exists)
    }
    @MainActor func testPersonalKeySettingsSaveAndClear() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.tabBars.buttons["我的"].tap()
        app.buttons["openAISettings"].tap()
        XCTAssertTrue(app.staticTexts["openrouter/free"].waitForExistence(timeout: 5))
        if app.buttons["clearOpenRouterKey"].exists { app.buttons["clearOpenRouterKey"].tap() }
        XCTAssertFalse(app.buttons["saveOpenRouterKey"].isEnabled)
        let input = app.secureTextFields["openRouterKeyInput"]
        input.tap(); input.typeText("fixture-only-ui-key")
        app.buttons["saveOpenRouterKey"].tap()
        XCTAssertTrue(app.staticTexts["已保存个人 Key"].waitForExistence(timeout: 3))
        app.buttons["clearOpenRouterKey"].tap()
        XCTAssertTrue(app.staticTexts["尚未配置个人 Key"].waitForExistence(timeout: 3))
    }
}
