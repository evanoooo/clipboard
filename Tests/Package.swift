// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipboardUnitTests",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift", exact: "0.15.4")
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
