// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoManagerKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PhotoManagerKit",
            targets: ["PhotoManagerKit"]
        )
    ],
    targets: [
        .target(
            name: "PhotoManagerKit",
            path: "Sources/PhotoManagerKit"
        ),
        .testTarget(
            name: "PhotoManagerKitTests",
            dependencies: ["PhotoManagerKit"],
            path: "Tests/PhotoManagerKitTests"
        )
    ]
)
