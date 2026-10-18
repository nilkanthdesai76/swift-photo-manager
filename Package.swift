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
    dependencies: [
        .package(url: "https://github.com/nilkanthdesai76/AlgorithmKit.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "PhotoManagerKit",
            dependencies: [
                .product(name: "AlgorithmKit", package: "AlgorithmKit")
            ],
            path: "Sources/PhotoManagerKit"
        ),
        .target(
            name: "PhotoKitManager",
            dependencies: [
                "PhotoManagerKit",
                .product(name: "AlgorithmKit", package: "AlgorithmKit")
            ],
            path: "Sources/PhotoKitManager"
        ),
        .testTarget(
            name: "PhotoManagerKitTests",
            dependencies: ["PhotoManagerKit", "PhotoKitManager"],
            path: "Tests/PhotoManagerKitTests"
        )
    ]
)
