// swift-tools-version: 6.2
import PackageDescription

// Data export and controlled local deletion (spec Q1 "transparente Löschung und Export", A34).
let package = Package(
    name: "SoftwareRegisseurPortability",
    defaultLocalization: "de",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "SoftwareRegisseurPortability", targets: ["SoftwareRegisseurPortability"]),
    ],
    dependencies: [
        .package(path: "../SoftwareRegisseurDomain"),
        .package(path: "../SoftwareRegisseurPersistence"),
        .package(path: "../SoftwareRegisseurSecrets"),
    ],
    targets: [
        .target(
            name: "SoftwareRegisseurPortability",
            dependencies: [
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
                .product(name: "SoftwareRegisseurPersistence", package: "SoftwareRegisseurPersistence"),
                .product(name: "SoftwareRegisseurSecrets", package: "SoftwareRegisseurSecrets"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SoftwareRegisseurPortabilityTests",
            dependencies: [
                "SoftwareRegisseurPortability",
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
                .product(name: "SoftwareRegisseurPersistence", package: "SoftwareRegisseurPersistence"),
                .product(name: "SoftwareRegisseurSecrets", package: "SoftwareRegisseurSecrets"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
