// swift-tools-version: 6.2
import PackageDescription

// Workspace layer of the macOS Agent Service (spec E1–E3, F1–F5, G, H4, M3, N2, U4; ADR-0003, ADR-0004,
// ADR-0012, ADR-0016, ADR-0018, ADR-0019): project catalog, project setup commands, request files,
// file watching and reconciliation, agent instructions, layout migration, ADR import, GitHub issues and
// repository context for AI elaboration. Mac only; writes into repositories only from here.
let package = Package(
    name: "SoftwareRegisseurWorkspace",
    defaultLocalization: "de",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SoftwareRegisseurWorkspace", targets: ["SoftwareRegisseurWorkspace"]),
    ],
    dependencies: [
        .package(path: "../SoftwareRegisseurDomain"),
        .package(path: "../SoftwareRegisseurPersistence"),
        .package(path: "../SoftwareRegisseurMarkdown"),
        .package(path: "../SoftwareRegisseurGit"),
        .package(path: "../SoftwareRegisseurProcess"),
        .package(path: "../SoftwareRegisseurAI"),
    ],
    targets: [
        .target(
            name: "SoftwareRegisseurWorkspace",
            dependencies: [
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
                .product(name: "SoftwareRegisseurPersistence", package: "SoftwareRegisseurPersistence"),
                .product(name: "SoftwareRegisseurMarkdown", package: "SoftwareRegisseurMarkdown"),
                .product(name: "SoftwareRegisseurGit", package: "SoftwareRegisseurGit"),
                .product(name: "SoftwareRegisseurProcess", package: "SoftwareRegisseurProcess"),
                .product(name: "SoftwareRegisseurAI", package: "SoftwareRegisseurAI"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SoftwareRegisseurWorkspaceTests",
            dependencies: [
                "SoftwareRegisseurWorkspace",
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
                .product(name: "SoftwareRegisseurPersistence", package: "SoftwareRegisseurPersistence"),
                .product(name: "SoftwareRegisseurMarkdown", package: "SoftwareRegisseurMarkdown"),
                .product(name: "SoftwareRegisseurGit", package: "SoftwareRegisseurGit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
