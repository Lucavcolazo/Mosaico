// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mosaico",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Mosaico",
            path: "Sources/Mosaico"
        )
    ],
    swiftLanguageModes: [.v5]
)
