// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Timecard",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TimecardCore"),
        .executableTarget(name: "Timecard", dependencies: ["TimecardCore"]),
        .testTarget(name: "TimecardCoreTests", dependencies: ["TimecardCore"]),
    ]
)
