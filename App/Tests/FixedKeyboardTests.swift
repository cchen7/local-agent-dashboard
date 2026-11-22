import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest

/// Actual-keyboard cases are opt-in. The ordinary smoke suite uses clicks and
/// synthetic state, so an unattended run never asks XCTest to pick a layout.
@MainActor
final class FixedKeyboardTests: XCTestCase {
    private let app = XCUIApplication()
    private var launched = false

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDown() async throws {
        if launched { app.terminate() }
    }

    func testABCLibraryShortcuts() throws {
        let keys = try launch(mode: .abc)
        try keys.press(kVK_ANSI_3, flags: .maskCommand)
        XCTAssertTrue(element("empty.tokens").waitForExistence(timeout: 5))
        try keys.press(kVK_ANSI_2, flags: .maskCommand)
        XCTAssertTrue(element("empty.projects").waitForExistence(timeout: 5))
        try keys.press(kVK_ANSI_1, flags: .maskCommand)
        XCTAssertTrue(element("empty.sessions").waitForExistence(timeout: 5))
    }

    func testABCMatchShortcutsKeepBoundaries() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_SEARCH_QUERY"] = "登录"
        let keys = try launch(mode: .abc, populated: true)
        XCTAssertTrue(position("1 of 3 matches").waitForExistence(timeout: 5))
        try keys.press(kVK_ANSI_G, flags: [.maskCommand, .maskShift])
        XCTAssertTrue(position("1 of 3 matches").exists)
        try keys.press(kVK_ANSI_G, flags: .maskCommand)
        XCTAssertTrue(position("2 of 3 matches").waitForExistence(timeout: 5))
        try keys.press(kVK_ANSI_G, flags: .maskCommand)
        XCTAssertTrue(position("3 of 3 matches").waitForExistence(timeout: 5))
        try keys.press(kVK_ANSI_G, flags: .maskCommand)
        XCTAssertTrue(position("3 of 3 matches").exists)
        try keys.press(kVK_ANSI_G, flags: [.maskCommand, .maskShift])
        XCTAssertTrue(position("2 of 3 matches").waitForExistence(timeout: 5))
    }

    func testABCSourceNameEnablesChoose() throws {
        let keys = try launch(mode: .abc)
        app.buttons["openSettings"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["Sources"].click()
        settings.buttons["source.add"].click()
        let name = app.textFields["source.add.name"]
        let choose = app.buttons["source.add.choose"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(choose.isEnabled)
        name.click()
        try keys.press(kVK_ANSI_Q)
        try keys.press(kVK_ANSI_A)
        XCTAssertTrue(choose.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        XCTAssertEqual(name.value as? String, "qa")
        app.buttons["Cancel"].firstMatch.click()
    }

    func testApplePinyinCommitsChineseIntoRealSearch() async throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_NATIVE_CHINESE"] = "1"
        let keys = try launch(mode: .pinyin, populated: true)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        // Hardware key positions for zhongwen, followed by a Pinyin commit.
        for key in [kVK_ANSI_Z, kVK_ANSI_H, kVK_ANSI_O, kVK_ANSI_N, kVK_ANSI_G,
                    kVK_ANSI_W, kVK_ANSI_E, kVK_ANSI_N] {
            try keys.press(key)
            try await Task.sleep(for: .milliseconds(75))
        }
        try keys.press(kVK_Space)
        let committed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "中文"), object: field)
        let result = await XCTWaiter.fulfillment(of: [committed], timeout: 5)
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(element("sessions.searchResults").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["中文输入 · Synthetic typing target"].firstMatch.waitForExistence(timeout: 5))
    }

    func testABCExistingSourceNameRoundTrip() throws {
        let keys = try launch(mode: .abc, populated: true)
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
        name.click()
        try keys.press(kVK_ANSI_A, flags: .maskCommand)
        try keys.press(kVK_Delete)
        XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: false, timeout: 5))
        try keys.press(kVK_ANSI_Q)
        try keys.press(kVK_ANSI_A)
        XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        save.click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        XCTAssertTrue(settings.staticTexts["qa"].waitForExistence(timeout: 5))
        edit.click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "qa")
    }

    func testABCResumeCopyShortcut() throws {
        app.launchEnvironment["AGENTDASH_SYNTHETIC_INDEXING_SOURCE"] = "1"
        app.launchEnvironment["AGENTDASH_NATIVE_ONBOARDING"] = "1"
        let keys = try launch(mode: .abc)
        let choose = app.buttons["onboarding.chooseSources"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        let start = app.buttons["onboarding.startIndexing"]
        XCTAssertTrue(start.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        start.click()
        let open = app.buttons["onboarding.openDashboard"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        XCTAssertTrue(app.buttons["session.actions.copy"].wait(for: \.isEnabled, toEqual: true, timeout: 10))
        try keys.press(kVK_ANSI_C, flags: [.maskCommand, .maskShift])
        let feedback = app.staticTexts.matching(identifier: "session.actions.feedback")
            .matching(NSPredicate(format: "value == %@ OR label == %@", "Resume command copied", "Resume command copied")).firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
    }

    private func launch(mode: FixedKeyboard.Mode, populated: Bool = false) throws -> FixedKeyboard {
        try FixedKeyboard.preflight(mode)
        guard NSRunningApplication.runningApplications(withBundleIdentifier: FixedKeyboard.bundleID).isEmpty else {
            throw XCTSkip("A Dashboard process is already running; preserve that instance.")
        }
        app.launchArguments = ["--synthetic", "--window-size", "1120x720", "--appearance", "dark",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if populated { app.launchArguments.append("--synthetic-sessions") }
        if app.launchEnvironment["AGENTDASH_NATIVE_ONBOARDING"] == "1" {
            app.launchArguments.append("--synthetic-onboarding")
        }
        app.launch()
        launched = true
        app.activate()
        XCTAssertTrue(app.windows["dashboardWindow"].waitForExistence(timeout: 10))
        return try FixedKeyboard(mode: mode, app: app)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func position(_ expected: String) -> XCUIElement {
        app.staticTexts.matching(identifier: "transcript.match.position")
            .matching(NSPredicate(format: "value == %@ OR label == %@", expected, expected)).firstMatch
    }
}

@MainActor
private struct FixedKeyboard {
    enum Mode: String {
        case abc, pinyin

        var sourceID: String {
            switch self {
            case .abc: "com.apple.keylayout.ABC"
            case .pinyin: "com.apple.inputmethod.SCIM.ITABC"
            }
        }
    }

    static let bundleID = "com.chenxin.AgentDashboard"
    let mode: Mode
    let app: XCUIApplication
    let pid: pid_t

    init(mode: Mode, app: XCUIApplication) throws {
        guard app.state == .runningForeground,
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == Self.bundleID else {
            throw XCTSkip("The synthetic Dashboard is not foreground; no keyboard events sent.")
        }
        self.mode = mode
        self.app = app
        pid = front.processIdentifier
    }

    static func preflight(_ mode: Mode) throws {
        guard ProcessInfo.processInfo.environment["AGENTDASH_NATIVE_KEYBOARD"] == mode.rawValue else {
            throw XCTSkip("Actual keyboard QA requires an explicit ABC or Apple Pinyin run.")
        }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
              Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String == mode.sourceID else {
            throw XCTSkip("The required Apple input source is not selected; no keyboard events sent.")
        }
        guard CGPreflightPostEventAccess() else {
            throw XCTSkip("This runner does not already have event-posting access; no permission requested.")
        }
    }

    func press(_ key: Int, flags: CGEventFlags = []) throws {
        try Self.preflight(mode)
        guard app.state == .runningForeground, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw XCTSkip("The synthetic Dashboard lost focus; stopped sending keyboard events.")
        }
        guard let code = CGKeyCode(exactly: key),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            XCTFail("Unable to construct the fixed keyboard events.")
            return
        }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
    }
}
