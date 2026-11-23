import AppKit
import XCTest

/// Interaction and native geometry tests use the isolated SyntheticQA app.
/// Visual review uses artifacts from its synthetic windows.
@MainActor
final class SmokeTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !AGENTDASH_SYNTHETIC_ONLY
        throw XCTSkip("UI testing requires the SyntheticQA build configuration.")
        #endif
    }
    override func tearDown() async throws { app.terminate() }

    func testSessionTitleCanBeRenamedAndRestoredToFirstPrompt() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_SESSION_TITLE"] = "1"
        let window = try launch(size: CGSize(width: 960, height: 600), appearance: "dark", populated: true)
        func titleText(_ id: String, _ expected: String) -> XCUIElement {
            window.staticTexts.matching(identifier: id)
                .matching(NSPredicate(format: "label == %@ OR value == %@", expected, expected)).firstMatch
        }
        let prompt = titleText("session.title.header", "排查合成会话的问题")
        let promptSource = titleText("session.title.source", "From first prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        XCTAssertTrue(promptSource.waitForExistence(timeout: 5))
        let rename = window.buttons["session.title.rename"]
        rename.click()
        let field = app.textFields["session.title.edit"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "自定义会话示例")
        app.buttons["session.title.save"].click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(titleText("session.title.header", "自定义会话示例").waitForExistence(timeout: 5))
        XCTAssertTrue(titleText("session.title.source", "Custom title").waitForExistence(timeout: 5))

        rename.click()
        let reset = app.buttons["session.title.reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        XCTAssertTrue(promptSource.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "session-title-restored-minimum-window"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testStorageRebuildKeepsSyntheticSearchResult() throws {
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", populated: true, query: "登录")
        waitForSyntheticChineseSearch()
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
        XCTAssertTrue(showsMatchPosition("1 of 3 matches"))
    }

    func testToolOutputArchiveReductionRequiresConfirmation() throws {
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        app.buttons["openSettings"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["Storage"].click()
        let size = settings.popUpButtons["storage.toolOutputLimit"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        XCTAssertEqual(size.value as? String, "64 KiB")
        size.click()
        app.menuItems["Searchable preview only"].firstMatch.click()
        let apply = app.buttons["Apply Tool Output Limit"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(apply.waitForNonExistence(timeout: 5))
        XCTAssertEqual(size.value as? String, "64 KiB")
        size.click()
        app.menuItems["Searchable preview only"].firstMatch.click()
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        apply.click()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Searchable preview only"), object: size)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
    }

    func testArchiveRetentionConfirmsChangingForeverPolicy() throws {
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        app.buttons["openSettings"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["Storage"].click()
        let retention = settings.popUpButtons["storage.archiveRetention"]
        XCTAssertTrue(retention.waitForExistence(timeout: 5))
        XCTAssertEqual(retention.value as? String, "Forever")
        retention.click()
        app.menuItems["90 days"].firstMatch.click()
        let apply = app.buttons["Apply Archive Retention"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(apply.waitForNonExistence(timeout: 5))
        XCTAssertEqual(retention.value as? String, "Forever")
        retention.click()
        app.menuItems["90 days"].firstMatch.click()
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        apply.click()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "90 days"), object: retention)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
    }

    func testStorageClearEverythingRequiresConfirmation() throws {
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", populated: true)
        let original = window.staticTexts["API_TOKEN=••••••"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        app.buttons["openSettings"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["Storage"].click()
        let everything = settings.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Everything")).firstMatch
        XCTAssertTrue(everything.waitForExistence(timeout: 5))
        everything.click()
        let review = settings.buttons["storage.clear.review"]
        XCTAssertTrue(review.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        review.click()
        let confirm = app.buttons["Clear Indexed Data"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let count = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                                       "Sessions to clear: 2.", "Sessions to clear: 2.")).firstMatch
        XCTAssertTrue(count.exists)
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(original.exists)
        review.click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        let finished = element("storage.clear.result")
        XCTAssertTrue(finished.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.staticTexts["Cleared 2 sessions from the local index."].exists)
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(original.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("empty.detail").waitForExistence(timeout: 5))
    }

    func testSessionListShowsCommittedUsageInGroupsAndChineseSearch() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_LIST_USAGE"] = "1"
        let size = CGSize(width: 1120, height: 720)
        _ = try launch(size: size, appearance: "dark", projects: true)
        assertListUsage("27 tokens · Partial estimate: $0.000061")
        assertListUsage("13 tokens · Unpriced")
        assertListUsage("1,000 tokens · List-price estimate: $0.002")
        element("sessions.groupByProject").click()
        XCTAssertTrue(element("sessions.project.section").waitForExistence(timeout: 5))
        assertListUsage("27 tokens · Partial estimate: $0.000061")
        XCTAssertTrue(app.staticTexts.matching(identifier: "session.usage.total").matching(
            NSPredicate(format: "value == %@ OR label == %@", "27", "27")).firstMatch.waitForExistence(timeout: 5))
        app.terminate()

        _ = try launch(size: size, appearance: "dark", projects: true, query: "会话用量")
        XCTAssertTrue(element("sessions.searchResults").waitForExistence(timeout: 5))
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "会话用量")
        assertListUsage("27 tokens · Partial estimate: $0.000061")
        assertListUsage("13 tokens · Unpriced")
        XCTAssertFalse(listUsage("1,000 tokens · List-price estimate: $0.002").exists)
        element("sessions.groupByProject").click()
        XCTAssertTrue(element("sessions.project.section").waitForExistence(timeout: 5))
        assertListUsage("27 tokens · Partial estimate: $0.000061")
        assertListUsage("13 tokens · Unpriced")
    }

    func testSessionRowUsageAtNativeWindowSizes() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_LIST_USAGE"] = "1"
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try launch(size: size, appearance: appearance, projects: true)
                let usage = listUsage("27 tokens · Partial estimate: $0.000061")
                XCTAssertTrue(usage.waitForExistence(timeout: 5))
                XCTAssertTrue(window.frame.contains(usage.frame))
                let screenshot = XCTAttachment(screenshot: window.screenshot())
                screenshot.name = "session-usage-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                app.terminate()
            }
        }
    }

    private func listUsage(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "session.list.usage")
            .matching(NSPredicate(format: "value == %@ OR label == %@", label, label)).firstMatch
    }

    private func assertListUsage(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(listUsage(label).waitForExistence(timeout: 5), "Missing row usage: \(label)", file: file, line: line)
    }

    func testGroupSessionsByProjectKeepsSelectionAndSidebarFilter() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_SESSION_GROUPING"] = "1"
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", projects: true)
        let list = element("sessions.list")
        let worktree = list.staticTexts["Validate synthetic integration"].firstMatch
        let docs = list.staticTexts["Review synthetic documentation"].firstMatch
        XCTAssertTrue(worktree.waitForExistence(timeout: 5))
        XCTAssertTrue(docs.exists)
        XCTAssertLessThan(docs.frame.minY, worktree.frame.minY)
        worktree.click()
        let detail = element("session.transcript")
        XCTAssertTrue(detail.staticTexts["Validate synthetic integration"].waitForExistence(timeout: 5))
        let toggle = element("sessions.groupByProject")
        toggle.click()
        XCTAssertTrue(element("sessions.project.section").waitForExistence(timeout: 5))
        XCTAssertLessThan(worktree.frame.minY, docs.frame.minY)
        XCTAssertTrue(detail.staticTexts["Validate synthetic integration"].exists)
        XCTAssertTrue(list.staticTexts["Synthetic without a project"].exists)
        element("sidebar.status.waiting").click()
        XCTAssertTrue(docs.waitForExistence(timeout: 5))
        XCTAssertTrue(worktree.waitForNonExistence(timeout: 5))
        XCTAssertTrue(detail.staticTexts["Review synthetic documentation"].waitForExistence(timeout: 5))
        toggle.click()
        XCTAssertTrue(element("sessions.project.section").waitForNonExistence(timeout: 5))
        XCTAssertTrue(window.exists && docs.exists)
    }

    func testGroupedSearchPreservesResultsAcrossPages() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_GROUPING_SEARCH"] = "1"
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark",
                                projects: true, query: "分组搜索")
        let firstPage = window.staticTexts["Sessions 1–50"]
        let lastPage = window.staticTexts["Sessions 51–53"]
        let toggle = element("sessions.groupByProject")
        XCTAssertTrue(firstPage.waitForExistence(timeout: 8))
        toggle.click()
        XCTAssertTrue(element("sessions.project.section").waitForExistence(timeout: 5))
        XCTAssertTrue(firstPage.exists)
        window.buttons["Later Results"].click()
        XCTAssertTrue(lastPage.waitForExistence(timeout: 8))
        XCTAssertTrue(element("sessions.project.section").exists)
        let tail = window.staticTexts["Synthetic search result 53"].firstMatch
        guard tail.waitForExistence(timeout: 5) else {
            let screenshot = XCTAttachment(screenshot: window.screenshot())
            screenshot.name = "grouped-search-last-page"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("Missing the expected row on the final page:\n\(window.debugDescription)")
            return
        }
        XCTAssertFalse(window.buttons["Later Results"].isEnabled)
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "分组搜索")
        window.buttons["Earlier Results"].click()
        XCTAssertTrue(firstPage.waitForExistence(timeout: 8))
        XCTAssertTrue(element("sessions.project.section").exists)
        XCTAssertFalse(tail.exists)
    }

    func testGroupedSessionsAtNativeWindowSizes() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_SESSION_GROUPING"] = "1"
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try launch(size: size, appearance: appearance, projects: true)
                let toggle = element("sessions.groupByProject")
                XCTAssertTrue(toggle.waitForExistence(timeout: 5))
                toggle.click()
                XCTAssertTrue(element("sessions.project.section").waitForExistence(timeout: 5))
                XCTAssertTrue(window.frame.contains(toggle.frame))
                let image = XCTAttachment(screenshot: window.screenshot())
                image.name = "session-groups-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                image.lifetime = .keepAlways
                add(image)
                app.terminate()
            }
        }
    }

    func testIndexedProjectsTimelineOpensLatestSession() throws {
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", projects: true)
        openLibrary("projects")
        XCTAssertTrue(element("projects.list").waitForExistence(timeout: 5))
        XCTAssertTrue(element("projects.timeline").waitForExistence(timeout: 5))
        XCTAssertTrue(projectTimelineEntry(containing: "Synthetic checkout verified").waitForExistence(timeout: 5))
        XCTAssertTrue(projectTimelineEntry(containing: "PROJECT_TOKEN=••••••").exists)
        XCTAssertFalse(projectTimelineEntry(containing: "PROJECT_TOKEN=synthetic-project-secret").exists)
        XCTAssertFalse(projectTimelineEntry(containing: "Synthetic documentation reviewed").exists)
        window.buttons["Open Latest Session"].click()
        XCTAssertTrue(element("session.transcript").waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Synthetic checkout verified"].exists)
    }

    func testProjectUsageChangesPeriodAndShowsOnlyProjectFacts() throws {
        _ = try openProjectUsage(size: CGSize(width: 1120, height: 720), appearance: "dark")
        let summary = element("projects.usage.summary")
        XCTAssertTrue(summary.staticTexts["20 tokens"].waitForExistence(timeout: 5))
        let priced = summary.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "List-price estimate", "List-price estimate")).firstMatch
        XCTAssertTrue(priced.exists)
        XCTAssertTrue(element("projects.usage.chart").waitForExistence(timeout: 5))
        let period = element("projects.usage.period")
        period.click()
        app.menuItems["7D"].firstMatch.click()
        XCTAssertTrue(summary.staticTexts["33 tokens"].waitForExistence(timeout: 5))
        let partial = summary.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "Partial estimate", "Partial estimate")).firstMatch
        XCTAssertTrue(partial.exists)
        XCTAssertTrue(element("projects.usage.chart").waitForExistence(timeout: 5))
        XCTAssertFalse(summary.staticTexts["1,033 tokens"].exists)
    }

    func testProjectUsageAtNativeWindowSizes() throws {
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try openProjectUsage(size: size, appearance: appearance)
                let total = element("projects.usage.summary").staticTexts["20 tokens"]
                XCTAssertTrue(total.waitForExistence(timeout: 5))
                XCTAssertTrue(window.frame.contains(total.frame))
                XCTAssertTrue(element("projects.usage.chart").waitForExistence(timeout: 5))
                let image = XCTAttachment(screenshot: window.screenshot())
                image.name = "project-usage-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                image.lifetime = .keepAlways
                add(image)
                app.terminate()
            }
        }
    }

    private func openProjectUsage(size: CGSize, appearance: String) throws -> XCUIElement {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_PROJECT_USAGE"] = "1"
        let window = try launch(size: size, appearance: appearance, projects: true)
        openLibrary("projects")
        let tabs = element("projects.tabs")
        let usage = tabs.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Usage")).firstMatch
        XCTAssertTrue(usage.waitForExistence(timeout: 5))
        usage.click()
        return window
    }

    func testStructuredProjectTimelineShowsActionsAndOpensTheirSession() throws {
        _ = try openStructuredProjectTimeline(size: CGSize(width: 1120, height: 720), appearance: "dark")
        let files = app.buttons["projects.timeline.files"]
        let command = app.buttons["projects.timeline.command"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        XCTAssertTrue(files.label.contains("/synthetic/edited.swift"))
        XCTAssertTrue(files.label.contains("Edit"))
        XCTAssertTrue(files.label.contains("+4"))
        XCTAssertTrue(files.label.contains("−3"))
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        XCTAssertTrue(command.label.contains("967 ms"))
        XCTAssertTrue(command.label.contains("Exit 2"))
        XCTAssertTrue(command.label.contains("Failed"))
        XCTAssertTrue(command.label.contains("API_TOKEN='••••••' synthetic diagnostic"))
        XCTAssertFalse(command.label.contains("synthetic-project-action-secret"))

        command.click()
        let session = element("session.transcript")
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        XCTAssertTrue(session.staticTexts["Validate synthetic integration"].exists)
        XCTAssertFalse(session.staticTexts["Verify synthetic checkout"].exists)
    }

    func testStructuredProjectTimelineAtNativeWindowSizes() throws {
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try openStructuredProjectTimeline(size: size, appearance: appearance)
                let command = app.buttons["projects.timeline.command"]
                XCTAssertTrue(command.waitForExistence(timeout: 5))
                XCTAssertTrue(command.label.contains("967 ms"))
                XCTAssertTrue(window.frame.contains(command.frame))
                XCTAssertTrue(element("projects.timeline.files").exists)
                let image = XCTAttachment(screenshot: window.screenshot())
                image.name = "project-actions-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                image.lifetime = .keepAlways
                add(image)
                app.terminate()
            }
        }
    }

    private func projectTimelineEntry(containing text: String) -> XCUIElement {
        app.buttons.matching(identifier: "projects.timeline.event")
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func openStructuredProjectTimeline(size: CGSize, appearance: String) throws -> XCUIElement {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_PROJECT_ACTIONS"] = "1"
        let window = try launch(size: size, appearance: appearance, projects: true)
        openLibrary("projects")
        XCTAssertTrue(element("projects.timeline").waitForExistence(timeout: 5))
        return window
    }

    func testProjectPinTogglesAndChangesListOrder() throws {
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", projects: true)
        openLibrary("projects")
        let list = element("projects.list")
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let docs = list.staticTexts["Review synthetic documentation"].firstMatch
        let client = list.staticTexts["Verify synthetic checkout"].firstMatch
        XCTAssertTrue(docs.waitForExistence(timeout: 5))
        XCTAssertTrue(client.exists)
        XCTAssertLessThan(client.frame.minY, docs.frame.minY)
        docs.click()
        let pin = window.buttons["projects.pin"]
        XCTAssertTrue(pin.wait(for: \.label, toEqual: "Pin Project", timeout: 5))
        pin.click()
        XCTAssertTrue(pin.wait(for: \.label, toEqual: "Unpin Project", timeout: 5))
        XCTAssertLessThan(docs.frame.minY, client.frame.minY)
        pin.click()
        XCTAssertTrue(pin.wait(for: \.label, toEqual: "Pin Project", timeout: 5))
        XCTAssertLessThan(client.frame.minY, docs.frame.minY)
    }

    func testProjectFinderUsesVerifiedSyntheticDirectory() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_PROJECT_DIRECTORY"] = "1"
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", projects: true)
        openLibrary("projects")
        let finder = app.buttons["projects.finder"]
        XCTAssertTrue(finder.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        finder.click()
        let received = app.staticTexts.matching(identifier: "projects.finder.feedback")
            .matching(NSPredicate(format: "label == %@ OR value == %@", "Finder request sent", "Finder request sent")).firstMatch
        XCTAssertTrue(received.waitForExistence(timeout: 5))
    }

    func testProjectControlsAtNativeWindowSizes() throws {
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try launch(size: size, appearance: appearance, projects: true)
                openLibrary("projects")
                let pin = window.buttons["projects.pin"]
                let finder = window.buttons["projects.finder"]
                XCTAssertTrue(pin.waitForExistence(timeout: 5))
                XCTAssertTrue(finder.waitForExistence(timeout: 5))
                XCTAssertTrue(window.frame.contains(pin.frame) && window.frame.contains(finder.frame))
                let image = XCTAttachment(screenshot: window.screenshot())
                image.name = "project-controls-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                image.lifetime = .keepAlways
                add(image)
                app.terminate()
            }
        }
    }

    func testIndexedProjectsAtAllSizes() throws {
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try launch(size: size, appearance: appearance, projects: true)
                openLibrary("projects")
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

    func testEmptyNavigationAndSettingsReopening() throws {
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        for (page, identifier) in [("tokens", "empty.tokens"), ("projects", "empty.projects"), ("sessions", "empty.sessions")] {
            openLibrary(page)
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

    func testGeneralPresentationPreferencesPersistAndUpdateSessionClock() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_PRESENTATION_ID"] = UUID().uuidString
        let size = CGSize(width: 1120, height: 720)
        let window = try launch(size: size, appearance: "dark", populated: true)
        XCTAssertTrue(app.staticTexts["session.started.clock"].waitForExistence(timeout: 5))

        var settings = try openGeneralDisplaySettings()
        let toggle = { self.app.switches["settings.general.menuRate"].firstMatch }
        XCTAssertTrue(toggle().waitForExistence(timeout: 5), settings.debugDescription)
        XCTAssertTrue(waitForValue("0", on: toggle()))
        selectClock("24-hour")
        toggle().click()
        XCTAssertTrue(waitForValue("1", on: toggle()))
        let shot = XCTAttachment(screenshot: settings.screenshot())
        shot.name = "general-preferences-dark"
        shot.lifetime = .keepAlways
        add(shot)
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        XCTAssertTrue(window.exists && absoluteStarted("17:04").waitForExistence(timeout: 5),
                      app.staticTexts["session.started.clock"].debugDescription)
        app.terminate()

        _ = try launch(size: size, appearance: "light", populated: true)
        XCTAssertTrue(absoluteStarted("17:04").waitForExistence(timeout: 5))
        settings = try openGeneralDisplaySettings()
        XCTAssertTrue(waitForValue("1", on: toggle()))
        selectClock("12-hour")
        toggle().click()
        XCTAssertTrue(waitForValue("0", on: toggle()))
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(absoluteStarted("5:04").waitForExistence(timeout: 5))

        _ = try openGeneralDisplaySettings()
        selectClock("System Default")
        let restored = XCTAttachment(screenshot: settings.screenshot())
        restored.name = "general-preferences-light"
        restored.lifetime = .keepAlways
        add(restored)
    }

    func testNativeStatusItemShowsEnabledRate() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_PRESENTATION_ID"] = UUID().uuidString
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", populated: true)
        let exposed = app.statusItems.matching(NSPredicate(format: "identifier == %@ OR label == %@", "dashboard.statusItem", "Agent Dashboard")).firstMatch
        if !exposed.exists { app.menuBars.firstMatch.hover() }
        guard exposed.waitForExistence(timeout: 3) else {
            throw XCTSkip("This XCTest host does not expose the status item. Verify the actual menu bar separately.")
        }
        let settings = try openGeneralDisplaySettings()
        element("settings.general.menuRate").click()
        XCTAssertTrue(waitForValue("48 tok/min", on: exposed, timeout: 8))
        settings.buttons[XCUIIdentifierCloseWindow].click()
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
        XCTAssertTrue(exposed.exists)
        exposed.click()
        let panel = app.dialogs["menuBarPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.staticTexts["48 tok/min"].firstMatch.waitForExistence(timeout: 5))
        panel.buttons["openDashboard"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        _ = try openGeneralDisplaySettings()
        element("settings.general.menuRate").click()
        XCTAssertNotEqual(exposed.value as? String, "48 tok/min")
    }

    private func waitForValue(_ value: String, on element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = Int(value).map { NSPredicate(format: "value == %@ OR value == %@", value, NSNumber(value: $0)) }
            ?? NSPredicate(format: "value == %@", value)
        let wait = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [wait], timeout: timeout) == .completed
    }

    private func absoluteStarted(_ text: String) -> XCUIElement {
        app.staticTexts.matching(identifier: "session.started.clock")
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)).firstMatch
    }

    private func openGeneralDisplaySettings() throws -> XCUIElement {
        app.buttons["openSettings"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["General"].click()
        XCTAssertTrue(element("settings.general.clock").waitForExistence(timeout: 5))
        return settings
    }

    private func selectClock(_ name: String) {
        element("settings.general.clock").click()
        let option = app.menuItems[name].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.click()
    }

    func testAboutMatchesTheSignedRunningApp() throws {
        struct Receipt: Decodable {
            let version: String
            let build: String
            let entitlements: [String: String]
        }
        guard let json = ProcessInfo.processInfo.environment["AGENTDASH_ABOUT_ARTIFACT_RECEIPT"] else {
            throw XCTSkip("Supply a receipt from codesign and the built Info.plist to compare the actual app.")
        }
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(json.utf8))
        XCTAssertFalse(receipt.entitlements.isEmpty)

        for (appearance, language, locale, tab) in [
            ("dark", "en", "en_US", "About"),
            ("light", "zh-Hans", "zh_CN", "关于"),
        ] {
            _ = try launch(size: CGSize(width: 1120, height: 720), appearance: appearance,
                           language: language, locale: locale)
            app.buttons["openSettings"].click()
            let settings = app.windows["settingsWindow"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.buttons[tab].click()
            let network = settings.descendants(matching: .any).matching(identifier: "settings.about.network.blocked").firstMatch
            XCTAssertTrue(network.waitForExistence(timeout: 6), settings.debugDescription)
            let version = settings.staticTexts["settings.about.version"].firstMatch
            let build = settings.staticTexts["settings.about.build"].firstMatch
            XCTAssertEqual(version.value as? String ?? version.label, receipt.version)
            XCTAssertEqual(build.value as? String ?? build.label, receipt.build)

            let keys = settings.staticTexts.matching(identifier: "settings.about.entitlement.key")
            let values = settings.staticTexts.matching(identifier: "settings.about.entitlement.value")
            let expected = receipt.entitlements.sorted { $0.key < $1.key }
            XCTAssertEqual(keys.count, expected.count)
            XCTAssertEqual(values.count, expected.count)
            for (index, entitlement) in expected.enumerated() {
                let key = keys.element(boundBy: index)
                let value = values.element(boundBy: index)
                XCTAssertEqual(key.value as? String ?? key.label, entitlement.key)
                XCTAssertEqual((value.value as? String ?? value.label).split(whereSeparator: \.isWhitespace),
                               entitlement.value.split(whereSeparator: \.isWhitespace))
            }
            XCTAssertFalse(settings.descendants(matching: .any)
                .matching(identifier: "settings.about.signature.unavailable").firstMatch.exists)
            let shot = XCTAttachment(screenshot: settings.screenshot())
            shot.name = "about-\(language)-\(appearance)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
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

    func testSessionActionsCopyButtonAndRequestFinder() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_INDEXING_SOURCE"] = "1"
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", onboarding: true)
        let choose = app.buttons["onboarding.chooseSources"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        let start = app.buttons["onboarding.startIndexing"]
        XCTAssertTrue(start.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        start.click()
        let open = app.buttons["onboarding.openDashboard"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        XCTAssertTrue(element("sessions.list").waitForExistence(timeout: 5))
        let prompt = window.staticTexts["Selected source 索引验证"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.click()

        let copy = element("session.actions.copy")
        let reveal = element("session.actions.reveal")
        func feedback(_ message: String) -> XCUIElement {
            app.staticTexts.matching(identifier: "session.actions.feedback")
                .matching(NSPredicate(format: "label == %@ OR value == %@", message, message)).firstMatch
        }
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(copy.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        XCTAssertTrue(reveal.isEnabled)
        XCTAssertLessThan(reveal.frame.maxX, copy.frame.minX)
        copy.click()
        XCTAssertTrue(feedback("Resume command copied").waitForExistence(timeout: 5))
        reveal.click()
        XCTAssertTrue(feedback("Finder request sent").waitForExistence(timeout: 5))
    }

    func testLiveSessionActivityTicksAndStopsAtDeadline() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_ACTIVITY"] = "1"
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        let bar = element("session.activity")
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(element("session.activity.elapsed").exists)
        let command = element("session.activity.command")
        let displayed = command.value as? String ?? command.label
        XCTAssertEqual(displayed, "API_TOKEN='••••••' npm test -- auth")
        let lastEvent = element("session.activity.lastEvent")
        let initial = lastEvent.value as? String ?? lastEvent.label
        XCTAssertTrue(initial.hasPrefix("Last event "))
        let ticked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            lastEvent.exists && (lastEvent.value as? String ?? lastEvent.label) != initial
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ticked], timeout: 5), .completed)
        XCTAssertTrue(bar.waitForNonExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["Possibly needs approval"].firstMatch.waitForExistence(timeout: 5))
    }

    func testLiveSessionActivityAtNativeWindowSizes() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_ACTIVITY"] = "1"
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try launch(size: size, appearance: appearance)
                let bar = element("session.activity")
                let command = element("session.activity.command")
                let lastEvent = element("session.activity.lastEvent")
                XCTAssertTrue(bar.waitForExistence(timeout: 5))
                XCTAssertTrue(window.frame.contains(command.frame) && window.frame.contains(lastEvent.frame))
                let attachment = XCTAttachment(screenshot: window.screenshot())
                attachment.name = "session-activity-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }

    func testExpandedToolReadsVerifiedOriginalInputOnClick() throws {
        _ = try openSyntheticOriginalInput(size: CGSize(width: 1120, height: 720), appearance: "dark")
        let toggle = app.buttons["transcript.tool.toggle"]
        let original = app.buttons["transcript.toolInput.readOriginal"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        let input = element("transcript.tool.input")
        func content(_ text: String) -> XCUIElement {
            input.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)).firstMatch
        }
        XCTAssertFalse(content("syntheticinputonly").exists)
        original.click()
        XCTAssertTrue(content("syntheticinputonly").waitForExistence(timeout: 5))
        XCTAssertTrue(content("••••••").exists)
        XCTAssertFalse(content("synthetic-input-secret").exists)
        toggle.click()
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        toggle.click()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertFalse(content("syntheticinputonly").exists)
    }

    func testOriginalInputControlAtNativeWindowSizes() throws {
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try openSyntheticOriginalInput(size: size, appearance: appearance)
                let read = app.buttons["transcript.toolInput.readOriginal"]
                XCTAssertTrue(read.waitForExistence(timeout: 5))
                XCTAssertTrue(read.isHittable)
                XCTAssertTrue(window.frame.contains(read.frame))
                let image = XCTAttachment(screenshot: window.screenshot())
                image.name = "original-input-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                image.lifetime = .keepAlways
                add(image)
                app.terminate()
            }
        }
    }

    private func openSyntheticOriginalInput(size: CGSize, appearance: String) throws -> XCUIElement {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_INDEXING_SOURCE"] = "1"
        app.launchEnvironment["AGENTDASH_SYNTHETIC_ORIGINAL_INPUT"] = "1"
        let window = try launch(size: size, appearance: appearance, onboarding: true)
        let choose = app.buttons["onboarding.chooseSources"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        let start = app.buttons["onboarding.startIndexing"]
        XCTAssertTrue(start.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        start.click()
        let open = app.buttons["onboarding.openDashboard"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()

        let toggle = app.buttons["transcript.tool.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.click()
        return window
    }

    func testFoldedToolResultOpensFromSearchBeyondFirstPage() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_TOOL_PAIR"] = "1"
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        let group = element("transcript.tool.row")
        let output = element("transcript.tool.output")
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertFalse(output.exists)
        let disclosure = app.buttons["transcript.tool.toggle"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.click()
        let input = element("transcript.tool.input")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let maskedInput = input.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR label CONTAINS %@", "••••••", "••••••")).firstMatch
        XCTAssertTrue(maskedInput.waitForExistence(timeout: 5))
        XCTAssertFalse(input.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR label CONTAINS %@", "synthetic-pair-input", "synthetic-pair-input")).firstMatch.exists)
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        let archived = window.staticTexts["Archived tool output"]
        XCTAssertTrue(archived.waitForExistence(timeout: 5))
        disclosure.click()
        XCTAssertTrue(output.waitForNonExistence(timeout: 5))

        app.terminate()
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", query: "foldedresult")
        XCTAssertTrue(element("sessions.searchResults").waitForExistence(timeout: 5))
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        XCTAssertTrue(archived.waitForExistence(timeout: 5))
        let matched = output.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR label CONTAINS %@", "PAIR_TOKEN=••••••", "PAIR_TOKEN=••••••")).firstMatch
        XCTAssertTrue(matched.waitForExistence(timeout: 5))
        let exposed = output.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR label CONTAINS %@", "synthetic-pair-secret", "synthetic-pair-secret")).firstMatch
        XCTAssertFalse(exposed.exists)
        XCTAssertEqual(window.descendants(matching: .any).matching(identifier: "transcript.tool.row").count, 1)
    }

    func testFoldedToolRowAtNativeWindowSizes() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_TOOL_PAIR"] = "1"
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try launch(size: size, appearance: appearance)
                let row = element("transcript.tool.row")
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                XCTAssertTrue(window.frame.contains(row.frame))
                XCTAssertTrue(app.buttons["transcript.tool.toggle"].isHittable)
                XCTAssertFalse(element("transcript.tool.output").exists)
                let attachment = XCTAttachment(screenshot: window.screenshot())
                attachment.name = "folded-tool-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }

    func testSessionActionFooterAtNativeWindowSizes() throws {
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try launch(size: size, appearance: appearance, populated: true)
                let copy = element("session.actions.copy")
                let reveal = element("session.actions.reveal")
                XCTAssertTrue(copy.waitForExistence(timeout: 5))
                XCTAssertTrue(reveal.exists)
                XCTAssertFalse(copy.isEnabled)
                XCTAssertFalse(reveal.isEnabled)
                XCTAssertTrue(window.frame.contains(copy.frame) && window.frame.contains(reveal.frame))
                XCTAssertLessThan(reveal.frame.maxX, copy.frame.minX)
                let attachment = XCTAttachment(screenshot: window.screenshot())
                attachment.name = "session-footer-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
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
        // The native Toggle can expose its preview as part of the row's
        // label instead of a separate static text accessibility element.
        let countPattern = "(?s).*Discovered session files: 1(?![0-9]).*"
        let count = element("onboarding.sources").descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES %@ OR value MATCHES %@", countPattern, countPattern))
            .firstMatch
        guard count.waitForExistence(timeout: 5) else {
            let shot = XCTAttachment(screenshot: window.screenshot())
            shot.name = "onboarding-count-synthetic"
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("The onboarding sheet did not expose one synthetic session file.")
            return
        }
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
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        openLibrary("tokens")
        XCTAssertTrue(element("usage.presented").waitForExistence(timeout: 5))
        let chart = element("usage.chart")
        let tokenAxis = chart.staticTexts["Tokens per minute"]
        XCTAssertTrue(tokenAxis.waitForExistence(timeout: 5))
        let weeklyPeriod = window.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "7D")).firstMatch
        XCTAssertTrue(weeklyPeriod.waitForExistence(timeout: 5))
        weeklyPeriod.click()
        let weeklyAxis = chart.staticTexts["Tokens per hour"]
        XCTAssertTrue(weeklyAxis.waitForExistence(timeout: 5))
        XCTAssertFalse(tokenAxis.exists)
        let metric = element("usage.metric")
        XCTAssertTrue(metric.waitForExistence(timeout: 3))
        metric.click()
        app.menuItems["Cost"].click()
        XCTAssertTrue(app.staticTexts["Peak spend rate"].waitForExistence(timeout: 5))
        XCTAssertTrue(chart.staticTexts["USD per hour"].waitForExistence(timeout: 5))
        XCTAssertFalse(weeklyAxis.exists)
    }

    func testUsageHeadroomExpiresWithoutNewRecords() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_USAGE"] = "1"
        app.launchEnvironment["AGENTDASH_SYNTHETIC_LIMIT_EXPIRY"] = "1"
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        openLibrary("tokens")
        XCTAssertTrue(window.staticTexts["58.0%"].waitForExistence(timeout: 6))
        XCTAssertFalse(element("usage.editRedlines").exists)
        XCTAssertTrue(element("usage.editRedlines").waitForExistence(timeout: 20))
        XCTAssertFalse(window.staticTexts["58.0%"].exists)
        XCTAssertTrue(element("usage.chart").exists)
    }

    func testUnpricedUsageOpensPricingSettings() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_USAGE"] = "1"
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark")
        let usage = window.staticTexts["Token Usage"].firstMatch
        XCTAssertTrue(usage.waitForExistence(timeout: 5))
        usage.click()
        XCTAssertTrue(element("usage.presented").waitForExistence(timeout: 5), "Usage report did not load")
        let link = element("usage.openPricing")
        XCTAssertTrue(link.waitForExistence(timeout: 5), "The unpriced tokens link should have its own identifier")
        link.click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(element("settings.pricing").waitForExistence(timeout: 5))
        XCTAssertTrue(settings.staticTexts["Bundled price table"].exists)
        XCTAssertTrue(settings.staticTexts["synthetic-unpriced"].waitForExistence(timeout: 5))
        XCTAssertTrue(settings.buttons["Copy Unpriced Models"].exists)
    }

    func testInheritedConversationExpandsOnlyConfirmedAndMaskedRows() throws {
        let window = try openInheritedTranscript(size: CGSize(width: 1120, height: 720), appearance: "dark")
        let disclosure = window.buttons["transcript.inherited.toggle"]
        let copy = window.staticTexts["Confirmed inherited message"].firstMatch
        let later = window.staticTexts["Later original message not copied"].firstMatch
        XCTAssertFalse(copy.exists)
        XCTAssertFalse(later.exists)
        disclosure.click()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["API_TOKEN=••••••"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(window.staticTexts["API_TOKEN=synthetic-inherited-secret"].exists)
        XCTAssertFalse(later.exists)
        XCTAssertTrue(window.staticTexts["Own continuation message"].exists)
        disclosure.click()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Own continuation message"].exists)
    }

    func testInheritedConversationAtNativeWindowSizes() throws {
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try openInheritedTranscript(size: size, appearance: appearance)
                let disclosure = window.buttons["transcript.inherited.toggle"]
                XCTAssertTrue(window.frame.contains(disclosure.frame))
                disclosure.click()
                XCTAssertTrue(window.staticTexts["Confirmed inherited message"].firstMatch.waitForExistence(timeout: 5))
                let shot = XCTAttachment(screenshot: window.screenshot())
                shot.name = "inherited-transcript-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                shot.lifetime = .keepAlways
                add(shot)
                app.terminate()
            }
        }
    }

    private func openInheritedTranscript(size: CGSize, appearance: String) throws -> XCUIElement {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_INDEXING_SOURCE"] = "1"
        app.launchEnvironment["AGENTDASH_SYNTHETIC_INHERITED_TRANSCRIPT"] = "1"
        let window = try launch(size: size, appearance: appearance, onboarding: true)
        let choose = app.buttons["onboarding.chooseSources"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        let start = app.buttons["onboarding.startIndexing"]
        XCTAssertTrue(start.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        start.click()
        let dashboard = app.buttons["onboarding.openDashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5))
        dashboard.click()
        XCTAssertTrue(dashboard.waitForNonExistence(timeout: 5))
        let child = element("sessions.list").staticTexts["continued-preview"].firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 10))
        let own = window.staticTexts["Own continuation message"].firstMatch
        if !own.exists {
            XCTAssertTrue(child.wait(for: \.isHittable, toEqual: true, timeout: 5))
            child.click()
        }
        guard own.waitForExistence(timeout: 5),
              window.buttons["transcript.inherited.toggle"].waitForExistence(timeout: 5) else {
            let shot = XCTAttachment(screenshot: window.screenshot())
            shot.name = "inherited-transcript-diagnostic"
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("The synthetic child transcript or its folded section did not appear:\n\(window.debugDescription)")
            return window
        }
        return window
    }

    func testOverviewShowsStructuredActionsFromIndexedSource() throws {
        let window = try openStructuredOverview(size: CGSize(width: 1120, height: 720), appearance: "dark")
        XCTAssertTrue(window.staticTexts["Touched Files"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["/synthetic/test/working.swift"].firstMatch.exists)
        XCTAssertTrue(window.staticTexts["+2"].firstMatch.exists)
        XCTAssertTrue(window.staticTexts["−1"].firstMatch.exists)
        XCTAssertTrue(window.staticTexts["Commands Run"].exists)
        XCTAssertTrue(window.staticTexts["713 ms"].firstMatch.exists)
        XCTAssertTrue(window.staticTexts["Succeeded"].firstMatch.exists)
        let masked = window.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR label CONTAINS %@", "API_TOKEN='••••••'", "API_TOKEN='••••••'")).firstMatch
        XCTAssertTrue(masked.exists)
        let raw = window.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR label CONTAINS %@", "synthetic-actions-secret", "synthetic-actions-secret")).firstMatch
        XCTAssertFalse(raw.exists)
    }

    func testStructuredOverviewAtNativeWindowSizes() throws {
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try openStructuredOverview(size: size, appearance: appearance)
                XCTAssertTrue(window.staticTexts["713 ms"].firstMatch.waitForExistence(timeout: 5))
                XCTAssertTrue(window.staticTexts["+2"].firstMatch.exists)
                let amount = window.staticTexts["713 ms"].firstMatch
                XCTAssertTrue(window.frame.contains(amount.frame))
                let capture = XCTAttachment(screenshot: window.screenshot())
                capture.name = "structured-overview-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                capture.lifetime = .keepAlways
                add(capture)
                app.terminate()
            }
        }
    }

    private func openStructuredOverview(size: CGSize, appearance: String) throws -> XCUIElement {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_INDEXING_SOURCE"] = "1"
        app.launchEnvironment["AGENTDASH_SYNTHETIC_STRUCTURED_ACTIONS"] = "1"
        let window = try launch(size: size, appearance: appearance, onboarding: true)
        let choose = app.buttons["onboarding.chooseSources"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        let start = app.buttons["onboarding.startIndexing"]
        XCTAssertTrue(start.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        start.click()
        let open = app.buttons["onboarding.openDashboard"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        let tabs = element("session.details.tabs")
        let overview = tabs.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Overview")).firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        overview.click()
        XCTAssertTrue(element("session.overview").waitForExistence(timeout: 5))

        return window
    }

    func testSessionTopicsAppearAfterNormalSourceIndexing() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_INDEXING_SOURCE"] = "1"
        app.launchEnvironment["AGENTDASH_SYNTHETIC_TOPICS"] = "1"
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", onboarding: true)
        app.buttons["onboarding.chooseSources"].click()
        let start = app.buttons["onboarding.startIndexing"]
        XCTAssertTrue(start.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        start.click()
        let open = app.buttons["onboarding.openDashboard"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        let tabs = element("session.details.tabs")
        let overview = tabs.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Overview")).firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        overview.click()
        let topic = element("session.topics").buttons["harmonic"]
        XCTAssertTrue(topic.waitForExistence(timeout: 8))
        topic.click()
        XCTAssertTrue(element("sessions.searchResults").waitForExistence(timeout: 5))
    }

    func testProjectTopicsOpenSearchAndFitNativeWindowSizes() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_TOPICS"] = "1"
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try launch(size: size, appearance: appearance, projects: true)
                openLibrary("projects")
                let chip = element("projects.topics").buttons["harmonic"]
                XCTAssertTrue(chip.waitForExistence(timeout: 8))
                XCTAssertTrue(chip.isHittable)
                XCTAssertTrue(window.frame.contains(chip.frame))
                let capture = XCTAttachment(screenshot: window.screenshot())
                capture.name = "project-topics-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                capture.lifetime = .keepAlways
                add(capture)
                if appearance == "dark", size.width == 1120 {
                    chip.click()
                    XCTAssertTrue(element("sessions.searchResults").waitForExistence(timeout: 5))
                }
                app.terminate()
            }
        }
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
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        XCTAssertFalse(settings.staticTexts["Synthetic custom source"].exists)
    }

    func testSessionDetailValuesAtNativeWindowSizes() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_DETAIL_FACTS"] = "1"
        app.launchEnvironment["AGENTDASH_SYNTHETIC_USAGE"] = "1"
        let sizes = [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)]
        for appearance in ["dark", "light"] {
            for size in sizes {
                let window = try launch(size: size, appearance: appearance, populated: true)
                let facts = window.descendants(matching: .any).matching(NSPredicate(
                    format: "identifier IN %@", ["session.details.facts.compact", "session.details.facts.wide"])).firstMatch
                XCTAssertTrue(facts.waitForExistence(timeout: 5))
                try awaitVisualReviewIfRequested(caseName: "session-facts-\(appearance)-\(Int(size.width))", frame: window.frame)
                if size.width == 960 {
                    XCTAssertEqual(facts.identifier, "session.details.facts.compact")
                } else if size.width == 1440 {
                    XCTAssertEqual(facts.identifier, "session.details.facts.wide")
                }
                for value in ["460,098,000", "$1,043.47", "List-price estimate", "654,321 / 999,999 tokens", "65.4% used"] {
                    let reading = facts.staticTexts.matching(NSPredicate(
                        format: "label CONTAINS %@ OR value CONTAINS %@", value, value)).firstMatch
                    XCTAssertTrue(reading.waitForExistence(timeout: 5), "Missing detail value: \(value)")
                    XCTAssertTrue(window.frame.contains(reading.frame))
                }
                app.terminate()
            }
        }
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

    func testPrivacyDisplayAndIndexControlsAreIndependent() throws {
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", populated: true)
        let masked = window.staticTexts["API_TOKEN=••••••"]
        let raw = window.staticTexts["API_TOKEN=synthetic-preview-only"]
        XCTAssertTrue(masked.waitForExistence(timeout: 5))
        XCTAssertFalse(raw.exists)
        app.buttons["openSettings"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["Privacy"].click()
        XCTAssertTrue(element("settings.privacy").waitForExistence(timeout: 5))
        let display = element("privacy.maskDisplay")
        XCTAssertTrue(display.waitForExistence(timeout: 5))
        display.click()
        XCTAssertTrue(raw.waitForExistence(timeout: 5))
        let redact = element("privacy.redactIndex")
        XCTAssertTrue(redact.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        redact.click()
        let confirm = app.buttons["Remove Indexed Credentials"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(raw.waitForNonExistence(timeout: 5))
        XCTAssertTrue(masked.waitForExistence(timeout: 5))
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
                let target: CGFloat = switch size.width { case 960: 300; case 1120: 356; default: 420 }
                assertSessionListWidth(target, in: window)
                let layout = size.width == 960 ? "compact" : "wide"
                XCTAssertTrue(element("session.details.facts.\(layout)").waitForExistence(timeout: 5))
                let name = "sessions-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                try awaitVisualReviewIfRequested(caseName: name, frame: window.frame)
                app.terminate()
            }
        }
    }

    func testDraggedSessionListWidthPersistsOnRelaunch() throws {
        guard ProcessInfo.processInfo.environment["AGENTDASH_VISUAL_REVIEW_DIR"] != nil else {
            throw XCTSkip("A real pointer drag and relaunch readback require the explicit visual review handoff.")
        }
        app.launchEnvironment["AGENTDASH_SYNTHETIC_PRESENTATION_ID"] = UUID().uuidString
        let first = try launch(size: .init(width: 1120, height: 720), appearance: "dark", populated: true)
        assertSessionListWidth(356, in: first)
        let handle = element("sessions.column.resize")
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let grip = handle.frame
        let trailingDivider = first.splitters.element(boundBy: 1).frame
        XCTAssertTrue(first.frame.contains(grip))
        XCTAssertEqual(grip.width, 8, accuracy: 1)
        XCTAssertEqual(grip.maxX, trailingDivider.midX, accuracy: 2,
                       "The mouse target must touch the actual trailing divider.")
        try awaitVisualReviewIfRequested(caseName: "session-divider-drag", frame: first.frame)
        let resized = first.splitters.element(boundBy: 1).frame.midX - first.splitters.element(boundBy: 0).frame.midX
        XCTAssertTrue((378...420).contains(resized), "Drag must change the actual Sessions list width; got \(resized)pt")
        app.terminate()
        let reopened = try launch(size: .init(width: 1440, height: 900), appearance: "light", populated: true)
        assertSessionListWidth(resized, in: reopened)
    }

    private func assertSessionListWidth(_ target: CGFloat, in window: XCUIElement, tolerance: CGFloat = 2) {
        let splitters = window.splitters
        let left = splitters.element(boundBy: 0)
        let right = splitters.element(boundBy: 1)
        guard left.waitForExistence(timeout: 5), right.waitForExistence(timeout: 5) else {
            return XCTFail("The Sessions window is missing either native divider.")
        }
        let matches = NSPredicate { _, _ in abs(right.frame.midX - left.frame.midX - target) <= tolerance }
        let expectation = XCTNSPredicateExpectation(predicate: matches, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 4)
        XCTAssertEqual(result, .completed, "Expected \(target)pt Sessions list; native divider span is \(right.frame.midX - left.frame.midX)pt.")
    }

    func testNativeSearchFiltersRemoveAndRestoreASmartGroup() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_SEARCH_FILTERS"] = "1"
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark",
                                populated: true, query: "登录 agent:codex role:assistant")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(matchCount("Matches: 1 · Sessions: 1").waitForExistence(timeout: 5))
        XCTAssertTrue(element("search.filters.menu").waitForExistence(timeout: 5))

        let initial = XCTAttachment(screenshot: window.screenshot())
        initial.name = "search-filters-dark"
        initial.lifetime = .keepAlways
        add(initial)

        element("search.filters.menu").click()
        let remove = app.menuItems["Remove role:assistant"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        XCTAssertTrue(matchCount("Matches: 3 · Sessions: 1").waitForExistence(timeout: 5))
        XCTAssertTrue((field.value as? String)?.contains("登录") == true)

        let group = app.buttons.matching(identifier: "search.smartGroup").firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.click()
        XCTAssertTrue(matchCount("Matches: 1 · Sessions: 1").waitForExistence(timeout: 5))
        XCTAssertTrue(element("sidebar.filter.clear").waitForExistence(timeout: 5))
        element("search.filters.menu").click()
        XCTAssertTrue(app.menuItems[#"Remove role:"assistant""#].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Remove agent:codex"].exists)
        app.menuItems["Remove agent:codex"].click()
        XCTAssertTrue(matchCount("Matches: 1 · Sessions: 1").waitForExistence(timeout: 5))
        XCTAssertTrue(element("sidebar.filter.clear").exists)
    }

    func testSearchFilterTokensInNativeWindowSizes() throws {
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try launch(size: size, appearance: appearance, populated: true, query: "登录 agent:codex role:assistant")
                let field = app.searchFields.firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                XCTAssertTrue(matchCount("Matches: 1 · Sessions: 1").waitForExistence(timeout: 5))
                XCTAssertTrue(window.frame.contains(field.frame))
                let shot = XCTAttachment(screenshot: window.screenshot())
                shot.name = "native-filter-tokens-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                shot.lifetime = .keepAlways
                add(shot)
                app.terminate()
            }
        }
    }

    func testRemovingLastFilterFromFilterOnlySearchRestoresLibrary() throws {
        _ = try launch(size: CGSize(width: 1120, height: 720), appearance: "light", populated: true, query: "agent:codex")
        XCTAssertTrue(element("sessions.searchResults").waitForExistence(timeout: 5))
        let filters = element("search.filters.menu")
        filters.click()
        let remove = app.menuItems["Remove agent:codex"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        XCTAssertTrue(element("sessions.list").waitForExistence(timeout: 5))
        XCTAssertTrue(filters.waitForNonExistence(timeout: 5))
    }

    private func matchCount(_ expected: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", expected, expected)).firstMatch
    }

    func testChineseSearchStepsAcrossBoundedTranscriptPages() throws {
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", populated: true, query: "登录")
        waitForSyntheticChineseSearch()
        let transcript = element("session.transcript.messages")
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let previous = window.buttons["Previous Match"]
        let next = window.buttons["Next Match"]
        let first = transcript.staticTexts["修复登录问题 · Synthetic search target"]
        let second = transcript.staticTexts["验证登录配置 · Second synthetic search target"]
        let third = transcript.staticTexts["完成登录修复 · Final synthetic search target"]
        guard first.waitForExistence(timeout: 5) else {
            let shot = XCTAttachment(screenshot: window.screenshot())
            shot.name = "first-search-hit-diagnostic"
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("The first synthetic Chinese search hit did not appear.")
            return
        }
        XCTAssertTrue(showsMatchPosition("1 of 3 matches"))
        XCTAssertFalse(previous.isEnabled)
        XCTAssertTrue(next.wait(for: \.isEnabled, toEqual: true, timeout: 5))

        next.click()
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(showsMatchPosition("2 of 3 matches"))
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        XCTAssertTrue(next.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        next.click()
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        XCTAssertTrue(showsMatchPosition("3 of 3 matches"))
        XCTAssertTrue(second.waitForNonExistence(timeout: 5))
        XCTAssertFalse(next.isEnabled)

        XCTAssertTrue(previous.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        previous.click()
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(showsMatchPosition("2 of 3 matches"))
        XCTAssertTrue(third.waitForNonExistence(timeout: 5))
        XCTAssertTrue(previous.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        previous.click()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(showsMatchPosition("1 of 3 matches"))
        XCTAssertTrue(second.waitForNonExistence(timeout: 5))
        XCTAssertFalse(previous.isEnabled)
        XCTAssertFalse(transcript.staticTexts["API_TOKEN=synthetic-preview-only"].exists)
    }

    func testSearchMatchControlsAtAllSizes() throws {
        for appearance in ["dark", "light"] {
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 720), CGSize(width: 1440, height: 900)] {
                let window = try launch(size: size, appearance: appearance, populated: true, query: "登录")
                waitForSyntheticChineseSearch()
                XCTAssertTrue(showsMatchPosition("1 of 3 matches"))
                let next = window.buttons["Next Match"]
                XCTAssertTrue(next.wait(for: \.isEnabled, toEqual: true, timeout: 5))
                XCTAssertTrue(next.isHittable)
                let name = "search-match-\(appearance)-\(Int(size.width))x\(Int(size.height))"
                try awaitVisualReviewIfRequested(caseName: name, frame: window.frame)
                app.terminate()
            }
        }
    }

    private func showsMatchPosition(_ expected: String) -> Bool {
        app.staticTexts.matching(identifier: "transcript.match.position")
            .matching(NSPredicate(format: "label == %@ OR value == %@", expected, expected))
            .firstMatch.waitForExistence(timeout: 5)
    }

    private func waitForSyntheticChineseSearch() {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let prefilled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "登录"), object: search)
        XCTAssertEqual(XCTWaiter.wait(for: [prefilled], timeout: 5), .completed)
        XCTAssertTrue(element("sessions.searchResults").waitForExistence(timeout: 5))
    }

    private func openLibrary(_ page: String) {
        let row = element("sidebar.library.\(page)")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
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
                        projects: Bool = false, onboarding: Bool = false, query: String? = nil,
                        language: String = "en", locale: String = "en_US") throws -> XCUIElement {
        app.launchArguments = ["--synthetic", "--window-size", "\(Int(size.width))x\(Int(size.height))", "--appearance", appearance,
                               "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        if populated { app.launchArguments.append("--synthetic-sessions") }
        if projects { app.launchArguments.append("--synthetic-projects") }
        if onboarding { app.launchArguments.append("--synthetic-onboarding") }
        app.launchEnvironment["AGENTDASH_SYNTHETIC_SEARCH_QUERY"] = query
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
