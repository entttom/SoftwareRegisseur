// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SoftwareRegisseurSecrets",
    defaultLocalization: "de",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "SoftwareRegisseurSecrets", targets: ["SoftwareRegisseurSecrets"]),
    ],
    targets: [
        .target(name: "SoftwareRegisseurSecrets", resources: [.process("Resources")]),
        .testTarget(
            name: "SoftwareRegisseurSecretsTests",
            dependencies: ["SoftwareRegisseurSecrets"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
