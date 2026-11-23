import ADPricing
import Darwin
import Foundation

@main
enum PricingInstallHarness {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 4 else { exit(2) }
        do {
            let table = try PriceTable.decode(Data(contentsOf: URL(fileURLWithPath: args[2])))
            let bytes = try Data(contentsOf: URL(fileURLWithPath: args[1]))
            try PricingInstaller.install(bytes, preserving: table, at: URL(fileURLWithPath: args[3]))
        } catch {
            exit(1)
        }
    }
}
