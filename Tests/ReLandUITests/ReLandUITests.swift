import XCTest

@MainActor
final class ReLandUITests: XCTestCase {
    func testOnboardingExplainsPurposeAndPrerequisites() {
        let app = XCUIApplication()
        app.launchArguments = ["--reland-reset-onboarding"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Your computer, back in reach"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["No ReLand cloud relay"].exists)
        XCTAssertTrue(app.staticTexts["Before you pair"].exists)
        XCTAssertTrue(app.buttons["Continue to ReLand"].isHittable)
    }

    func testAppSettingsExposeControlsPrivacyAndStorage() {
        let app = XCUIApplication()
        app.launchArguments = ["--reland-device-list-e2e"]
        app.launch()

        let settings = app.buttons["appSettingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        XCTAssertTrue(
            app.navigationBars["Settings"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.switches["Three-finger app switching"].exists
        )
        let clearCache = app.buttons["Clear downloaded cache"]
        for _ in 0..<4 where !clearCache.exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            clearCache.waitForExistence(timeout: 3)
        )
        let clipboard = app.switches[
            "Allow terminal clipboard writes"
        ]
        for _ in 0..<4 where !clipboard.exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            clipboard.waitForExistence(timeout: 3)
        )
    }

    func testEmptyStateIsAccessible() {
        let app = XCUIApplication()
        app.launchArguments = ["--reland-skip-onboarding"]
        app.launch()

        XCTAssertTrue(app.navigationBars["ReLand"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add computer"].exists)
    }

    func testWindowsDeviceOffersOnlySupportedDesktopActions() {
        verifyWindowsDeviceActions()
    }

    private func verifyWindowsDeviceActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--reland-windows-device-list-e2e"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Example Windows PC"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["deviceScreenButton"].isHittable)
        XCTAssertFalse(app.buttons["deviceAppButton"].exists)
        XCTAssertFalse(app.buttons["deviceTerminalButton"].exists)
        XCTAssertTrue(app.buttons["Add computer"].exists)
        attachScreenshot(named: "Windows device actions")
    }

    func testWindowsSessionHidesMacServicesAndUsesWindowsKeyboardLabels() {
        verifyWindowsSessionControls()
    }

