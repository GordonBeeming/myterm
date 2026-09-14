// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MyTerm",
    platforms: [
        .macOS(.v14),
        // MyTermCore is shared with the companion app. MyTermPlatform and MyTerm import AppKit and
        // are never built for iOS, so only MyTermCore has to hold to this deployment target.
        .iOS(.v17),
    ],
    products: [
        .library(name: "MyTermCore", targets: ["MyTermCore"]),
        .library(name: "MyTermRemoteProtocol", targets: ["MyTermRemoteProtocol"]),
        .library(name: "MyTermPlatform", targets: ["MyTermPlatform"]),
        .executable(name: "MyTerm", targets: ["MyTerm"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.15.0"
        ),
    ],
    targets: [
        .target(name: "MyTermCore"),
        .target(name: "MyTermRemoteProtocol", dependencies: ["MyTermCore"]),
        .target(name: "MyTermRemoteHost", dependencies: ["MyTermRemoteProtocol"]),
        .target(
            name: "MyTermPlatform",
            dependencies: [
                "MyTermCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .executableTarget(
            name: "MyTerm",
            dependencies: ["MyTermCore", "MyTermPlatform", "MyTermRemoteHost", "MyTermRemoteProtocol"]
        ),
        .testTarget(name: "MyTermCoreTests", dependencies: ["MyTermCore"]),
        .testTarget(
            name: "MyTermRemoteProtocolTests",
            dependencies: ["MyTermRemoteProtocol"]
        ),
        // RemoteHostDemo serves real terminals to a device, which is the one place the remote host
        // meets MyTermPlatform. The library itself never imports it.
        .testTarget(
            name: "MyTermRemoteHostTests",
            dependencies: ["MyTermRemoteHost", "MyTermRemoteProtocol", "MyTermCore", "MyTermPlatform"]
        ),
        .testTarget(
            name: "MyTermPlatformTests",
            dependencies: ["MyTermPlatform"]
        ),
        .testTarget(
            name: "MyTermTests",
            dependencies: ["MyTerm"]
        ),
    ]
)
