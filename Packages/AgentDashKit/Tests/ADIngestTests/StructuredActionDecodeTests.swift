@testable import ADAdapters
import ADCore
import Foundation
import Testing

@Test("§10.5: Claude counts replacement lines, joins MultiEdit targets, and does not invent Write counts")
func claudeStructuredActionsKeepExactLineCounts() throws {
    let single = try #require(ToolActionDecoder.claude(name: "Edit", input: [
        "file_path": "synthetic/text", "old_string": "kept\nold\n", "new_string": "kept\nnew\nadded\n"
    ])?.files.first)
    #expect(single.operation == .edit && single.added == 2 && single.removed == 1)
    let multi = try #require(ToolActionDecoder.claude(name: "MultiEdit", input: [
        "file_path": "synthetic/text", "edits": [
            ["old_string": "a", "new_string": "b"],
            ["old_string": "", "new_string": "จ\nc\n"],
        ]
    ])?.files)
    #expect(multi.count == 1)
    #expect(multi.first?.added == 3 && multi.first?.removed == 1)
    let write = ToolActionDecoder.claude(name: "Write", input: ["file_path": "synthetic/text", "content": "new\n"])
    #expect(write?.files.first?.operation == .write && write?.files.first?.added == nil)
    #expect(ToolActionDecoder.claude(name: "Read", input: ["file_path": "x\u{0}y"]) == nil)
    #expect(ToolActionDecoder.claude(name: "Edit", input: ["file_path": String(repeating: "x", count: 4097)]) == nil)
}

@Test("§10.5: Codex records patch sections and counts only actual marked diff lines")
func codexStructuredPatchCounts() throws {
    let patch = """
        *** Begin Patch
        *** Update File: synthetic/change
        @@
         kept
        -old
        +new
        +extra
        *** Add File: synthetic/new
        +one
        +two
        *** Delete File: synthetic/old
        *** End Patch
        """
    let files = try #require(ToolActionDecoder.codex(name: "apply_patch", arguments: patch)?.files)
    #expect(files == [
        .init(path: "synthetic/change", operation: .edit, added: 2, removed: 1),
        .init(path: "synthetic/new", operation: .write, added: 2, removed: 0),
        .init(path: "synthetic/old", operation: .delete),
    ])
    #expect(ToolActionDecoder.codex(name: "apply_patch", arguments: "*** Add File: synthetic/no-envelope") == nil)
    #expect(ToolActionDecoder.codex(name: "exec_command", arguments: #"{"cmd":"synthetic pipeline"}"#)?.command == "synthetic pipeline")
    #expect(ToolActionDecoder.codex(name: "unknown", arguments: #"{"cmd":"synthetic ignored"}"#) == nil)
}

@Test("§10.5: Copilot uses known tool argument shapes and does not treat shell text as a file operation")
func copilotStructuredActionsUseNamedFields() throws {
    #expect(ToolActionDecoder.copilot(name: "view", arguments: ["path": "synthetic/目录"])?.files ==
            [.init(path: "synthetic/目录", operation: .read)])
    #expect(ToolActionDecoder.copilot(name: "edit", arguments: ["path": "synthetic/file"])?.files.first?.added == nil)
    #expect(ToolActionDecoder.copilot(name: "bash", arguments: ["command": "synthetic privacy-safe"])?.command ==
            "synthetic privacy-safe")
    #expect(ToolActionDecoder.copilot(name: "grep", arguments: ["path": "synthetic/ignored"]) == nil)
}
