import ADCore
import Foundation

/// Read the title-only scalar subset of Copilot's optional workspace sidecar.
/// Neither the parsed YAML nor its unrelated fields enter the index.
public enum CopilotWorkspaceTitle {
    private static let storagePrefix = "session-state/"
    private static let eventsName = "events.jsonl"
    private static let workspaceName = "workspace.yaml"
    private static let limit = 256 * 1024

    public static func eventPath(forWorkspacePath path: String) -> String? {
        sibling(of: path, current: workspaceName, desired: eventsName)
    }

    public static func read(forEventPath path: String, authorizedRoot: URL,
                            expectedRoot: SourceFileReader.DirectoryIdentity?) -> String? {
        guard let workspacePath = sibling(of: path, current: eventsName, desired: workspaceName),
              let reader = try? SourceFileReader(root: authorizedRoot, relativePath: workspacePath,
                                                 expectedRoot: expectedRoot),
              let before = try? reader.snapshot(), (1...Int64(limit)).contains(before.size),
              let data = try? reader.read(upToCount: Int(before.size), offset: 0),
              data.count == before.size, before == (try? reader.snapshot())
        else { return nil }
        return title(from: data)
    }

    private static func sibling(of path: String, current: String, desired: String) -> String? {
        let parts = path.utf8.split(separator: 47, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].elementsEqual("session-state".utf8),
              parts[2].elementsEqual(current.utf8), !parts[1].isEmpty, parts[1].first != 46,
              !parts[1].contains(0)
        else { return nil }
        return storagePrefix + String(decoding: parts[1], as: UTF8.self) + "/" + desired
    }

    static func title(from data: Data) -> String? {
        guard data.count <= limit, let text = String(data: data, encoding: .utf8),
              !text.utf8.contains(0) else { return nil }
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        var values: [String: String] = [:]
        var seen = Set<String>()
        for (index, line) in lines.enumerated() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            guard key == "name" || key == "summary" else { continue }
            guard seen.insert(key).inserted else { return nil }
            let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let scalar: String?
            if ["|", "|-", "|+", ">", ">-", ">+"].contains(raw) {
                let body = lines.dropFirst(index + 1).prefix {
                    $0.isEmpty || $0.first == " " || $0.first == "\t" || $0 == "\r"
                }
                scalar = body.joined(separator: "\n")
            } else if raw.hasPrefix("\"") {
                scalar = try? JSONDecoder().decode(String.self, from: Data(raw.utf8))
            } else if raw.hasPrefix("'") {
                scalar = singleQuoted(raw)
            } else {
                scalar = plain(raw)
            }
            if let scalar, let value = normalized(scalar) { values[key] = value }
        }
        return values["name"] ?? values["summary"]
    }

    private static func singleQuoted(_ raw: String) -> String? {
        guard raw.count >= 2, raw.last == "'" else { return nil }
        var result = ""
        var pendingQuote = false
        for character in raw.dropFirst().dropLast() {
            if character == "'" {
                if pendingQuote { result.append(character) }
                pendingQuote.toggle()
            } else {
                guard !pendingQuote else { return nil }
                result.append(character)
            }
        }
        return pendingQuote ? nil : result
    }

    private static func plain(_ raw: String) -> String? {
        guard let first = raw.first, !"!&*[]{}>|#".contains(first) else { return nil }
        let prefix = raw.range(of: " #") ?? raw.range(of: "\t#")
        let value = prefix.map { String(raw[..<$0.lowerBound]) } ?? raw
        return ["~", "null"].contains(value.lowercased()) ? nil : value
    }

    private static func normalized(_ value: String) -> String? {
        guard !value.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control && !CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return nil }
        let title = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return title.isEmpty ? nil : title
    }
}
