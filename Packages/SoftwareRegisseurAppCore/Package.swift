// swift-tools-version: 6.2
import PackageDescription

// iPhone app logic (spec H, J2/J2a, K1, M1, P, Q4) in testable form: job requests, task filters,
// permission flow, upload consent, draft review. No SwiftUI and no user-facing strings: the app maps the
// enums here to its String Catalog (spec P language rule).
let package = Package(
    name: "SoftwareRegisseurAppCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "SoftwareRegisseurAppCore", targets: ["SoftwareRegisseurAppCore"]),
    ],
    dependencies: [
        .package(path: "../SoftwareRegisseurDomain"),
        .package(path: "../SoftwareRegisseurPersistence"),
        .package(path: "../SoftwareRegisseurAI"),
        .package(path: "../SoftwareRegisseurSecrets"),
        // Data export and deletion (A34).
        .package(path: "../SoftwareRegisseurPortability"),
    ],
    targets: [
        .target(
            name: "SoftwareRegisseurAppCore",
            dependencies: [
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
                .product(name: "SoftwareRegisseurPersistence", package: "SoftwareRegisseurPersistence"),
                .product(name: "SoftwareRegisseurAI", package: "SoftwareRegisseurAI"),
                .product(name: "SoftwareRegisseurSecrets", package: "SoftwareRegisseurSecrets"),
                .product(name: "SoftwareRegisseurPortability", package: "SoftwareRegisseurPortability"),
            ]
        ),
        .testTarget(
            name: "SoftwareRegisseurAppCoreTests",
            dependencies: [
                "SoftwareRegisseurAppCore",
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
                .product(name: "SoftwareRegisseurPersistence", package: "SoftwareRegisseurPersistence"),
                .product(name: "SoftwareRegisseurAI", package: "SoftwareRegisseurAI"),
                .product(name: "SoftwareRegisseurSecrets", package: "SoftwareRegisseurSecrets"),
                .product(name: "SoftwareRegisseurPortability", package: "SoftwareRegisseurPortability"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
