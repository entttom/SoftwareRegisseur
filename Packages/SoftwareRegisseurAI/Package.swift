// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SoftwareRegisseurAI",
    defaultLocalization: "de",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "SoftwareRegisseurAI", targets: ["SoftwareRegisseurAI"]),
    ],
    dependencies: [
        .package(path: "../SoftwareRegisseurSecrets"),
    ],
    targets: [
        .target(
            name: "SoftwareRegisseurAI",
            dependencies: [
                .product(name: "SoftwareRegisseurSecrets", package: "SoftwareRegisseurSecrets"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SoftwareRegisseurAITests",
            dependencies: [
                "SoftwareRegisseurAI",
                .product(name: "SoftwareRegisseurSecrets", package: "SoftwareRegisseurSecrets"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
