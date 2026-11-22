import ADCore
import Foundation

/// Read only a known tool result at a verified frame, without constructing
/// transcript rows or accepting unrelated free-form record fields.
public enum ToolOutputText {
    public static func read(_ frame: JSONLFrame, format: ToolOutputFormat, maximumBytes: Int) throws -> OriginalToolOutput? {
        guard (1...ToolOutputCapture.decodedArchiveBytes).contains(maximumBytes) else { return nil }
        let row: [String: Any]?
        if frame.isTruncated {
            guard case .claude(let block) = format else { return nil }
            // Spare UTF-8 bytes distinguish a clipped scalar from text
            // whose complete body fits, even if the original line was huge.
            row = try ClaudeOversizedJSON.row(from: frame, textLimit: maximumBytes + 4, onlyBlock: block)
        } else { row = (try? JSONSerialization.jsonObject(with: frame.bytes)) as? [String: Any] }
        guard let row else { return nil }
        let body: String?
        switch format {
        case .claude(let index):
            guard let type = row["type"] as? String, type == "user" || type == "assistant",
                  let message = row["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]],
                  blocks.indices.contains(index), blocks[index]["type"] as? String == "tool_result" else { return nil }
            body = text(blocks[index]["content"])
        case .codex:
            guard row["type"] as? String == "response_item", let payload = row["payload"] as? [String: Any],
                  let kind = payload["type"] as? String, kind == "function_call_output" || kind == "custom_tool_call_output"
            else { return nil }
            body = codex(payload["output"])
        case .copilot:
            guard row["type"] as? String == "tool.execution_complete", let data = row["data"] as? [String: Any] else { return nil }
            body = copilot(data["result"])
        }
        guard let body else { return nil }
        let clipped = body.utf8.count > maximumBytes
        return .init(text: AdapterJSON.prefix(body, bytes: maximumBytes), truncated: clipped)
    }

    static func text(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return nil }
        return blocks.compactMap { block in
            guard let type = block["type"] as? String, ["text", "input_text", "output_text"].contains(type) else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
    }

    static func codex(_ value: Any?) -> String? {
        text(value) ?? (value as? AdapterJSON.Object).flatMap(AdapterJSON.json)
    }

    static func copilot(_ value: Any?) -> String? {
        text((value as? AdapterJSON.Object)?["content"] ?? value)
    }
}
