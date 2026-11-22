import ADCore
import ADStore
import CryptoKit
import Foundation

public enum ToolInputReadFailure: Error, Equatable, Sendable {
    case changedOrUnavailable
    case tooLarge
}

/// Explicit read of one previously indexed tool call. It does not read a path
/// mentioned in the arguments or save the recovered body.
public enum ToolInputReader {
    private static let frameLimit = 1_048_576
    private static let viewLimit = 256 * 1024

    public static func read(_ registered: RegisteredToolInput, authorizedRoot: URL) throws -> String {
        let root = try SourceFileReader.directoryIdentity(root: authorizedRoot)
        if let expected = registered.rootIdentity, try SourceFileReader.registrationIdentity(root: authorizedRoot) != expected {
            throw ToolInputReadFailure.changedOrUnavailable
        }
        let reader = try SourceFileReader(root: authorizedRoot, relativePath: registered.file.relativePath, expectedRoot: root)
        let snapshot = try reader.snapshot()
        let origin = registered.origin
        guard snapshot.device == origin.device, snapshot.inode == origin.inode,
              origin.sequence >= 0, (1...Int64(frameLimit)).contains(origin.byteLength) else {
            throw ToolInputReadFailure.changedOrUnavailable
        }
        let bytes: Data
        if let start = origin.byteStart {
            let end = start.addingReportingOverflow(origin.byteLength)
            guard start >= 0, !end.overflow, end.partialValue < snapshot.size,
                  try reader.read(upToCount: 1, offset: end.partialValue) == Data([0x0A]) else {
                throw ToolInputReadFailure.changedOrUnavailable
            }
            bytes = try reader.read(upToCount: Int(origin.byteLength), offset: start)
        } else {
            guard registered.file.relativePath.hasSuffix(".jsonl.zst"),
                  snapshot.size == origin.size, snapshot.modificationTimeNS == origin.modificationTimeNS
            else { throw ToolInputReadFailure.changedOrUnavailable }
            bytes = try compressedRecord(reader, size: snapshot.size, sequence: origin.sequence)
        }
        guard Int64(bytes.count) == origin.byteLength, Data(SHA256.hash(data: bytes)) == origin.digest,
              try reader.snapshot() == snapshot, try SourceFileReader.directoryIdentity(root: authorizedRoot) == root,
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let value = input(from: object, format: origin.format) else {
            throw ToolInputReadFailure.changedOrUnavailable
        }
        if let text = value as? String {
            guard text.utf8.count <= viewLimit else { throw ToolInputReadFailure.tooLarge }
            return text
        }
        guard let object = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { throw ToolInputReadFailure.changedOrUnavailable }
        // Never cut an object into invalid JSON before display redaction.
        guard data.count <= viewLimit else { throw ToolInputReadFailure.tooLarge }
        return String(decoding: data, as: UTF8.self)
    }

    private static func input(from record: [String: Any], format: ToolInputFormat) -> Any? {
        switch format {
        case .claude(let index):
            guard record["type"] as? String == "assistant",
                  let message = record["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]], blocks.indices.contains(index),
                  blocks[index]["type"] as? String == "tool_use" else { return nil }
            return blocks[index]["input"] as? [String: Any]
        case .codex:
            guard record["type"] as? String == "response_item",
                  let payload = record["payload"] as? [String: Any],
                  let type = payload["type"] as? String, ["function_call", "custom_tool_call"].contains(type)
            else { return nil }
            return (payload["arguments"] ?? payload["input"]) as? String
        case .copilot:
            guard record["type"] as? String == "tool.execution_start",
                  let data = record["data"] as? [String: Any] else { return nil }
            return data["arguments"]
        }
    }

    private enum StopReading: Error { case found }

    private static func compressedRecord(_ reader: SourceFileReader, size: Int64, sequence: Int64) throws -> Data {
        var framer = JSONLFramer(offset: 0, sequence: -1, prefixLimit: frameLimit)
        var result: Data?
        var expanded = 0
        do {
            try JSONLFileImporter.inflate(reader, size: size) { chunk in
                try Task.checkCancellation()
                expanded += chunk.count
                guard expanded <= 128 * 1024 * 1024 else { throw ToolInputReadFailure.changedOrUnavailable }
                try framer.push(chunk) { line in
                    guard line.sequence == sequence else { return }
                    guard !line.isTruncated else { throw ToolInputReadFailure.changedOrUnavailable }
                    result = line.bytes
                    throw StopReading.found
                }
            }
        } catch StopReading.found { }
        guard let result else { throw ToolInputReadFailure.changedOrUnavailable }
        return result
    }
}
