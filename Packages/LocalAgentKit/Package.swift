// swift-tools-version: 6.2
import PackageDescription

/// Dependency-free code shared by the app and its local agent runner service.
let package = Package(
    name: "LocalAgentKit",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [.library(name: "LocalAgentKit", targets: ["LocalAgentKit"])],
    targets: [
        .target(name: "LocalAgentKit"),
        .testTarget(name: "LocalAgentKitTests", dependencies: ["LocalAgentKit"]),
    ],
    swiftLanguageModes: [.v6]
)
