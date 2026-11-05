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
        .executable(name: "MyTermSessionHost", targets: ["MyTermSessionHost"]),
        .executable(name: "MyTermUpdateAgent", targets: ["MyTermUpdateAgent"]),
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
        .package(path: "Packages/MyTermRemote"),
    ],
    targets: [
        .target(name: "MyTermCore"),
        .target(name: "MyTermUpdating", dependencies: ["MyTermCore"]),
        .executableTarget(name: "MyTermUpdateAgent", dependencies: ["MyTermCore", "MyTermUpdating"]),
        .target(name: "MyTermContinuity", dependencies: ["MyTermCore"]),
        .executableTarget(name: "MyTermSessionHost", dependencies: [
            "MyTermContinuity", .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .target(name: "MyTermUI", dependencies: ["MyTermCore"]),
        .target(
            name: "MyTermPlatform",
            dependencies: [
                "MyTermCore",
                "MyTermContinuity",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "MyTermRemote", package: "MyTermRemote"),
            ]
        ),
        .executableTarget(
            name: "MyTerm",
            dependencies: [
                "MyTermCore", "MyTermPlatform", "MyTermUI", "MyTermUpdating",
                .product(name: "MyTermRemote", package: "MyTermRemote"),
            ]
        ),
        .testTarget(name: "MyTermCoreTests", dependencies: ["MyTermCore"]),
        .testTarget(name: "MyTermContinuityTests", dependencies: [
            "MyTermContinuity", "MyTermSessionHost",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .testTarget(
            name: "MyTermPlatformTests",
            dependencies: [
                "MyTermPlatform",
                "MyTermContinuity",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "MyTermTests",
            dependencies: ["MyTerm", "MyTermUpdating", "MyTermUpdateAgent"]
        ),
    ]
)
