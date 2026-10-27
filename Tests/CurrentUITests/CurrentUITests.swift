import XCTest

final class CurrentUITests: XCTestCase {
    @MainActor func testPlaybackScrubberSeeksWithoutJumpingAndResetsForNextTrack() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-playlist-preview"]
        app.launch()
        let play = app.buttons["playGeneratedPlaylist"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        app.buttons["miniPlayer"].tap()
        let toggle = app.buttons["playerToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.label == "暂停" { toggle.tap() }
        let slider = app.sliders["播放进度"]
        XCTAssertTrue(slider.isHittable)
        XCTAssertGreaterThanOrEqual(slider.frame.height, 44)
        let elapsed = app.staticTexts["playerElapsedTime"]
        func seconds() -> Int {
            let parts = elapsed.label.split(separator: ":").compactMap { Int($0) }
            return parts.count == 2 ? parts[0] * 60 + parts[1] : -100
        }
        func capture(_ name: String) {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = name; image.lifetime = .keepAlways; add(image)
        }
        // Pressing far from the playhead must not jump to the finger's position.
        let before = seconds()
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        XCTAssertEqual(seconds(), before, accuracy: 1)
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        XCTAssertGreaterThan(seconds(), before + 5)
        let sought = seconds()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(seconds(), sought, accuracy: 1, "A completed seek must not snap back")
        XCTAssertEqual(toggle.label, "播放", "Seeking while paused must keep playback paused")
        XCTAssertTrue(app.staticTexts["playerRemainingTime"].label.hasPrefix("−"))
        capture("player-scrubber-paused-after-seek")

        toggle.tap()
        expectation(for: NSPredicate { _, _ in seconds() > sought }, evaluatedWith: elapsed)
        waitForExpectations(timeout: 5)
        toggle.tap()
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        XCTAssertLessThanOrEqual(seconds(), 1)
        capture("player-scrubber-at-start")

        app.buttons["playerNext"].tap()
        expectation(for: NSPredicate { _, _ in seconds() >= 0 && seconds() < 5 }, evaluatedWith: elapsed)
        waitForExpectations(timeout: 5)
        if toggle.label == "暂停" { toggle.tap() }
        XCTAssertTrue(slider.isHittable)
        capture("player-scrubber-next-track")
        app.buttons["收起播放器"].tap()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 5))
    }

    @MainActor func testPlayerReturnsToMiniBarAndCanReopenAcrossTabs() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-mini-player"]
        app.launch()
        let miniPlayer = app.buttons["miniPlayer"]
        let collapse = app.buttons["收起播放器"]
        let hittable = NSPredicate(format: "isHittable == true")

        for tab in ["此刻", "音乐库", "我的"] {
            app.tabBars.buttons[tab].tap()
            expectation(for: hittable, evaluatedWith: miniPlayer)
            waitForExpectations(timeout: 5)
            miniPlayer.tap()
            XCTAssertTrue(collapse.waitForExistence(timeout: 5))
            expectation(for: hittable, evaluatedWith: collapse)
            waitForExpectations(timeout: 5)

            let header = app.staticTexts["正在播放"]
            let headerY = header.frame.minY
            XCTAssertTrue(app.sliders["播放进度"].isHittable)
            XCTAssertTrue(app.buttons["playbackTempo"].isHittable)
            XCTAssertTrue(app.buttons["openFeedback"].isHittable)
            XCTAssertTrue(app.buttons["likeTrack"].isHittable)
            // An upward drag must not scroll the header away or create a scroll offset
            // that consumes the first subsequent downward dismissal gesture.
            let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                .descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
            if banner.exists { banner.swipeUp() }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            XCTAssertEqual(header.frame.minY, headerY, accuracy: 2)

            // Drag from the header, clear of the seek slider and playback controls.
            if banner.exists { banner.swipeUp() }
            header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: collapse)
            waitForExpectations(timeout: 5)
            expectation(for: hittable, evaluatedWith: miniPlayer)
            waitForExpectations(timeout: 5)

            // The source must remain usable after an interactive dismissal.
            miniPlayer.tap()
            expectation(for: hittable, evaluatedWith: collapse)
            waitForExpectations(timeout: 5)
            collapse.tap()
            expectation(for: hittable, evaluatedWith: miniPlayer)
            waitForExpectations(timeout: 5)
        }
    }

    @MainActor func testLibraryPlayAllReplacesQueueWithFilteredSongs() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-library-genres"]
        app.launch()
        app.tabBars.buttons["音乐库"].tap()
        XCTAssertTrue(app.staticTexts["2 首歌曲"].waitForExistence(timeout: 10))
        app.buttons["libraryPlayAll"].tap()
        app.tabBars.buttons["此刻"].tap()
        XCTAssertTrue(app.staticTexts["2 首"].waitForExistence(timeout: 5))
        app.tabBars.buttons["音乐库"].tap()
        app.buttons["libraryFilters"].tap()
        app.buttons["libraryWiki:family:电子"].tap()
        app.buttons["libraryWiki:option:电子-House"].tap()
        app.buttons["查看 1 首"].tap()
        XCTAssertTrue(app.staticTexts["1 首歌曲"].waitForExistence(timeout: 5))
        app.buttons["libraryPlayAll"].tap()
        app.tabBars.buttons["此刻"].tap()
        XCTAssertTrue(app.staticTexts["1 首"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["非 House 样本"].exists)
        XCTAssertFalse(app.staticTexts["House 筛选样本"].exists)
    }

    @MainActor func testLibraryFiltersExposeHouseAndSubstyles() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-library-genres"]
        app.launch()
        app.tabBars.buttons["音乐库"].tap()
        XCTAssertTrue(app.staticTexts["2 首歌曲"].waitForExistence(timeout: 10))
        app.buttons["libraryFilters"].tap()
        XCTAssertTrue(app.staticTexts["音频曲风"].waitForExistence(timeout: 5))
        app.buttons["libraryAudio:family:电子"].tap()
        XCTAssertTrue(app.staticTexts["百科曲风"].exists)
        XCTAssertTrue(app.buttons["libraryAudio:option:House"].exists)
        XCTAssertTrue(app.buttons["libraryAudio:option:Deep House"].exists)
        app.buttons["libraryAudio:option:House"].tap()
        XCTAssertTrue(app.buttons["查看 1 首"].waitForExistence(timeout: 5))
        app.buttons["查看 1 首"].tap()
        XCTAssertTrue(app.staticTexts["House 筛选样本"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["非 House 样本"].exists)
        app.buttons["移除筛选：House"].tap()
        XCTAssertTrue(app.staticTexts["2 首歌曲"].waitForExistence(timeout: 5))
        app.buttons["libraryFilters"].tap()
        app.buttons["libraryWiki:family:电子"].tap()
        app.buttons["libraryWiki:option:电子-House"].tap()
        XCTAssertTrue(app.buttons["查看 1 首"].waitForExistence(timeout: 5))
        app.buttons["查看 1 首"].tap()
        XCTAssertTrue(app.staticTexts["非 House 样本"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["House 筛选样本"].exists)
        app.buttons["libraryFilters"].tap()
        app.buttons["libraryAudio:family:电子"].tap()
        app.buttons["libraryAudio:option:House"].tap()
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
        XCTAssertFalse(app.buttons["configureDeepSeek"].exists)
        XCTAssertFalse(app.buttons["playlistGenreConditions"].exists)
        XCTAssertFalse(app.staticTexts["DeepSeek · 按需求匹配歌曲池"].exists)
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

    @MainActor func testDemoPoolRequiresPersonalDeepSeekKey() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.tabBars.buttons["我的"].tap()
        app.buttons["openAISettings"].tap()
        if app.buttons["clearDeepSeekKey"].exists { app.buttons["clearDeepSeekKey"].tap() }
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
        XCTAssertTrue(app.buttons["generationAISettings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["暂时无法完成"].exists)
        XCTAssertTrue(app.staticTexts["请先在我的 → AI 设置填写个人 DeepSeek Key。"].exists)
        XCTAssertFalse(app.buttons["miniPlayer"].exists)
    }
    @MainActor func testGeneratedPlaylistWaitsForExplicitPlayback() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-playlist-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["generatedPlaylistTitle"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["miniPlayer"].exists)
        XCTAssertFalse(app.staticTexts["feedbackToast"].exists)
        XCTAssertFalse(app.staticTexts["recommendationConditions"].exists)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "playlist-preview-before-playback"; preview.lifetime = .keepAlways; add(preview)
        let conditions = app.buttons["查看匹配条件"]
        for _ in 0..<4 {
            if conditions.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        conditions.tap()
        XCTAssertTrue(app.staticTexts["recommendationConditions"].waitForExistence(timeout: 5))
        conditions.tap()
        let play = app.buttons["playGeneratedPlaylist"]
        if !play.isHittable { app.scrollViews.firstMatch.swipeDown() }
        play.tap()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["正在播放"].exists, "Playback must not open the player sheet")
        let playing = XCTAttachment(screenshot: app.screenshot())
        playing.name = "playlist-explicit-playback"; playing.lifetime = .keepAlways; add(playing)
    }

    @MainActor func testNewPlaylistPreviewPreservesExistingMiniPlayer() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-mini-player", "-ui-testing-playlist-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["generatedPlaylistTitle"].waitForExistence(timeout: 10))
        let mini = app.buttons["miniPlayer"]
        XCTAssertTrue(mini.exists)
        XCTAssertEqual(mini.label, "正在播放：暮色缓流")
        let track = app.buttons["generatedTrack:1"]
        for _ in 0..<4 {
            if track.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        track.tap()
        XCTAssertEqual(mini.label, "正在播放：沿着海岸")
        XCTAssertFalse(app.staticTexts["正在播放"].exists)
    }

    @MainActor func testPersonalKeySettingsSaveAndClear() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.tabBars.buttons["我的"].tap()
        app.buttons["openAISettings"].tap()
        XCTAssertTrue(app.staticTexts["deepseek-flash"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["OpenRouter"].exists)
        XCTAssertFalse(app.staticTexts["openrouter/free"].exists)
        XCTAssertFalse(app.buttons["获取 OpenRouter Key"].exists)
        if app.buttons["clearDeepSeekKey"].exists { app.buttons["clearDeepSeekKey"].tap() }
        XCTAssertFalse(app.buttons["saveDeepSeekKey"].isEnabled)
        let input = app.secureTextFields["deepSeekKeyInput"]
        input.tap(); input.typeText("fixture-only-ui-key")
        app.buttons["saveDeepSeekKey"].tap()
        XCTAssertTrue(app.staticTexts["已保存个人 Key"].waitForExistence(timeout: 3))
        app.buttons["clearDeepSeekKey"].tap()
        XCTAssertTrue(app.staticTexts["尚未配置个人 Key"].waitForExistence(timeout: 3))
    }
}