    private func verifyWindowsSessionControls() {
        let app = launchE2EApplication(port: "45456")
        XCTAssertTrue(app.buttons["keyboardButton"].isHittable)
        XCTAssertTrue(app.buttons["moreButton"].isHittable)
        XCTAssertFalse(app.buttons["appsButton"].exists)
        XCTAssertFalse(app.buttons["terminalButton"].exists)
        XCTAssertFalse(app.buttons["filesButton"].exists)
        attachScreenshot(named: "Windows desktop controls")

        app.buttons["keyboardButton"].tap()
        XCTAssertTrue(app.buttons["Windows"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Alt"].exists)
        XCTAssertTrue(app.buttons["Control"].exists)
        XCTAssertFalse(app.buttons["Command"].exists)
        attachScreenshot(named: "Windows keyboard controls")
        app.navigationBars["Keyboard"].buttons["Cancel"].tap()

        let acknowledgement = app.staticTexts["lastInputAck"]
        let canvas = app.otherElements["remoteCanvas"]
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForLabelChange(from: "No input sent", element: acknowledgement, timeout: 5)
        tapRemoteMoreControl("reconnectTestButton", in: app)
        waitForLabelChange(
            from: "Connected",
            element: app.staticTexts["connectionStatus"],
            timeout: 10
        )
        waitForLabel(
            "Connected",
            element: app.staticTexts["connectionStatus"],
            timeout: 10
        )
        XCTAssertFalse(app.buttons["appsButton"].exists)
        XCTAssertFalse(app.buttons["terminalButton"].exists)
        XCTAssertFalse(app.buttons["filesButton"].exists)
    }

    func testDeviceActionsAdaptOnPhone() {
        let app = XCUIApplication()
        app.launchArguments = ["--reland-device-list-e2e"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Example MacBook Pro with a Long Name"]
                .waitForExistence(timeout: 5)
        )
        for identifier in [
            "deviceScreenButton",
            "deviceAppButton",
            "deviceTerminalButton",
        ] {
            XCTAssertTrue(app.buttons[identifier].isHittable)
        }
        attachScreenshot(named: "Device actions")
        verifyWindowsDeviceActions()
    }

    func testTerminalActionsSheetKeepsStableHierarchyWhileScrolling() {
        let app = launchE2EApplication()

        app.buttons["terminalButton"].tap()
        waitForTerminalList(in: app)

        let more = app.buttons["terminalMoreButton-rl-e2e"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()

        let sheet = app.navigationBars["E2E Terminal"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.navigationBars["Terminal Options"].exists
        )
        attachScreenshot(named: "Terminal actions top")

        app.swipeUp()

        XCTAssertTrue(sheet.exists)
        XCTAssertTrue(
            app.buttons["terminalActionStopButton"]
                .waitForExistence(timeout: 5)
        )
        attachScreenshot(named: "Terminal actions scrolled")

    }

    private func verifyTerminalSessionFilesStayScoped(
        in app: XCUIApplication
    ) {
        if !app.buttons["terminalMoreButton-rl-e2e-2"].exists {
            app.buttons["createTerminalButton"].tap()
            let createTerminal = app.navigationBars["New Terminal"]
            XCTAssertTrue(
                createTerminal.waitForExistence(timeout: 5)
            )
            createTerminal.buttons["Create"].tap()
            XCTAssertTrue(
                createTerminal.waitForNonExistence(timeout: 5)
            )
            XCTAssertTrue(
                app.descendants(matching: .any)["terminalView"]
                    .waitForExistence(timeout: 10)
            )
            app.buttons["terminalSessionsButton"].tap()
        }

        openSessionFiles(
            sessionID: "rl-e2e",
            expectedArtifact: "rl-e2e-artifact.txt",
            in: app
        )
        app.navigationBars["Artifacts"].buttons["Done"].tap()
        app.navigationBars["E2E Terminal"].buttons["Done"].tap()

        let secondMore = app.buttons[
            "terminalMoreButton-rl-e2e-2"
        ]
        XCTAssertTrue(secondMore.waitForExistence(timeout: 5))
        secondMore.tap()
        let files = app.buttons[
            "terminalActionSessionFilesButton"
        ]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()

        XCTAssertTrue(
            app.navigationBars["Artifacts"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.staticTexts["rl-e2e-artifact.txt"].exists
        )
        XCTAssertTrue(
            app.staticTexts["rl-e2e-2-artifact.txt"]
                .waitForExistence(timeout: 5)
        )
        app.navigationBars["Artifacts"].buttons["Done"].tap()
        app.navigationBars["terminal-2"].buttons["Done"].tap()
    }

    func testSyntheticHostStreamsInputsAndReconnects() {
        let app = launchE2EApplication()

        let status = app.staticTexts["connectionStatus"]
        for identifier in [
            "disconnectButton",
            "appsButton",
            "keyboardButton",
            "terminalButton",
            "filesButton",
            "moreButton",
        ] {
            XCTAssertTrue(app.buttons[identifier].isHittable)
        }

        let frames = app.staticTexts["frameCount"]
        XCTAssertTrue(frames.waitForExistence(timeout: 5))
        let initialFrameLabel = frames.label
        waitForLabelChange(
            from: initialFrameLabel,
            element: frames,
            timeout: 5
        )
        attachScreenshot(named: "Remote controls")

        let canvas = app.otherElements["remoteCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .tap()

        let acknowledgement = app.staticTexts["lastInputAck"]
        XCTAssertTrue(acknowledgement.waitForExistence(timeout: 5))
        waitForLabelChange(
            from: "No input sent",
            element: acknowledgement,
            timeout: 5
        )

        let dragStart = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)
        )
        let dragEnd = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)
        )
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
        waitForLabelContaining(
            "move",
            element: acknowledgement,
            timeout: 5
        )

        let zoomStatus = app.staticTexts["zoomStatus"]
        XCTAssertTrue(zoomStatus.waitForExistence(timeout: 5))
        let initialZoom = zoomStatus.label
        canvas.pinch(withScale: 2, velocity: 1)
        waitForLabelChange(
            from: initialZoom,
            element: zoomStatus,
            timeout: 5
        )
        tapRemoteMoreControl(
            "resetZoomButton",
            in: app
        )
        waitForLabelContaining(
            "1.0",
            element: zoomStatus,
            timeout: 5
        )

        tapRemoteMoreControl(
            "rightClickButton",
            in: app
        )
        waitForLabelContaining(
            "right",
            element: acknowledgement,
            timeout: 5
        )

        tapRemoteMoreControl(
            "scrollButton",
            in: app
        )
        waitForLabelContaining(
            "scroll",
            element: acknowledgement,
            timeout: 5
        )

        app.buttons["keyboardButton"].tap()
        let textField = app.textFields["remoteTextField"]
        XCTAssertTrue(textField.waitForExistence(timeout: 5))
        textField.tap()
        textField.typeText("hello from simulator")
        app.buttons["sendTextButton"].tap()
        waitForLabelContaining(
            "text",
            element: acknowledgement,
            timeout: 5
        )

        app.buttons["terminalButton"].tap()
        waitForTerminalList(in: app)

        let terminalMore = app.buttons[
            "terminalMoreButton-rl-e2e"
        ]
        XCTAssertTrue(terminalMore.waitForExistence(timeout: 5))
        XCTAssertTrue(terminalMore.isHittable)
        terminalMore.tap()

        let terminalOptions = app.navigationBars[
            "E2E Terminal"
        ]
        XCTAssertTrue(
            terminalOptions.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons["terminalActionOpenButton"].exists
        )
        XCTAssertTrue(
            app.buttons["terminalActionSessionFilesButton"].exists
        )
        XCTAssertTrue(
            app.buttons["terminalActionMacFilesButton"].exists
        )

        let renameAction = app.buttons[
            "terminalActionRenameButton"
        ]
        for _ in 0..<3 where !renameAction.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(renameAction.isHittable)
        renameAction.tap()

        XCTAssertTrue(
            app.navigationBars["Rename Terminal"]
                .waitForExistence(timeout: 5)
        )
        let terminalName = app.textFields["terminalNameField"]
        XCTAssertTrue(terminalName.waitForExistence(timeout: 5))
        terminalName.tap()
        terminalName.typeText(
            String(
                repeating: XCUIKeyboardKey.delete.rawValue,
                count: 32
            )
        )
        terminalName.typeText("Renamed Terminal")
        app.buttons["saveTerminalNameButton"].tap()
        XCTAssertTrue(
            app.navigationBars["Rename Terminal"]
                .waitForNonExistence(timeout: 5)
        )
        app.navigationBars["Renamed Terminal"]
            .buttons["Done"]
            .tap()
        XCTAssertTrue(
            app.staticTexts["Renamed Terminal"]
                .waitForExistence(timeout: 5)
        )
        renameTerminal(
            sessionID: "rl-e2e",
            to: "E2E Terminal",
            in: app
        )

        app.buttons["createTerminalButton"].tap()
        let createTerminal = app.navigationBars["New Terminal"]
        XCTAssertTrue(
            app.staticTexts["Shell / manual command"]
                .waitForExistence(timeout: 15)
        )
        app.buttons["chooseProjectFolderButton"].tap()
        XCTAssertTrue(
            app.navigationBars["Project Folder"]
                .waitForExistence(timeout: 5)
        )
        let testHome = app.buttons["workingDirectory-@test"]
        XCTAssertTrue(testHome.waitForExistence(timeout: 5))
        testHome.tap()
        let useFolder = app.buttons["useWorkingDirectoryButton"]
        XCTAssertTrue(useFolder.waitForExistence(timeout: 5))
        useFolder.tap()
        XCTAssertTrue(
            app.staticTexts["selectedWorkingDirectory"]
                .waitForExistence(timeout: 5)
        )
        attachScreenshot(named: "New terminal setup")
        createTerminal.buttons["Create"].tap()
        XCTAssertTrue(
            createTerminal.waitForNonExistence(timeout: 5)
        )
        let terminal = app.descendants(
            matching: .any
        )["terminalView"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["terminal-2"]
                .waitForExistence(timeout: 5)
        )
        terminal.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        .tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 5)
        )
        let focusedTerminal = app.textViews.firstMatch
        XCTAssertTrue(focusedTerminal.waitForExistence(timeout: 5))
        focusedTerminal.typeText("hello-terminal")

