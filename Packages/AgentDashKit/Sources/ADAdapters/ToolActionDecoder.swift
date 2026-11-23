import ADCore
import CoreFoundation
import Foundation

/// Select only known tools and bounded, explicit argument shapes.
enum ToolActionDecoder {
    static func claude(name: String?, input: [String: Any]) -> ToolActionEvidence? {
        switch name {
        case "Bash": return command(input["command"])
        case "Read": return file(input["file_path"], operation: .read)
        case "Write": return file(input["file_path"], operation: .write)
        case "Delete": return file(input["file_path"], operation: .delete)
        case "Edit": return file(input["file_path"], operation: .edit, counts: edit(input, old: "old_string", new: "new_string"))
        case "MultiEdit":
            let counts = (input["edits"] as? [[String: Any]]).flatMap(combinedEdits)
            return file(input["file_path"], operation: .edit, counts: counts)
        default: return nil
        }
    }

    static func codex(name: String, arguments: String) -> ToolActionEvidence? {
        switch name {
        case "exec_command":
            return command(tryObject(arguments)?["cmd"])
        case "apply_patch":
            let patch = (tryObject(arguments)?["patch"] as? String) ?? arguments
            return parsePatch(patch)
        default: return nil
        }
    }

    static func copilot(name: String, arguments: [String: Any]) -> ToolActionEvidence? {
        switch name {
        case "bash", "shell", "run_command", "powershell": return command(arguments["command"] ?? arguments["cmd"])
        case "view", "read_file": return file(arguments["path"] ?? arguments["filePath"], operation: .read)
        case "edit", "edit_file":
            return file(arguments["path"] ?? arguments["filePath"], operation: .edit,
                        counts: edit(arguments, old: "old_str", new: "new_str"))
        case "create", "write_file": return file(arguments["path"] ?? arguments["filePath"], operation: .write)
        case "apply_patch": return (arguments["patch"] as? String).flatMap(parsePatch)
        default: return nil
        }
    }

    static func completion(exitCode: Any? = nil, durationMS: Any? = nil, success: Any? = nil) -> ToolActionEvidence? {
        let exit = AdapterJSON.integer(exitCode)
        let duration = AdapterJSON.integer(durationMS).flatMap { $0 >= 0 ? $0 : nil }
        let evidence = ToolActionEvidence(completion: .init(exitCode: exit, durationMS: duration, success: boolean(success)))
        return evidence.isEmpty ? nil : evidence
    }

    static func boolean(_ raw: Any?) -> Bool? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private static func tryObject(_ text: String) -> [String: Any]? {
        guard text.utf8.count <= 1_048_576 else { return nil }
        return AdapterJSON.object(Data(text.utf8))
    }

    private static func command(_ raw: Any?) -> ToolActionEvidence? {
        let evidence = ToolActionEvidence(command: AdapterJSON.string(raw))
        return evidence.isEmpty ? nil : evidence
    }

    private struct Counts {
        var added: Int64 = 0
        var removed: Int64 = 0
    }

    private static func file(_ raw: Any?, operation: ToolFileAction.Operation, counts: Counts? = nil) -> ToolActionEvidence? {
        guard let path = raw as? String, ToolFileAction.validPath(path) else { return nil }
        return .init(files: [.init(path: path, operation: operation, added: counts?.added, removed: counts?.removed)])
    }

    private static func edit(_ args: [String: Any], old: String, new: String) -> Counts? {
        guard let before = args[old] as? String, let after = args[new] as? String,
              before.utf8.count + after.utf8.count <= 131_072 else { return nil }
        func lines(_ text: String) -> [Substring] {
            guard !text.isEmpty else { return [] }
            var values = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            if text.last?.isNewline == true { values.removeLast() }
            return values
        }
        let previous = lines(before)
        let next = lines(after)
        guard previous.count <= 512, next.count <= 512 else { return nil }
        let changes = next.difference(from: previous) { $0.utf8.elementsEqual($1.utf8) }
        return .init(added: Int64(changes.insertions.count), removed: Int64(changes.removals.count))
    }

    private static func combinedEdits(_ edits: [[String: Any]]) -> Counts? {
        guard !edits.isEmpty, edits.count <= 32 else { return nil }
        var result = Counts()
        var bytes = 0
        for entry in edits {
            guard let before = entry["old_string"] as? String, let after = entry["new_string"] as? String else { return nil }
            bytes += before.utf8.count + after.utf8.count
            guard bytes <= 131_072, let counts = edit(entry, old: "old_string", new: "new_string") else { return nil }
            result.added += counts.added
            result.removed += counts.removed
        }
        return result
    }

    /// Count patch records, not command output, a filesystem diff, or filenames
    /// inferred from shell commands. Stop at the explicit bounded envelope.
    private static func parsePatch(_ patch: String) -> ToolActionEvidence? {
        guard patch.utf8.count <= 1_048_576 else { return nil }
        let text = patch.trimmingCharacters(in: .newlines)
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.first == "*** Begin Patch", lines.last == "*** End Patch", lines.count > 2 else { return nil }
        var files: [ToolFileAction] = []
        var path: String?
        var operation: ToolFileAction.Operation = .edit
        var counts = Counts()
        var moved: String?
        func finishSection() -> Bool {
            guard let path else { return true }
            guard files.count < ToolActionEvidence.maximumFiles else { return false }
            let known = operation != .delete
            files.append(.init(path: path, operation: operation, added: known ? counts.added : nil, removed: known ? counts.removed : nil))
            if let moved {
                guard files.count < ToolActionEvidence.maximumFiles else { return false }
                files.append(.init(path: moved, operation: .write))
            }
            return true
        }
        for line in lines.dropFirst().dropLast() {
            let headers: [(String, ToolFileAction.Operation)] = [
                ("*** Add File: ", .write), ("*** Update File: ", .edit), ("*** Delete File: ", .delete)
            ]
            if let (header, kind) = headers.first(where: { line.hasPrefix($0.0) }) {
                guard finishSection() else { return nil }
                let target = String(line.dropFirst(header.count))
                guard ToolFileAction.validPath(target) else { return nil }
                path = target
                operation = kind
                counts = Counts()
                moved = nil
            } else if line.hasPrefix("*** Move to: ") {
                let target = String(line.dropFirst("*** Move to: ".count))
                guard path != nil, operation == .edit, moved == nil, ToolFileAction.validPath(target) else { return nil }
                moved = target
            } else {
                guard path != nil else { return nil }
                switch line.first {
                case "+" where operation != .delete: counts.added += 1
                case "-" where operation == .edit: counts.removed += 1
                case " " where operation == .edit, "@" where operation == .edit: break
                case "*" where line == "*** End of File" && operation == .edit: break
                default: return nil
                }
            }
        }
        guard finishSection(), !files.isEmpty else { return nil }
        return .init(files: files)
    }
}
