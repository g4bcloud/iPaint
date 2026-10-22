// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "iPaint",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "iPaint",
            path: "Sources/iPaint"
        )
    ]
)
