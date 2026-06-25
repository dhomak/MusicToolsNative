// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MusicTools",
    platforms: [ .macOS(.v13) ],   // NavigationSplitView requires macOS 13
    targets: [
        .executableTarget(
            name: "MusicTools",
            path: "Sources/MusicToolsNative"
        )
    ]
)
