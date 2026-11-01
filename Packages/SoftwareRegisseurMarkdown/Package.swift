// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SoftwareRegisseurMarkdown",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "SoftwareRegisseurMarkdown", targets: ["SoftwareRegisseurMarkdown"]),
    ],
    dependencies: [
        // Used only to decode YAML values; all writes are surgical line edits (spec F3).
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        .target(
            name: "SoftwareRegisseurMarkdown",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .testTarget(
            name: "SoftwareRegisseurMarkdownTests",
            dependencies: ["SoftwareRegisseurMarkdown"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
