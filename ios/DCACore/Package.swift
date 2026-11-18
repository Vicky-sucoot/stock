// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DCACore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DCACore", targets: ["DCACore"]),
    ],
    targets: [
        .target(name: "DCACore"),
        .testTarget(name: "DCACoreTests", dependencies: ["DCACore"]),
    ]
)
