// swift-tools-version: 6.2
import PackageDescription

// Job orchestration of the macOS agent service (spec J3, K1–K3, L1–L3, M1, M2, N2–N4;
// ADR-0006, ADR-0007, ADR-0012, ADR-0015, ADR-0021). Pure orchestration logic with injected
// clock, repositories, providers and process inspection. macOS host only.
let package = Package(
    name: "SoftwareRegisseurJobs",
    defaultLocalization: "de",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SoftwareRegisseurJobs", targets: ["SoftwareRegisseurJobs"]),
    ],
    dependencies: [
        .package(path: "../SoftwareRegisseurDomain"),
        .package(path: "../SoftwareRegisseurPersistence"),
        .package(path: "../SoftwareRegisseurAgents"),
        .package(path: "../SoftwareRegisseurGit"),
        .package(path: "../SoftwareRegisseurProcess"),
    ],
    targets: [
        .target(
            name: "SoftwareRegisseurJobs",
            dependencies: [
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
                .product(name: "SoftwareRegisseurPersistence", package: "SoftwareRegisseurPersistence"),
                .product(name: "SoftwareRegisseurAgents", package: "SoftwareRegisseurAgents"),
                .product(name: "SoftwareRegisseurGit", package: "SoftwareRegisseurGit"),
                .product(name: "SoftwareRegisseurProcess", package: "SoftwareRegisseurProcess"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SoftwareRegisseurJobsTests",
            dependencies: [
                "SoftwareRegisseurJobs",
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
                .product(name: "SoftwareRegisseurPersistence", package: "SoftwareRegisseurPersistence"),
                .product(name: "SoftwareRegisseurAgents", package: "SoftwareRegisseurAgents"),
                .product(name: "SoftwareRegisseurGit", package: "SoftwareRegisseurGit"),
                .product(name: "SoftwareRegisseurProcess", package: "SoftwareRegisseurProcess"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
