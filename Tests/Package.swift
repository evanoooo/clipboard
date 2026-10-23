// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipboardUnitTests",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift", exact: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "ClipboardUnitTests",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift")
            ],
            path: "Sources"
        )
    ]
)
