// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SoftwareRegisseurSync",
    defaultLocalization: "de",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "SoftwareRegisseurSync", targets: ["SoftwareRegisseurSync"]),
        // In-memory CloudKit server for tests and previews; never linked into release apps.
        .library(name: "SoftwareRegisseurSyncTesting", targets: ["SoftwareRegisseurSyncTesting"]),
    ],
    dependencies: [
        .package(path: "../SoftwareRegisseurDomain"),
        .package(path: "../SoftwareRegisseurPersistence"),
    ],
    targets: [
        .target(
            name: "SoftwareRegisseurSync",
            dependencies: [
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
                .product(name: "SoftwareRegisseurPersistence", package: "SoftwareRegisseurPersistence"),
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "SoftwareRegisseurSyncTesting",
            dependencies: ["SoftwareRegisseurSync"]
        ),
        .testTarget(
            name: "SoftwareRegisseurSyncTests",
            dependencies: [
                "SoftwareRegisseurSync",
                "SoftwareRegisseurSyncTesting",
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
                .product(name: "SoftwareRegisseurPersistence", package: "SoftwareRegisseurPersistence"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
