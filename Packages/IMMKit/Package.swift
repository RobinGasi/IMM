// swift-tools-version: 6.2
import PackageDescription

let codec: [SwiftSetting] = [.define("SQLITE_HAS_CODEC")]

let package = Package(
    name: "IMMKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "IMMVault", targets: ["IMMVault"]),
        .library(name: "IMMLedger", targets: ["IMMLedger"]),
        .library(name: "IMMBanking", targets: ["IMMBanking"]),
        .library(name: "IMMDesign", targets: ["IMMDesign"]),
        .library(name: "IMMUI", targets: ["IMMUI"]),
        .library(name: "IMMSyncCore", targets: ["IMMSyncCore"]),
        .library(name: "IMMSync", targets: ["IMMSync"]),
        .executable(name: "imm-demo-report", targets: ["IMMDemoReport"]),
        .executable(name: "imm-sync-peer", targets: ["IMMSyncPeer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/GRDB.swift.git", from: "7.12.0"),
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", "4.20.0"..<"5.0.0"),
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "IMMVault",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "Clibsodium", package: "swift-sodium"),
            ],
            swiftSettings: codec
        ),
        .target(
            name: "IMMLedger",
            dependencies: [
                "IMMVault",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: codec
        ),
        .target(
            name: "IMMBanking",
            dependencies: [
                "IMMLedger",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.process("Resources")],
            swiftSettings: codec
        ),
        .target(
            name: "IMMDesign",
            resources: [.process("Resources")]
        ),
        .target(
            name: "IMMSyncCore",
            dependencies: [
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "Clibsodium", package: "swift-sodium"),
            ]
        ),
        .target(
            name: "IMMSync",
            dependencies: [
                "IMMSyncCore",
                "IMMLedger",
                "IMMVault",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: codec
        ),
        .target(
            name: "IMMUI",
            dependencies: [
                "IMMSync",
                "IMMVault",
                "IMMLedger",
                "IMMBanking",
                "IMMDesign",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.process("Resources")],
            swiftSettings: codec
        ),
        .executableTarget(
            name: "IMMDemoReport",
            dependencies: [
                "IMMBanking",
                "IMMLedger",
                "IMMVault",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: codec
        ),
        .executableTarget(
            name: "IMMSyncPeer",
            dependencies: ["IMMSync", "IMMSyncCore", "IMMBanking", "IMMLedger", "IMMVault", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: codec
        ),
        .testTarget(
            name: "IMMVaultTests",
            dependencies: ["IMMVault", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: codec
        ),
        .testTarget(
            name: "IMMLedgerTests",
            dependencies: ["IMMLedger", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: codec
        ),
        .testTarget(
            name: "IMMBankingTests",
            dependencies: ["IMMBanking", "IMMLedger", "IMMVault", .product(name: "GRDB", package: "GRDB.swift")],
            exclude: ["Fixtures"],
            swiftSettings: codec
        ),
        .testTarget(
            name: "IMMDesignTests",
            dependencies: ["IMMDesign"]
        ),
        .testTarget(
            name: "IMMUITests",
            dependencies: ["IMMUI", "IMMBanking", "IMMDesign", "IMMVault", "IMMLedger"],
            swiftSettings: codec
        ),
        .testTarget(
            name: "IMMSyncCoreTests",
            dependencies: ["IMMSyncCore"],
            resources: [.copy("Vectors")]
        ),
        .testTarget(
            name: "IMMSyncTests",
            dependencies: ["IMMSync", "IMMSyncCore", "IMMBanking", "IMMLedger", "IMMVault", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: codec
        ),
    ],
    swiftLanguageModes: [.v6]
)
