// swift-tools-version: 6.2
import PackageDescription

// Vendored from film-workflow's RxRemotion and extended to iOS. See README.md.
let package = Package(
    name: "RxRemotion",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "RxRemotion", targets: ["RxRemotion"]),
        .library(name: "RxRemotionUI", targets: ["RxRemotionUI"]),
    ],
    targets: [
        .target(name: "RxRemotionPixels"),
        .target(name: "RxRemotion", dependencies: ["RxRemotionPixels"], resources: [.copy("Resources/Web"), .copy("Resources/Template")]),
        .target(name: "RxRemotionUI", dependencies: ["RxRemotion"]),
        .testTarget(name: "RxRemotionTests", dependencies: ["RxRemotion"]),
    ]
)
