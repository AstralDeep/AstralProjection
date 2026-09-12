import XCTest

final class WorkspacePresentationUITests: XCTestCase {
    func testWorkspaceActionsFollowServerOrderKeepNativeTargetsAndLeaveWithCanvas() {
        let app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-first-login", "workspace-actions"]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()
        defer { app.terminate() }
        let export = app.buttons["workspace-action-export"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        let share = app.buttons["workspace-action-share"]
        XCTAssertTrue(share.exists)
        XCTAssertFalse(app.buttons["Export this canvas as HTML"].exists)
        let controls = [
            app.buttons["new-chat-button"], app.buttons["Recent chats"], export, share,
            app.buttons["Pulse"], app.buttons["Timeline"],
        ]
        let window = app.windows.firstMatch.frame
        for (index, control) in controls.enumerated() {
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertGreaterThanOrEqual(control.frame.minX, window.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, window.maxX)
            if index > 0 {
                let previous = controls[index - 1].frame
                XCTAssertTrue(control.frame.minY > previous.minY || control.frame.minX >= previous.maxX)
            }
        }
        capture(app, name: "workspace-088-server-actions-native-wrap")
        app.buttons["new-chat-button"].tap()
        XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 3))
        XCTAssertFalse(export.exists)
        XCTAssertFalse(share.exists)
    }

    func testHistoryPreviewsDistinguishSameTitleConversationsAndOpenExactRow() {
        let app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-first-login", "workspace-history"]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()
        defer { app.terminate() }
        let preview = app.staticTexts["Alpha = 2 Beta = 5"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["First preview"].exists)
        XCTAssertTrue(app.staticTexts["3h"].exists)
        capture(app, name: "workspace-088-history-server-rows")
        preview.tap()
        XCTAssertTrue(app.staticTexts["Opened second history row"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Opened first history row"].exists)
        app.buttons["Recent chats"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["First preview"].exists)
        XCTAssertTrue(app.staticTexts["2h"].exists)
        XCTAssertTrue(app.staticTexts["3h"].exists)
        app.staticTexts["First preview"].tap()
        XCTAssertTrue(app.staticTexts["Opened first history row"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Opened second history row"].exists)
    }

    func testMetricContentAndNativeNewChatTargetMatchWebWorkspace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-first-login", "workspace-styles"]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()
        defer { app.terminate() }

        let total = app.staticTexts["TOTAL"]
        XCTAssertTrue(total.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["18"].exists)
        XCTAssertTrue(app.staticTexts["Six dice"].exists)
        XCTAssertTrue(app.staticTexts["COMPLETED"].exists)
        let newChat = app.buttons["new-chat-button"]
        XCTAssertGreaterThanOrEqual(newChat.frame.width, 44)
        XCTAssertGreaterThanOrEqual(newChat.frame.height, 44)
        capture(app, name: "workspace-088-card-metrics-native-target")
        newChat.tap()
        XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 3))
        XCTAssertFalse(total.exists)
    }

    #if os(iOS)
        func testCancelingComponentRefinementPreservesResultSelectedTabAndComposerDraft() {
            let app = XCUIApplication()
            app.launchArguments = ["--astral-ui-test-first-login", "workspace-rich-result"]
            app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
            app.launch()
            defer { app.terminate() }
            let toggle = app.buttons["workspace-messages-toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 8))
            toggle.tap()
            let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch
            composer.tap()
            composer.typeText("Draft to keep")
            let canvas = app.scrollViews["workspace-canvas-scroll"]
            for _ in 0..<10 {
                if app.staticTexts["Overview pane is selected"].isHittable { break }
                canvas.swipeUp(velocity: .slow)
            }
            app.buttons["Measurements"].tap()
            XCTAssertTrue(app.staticTexts["Measurement pane is selected"].waitForExistence(timeout: 3))
            app.buttons["Result details"].press(forDuration: 1)
            let menuRefine = app.buttons["Refine…"]
            XCTAssertTrue(menuRefine.waitForExistence(timeout: 3))
            menuRefine.tap()
            XCTAssertTrue(app.staticTexts["Refine Result details"].waitForExistence(timeout: 3))
            let submit = app.buttons["Refine"].firstMatch
            XCTAssertFalse(submit.isEnabled)
            // The unlabelled native field's placeholder becomes its value
            // after typing. Identify the sheet field independently of its text.
            let fields = app.textFields.matching(NSPredicate(format: "identifier != %@", "chat-composer-input"))
            XCTAssertEqual(fields.count, 1)
            let instruction = fields.firstMatch
            instruction.tap()
            instruction.typeText("   ")
            XCTAssertFalse(submit.isEnabled)
            instruction.typeText("Sort by total")
            XCTAssertTrue(submit.isEnabled)
            capture(app, name: "workspace-088-refine-edit-before-cancel")
            // Cancellation is local. This fixture does not pretend to process
            // a component_refine command or produce a server-side revision.
            app.buttons["Cancel"].tap()
            XCTAssertFalse(app.staticTexts["Refine Result details"].exists)
            XCTAssertEqual(composer.value as? String, "Draft to keep")
            XCTAssertTrue(app.staticTexts["Measurement pane is selected"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.staticTexts["Overview pane is selected"].exists)
            for _ in 0..<8 {
                if app.staticTexts["Measurement pane is selected"].isHittable { break }
                canvas.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(app.staticTexts["Measurement pane is selected"].isHittable)
            capture(app, name: "workspace-088-refine-cancel-preserves-tab-and-draft")
        }

        func testSlashSuggestionAndOneShotBackgroundSendUseTheExistingComposer() {
            let app = XCUIApplication()
            app.launchArguments = ["--astral-ui-test-first-login", "workspace-start"]
            app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.staticTexts["How can I help?"].waitForExistence(timeout: 8))
            let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch
            XCTAssertTrue((composer.value as? String ?? "").contains("First line"))
            app.buttons["new-chat-button"].tap()
            XCTAssertFalse((composer.value as? String ?? "").contains("First line"))
            composer.tap()
            composer.typeText("/r")
            XCTAssertEqual(composer.value as? String, "/r")
            let suggestion = app.buttons["/research"]
            XCTAssertTrue(suggestion.waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["/help"].exists)
            suggestion.tap()
            XCTAssertEqual(composer.value as? String, "/research ")
            composer.typeText("Summarize the synthetic measurements")
            XCTAssertFalse(suggestion.exists)
            let background = app.buttons["Run in background"]
            XCTAssertEqual(background.value as? String, "Off")
            background.tap()
            XCTAssertEqual(background.value as? String, "On")
            app.buttons["Send message"].tap()
            // This proves the native composer and its one-shot arming. The
            // existing deterministic reply is not evidence of a real worker.
            XCTAssertTrue(app.staticTexts["Workspace result"].waitForExistence(timeout: 5))
            XCTAssertEqual(background.value as? String, "Off")
            XCTAssertFalse((composer.value as? String ?? "").contains("/research"))
            XCTAssertTrue(app.staticTexts["/research Summarize the synthetic measurements"].exists)
            capture(app, name: "workspace-088-slash-background-send-disarms")
        }

        func testRichResultKeepsVisibleValuesAndSelectedTabAfterDisclosureReopens() {
            let app = XCUIApplication()
            app.launchArguments = ["--astral-ui-test-first-login", "workspace-rich-result"]
            app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
            app.launch()
            defer { app.terminate() }
            let toggle = app.buttons["workspace-messages-toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 8))
            toggle.tap()
            let canvas = app.scrollViews["workspace-canvas-scroll"]
            XCTAssertTrue(canvas.exists)
            for label in [
                "SYNTHETIC REVIEW", "Review report", "One result, with details you can revisit", "Local fixture",
                "Review required", "Check the original measurements before proceeding.",
                "Review confidence", "3.5/5", "Based on seven observations", "Checks complete", "50%",
                "Result source", "Source", "Synthetic measurements", "Review history", "09:30",
                "Validation complete", "The measurements were normalized.", "total = 18",
                "Inspect each measurement", "Record the review outcome",
            ] {
                let text = app.staticTexts[label]
                for _ in 0..<8 {
                    if text.isHittable { break }
                    canvas.swipeUp(velocity: .slow)
                }
                XCTAssertTrue(text.isHittable, "The displayed result must include \(label)")
                XCTAssertGreaterThanOrEqual(text.frame.minX, canvas.frame.minX)
                XCTAssertLessThanOrEqual(text.frame.maxX, canvas.frame.maxX)
            }
            let details = app.buttons["Result details"]
            for _ in 0..<8 {
                if app.staticTexts["Overview pane is selected"].isHittable { break }
                canvas.swipeUp(velocity: .slow)
            }
            XCTAssertEqual(details.value as? String, "Expanded")
            XCTAssertTrue(app.staticTexts["Overview pane is selected"].isHittable)
            app.buttons["Measurements"].tap()
            XCTAssertTrue(app.staticTexts["Measurement pane is selected"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.staticTexts["Overview pane is selected"].exists)
            capture(app, name: "workspace-088-rich-result-selected-tab")
            details.tap()
            XCTAssertEqual(details.value as? String, "Collapsed")
            XCTAssertFalse(app.staticTexts["Measurement pane is selected"].exists)
            details.tap()
            XCTAssertEqual(details.value as? String, "Expanded")
            XCTAssertTrue(app.staticTexts["Measurement pane is selected"].waitForExistence(timeout: 3))
            // Collapsing content can clamp the scroll position to the shorter
            // canvas. Reopening restores the selected pane below that viewport.
            for _ in 0..<8 {
                if app.staticTexts["Measurement pane is selected"].isHittable { break }
                canvas.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(app.staticTexts["Measurement pane is selected"].isHittable)
            XCTAssertFalse(app.staticTexts["Overview pane is selected"].exists)
            capture(app, name: "workspace-088-rich-result-retained-tab-after-reopen")
        }
    #endif

    func testPhoneCanScrollToTheCompleteBelowFoldChartAndBackAfterMessagesCollapse() throws {
        #if os(iOS)
            let app = XCUIApplication()
            app.launchArguments = ["--astral-ui-test-first-login", "workspace-chart-scroll"]
            app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
            app.launch()
            defer { app.terminate() }
            let toggle = app.buttons["workspace-messages-toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 8))
            toggle.tap()
            let canvas = app.scrollViews["workspace-canvas-scroll"]
            let chart = app.webViews.firstMatch
            let footer = app.staticTexts["Complete chart footer"]
            for _ in 0..<12 {
                if chart.exists, footer.isHittable, canvas.frame.contains(chart.frame) { break }
                canvas.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(chart.waitForExistence(timeout: 5))
            XCTAssertTrue(chart.isHittable)
            XCTAssertTrue(canvas.frame.contains(chart.frame), "The whole chart must fit within the visible canvas")
            XCTAssertTrue(footer.isHittable)
            XCTAssertTrue(app.staticTexts["Below-fold Alpha vs Beta"].isHittable)
            XCTAssertFalse(app.staticTexts["Chart could not be displayed. Reopen this result to try again."].exists)
            capture(app, name: "workspace-088-complete-below-fold-chart-synthetic-fixture")
            for _ in 0..<12 {
                if app.staticTexts["Dice layout regression"].isHittable { break }
                canvas.swipeDown(velocity: .slow)
            }
            XCTAssertTrue(app.staticTexts["Dice layout regression"].isHittable)
            toggle.tap()
            XCTAssertTrue(app.scrollViews["conversation-message-scroll"].waitForExistence(timeout: 3))
        #endif
    }

    func testPhoneCanvasRemainsResponsiveWhileCollapsingAndScrollingMessages() throws {
        #if os(iOS)
            let app = XCUIApplication()
            app.launchArguments = ["--astral-ui-test-first-login", "workspace-canvas"]
            app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
            app.launch()
            defer { app.terminate() }

            guard app.windows.firstMatch.frame.width < 700 else {
                throw XCTSkip("requires the phone stacked workspace layout")
            }
            let toggle = app.buttons["workspace-messages-toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            let canvas = app.scrollViews["workspace-canvas-scroll"]
            XCTAssertTrue(canvas.exists)
            for _ in 0..<5 {
                toggle.tap()
                XCTAssertFalse(app.scrollViews["conversation-message-scroll"].exists)
                canvas.swipeUp()
                XCTAssertTrue(app.staticTexts["Canvas layout end"].waitForExistence(timeout: 3))
                toggle.tap()
                XCTAssertTrue(app.scrollViews["conversation-message-scroll"].waitForExistence(timeout: 3))
                canvas.swipeDown()
            }
            let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch
            composer.tap()
            composer.typeText("Still responsive")
            XCTAssertTrue((composer.value as? String ?? "").contains("Still responsive"))
            capture(app, name: "workspace-088-canvas-collapse-scroll-synthetic-fixture")
        #endif
    }

    func testStartComposerDisclosureAndIrreversibleWorkTransition() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--astral-ui-test-first-login", "workspace-start"]
        app.launchEnvironment["ASTRAL_UI_TESTING"] = "1"
        app.launch()
        defer { app.terminate() }

        let title = app.staticTexts["How can I help?"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        capture(app, name: "workspace-088-start-synthetic-fixture")
        XCTAssertTrue(app.buttons["Research brief"].exists)
        XCTAssertFalse(app.buttons["Business dashboard"].exists)
        app.buttons["More examples"].tap()
        XCTAssertTrue(app.buttons["Business dashboard"].waitForExistence(timeout: 3))
        capture(app, name: "workspace-088-more-synthetic-fixture")
        app.buttons["More examples"].tap()

        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer-input").firstMatch
        XCTAssertTrue(composer.exists)
        composer.tap()
        composer.typeText("Second line")
        XCTAssertTrue((composer.value as? String ?? "").contains("Second line"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "workspace-088-multiline-composer"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts["Workspace result"].waitForExistence(timeout: 5))
        capture(app, name: "workspace-088-work-synthetic-fixture")
        XCTAssertFalse(title.exists)
        XCTAssertFalse(app.buttons["Research brief"].exists)
        app.buttons["New chat"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 3))
    }
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
