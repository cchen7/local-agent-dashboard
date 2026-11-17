import XCTest

/// Pending full Xcode. Synthetic launch never resolves or probes the user's agent roots.
@MainActor
final class SmokeTests: XCTestCase {
    func testEmptyNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your private, local dashboard"].waitForExistence(timeout: 5))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["No token usage yet"].waitForExistence(timeout: 3))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["No projects yet"].waitForExistence(timeout: 3))
        app.terminate()
    }
}
