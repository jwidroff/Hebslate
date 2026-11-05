// swift-tools-version:5.9
import PackageDescription

// HebslateCore holds the platform-independent logic (message models, OCR line
// grouping, frame-to-frame stitching, text similarity). It is used by the iOS
// app target defined in project.yml and is unit-tested with `swift test`.
let package = Package(
    name: "HebslateCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "HebslateCore", targets: ["HebslateCore"])
    ],
    targets: [
        .target(name: "HebslateCore"),
        .testTarget(name: "HebslateCoreTests", dependencies: ["HebslateCore"])
    ]
)
