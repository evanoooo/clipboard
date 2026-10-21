// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipboardUnitTests",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClipboardUnitTests",
            path: "Sources"
        )
    ]
)
