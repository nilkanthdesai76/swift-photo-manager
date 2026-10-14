// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoManagerKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PhotoManagerKit",
            targets: ["PhotoManagerKit"]
        ),
        .library(
            name: "PhotoKitManager",
            targets: ["PhotoKitManager"]
        )
    ],
    targets: [
        .target(
            name: "PhotoManagerKit",
            path: "Sources/PhotoManagerKit"
        ),
        .target(
            name: "PhotoKitManager",
            dependencies: ["PhotoManagerKit"],
            path: "Sources/PhotoKitManager"
        ),
        .testTarget(
            name: "PhotoManagerKitTests",
            dependencies: ["PhotoManagerKit", "PhotoKitManager"],
            path: "Tests/PhotoManagerKitTests"
        )
    ]
)
