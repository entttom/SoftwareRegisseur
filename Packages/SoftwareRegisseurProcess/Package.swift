// swift-tools-version: 6.2
import PackageDescription

// Process execution without a shell (spec L3), executable discovery for LaunchAgents (spec J1)
// and secret redaction for logs (spec Q1). macOS host only.
let package = Package(
    name: "SoftwareRegisseurProcess",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SoftwareRegisseurProcess", targets: ["SoftwareRegisseurProcess"]),
    ],
    targets: [
        .target(
            name: "SoftwareRegisseurProcess",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SoftwareRegisseurProcessTests",
            dependencies: ["SoftwareRegisseurProcess"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
