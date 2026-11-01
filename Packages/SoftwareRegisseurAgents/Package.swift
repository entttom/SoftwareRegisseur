// swift-tools-version: 6.2
import PackageDescription

// Coding-agent adapters (spec J1–J6, K2, L3; ADR-0005, ADR-0006, ADR-0021): Codex via
// `codex app-server` JSON-RPC, Claude Code headless via stream-json. macOS host only.
let package = Package(
    name: "SoftwareRegisseurAgents",
    defaultLocalization: "de",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SoftwareRegisseurAgents", targets: ["SoftwareRegisseurAgents"]),
    ],
    dependencies: [
        .package(path: "../SoftwareRegisseurDomain"),
        .package(path: "../SoftwareRegisseurProcess"),
    ],
    targets: [
        .target(
            name: "SoftwareRegisseurAgents",
            dependencies: [
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
                .product(name: "SoftwareRegisseurProcess", package: "SoftwareRegisseurProcess"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SoftwareRegisseurAgentsTests",
            dependencies: [
                "SoftwareRegisseurAgents",
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
                .product(name: "SoftwareRegisseurProcess", package: "SoftwareRegisseurProcess"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
