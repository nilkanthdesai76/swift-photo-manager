// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoManagerKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
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
