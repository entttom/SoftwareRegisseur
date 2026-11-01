// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SoftwareRegisseurPersistence",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "SoftwareRegisseurPersistence", targets: ["SoftwareRegisseurPersistence"]),
    ],
    dependencies: [
        .package(path: "../SoftwareRegisseurDomain"),
        // ADR-0019: GRDB 7, exact pin. v7.11.1 verified as latest tag on github.com/groue/GRDB.swift (2026-10-30).
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "SoftwareRegisseurPersistence",
            dependencies: [
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
                .product(name: "GRDB", package: "GRDB.swift"),
                // C API for SQLITE_FCNTL_PERSIST_WAL (GRDB DatabaseSharing guide).
                .product(name: "GRDBSQLite", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "SoftwareRegisseurPersistenceTests",
            dependencies: [
                "SoftwareRegisseurPersistence",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
