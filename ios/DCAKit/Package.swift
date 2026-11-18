// swift-tools-version:5.9
import PackageDescription

// 可在 Linux 上編譯與測試的 App 邏輯（SwiftUI 畫面在 ios/App，只能用 Xcode 建置）。
let package = Package(
    name: "DCAKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DCASecurity", targets: ["DCASecurity"]),
        .library(name: "DCAKit", targets: ["DCAKit"]),
    ],
    dependencies: [
        .package(path: "../DCACore"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        .target(name: "DCASecurity", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "DCAKit", dependencies: [.product(name: "DCACore", package: "DCACore")]),
        .testTarget(name: "DCASecurityTests", dependencies: ["DCASecurity"]),
        .testTarget(name: "DCAKitTests", dependencies: ["DCAKit"], resources: [.copy("Fixtures")]),
    ]
)
