// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThreadsVideoDownloader",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ThreadsVideoDownloader", targets: ["ThreadsVideoDownloader"]),
        .library(name: "ThreadsVideoDownloaderCore", targets: ["ThreadsVideoDownloaderCore"])
    ],
    targets: [
        .target(name: "ThreadsVideoDownloaderCore"),
        .executableTarget(
            name: "ThreadsVideoDownloader",
            dependencies: ["ThreadsVideoDownloaderCore"]
        ),
        .testTarget(
            name: "ThreadsVideoDownloaderCoreTests",
            dependencies: ["ThreadsVideoDownloaderCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
