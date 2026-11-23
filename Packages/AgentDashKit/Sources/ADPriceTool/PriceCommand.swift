import ADPricing
import Darwin
import Foundation

@main
enum PriceCommand {
    private enum Failure: Error { case usage, unreadableTable }
    private struct Validation: Encodable {
        let updatedAt: String
        let models: Int
        let comparedPreviousTable: Bool
        let impact: HistoricalPriceImpact?
        let quoteDeltaMicroUSD: Int64?
        let backfillDeltaMicroUSD: Int64?
    }
    private struct Inventory: Encodable {
        let scope = "indexed accounting snapshot only"
        let models: [PriceInventory.Entry]
    }
    private struct Installation: Encodable { let installed: Bool }

    private static let usage = """
        Usage:
          validate PRICE_FILE [--previous PRICE_FILE [--index-snapshot COPY]]
          models-seen PRICE_FILE --index-snapshot COPY
          install PRICE_FILE BUNDLED_PRICE_FILE --apply
        COPY must be a standalone Agent Dashboard index snapshot without SQLite sidecars.
        """

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] || args.count == 2 && args[1] == "--help" {
            print(usage)
            return
        }
        do {
            let destination = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/agent-dashboard/pricing.json")
            FileHandle.standardOutput.write(try render(args, installAt: destination))
        } catch Failure.usage {
            writeError(usage)
            exit(2)
        } catch {
            let reason: String
            switch error {
            case let value as PricingError: reason = String(describing: value)
            case let value as PriceHistoryFailure: reason = String(describing: value)
            case let value as PriceUsageSnapshot.Failure: reason = String(describing: value)
            case let value as PricingInstaller.Failure: reason = String(describing: value)
            case Failure.unreadableTable: reason = "unreadableTable"
            default: reason = "operationCouldNotComplete"
            }
            writeError("Pricing: " + reason)
            exit(1)
        }
    }

    static func render(_ args: [String], installAt destination: URL) throws -> Data {
        guard args.count >= 2, !args[1].hasPrefix("--") else { throw Failure.usage }
        switch args[0] {
        case "validate":
            guard args.count == 2 ||
                ((args.count == 4 || args.count == 6) && args[2] == "--previous" && !args[3].hasPrefix("--") &&
                 (args.count == 4 || args[4] == "--index-snapshot" && !args[5].hasPrefix("--")))
            else { throw Failure.usage }
            let candidate = try PriceTable.decode(readTable(args[1]))
            let previous = try args.count >= 4 ? PriceTable.decode(readTable(args[3])) : nil
            if let previous { try preservePrices(in: previous, with: candidate) }
            var impact: HistoricalPriceImpact?
            if args.count == 6, let previous {
                var report = HistoricalPriceImpact()
                try PriceUsageSnapshot.visit(URL(fileURLWithPath: args[5])) { row in
                    try report.include(row, before: previous, candidate: candidate)
                }
                impact = report
            }
            return try encode(Validation(updatedAt: candidate.updatedAt.rawValue, models: candidate.models.count,
                                         comparedPreviousTable: previous != nil, impact: impact,
                                         quoteDeltaMicroUSD: impact.map { $0.candidateMicroUSD - $0.beforeMicroUSD },
                                         backfillDeltaMicroUSD: impact.map { $0.projectedStoredMicroUSD - $0.storedMicroUSD }))
        case "models-seen":
            guard args.count == 4, args[2] == "--index-snapshot", !args[3].hasPrefix("--") else { throw Failure.usage }
            let table = try PriceTable.decode(readTable(args[1]))
            var inventory = PriceInventory()
            try PriceUsageSnapshot.visit(URL(fileURLWithPath: args[3])) { row in
                try inventory.include(row, table: table)
            }
            return try encode(Inventory(models: inventory.sorted))
        case "install":
            guard args.count == 4, !args[2].hasPrefix("--"), args[3] == "--apply" else { throw Failure.usage }
            try PricingInstaller.install(readTable(args[1]), preserving: PriceTable.decode(readTable(args[2])), at: destination)
            return try encode(Installation(installed: true))
        default:
            throw Failure.usage
        }
    }

    private static func readTable(_ path: String) throws -> Data {
        guard case .bytes(let data) = PriceFileReader.read(URL(fileURLWithPath: path)) else { throw Failure.unreadableTable }
        return data
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(value) + Data([10])
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
