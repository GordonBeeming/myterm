// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyTermRemote",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [.library(name: "MyTermRemote", targets: ["MyTermRemote"])],
    targets: [
        .target(name: "MyTermRemote"),
        .testTarget(name: "MyTermRemoteTests", dependencies: ["MyTermRemote"]),
    ]
)
