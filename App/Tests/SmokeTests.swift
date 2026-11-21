import AppKit
import XCTest

/// Interaction and native geometry tests use synthetic data only. Visual review
/// uses the owner's already-authorized Computer Use tool, not runner permissions.
@MainActor
final class SmokeTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDown() async throws { app.terminate() }

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

    func testChineseSearchOpensTheMatchedTranscriptPage() throws {
        let window = try launch(size: CGSize(width: 1120, height: 720), appearance: "dark", populated: true)
        XCTAssertTrue(element("sessions.list").waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("登录")
        XCTAssertTrue(element("sessions.searchResults").waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["修复登录问题 · Synthetic search target"].waitForExistence(timeout: 5))
        XCTAssertFalse(window.staticTexts["API_TOKEN=synthetic-preview-only"].exists)
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
        app.buttons["openDashboard"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(element("empty.sessions").waitForExistence(timeout: 3))
    }

    private func launch(size: CGSize, appearance: String, populated: Bool = false) throws -> XCUIElement {
        app.launchArguments = ["--synthetic", "--window-size", "\(Int(size.width))x\(Int(size.height))", "--appearance", appearance,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if populated { app.launchArguments.append("--synthetic-sessions") }
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
