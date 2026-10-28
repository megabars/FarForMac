// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FarForMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FarCore", targets: ["FarCore"]),
        .executable(name: "FarForMac", targets: ["FarForMac"])
    ],
    targets: [
        .target(name: "FarCore"),
        .executableTarget(name: "FarForMac", dependencies: ["FarCore"]),
        .testTarget(name: "FarCoreTests", dependencies: ["FarCore"])
    ],
    swiftLanguageModes: [.v5]
)
