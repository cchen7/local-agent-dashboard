@testable import ADAdapters
import Foundation
import Testing

@Test("ADP-CP: workspace title scalar shapes and summary fallback")
func copilotTitleShapes() {
    let cases = [
        ("name: Ordinary title\nsummary: ignored\n", "Ordinary title"),
        ("name: 'A ''quoted'' title'\n", "A 'quoted' title"),
        ("name: \"A \\\"quoted\\\" title\"\r\n", "A \"quoted\" title"),
        ("name: |-\n  First line\n  second line\nother: ignored\n", "First line second line"),
        ("name: *unsupported\nsummary: Fallback summary\n", "Fallback summary"),
    ]
    for (input, expected) in cases {
        #expect(CopilotWorkspaceTitle.title(from: Data(input.utf8)) == expected)
    }
    #expect(CopilotWorkspaceTitle.title(from: Data("name: one\nname: two\n".utf8)) == nil)
    #expect(CopilotWorkspaceTitle.eventPath(forWorkspacePath: "session-state/../workspace.yaml") == nil)
    #expect(CopilotWorkspaceTitle.eventPath(forWorkspacePath: "session-state/x/workspace.yaml") == "session-state/x/events.jsonl")
}
