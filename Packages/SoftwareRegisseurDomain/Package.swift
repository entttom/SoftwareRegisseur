// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SoftwareRegisseurDomain",
    defaultLocalization: "de",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "SoftwareRegisseurDomain", targets: ["SoftwareRegisseurDomain"]),
    ],
    targets: [
        .target(
            name: "SoftwareRegisseurDomain",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SoftwareRegisseurDomainTests",
            dependencies: ["SoftwareRegisseurDomain"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
