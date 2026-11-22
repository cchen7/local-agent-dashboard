// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDashKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AgentDashKit", targets: [
            "ADCore", "ADAdapters", "ADStore", "ADIngest", "ADSearch",
            "ADInsights", "ADPrivacy", "ADPricing", "ADZstd"
        ])
    ],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")],
    targets: [
        .target(name: "CZstd", exclude: ["Vendor"], publicHeadersPath: "include"),
        .target(name: "ADZstd", dependencies: ["CZstd"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ADCore", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ADAdapters", dependencies: ["ADCore"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ADStore", dependencies: ["ADCore", .product(name: "GRDB", package: "GRDB.swift")],
                resources: [.process("Resources")], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ADIngest", dependencies: ["ADCore", "ADAdapters", "ADStore", "ADZstd"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ADSearch", dependencies: ["ADCore", "ADStore", "ADPrivacy"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ADInsights", dependencies: ["ADCore", "ADStore", "ADPrivacy"],
                resources: [.process("Resources")], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ADPrivacy", dependencies: ["ADCore"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ADPricing", dependencies: ["ADCore"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "ADPricingTests", dependencies: ["ADPricing", "ADCore"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "ADSearchTests", dependencies: ["ADSearch", "ADStore", "ADCore", .product(name: "GRDB", package: "GRDB.swift")], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "ADPrivacyTests", dependencies: ["ADPrivacy"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "ADZstdTests", dependencies: ["ADZstd"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "ADIngestTests", dependencies: ["ADIngest", "ADAdapters", "ADCore", "ADStore",
                                                          .product(name: "GRDB", package: "GRDB.swift")],
                    swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "ADCoreTests", dependencies: ["ADCore"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "ADInsightsTests", dependencies: ["ADInsights", "ADCore", "ADStore"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "ADStoreTests", dependencies: ["ADStore", "ADCore", "ADPricing", .product(name: "GRDB", package: "GRDB.swift")], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")])
    ],
    swiftLanguageModes: [.v6]
)
