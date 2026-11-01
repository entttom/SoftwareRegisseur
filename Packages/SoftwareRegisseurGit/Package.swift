// swift-tools-version: 6.2
import PackageDescription

// Git access for the Mac host (spec E1–E3, L2, M1; ADR-0003, ADR-0007, ADR-0015). Uses the real
// `git` binary through SoftwareRegisseurProcess – never a shell, never `push`, never force.
let package = Package(
    name: "SoftwareRegisseurGit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SoftwareRegisseurGit", targets: ["SoftwareRegisseurGit"]),
    ],
    dependencies: [
        .package(path: "../SoftwareRegisseurProcess"),
    ],
    targets: [
        .target(
            name: "SoftwareRegisseurGit",
            dependencies: [.product(name: "SoftwareRegisseurProcess", package: "SoftwareRegisseurProcess")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SoftwareRegisseurGitTests",
            dependencies: ["SoftwareRegisseurGit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
