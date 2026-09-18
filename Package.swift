// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MyTerm",
    platforms: [
        .macOS(.v14),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "MyTermCore", targets: ["MyTermCore"]),
        .library(name: "MyTermPlatform", targets: ["MyTermPlatform"]),
        .library(name: "MyTermUI", targets: ["MyTermUI"]),
        .executable(name: "MyTerm", targets: ["MyTerm"]),
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
        .package(path: "Packages/MyTermRemote"),
    ],
    targets: [
        .target(name: "MyTermCore"),
        .target(name: "MyTermUI", dependencies: ["MyTermCore"]),
        .target(
            name: "MyTermPlatform",
            dependencies: [
                "MyTermCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "MyTermRemote", package: "MyTermRemote"),
            ]
        ),
        .executableTarget(
            name: "MyTerm",
            dependencies: [
                "MyTermCore", "MyTermPlatform", "MyTermUI",
                .product(name: "MyTermRemote", package: "MyTermRemote"),
            ]
        ),
        .testTarget(name: "MyTermCoreTests", dependencies: ["MyTermCore"]),
        .testTarget(
            name: "MyTermPlatformTests",
            dependencies: [
                "MyTermPlatform",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "MyTermTests",
            dependencies: ["MyTerm"]
        ),
    ]
)