        let terminalOutput = app.staticTexts[
            "terminalOutputStatus"
        ]
        XCTAssertTrue(
            terminalOutput.waitForExistence(timeout: 5)
        )
        waitForLabelContaining(
            "hello-terminal",
            element: terminalOutput,
            timeout: 5
        )
        app.buttons["terminalKeyboardButton"].tap()
        XCTAssertTrue(
            app.keyboards.firstMatch
                .waitForNonExistence(timeout: 5)
        )
        let terminalGrid = app.staticTexts[
            "terminalGridSizeStatus"
        ]
        XCTAssertTrue(
            terminalGrid.waitForExistence(timeout: 5)
        )
        let gridSize = terminalGrid.label
            .replacingOccurrences(of: "grid ", with: "")

        tapTerminalOption(
            "terminalReconnectTestButton",
            in: app
        )
        let terminalConnectionStatus = app.staticTexts[
            "terminalConnectionStatus"
        ]
        XCTAssertTrue(
            terminalConnectionStatus.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            terminalConnectionStatus.waitForNonExistence(timeout: 10)
        )
        waitForLabelContaining(
            "attachment-2-size-\(gridSize)",
            element: terminalOutput,
            timeout: 10
        )

        app.buttons["terminalKeyboardButton"].tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 5)
        )
        app.textViews.firstMatch.typeText("after-reconnect")
        waitForLabelContaining(
            "after-reconnect",
            element: terminalOutput,
            timeout: 5
        )
        app.buttons["terminalKeyboardButton"].tap()

        let backspace = app.buttons["terminalKey-Backspace"]
        XCTAssertTrue(backspace.waitForExistence(timeout: 5))
        XCTAssertTrue(backspace.isHittable)
        backspace.press(forDuration: 0.9)
        waitForLabelContaining(
            "backspace-count-3",
            element: terminalOutput,
            timeout: 5
        )

        app.buttons["terminalSessionsButton"].tap()
        XCTAssertTrue(
            app.buttons["createTerminalButton"]
                .waitForExistence(timeout: 5)
        )
        verifyTerminalSessionFilesStayScoped(in: app)
        app.buttons["createTerminalButton"].tap()
        let rememberedDirectory = app.staticTexts[
            "selectedWorkingDirectory"
        ]
        XCTAssertTrue(
            rememberedDirectory.waitForExistence(timeout: 5)
        )
        XCTAssertEqual(rememberedDirectory.label, "Test Home")
        let useWorkspace = app.buttons["useSessionWorkspaceButton"]
        XCTAssertTrue(useWorkspace.waitForExistence(timeout: 5))
        useWorkspace.tap()
        app.buttons["chooseProjectFolderButton"].tap()
        XCTAssertTrue(
            app.buttons["recentWorkingDirectory-@test"]
                .waitForExistence(timeout: 5)
        )
        app.buttons["cancelWorkingDirectoryPickerButton"].tap()
        app.buttons["cancelCreateTerminalButton"].tap()
        app.buttons["Done"].tap()

        let beforeReconnect = frames.label
        tapRemoteMoreControl(
            "reconnectTestButton",
            in: app
        )
        waitForLabel("Connected", element: status, timeout: 10)
        waitForLabelChange(
            from: beforeReconnect,
            element: frames,
            timeout: 10
        )
    }

    func testShowsMacPermissionRecoveryActions() {
        let app = launchE2EApplication()

        let banner = app.otherElements["hostAttentionBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Mac Screen"].isHittable)
        XCTAssertTrue(app.buttons["Retry"].isHittable)
    }

    func testTerminalScrollingAndAdaptiveLayout() {
        let app = launchE2EApplication()
        openTerminal(named: "E2E Terminal", in: app)

        let terminal = app.descendants(
            matching: .any
        )["terminalView"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["terminalInteractionModeButton"].isHittable
        )
        XCTAssertTrue(
            app.buttons["terminalWidthModeButton"].isHittable
        )
        XCTAssertTrue(
            app.buttons["terminalKeyboardButton"].isHittable
        )
        let output = app.staticTexts["terminalOutputStatus"]
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        waitForLabelContaining(
            "terminal-scroll-fixture-120",
            element: output,
            timeout: 5
        )

        let liveButton = app.buttons["terminalLiveButton"]
        XCTAssertFalse(liveButton.exists)

        terminal.swipeDown(velocity: .fast)
        XCTAssertTrue(
            liveButton.waitForExistence(timeout: 5)
        )
        liveButton.tap()
        XCTAssertTrue(
            liveButton.waitForNonExistence(timeout: 5)
        )

        if terminal.frame.width < 700 {
            waitForDynamicLabel(
                "terminalHorizontalScrollStatus",
                in: app,
                timeout: 5
            ) { $0 == "horizontal 0" }

            let moveRight = app.buttons[
                "terminalViewportRightButton"
            ]
            let moveLeft = app.buttons[
                "terminalViewportLeftButton"
            ]
            XCTAssertTrue(moveRight.waitForExistence(timeout: 5))
            XCTAssertTrue(moveRight.isHittable)
            moveRight.tap()
            waitForDynamicLabel(
                "terminalHorizontalScrollStatus",
                in: app,
                timeout: 5
            ) { $0 != "horizontal 0" }
            XCTAssertTrue(moveLeft.isHittable)
            moveLeft.tap()
            waitForDynamicLabel(
                "terminalHorizontalScrollStatus",
                in: app,
                timeout: 5
            ) { $0 == "horizontal 0" }

            terminal.swipeLeft(velocity: .fast)
            waitForDynamicLabel(
                "terminalHorizontalScrollStatus",
                in: app,
                timeout: 5
            ) { $0 != "horizontal 0" }
            terminal.swipeRight(velocity: .fast)
            waitForDynamicLabel(
                "terminalHorizontalScrollStatus",
                in: app,
                timeout: 5
            ) { $0 == "horizontal 0" }
        }

        app.buttons["terminalArtifactsButton"].tap()
        XCTAssertTrue(
            app.navigationBars["Artifacts"]
                .waitForExistence(timeout: 5)
        )
        let artifact = app.staticTexts["rl-e2e-artifact.txt"]
        XCTAssertTrue(artifact.waitForExistence(timeout: 5))
        artifact.tap()
        XCTAssertTrue(
            app.navigationBars["rl-e2e-artifact.txt"]
                .waitForExistence(timeout: 10)
        )

        let artifactScreenshot = XCTAttachment(
            screenshot: XCUIScreen.main.screenshot()
        )
        artifactScreenshot.name = "Terminal artifact preview"
        artifactScreenshot.lifetime = .keepAlways
        add(artifactScreenshot)

        app.navigationBars["rl-e2e-artifact.txt"]
            .buttons["Done"].tap()
        app.navigationBars["Artifacts"]
            .buttons["Done"].tap()

        let portraitScreenshot = XCTAttachment(
            screenshot: XCUIScreen.main.screenshot()
        )
        portraitScreenshot.name = "Terminal portrait"
        portraitScreenshot.lifetime = .keepAlways
        add(portraitScreenshot)

        tapTerminalOption(
            "terminalDelayedReconnectTestButton",
            in: app
        )
        XCTAssertTrue(
            app.staticTexts["terminalConnectionStatus"]
                .waitForExistence(timeout: 5)
        )
        app.buttons["terminalSessionsButton"].tap()
        XCTAssertFalse(app.alerts["ReLand"].exists)
        let more = app.buttons["terminalMoreButton-rl-e2e"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        for identifier in [
            "terminalActionOpenButton",
            "terminalActionOpenOnMacButton",
            "terminalActionSessionFilesButton",
            "terminalActionMacFilesButton",
            "terminalActionStopButton",
        ] {
            let action = app.buttons[identifier]
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            XCTAssertFalse(action.isEnabled)
        }
    }

    func testBrowseMacFilesAndPreview() {
        let app = launchE2EApplication()
        app.buttons["filesButton"].tap()

        XCTAssertTrue(
            app.navigationBars["Mac Files"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons["remoteFile-@test"]
                .waitForExistence(timeout: 5)
        )

        app.buttons["remoteFile-@test"].tap()
        XCTAssertTrue(
            app.navigationBars["Test Home"]
                .waitForExistence(timeout: 5)
        )
        app.buttons["remoteFile-@test/Test Files"].tap()
        XCTAssertTrue(
            app.navigationBars["Test Files"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["nested.txt"]
                .waitForExistence(timeout: 5)
        )
        app.buttons["remoteFileParentButton"].tap()

        let homeFile = app.buttons[
            "remoteFile-@test/home-note.txt"
        ]
        XCTAssertTrue(homeFile.waitForExistence(timeout: 5))
        homeFile.tap()
        XCTAssertTrue(
            app.navigationBars["home-note.txt"]
                .waitForExistence(timeout: 10)
        )

        let screenshot = XCTAttachment(
            screenshot: XCUIScreen.main.screenshot()
        )
        screenshot.name = "Mac file preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.navigationBars["home-note.txt"]
            .buttons["Done"].tap()
        app.navigationBars["Test Home"]
            .buttons["Done"].tap()
    }

    func testSelectAppWindowAndUseDirectTouch() {
        let app = launchE2EApplication()
        app.buttons["appsButton"].tap()

        XCTAssertTrue(
            app.navigationBars["Mac Apps"]
                .waitForExistence(timeout: 5)
        )
        let notesWindow = app.buttons[
            "captureTarget-window-notes"
        ]
        XCTAssertTrue(notesWindow.waitForExistence(timeout: 5))
        attachScreenshot(named: "Mac Apps picker")
        notesWindow.tap()
        XCTAssertTrue(
            app.navigationBars["Mac Apps"]
                .waitForNonExistence(timeout: 5)
        )
        let dashboard = app.buttons[
            "appSwitcher-window-dashboard"
        ]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5))
        dashboard.tap()
        waitForLabelContaining(
            "Dashboard",
            element: app.staticTexts["captureTargetStatus"],
            timeout: 5
        )

        let acknowledgement = app.staticTexts["lastInputAck"]
        let beforeInput = acknowledgement.label
        app.otherElements["remoteCanvas"]
            .coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            )
            .tap()
        waitForLabelChange(
            from: beforeInput,
            element: acknowledgement,
            timeout: 5
        )

        attachScreenshot(named: "App Mode direct touch")
        verifyWindowsSessionControls()
    }

    func testExistingCopilotTerminalUX() throws {
        guard
            let sessionName = ProcessInfo.processInfo.environment[
                "RELAND_E2E_TERMINAL_NAME"
            ],
            !sessionName.isEmpty
        else {
            throw XCTSkip(
                "Set RELAND_E2E_TERMINAL_NAME for a local tmux review."
            )
        }

        let app = launchE2EApplication()
        openTerminal(named: sessionName, in: app)

        let terminal = app.descendants(
            matching: .any
        )["terminalView"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        waitForDynamicLabel(
            "terminalHorizontalScrollStatus",
            in: app,
            timeout: 5
        ) { $0 == "horizontal 0" }

        let moveRight = app.buttons[
            "terminalViewportRightButton"
        ]
        let moveLeft = app.buttons[
            "terminalViewportLeftButton"
        ]
        XCTAssertTrue(moveRight.waitForExistence(timeout: 5))
        attachScreenshot(
            named: "Copilot terminal before moving right"
        )

        moveRight.tap()
        waitForDynamicLabel(
            "terminalHorizontalScrollStatus",
            in: app,
            timeout: 5
        ) { $0 != "horizontal 0" }
        holdForRecording()
        attachScreenshot(
            named: "Copilot terminal moved right"
        )

        XCTAssertTrue(moveLeft.isHittable)
        moveLeft.tap()
        waitForDynamicLabel(
            "terminalHorizontalScrollStatus",
            in: app,
            timeout: 5
        ) { $0 == "horizontal 0" }
        holdForRecording()
        attachScreenshot(
            named: "Copilot terminal returned left"
        )
    }

    func testLiveChromeAppMode() throws {
        guard
            let windowTitle = ProcessInfo.processInfo.environment[
                "RELAND_LIVE_CHROME_TITLE"
            ],
            !windowTitle.isEmpty
        else {
            throw XCTSkip(
                "Set RELAND_LIVE_CHROME_TITLE for live Chrome E2E."
            )
        }

        let app = launchE2EApplication()
        let targetStatus = app.staticTexts["captureTargetStatus"]
        XCTAssertTrue(targetStatus.waitForExistence(timeout: 10))
        waitForLabel("Screen", element: targetStatus, timeout: 10)
        waitForDynamicLabel(
            "frameCount",
            in: app,
            timeout: 10
        ) { $0 != "Frames 0" }
        holdForRecording()
        attachScreenshot(
            named: "Live background Chrome absent from Screen Mode"
        )

        app.buttons["appsButton"].tap()
        XCTAssertTrue(
            app.navigationBars["Mac Apps"]
                .waitForExistence(timeout: 10)
        )
        let chromeWindow = app.staticTexts[windowTitle]
        XCTAssertTrue(
            chromeWindow.waitForExistence(timeout: 10)
        )
        attachScreenshot(named: "Live Chrome picker")
        holdForRecording()
        chromeWindow.tap()
        XCTAssertTrue(
            app.navigationBars["Mac Apps"]
                .waitForNonExistence(timeout: 10)
        )
        holdForRecording()
        attachScreenshot(named: "Live Chrome before tap")

        let acknowledgement = app.staticTexts["lastInputAck"]
        app.otherElements["remoteCanvas"]
            .coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            )
            .tap()
        waitForLabelContaining(
            "left up",
            element: acknowledgement,
            timeout: 10
        )
        holdForRecording()
        attachScreenshot(named: "Live Chrome after tap")
    }

    private func launchE2EApplication(port: String = "45455") -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--reland-e2e",
            "--e2e-host",
            "127.0.0.1",
            "--e2e-port",
            port,
        ]
        app.launch()

        let status = app.staticTexts["connectionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        waitForLabel("Connected", element: status, timeout: 10)
        return app
    }

    private func tapRemoteMoreControl(
        _ identifier: String,
        in app: XCUIApplication
    ) {
        app.buttons["moreButton"].tap()
        let control = app.buttons.matching(
            identifier: identifier
        ).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.35)
        control.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        .tap()
    }

    private func tapTerminalOption(
        _ identifier: String,
        in app: XCUIApplication
    ) {
        app.buttons["terminalOptionsButton"].tap()
        let option = app.buttons.matching(
            identifier: identifier
        ).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.35)
        option.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        .tap()
    }

    private func waitForTerminalList(in app: XCUIApplication) {
        XCTAssertTrue(
            app.navigationBars["Terminal sessions"]
                .waitForExistence(timeout: 5)
        )
    }

    private func openTerminal(
        named name: String,
        in app: XCUIApplication
    ) {
        app.buttons["terminalButton"].tap()
        waitForTerminalList(in: app)

        let session = app.staticTexts[name]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()
    }

    private func renameTerminal(
        sessionID: String,
        to name: String,
        in app: XCUIApplication
    ) {
        let more = app.buttons[
            "terminalMoreButton-\(sessionID)"
        ]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()

        let rename = app.buttons[
            "terminalActionRenameButton"
        ]
        for _ in 0..<3 where !rename.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(rename.isHittable)
        rename.tap()

        let nameField = app.textFields["terminalNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(
            String(
                repeating: XCUIKeyboardKey.delete.rawValue,
                count: 64
            )
        )
        nameField.typeText(name)
        app.buttons["saveTerminalNameButton"].tap()
        XCTAssertTrue(
            app.navigationBars["Rename Terminal"]
                .waitForNonExistence(timeout: 5)
        )
        app.navigationBars[name]
            .buttons["Done"]
            .tap()
        XCTAssertTrue(
            app.staticTexts[name]
                .waitForExistence(timeout: 5)
        )
    }

    private func openSessionFiles(
        sessionID: String,
        expectedArtifact: String,
        in app: XCUIApplication
    ) {
        let more = app.buttons[
            "terminalMoreButton-\(sessionID)"
        ]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let files = app.buttons[
            "terminalActionSessionFilesButton"
        ]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()
        XCTAssertTrue(
            app.navigationBars["Artifacts"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts[expectedArtifact]
                .waitForExistence(timeout: 5)
        )
    }

    private func waitForLabel(
        _ label: String,
        element: XCUIElement,
        timeout: TimeInterval
    ) {
        let predicate = NSPredicate(format: "label == %@", label)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func waitForLabelContaining(
        _ value: String,
        element: XCUIElement,
        timeout: TimeInterval
    ) {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@",
            value
        )
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func waitForLabelChange(
        from label: String,
        element: XCUIElement,
        timeout: TimeInterval
    ) {
        let predicate = NSPredicate(format: "label != %@", label)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func waitForDynamicLabel(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        condition: (String) -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var latestLabel = ""
        repeat {
            latestLabel = app.staticTexts[identifier].label
            if condition(latestLabel) {
                return
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(0.05)
            )
        } while Date() < deadline

        XCTFail(
            "Timed out waiting for \(identifier); "
                + "latest label was \(latestLabel)"
        )
    }

    private func holdForRecording() {
        RunLoop.current.run(
            until: Date().addingTimeInterval(1)
        )
    }

    private func attachScreenshot(named name: String) {
        let screenshot = XCTAttachment(
            screenshot: XCUIScreen.main.screenshot()
        )
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}
