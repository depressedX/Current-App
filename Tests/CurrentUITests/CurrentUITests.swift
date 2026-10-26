import XCTest

final class CurrentUITests: XCTestCase {
    @MainActor func testLibraryFiltersExposeHouseAndSubstyles() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-library-genres"]
        app.launch()
        app.tabBars.buttons["音乐库"].tap()
        XCTAssertTrue(app.staticTexts["2 首歌曲"].waitForExistence(timeout: 10))
        app.buttons["libraryFilters"].tap()
        XCTAssertTrue(app.staticTexts["音频风格大类"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["音频具体风格"].exists)
        XCTAssertTrue(app.staticTexts["百科曲风"].exists)
        XCTAssertTrue(app.buttons["House"].exists)
        XCTAssertTrue(app.buttons["Deep House"].exists)
        app.buttons["House"].tap()
        XCTAssertTrue(app.buttons["查看 1 首"].waitForExistence(timeout: 5))
        app.buttons["查看 1 首"].tap()
        XCTAssertTrue(app.staticTexts["House 筛选样本"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["非 House 样本"].exists)
        app.buttons["移除筛选：House"].tap()
        XCTAssertTrue(app.staticTexts["2 首歌曲"].waitForExistence(timeout: 5))
        app.buttons["libraryFilters"].tap()
        app.buttons["电子-House"].tap()
        XCTAssertTrue(app.buttons["查看 1 首"].waitForExistence(timeout: 5))
        app.buttons["查看 1 首"].tap()
        XCTAssertTrue(app.staticTexts["非 House 样本"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["House 筛选样本"].exists)
        app.buttons["libraryFilters"].tap()
        app.buttons["House"].tap()
        XCTAssertTrue(app.buttons["查看 2 首"].waitForExistence(timeout: 5))
        app.buttons["查看 2 首"].tap()
        XCTAssertTrue(app.staticTexts["2 首歌曲"].waitForExistence(timeout: 5))
        app.buttons["移除筛选：百科：电子-House"].tap()
        XCTAssertTrue(app.staticTexts["1 首歌曲"].waitForExistence(timeout: 5))
    }

    @MainActor func testHomeComposerKeepsMiniPlayerOutOfKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-mini-player"]
        app.launch()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["试试这些"].exists)
        XCTAssertFalse(app.buttons["configureOpenRouter"].exists)
        XCTAssertFalse(app.staticTexts["OpenRouter · 按需求匹配歌曲池"].exists)
        let input = app.textFields["promptInput"].exists ? app.textFields["promptInput"] : app.textViews["promptInput"]
        input.tap(); input.typeText("house")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["generateQueue"].isHittable)
        let hidden = NSPredicate(format: "exists == false")
        expectation(for: hidden, evaluatedWith: app.buttons["miniPlayer"])
        waitForExpectations(timeout: 5)
        // A native Done key may exist inside the keyboard; no separate Done toolbar remains.
        XCTAssertFalse(app.toolbars.buttons["完成"].exists)
        // AX updates before the system keyboard/accessory presentation finishes rendering.
        Thread.sleep(forTimeInterval: 1)
        let editing = XCTAttachment(screenshot: app.screenshot())
        editing.name = "home-editing-no-floating-player"; editing.lifetime = .keepAlways; add(editing)

        app.staticTexts["此刻想听什么？"].tap()
        expectation(for: hidden, evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 5))
        XCTAssertTrue((input.value as? String)?.contains("house") == true)
        Thread.sleep(forTimeInterval: 1)
        let restored = XCTAttachment(screenshot: app.screenshot())
        restored.name = "home-idle-native-mini-player"; restored.lifetime = .keepAlways; add(restored)
        app.tabBars.buttons["音乐库"].tap()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 5))
        app.tabBars.buttons["此刻"].tap()
        XCTAssertTrue((input.value as? String)?.contains("house") == true)
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.staticTexts["正在播放"].waitForExistence(timeout: 5))
    }

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
