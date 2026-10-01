// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SummaryKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "SummaryKit", targets: ["SummaryKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/onevcat/Kingfisher", from: "8.0.0"),
    ],
    targets: [
        .target(
            name: "SummaryKit",
            dependencies: [
                .product(name: "Kingfisher", package: "Kingfisher"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "SummaryKitTests",
            dependencies: ["SummaryKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
