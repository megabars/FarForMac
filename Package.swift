// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FarForMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FarCore", targets: ["FarCore"]),
        .executable(name: "FarForMac", targets: ["FarForMac"]),
        .executable(name: "FarPerformance", targets: ["FarPerformance"])
    ],
    targets: [
        .systemLibrary(name: "CArchive"),
        .target(name: "CFarPTY"),
        .target(name: "CNetwork", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "FarCore", dependencies: ["CFarPTY", "CArchive", "CNetwork"]),
        .executableTarget(name: "FarForMac", dependencies: ["FarCore"]),
        .executableTarget(name: "FarPerformance", dependencies: ["FarCore"]),
        .testTarget(name: "FarCoreTests", dependencies: ["FarCore"])
    ],
    swiftLanguageModes: [.v5]
)
