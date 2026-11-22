import AppKit
import XCTest

/// Interaction and native geometry tests use synthetic data only. Visual review
/// uses the owner's already-authorized Computer Use tool, not runner permissions.
@MainActor
final class SmokeTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDown() async throws { app.terminate() }

    func testStorageRebuildKeepsSyntheticSearchResult() throws {
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", populated: true)
        openSyntheticChineseSearch()
        app.buttons["openSettings"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["Storage"].click()
        let size = element("indexStorageSize")
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        let rebuild = settings.buttons["rebuildLocalIndex"]
        XCTAssertTrue(rebuild.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        rebuild.click()
        XCTAssertTrue(element("indexRebuildSucceeded").waitForExistence(timeout: 10))
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.exists)
        XCTAssertTrue(element("sessions.searchResults").waitForExistence(timeout: 5))
        XCTAssertTrue(element("transcript.match.position").wait(for: \.label, toEqual: "1 of 3 matches", timeout: 5))
    }

    func testIndexedProjectsTimelineOpensLatestSession() throws {
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", projects: true)
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(element("projects.list").waitForExistence(timeout: 5))
        XCTAssertTrue(element("projects.timeline").waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Synthetic checkout verified"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["PROJECT_TOKEN=••••••"].exists)
        XCTAssertFalse(window.staticTexts["PROJECT_TOKEN=synthetic-project-secret"].exists)
        XCTAssertFalse(window.staticTexts["Synthetic documentation reviewed"].exists)
        window.buttons["Open Latest Session"].click()
        XCTAssertTrue(element("session.transcript").waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Synthetic checkout verified"].exists)
    }

    func testIndexedProjectsAtAllSizes() throws {
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try launch(size: size, appearance: appearance, projects: true)
                app.typeKey("2", modifierFlags: .command)
                XCTAssertTrue(element("projects.detail").waitForExistence(timeout: 5))
                let latest = window.buttons["Open Latest Session"]
                XCTAssertTrue(latest.waitForExistence(timeout: 5))
                XCTAssertTrue(latest.isHittable)
                let name = "projects-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                try awaitVisualReviewIfRequested(caseName: name, frame: window.frame)
                app.terminate()
            }
        }
    }

    func testSourceEditorSavesMetadataAndReopensWithSavedValues() throws {
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", populated: true)
        app.buttons["openSettings"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["Sources"].click()
        let edit = settings.buttons["source.edit"].firstMatch
        XCTAssertTrue(edit.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        edit.click()
        let name = app.textFields["source.edit.name"]
        let save = app.buttons["source.edit.save"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["source.edit.addRule"].exists)
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: false, timeout: 5))
        name.typeText("Synthetic edited source")
        XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        save.click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        XCTAssertTrue(settings.staticTexts["Synthetic edited source"].waitForExistence(timeout: 5))
        edit.click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Synthetic edited source")
    }

    func testEmptyNavigationAndSettingsReopening() throws {
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        for (key, identifier) in [("3", "empty.tokens"), ("2", "empty.projects"), ("1", "empty.sessions")] {
            app.typeKey(key, modifierFlags: .command)
            XCTAssertTrue(element(identifier).waitForExistence(timeout: 3))
        }
        for _ in 1...2 {
            app.buttons["openSettings"].click()
            let settings = app.windows["settingsWindow"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            // Native Settings remembers its last tab; select the page under test.
            settings.buttons["General"].click()
            XCTAssertTrue(element("settingsPrivacyPromise").waitForExistence(timeout: 3))
            settings.buttons[XCUIIdentifierCloseWindow].click()
            XCTAssertTrue(settings.waitForNonExistence(timeout: 3))
            XCTAssertTrue(window.exists)
        }
    }

    func testLaunchAtLoginShowsPendingApprovalAndAllowsCancellation() throws {
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        app.buttons["openSettings"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["General"].click()
        let toggle = element("launchAtLoginToggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        toggle.click()
        let pending = element("loginItemApprovalRequired")
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        toggle.click()
        XCTAssertTrue(pending.waitForNonExistence(timeout: 5))
    }

    func testRegisteredSyntheticSourceStartsAndStopsOnlyOnRequest() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_INDEXING_SOURCE"] = "1"
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        app.buttons["openSettings"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["Sources"].click()
        let start = settings.buttons["source.startIndexing"]
        let live = settings.descendants(matching: .any)["source.watching"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(live.exists)
        start.click()
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        settings.buttons["source.stopIndexing"].click()
        XCTAssertTrue(settings.staticTexts["source.stopped"].waitForExistence(timeout: 5))
        XCTAssertTrue(start.exists)
        XCTAssertFalse(live.exists)
    }

    func testOnboardingShowsFileCountAndStartsSelectedSource() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_INDEXING_SOURCE"] = "1"
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", onboarding: true)
        let choose = app.buttons["onboarding.chooseSources"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        XCTAssertTrue(app.staticTexts["Discovered session files: 1"].waitForExistence(timeout: 5))
        let start = app.buttons["onboarding.startIndexing"]
        XCTAssertTrue(start.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        start.click()
        let open = app.buttons["onboarding.openDashboard"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        XCTAssertTrue(window.exists)
        XCTAssertTrue(element("sessions.list").waitForExistence(timeout: 5))
    }

    func testRescanOfStoppedSourceDoesNotStartWatching() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_INDEXING_SOURCE"] = "1"
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        app.buttons["openSettings"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["Sources"].click()
        let rescan = settings.buttons["source.rescan"]
        XCTAssertTrue(rescan.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        rescan.click()
        XCTAssertTrue(settings.staticTexts["source.rescanned"].waitForExistence(timeout: 5))
        XCTAssertTrue(settings.buttons["source.startIndexing"].isEnabled)
        XCTAssertFalse(settings.descendants(matching: .any)["source.watching"].firstMatch.exists)
    }

    func testRegisteredSyntheticCodexSourceCanBeStarted() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_CODEX_SOURCE"] = "1"
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        app.buttons["openSettings"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["Sources"].click()
        XCTAssertTrue(settings.staticTexts["Synthetic Codex source"].waitForExistence(timeout: 5))
        settings.buttons["source.startIndexing"].click()
        XCTAssertTrue(settings.descendants(matching: .any)["source.watching"].firstMatch.waitForExistence(timeout: 5))
    }

    func testSyntheticUsageShowsTheChartAndSwitchesToCost() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_USAGE"] = "1"
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(element("usage.presented").waitForExistence(timeout: 5))
        XCTAssertTrue(element("usage.chart.plot").waitForExistence(timeout: 5))
        let metric = app.popUpButtons["Metric"].firstMatch
        XCTAssertTrue(metric.waitForExistence(timeout: 3))
        metric.click()
        app.menuItems["Cost"].click()
        XCTAssertTrue(app.staticTexts["Peak spend rate"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("usage.chart.plot").waitForExistence(timeout: 5))
    }

    func testSessionOverviewShowsProgressAndMasksToolOutput() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_OVERVIEW"] = "1"
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", populated: true)
        XCTAssertTrue(element("session.transcript").waitForExistence(timeout: 5))
        let tabs = element("session.details.tabs")
        let overview = tabs.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Overview")).firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        overview.click()
        XCTAssertTrue(element("session.overview").waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Synthetic checkpoint verified"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["OVERVIEW_TOKEN=••••••"].exists)
        XCTAssertFalse(window.staticTexts["OVERVIEW_TOKEN=synthetic-overview-only"].exists)
    }

    func testAddSourceFormRequiresNameAndCancelsWithoutAdding() throws {
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        app.buttons["openSettings"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["Sources"].click()
        let add = settings.buttons["source.add"]
        XCTAssertTrue(add.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        add.click()
        let name = app.textFields["source.add.name"]
        let choose = app.buttons["source.add.choose"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(choose.isEnabled)
        name.click()
        name.typeText("Synthetic custom source")
        XCTAssertTrue(choose.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        XCTAssertFalse(settings.staticTexts["Synthetic custom source"].exists)
    }

    func testNativeWindowGeometry() throws {
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try launch(size: size, appearance: appearance)
                XCTAssertEqual(window.frame.width, size.width, accuracy: 1)
                XCTAssertEqual(window.frame.height, size.height, accuracy: 1)
                XCTAssertTrue(element("empty.sessions").exists)
                XCTAssertTrue(element("empty.detail").exists)
                let caseName = "\(appearance)-\(Int(size.width))x\(Int(size.height))"
                let attachment = XCTAttachment(string: NSStringFromRect(window.frame))
                attachment.name = "verified-frame-\(caseName)"
                attachment.lifetime = .keepAlways
                add(attachment)
                try awaitVisualReviewIfRequested(caseName: caseName, frame: window.frame)
                app.terminate()
            }
        }
    }

    func testSourcesShowsRecordedIndexCounts() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_INDEX_STATUS"] = "1"
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        app.buttons["openSettings"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["Sources"].click()
        XCTAssertTrue(settings.staticTexts["source.index.files.1"].wait(for: \.label,
                                                                       toEqual: "Indexed files: 1 of 2", timeout: 5))
        XCTAssertEqual(settings.staticTexts["source.index.sessions.1"].label, "Indexed sessions: 1")
        XCTAssertEqual(settings.staticTexts["source.index.unknown.1"].label, "Unknown records: 3")
        XCTAssertTrue(settings.staticTexts["Partial files: 1"].exists)
    }

    func testIndexedSessionsKeepCredentialsMaskedAndPageWithinSelection() throws {
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", populated: true)
        XCTAssertTrue(element("sessions.list").waitForExistence(timeout: 5))
        let first = window.staticTexts["API_TOKEN=••••••"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let raw = window.staticTexts["API_TOKEN=synthetic-preview-only"]
        XCTAssertFalse(raw.exists)
        window.buttons["Reveal Credentials Briefly"].click()
        XCTAssertTrue(raw.waitForExistence(timeout: 3))
        window.buttons["Hide Credentials"].click()
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        window.buttons["Newer Messages"].click()
        XCTAssertTrue(window.staticTexts["合成转录 · Synthetic message 128"].waitForExistence(timeout: 5))
        XCTAssertFalse(first.exists)
        window.staticTexts["Review synthetic documentation"].click()
        XCTAssertTrue(window.staticTexts["Documentation preview"].waitForExistence(timeout: 5))
        XCTAssertFalse(window.staticTexts["合成转录 · Synthetic message 128"].exists)
    }

    func testPopulatedSessionAtAllSizes() throws {
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try launch(size: size, appearance: appearance, populated: true)
                XCTAssertTrue(element("sessions.list").waitForExistence(timeout: 5))
                XCTAssertTrue(window.staticTexts["API_TOKEN=••••••"].waitForExistence(timeout: 5))
                let name = "sessions-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                try awaitVisualReviewIfRequested(caseName: name, frame: window.frame)
                app.terminate()
            }
        }
    }

    func testChineseSearchStepsAcrossBoundedTranscriptPages() throws {
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", populated: true)
        openSyntheticChineseSearch()
        let transcript = element("session.transcript.messages")
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let position = element("transcript.match.position")
        let previous = window.buttons["Previous Match"]
        let next = window.buttons["Next Match"]
        let first = transcript.staticTexts["修复登录问题 · Synthetic search target"]
        let second = transcript.staticTexts["验证登录配置 · Second synthetic search target"]
        let third = transcript.staticTexts["完成登录修复 · Final synthetic search target"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(position.wait(for: \.label, toEqual: "1 of 3 matches", timeout: 5))
        XCTAssertFalse(previous.isEnabled)
        XCTAssertTrue(next.wait(for: \.isEnabled, toEqual: true, timeout: 5))

        window.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertEqual(position.label, "1 of 3 matches")
        window.typeKey("g", modifierFlags: .command)
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(position.wait(for: \.label, toEqual: "2 of 3 matches", timeout: 5))
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        XCTAssertTrue(next.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        next.click()
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        XCTAssertTrue(position.wait(for: \.label, toEqual: "3 of 3 matches", timeout: 5))
        XCTAssertTrue(second.waitForNonExistence(timeout: 5))
        XCTAssertFalse(next.isEnabled)

        window.typeKey("g", modifierFlags: .command)
        XCTAssertEqual(position.label, "3 of 3 matches")
        XCTAssertTrue(previous.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        window.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(position.wait(for: \.label, toEqual: "2 of 3 matches", timeout: 5))
        XCTAssertTrue(third.waitForNonExistence(timeout: 5))
        XCTAssertTrue(previous.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        previous.click()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(position.wait(for: \.label, toEqual: "1 of 3 matches", timeout: 5))
        XCTAssertTrue(second.waitForNonExistence(timeout: 5))
        XCTAssertFalse(previous.isEnabled)
        XCTAssertFalse(transcript.staticTexts["API_TOKEN=synthetic-preview-only"].exists)
    }

    func testSearchMatchControlsAtAllSizes() throws {
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try launch(size: size, appearance: appearance, populated: true)
                openSyntheticChineseSearch()
                XCTAssertTrue(element("transcript.match.position").wait(for: \.label, toEqual: "1 of 3 matches", timeout: 5))
                let next = window.buttons["Next Match"]
                XCTAssertTrue(next.wait(for: \.isEnabled, toEqual: true, timeout: 5))
                XCTAssertTrue(next.isHittable)
                let name = "search-match-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                try awaitVisualReviewIfRequested(caseName: name, frame: window.frame)
                app.terminate()
            }
        }
    }

    private func openSyntheticChineseSearch() {
        XCTAssertTrue(element("sessions.list").waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("登录")
        XCTAssertTrue(element("sessions.searchResults").waitForExistence(timeout: 5))
    }

    func testMenuPanelReopensClosedDashboard() throws {
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 3))
        XCTAssertNotEqual(app.state, .notRunning)
        app.activate()
        XCTAssertFalse(window.exists)
        let toggle = app.statusItems["Agent Dashboard"]
        if !toggle.exists {
            app.menuBars.firstMatch.hover()
        }
        // Observed native role: MenuBarExtra is an AXDialog, not an AXWindow.
        let panel = app.dialogs["menuBarPanel"]
        if toggle.waitForExistence(timeout: 3) {
            toggle.click()
        } else if ProcessInfo.processInfo.environment["AGENTDASH_MANUAL_MENU_REVIEW"] == "1" {
            print("AGENTDASH_MENU_REVIEW_READY: open this app's menu-bar panel to continue the actual panel/reopen assertions.")
            XCTAssertTrue(panel.waitForExistence(timeout: 300))
        } else {
            throw XCTSkip("This desktop does not expose the status item to XCTest. Explicit manual-menu review is still required before accepting menu changes.")
        }
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertEqual(panel.frame.width, 360, accuracy: 1)
        XCTAssertTrue(panel.textFields["menu.search"].exists)
        XCTAssertTrue(element("menu.usage").waitForExistence(timeout: 5))
        XCTAssertTrue(panel.staticTexts["No active sessions"].exists)
        app.buttons["openDashboard"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(element("empty.sessions").waitForExistence(timeout: 3))
    }

    private func launch(size: CGSize, appearance: String, populated: Bool = false,
                        projects: Bool = false, onboarding: Bool = false) throws -> XCUIElement {
        app.launchArguments = ["--synthetic", "--window-size", "\(Int(size.width))x\(Int(size.height))", "--appearance", appearance,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if populated { app.launchArguments.append("--synthetic-sessions") }
        if projects { app.launchArguments.append("--synthetic-projects") }
        if onboarding { app.launchArguments.append("--synthetic-onboarding") }
        app.launch()
        app.activate()
        let window = app.windows["dashboardWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(window.wait(for: \.frame.size, toEqual: size, timeout: 5),
                      "Expected outer size \(size); actual frame \(window.frame).")
        return window
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Normal runs do not wait or capture. The coordinator's authorized CUA tool
    /// captures the synthetic window during this optional, serialized handoff.
    /// Acknowledgment is written only after the actual image has been inspected.
    private func awaitVisualReviewIfRequested(caseName: String, frame: CGRect) throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTDASH_VISUAL_REVIEW_DIR"] else { return }
        let directory = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let allowedRoot = URL(fileURLWithPath: "/private/tmp/agentdash-m0-visual", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard directory.path.hasPrefix(allowedRoot.path + "/"),
              FileManager.default.fileExists(atPath: directory.path) else {
            XCTFail("Visual review directory must be an existing task-local temporary directory: \(directory.path).")
            return
        }
        let acknowledgment = directory.appendingPathComponent(caseName + ".ack")
        XCTAssertFalse(FileManager.default.fileExists(atPath: acknowledgment.path), "Use a fresh review directory.")
        // The sandboxed runner can read the acknowledgment directory but does not
        // need write access to it. Emit only synthetic geometry through test output.
        let ready = "AGENTDASH_VISUAL_REVIEW_READY \(caseName) FRAME \(NSStringFromRect(frame))\n"
        FileHandle.standardOutput.write(Data(ready.utf8))
        let received = expectation(for: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: acknowledgment.path)
        }, evaluatedWith: nil)
        wait(for: [received], timeout: 300)
    }
}
