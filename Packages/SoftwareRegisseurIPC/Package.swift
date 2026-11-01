// swift-tools-version: 6.2
import PackageDescription

// IPC-Verträge zwischen macOS-UI und Agent Service (ADR-0020).
// Nur macOS: iPhone und Mac kommunizieren ausschließlich über CloudKit (ADR-0003, ADR-0011).
// Die Nachrichten verwenden die Domänentypen (IDs, Status, Zeitpläne), damit UI und Dienst
// dieselben, verlustfrei kodierten Werte austauschen (ADR-0012, ADR-0006).
let package = Package(
    name: "SoftwareRegisseurIPC",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "SoftwareRegisseurIPC", targets: ["SoftwareRegisseurIPC"]),
    ],
    dependencies: [
        .package(path: "../SoftwareRegisseurDomain"),
    ],
    targets: [
        .target(
            name: "SoftwareRegisseurIPC",
            dependencies: [
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
            ]
        ),
        .testTarget(
            name: "SoftwareRegisseurIPCTests",
            dependencies: [
                "SoftwareRegisseurIPC",
                .product(name: "SoftwareRegisseurDomain", package: "SoftwareRegisseurDomain"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
