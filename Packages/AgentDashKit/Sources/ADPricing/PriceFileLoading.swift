import ADCore
import CryptoKit
import Darwin
import Foundation

public enum PriceFileCandidate: Sendable { case missing, unreadable, bytes(Data) }
public enum PriceFileOrigin: Equatable, Sendable { case external, bundled, lastVerified, none }

public struct PriceFileIssue: Equatable, Sendable {
    public enum Failure: Equatable, Sendable {
        case unreadable, invalid(PricingError), cacheWriteFailed, watchingUnavailable, pricingApplyFailed
    }
    public let origin: PriceFileOrigin
    public let failure: Failure

    public init(origin: PriceFileOrigin, failure: Failure) { self.origin = origin; self.failure = failure }
}

public struct PriceFileStatus: Equatable, Sendable {
    public let origin: PriceFileOrigin
    public let fingerprint: String?
    public let updatedAt: UTCDate?
    public let modelCount: Int
    public let displayCurrencies: [DisplayCurrency]
    public let issues: [PriceFileIssue]

    public static let empty = Self(origin: .none, fingerprint: nil, updatedAt: nil, modelCount: 0,
                                   displayCurrencies: [], issues: [])

    public func reporting(_ issue: PriceFileIssue) -> Self {
        Self(origin: origin, fingerprint: fingerprint, updatedAt: updatedAt, modelCount: modelCount,
             displayCurrencies: displayCurrencies, issues: issues + [issue])
    }
}

/// No file or historical-row mutations. Validated bytes can be retained by an app-owned cache.
public struct PriceFileResolver: Sendable {
    private struct Verified: Sendable {
        let table: PriceTable
        let data: Data
        let fingerprint: String

        init(_ data: Data) throws(PricingError) {
            table = try PriceTable.decode(data)
            self.data = data
            fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    private var last: Verified?
    private var invalidCache = false
    public var verifiedBytes: Data? { last?.data }
    public var verifiedTable: PriceTable? { last?.table }

    public init(lastVerified: PriceFileCandidate = .missing) {
        switch lastVerified {
        case .missing: break
        case .unreadable: invalidCache = true
        case .bytes(let data):
            last = try? Verified(data)
            invalidCache = last == nil
        }
    }

    public mutating func refresh(external: PriceFileCandidate, bundled: PriceFileCandidate) -> PriceFileStatus {
        var issues: [PriceFileIssue] = []
        for (origin, candidate) in [(PriceFileOrigin.external, external), (.bundled, bundled)] {
            // A broken external edit should not replace a working table with the
            // bundle (which may have fewer rates or no rates yet).
            if origin == .bundled, !issues.isEmpty, let last {
                return status(last, origin: .lastVerified, issues: issues)
            }
            switch candidate {
            case .missing: continue
            case .unreadable: issues.append(.init(origin: origin, failure: .unreadable))
            case .bytes(let data):
                if let last, last.data == data { return status(last, origin: origin, issues: issues) }
                do {
                    let value = try Verified(data)
                    last = value; invalidCache = false
                    return status(value, origin: origin, issues: issues)
                } catch { issues.append(.init(origin: origin, failure: .invalid(error))) }
            }
        }
        if invalidCache { issues.append(.init(origin: .lastVerified, failure: .unreadable)) }
        return status(last, origin: last == nil ? .none : .lastVerified, issues: issues)
    }

    private func status(_ value: Verified?, origin: PriceFileOrigin, issues: [PriceFileIssue]) -> PriceFileStatus {
        .init(origin: origin, fingerprint: value?.fingerprint, updatedAt: value?.table.updatedAt,
              modelCount: value?.table.models.count ?? 0, displayCurrencies: value?.table.displayCurrencies ?? [], issues: issues)
    }
}

/// Reads only the explicit file, without following symlinks, and checks that
/// the open file's metadata stayed stable across the bounded read.
public enum PriceFileReader {
    public static func read(_ url: URL, maxBytes: Int = 4 * 1024 * 1024) -> PriceFileCandidate {
        guard Source.isLocalRoot(url), maxBytes > 0 else { return .unreadable }
        // Use fresh metadata: resourceValues can retain an earlier successful
        // lookup on a URL even after an editor removes or replaces the file.
        for _ in 0..<2 {
            switch presence(at: url) {
            case .missing: return .missing
            case .unreadable: return .unreadable
            case .regular: break
            }
            do {
                let reader = try SourceFileReader(root: url.deletingLastPathComponent(), relativePath: url.lastPathComponent)
                let start = try reader.snapshot()
                guard (0...Int64(maxBytes)).contains(start.size) else { return .unreadable }
                var data = Data(capacity: Int(start.size))
                while Int64(data.count) < start.size {
                    let offset = Int64(data.count)
                    let chunk = try reader.read(upToCount: Int(min(start.size - offset, 64 * 1024)), offset: offset)
                    guard !chunk.isEmpty else { break }
                    data.append(chunk)
                }
                switch presence(at: url) {
                case .missing: return .missing
                case .unreadable: return .unreadable
                case let .regular(device, inode):
                    if start.device == device, start.inode == inode, data.count == start.size,
                       try reader.snapshot() == start { return .bytes(data) }
                }
            } catch {
                if case .missing = presence(at: url) { return .missing }
            }
        }
        return .unreadable
    }

    private enum Presence {
        case missing, unreadable, regular(device: Int64, inode: Int64)
    }

    private static func presence(at url: URL) -> Presence {
        var value = stat()
        guard lstat(url.path(percentEncoded: false), &value) == 0 else {
            return errno == ENOENT ? .missing : .unreadable
        }
        guard value.st_mode & S_IFMT == S_IFREG else { return .unreadable }
        return .regular(device: Int64(value.st_dev), inode: Int64(bitPattern: value.st_ino))
    }
}
