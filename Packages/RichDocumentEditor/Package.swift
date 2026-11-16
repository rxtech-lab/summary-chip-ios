// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "RichDocumentEditor",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [.library(name: "RichDocumentEditor", targets: ["RichDocumentEditor"])],
    targets: [.target(name: "RichDocumentEditor")]
)
