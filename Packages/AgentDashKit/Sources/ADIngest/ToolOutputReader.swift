import ADAdapters
import ADCore
import ADStore
import CryptoKit
import Foundation

public enum ToolOutputReadFailure: Error, Equatable, Sendable { case changedOrUnavailable }

/// No index writes and no discovery outside the explicit registered file.
public enum ToolOutputReader {
    private static let framePrefix = 1_048_576
    private static let viewLimit = ToolOutputCapture.decodedArchiveBytes

    public static func read(_ registered: RegisteredToolOutput, authorizedRoot: URL) throws -> OriginalToolOutput {
        let rootIdentity = try SourceFileReader.directoryIdentity(root: authorizedRoot)
        let reader = try SourceFileReader(root: authorizedRoot, relativePath: registered.file.relativePath, expectedRoot: rootIdentity)
        let stamp = try reader.snapshot()
        let origin = registered.origin
        guard stamp.device == origin.device, stamp.inode == origin.inode, origin.sequence >= 0,
              origin.byteLength > 0, origin.byteLength <= ToolOutputCapture.maximumSourceLineBytes else {
            throw ToolOutputReadFailure.changedOrUnavailable
        }
        let output: OriginalToolOutput?
        if let start = origin.byteStart {
            let end = start.addingReportingOverflow(origin.byteLength)
            guard start >= 0, !end.overflow, end.partialValue < stamp.size,
                  try reader.read(upToCount: 1, offset: end.partialValue) == Data([0x0A]),
                  try JSONLFileImporter.lineDigest(reader, start: start, length: origin.byteLength) == origin.digest
            else { throw ToolOutputReadFailure.changedOrUnavailable }
            let count = Int(min(Int64(framePrefix), origin.byteLength))
            let prefix = try reader.read(upToCount: count, offset: start)
            guard prefix.count == count else { throw ToolOutputReadFailure.changedOrUnavailable }
            var frame = JSONLFrame(bytes: prefix, isTruncated: Int64(count) < origin.byteLength,
                                   endOffset: end.partialValue + 1, sequence: origin.sequence)
            if frame.isTruncated { frame = JSONLFileImporter.withOverflow(frame, start: start, reader: reader) }
            output = try ToolOutputText.read(frame, format: origin.format, maximumBytes: viewLimit)
        } else {
            guard registered.file.relativePath.hasSuffix(".jsonl.zst"), stamp.size == origin.size,
                  stamp.modificationTimeNS == origin.modificationTimeNS else { throw ToolOutputReadFailure.changedOrUnavailable }
            output = try readCompressed(reader, stamp: stamp, origin: origin)
        }
        guard let output, try reader.snapshot() == stamp,
              try SourceFileReader.directoryIdentity(root: authorizedRoot) == rootIdentity else {
            throw ToolOutputReadFailure.changedOrUnavailable
        }
        if case .claude = origin.format, let relativeSidecar = sidecarPath(for: output.text, transcript: registered.file.relativePath) {
            guard let sidecar = try readSidecar(relativeSidecar, authorizedRoot: authorizedRoot, expectedRoot: rootIdentity)
            else { throw ToolOutputReadFailure.changedOrUnavailable }
            return sidecar
        }
        return output
    }

    private enum SearchControl: Error { case found }

    private static func readCompressed(_ reader: SourceFileReader, stamp: SourceFileReader.Snapshot,
                                       origin: ToolOutputOrigin) throws -> OriginalToolOutput? {
        var framer = JSONLFramer(offset: 0, sequence: -1, prefixLimit: framePrefix)
        var output: OriginalToolOutput?
        var expanded: Int64 = 0
        do {
            try JSONLFileImporter.inflate(reader, size: stamp.size) { chunk in
                expanded += Int64(chunk.count)
                guard expanded <= 128 * 1024 * 1024 else { throw ToolOutputReadFailure.changedOrUnavailable }
                try framer.push(chunk) { line in
                    guard line.sequence == origin.sequence else { return }
                    guard !line.isTruncated, Int64(line.bytes.count) == origin.byteLength,
                          Data(SHA256.hash(data: line.bytes)) == origin.digest else {
                        throw ToolOutputReadFailure.changedOrUnavailable
                    }
                    output = try ToolOutputText.read(line, format: origin.format, maximumBytes: viewLimit)
                    throw SearchControl.found
                }
            }
        } catch SearchControl.found { }
        return output
    }

    // Derive only the filename under the same transcript's tool-results
    // directory. Never open the absolute path printed in the inline marker.
    private static func sidecarPath(for text: String, transcript: String) -> String? {
        guard text.hasPrefix("<persisted-output>") else { return nil }
        let parts = transcript.split(separator: "/")
        guard parts.count == 3, parts[0] == "projects", let file = parts.last, file.hasSuffix(".jsonl"),
              UUID(uuidString: String(file.dropLast(6))) != nil else { return nil }
        for line in text.split(whereSeparator: \.isNewline).prefix(4) {
            guard let marker = line.range(of: "Full output saved to: ") else { continue }
            let target = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            let names = target.split(separator: "/", omittingEmptySubsequences: false)
            guard target.hasPrefix("/"), names.count >= 4, names[names.count-2] == "tool-results",
                  names[names.count-3] == file.dropLast(6), let name = names.last,
                  name.utf8.count < 256, name.hasSuffix(".txt"),
                  name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) })
            else { return nil }
            return "\(parts[0])/\(parts[1])/\(file.dropLast(6))/tool-results/\(name)"
        }
        return nil
    }

    private static func readSidecar(_ path: String, authorizedRoot: URL, expectedRoot: SourceFileReader.DirectoryIdentity) throws -> OriginalToolOutput? {
        let reader = try SourceFileReader(root: authorizedRoot, relativePath: path, expectedRoot: expectedRoot)
        let snapshot = try reader.snapshot()
        let count = Int(min(Int64(viewLimit), snapshot.size))
        let bytes = try reader.read(upToCount: count, offset: 0)
        guard count == bytes.count, try reader.snapshot() == snapshot else { return nil }
        let truncated = snapshot.size > Int64(count)
        let text = (0...(truncated ? min(3, count) : 0)).lazy.compactMap {
            String(bytes: bytes.dropLast($0), encoding: .utf8)
        }.first
        return text.map { .init(text: $0, truncated: truncated) }
    }
}
