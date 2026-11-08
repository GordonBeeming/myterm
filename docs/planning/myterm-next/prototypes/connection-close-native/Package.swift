// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConnectionClosePrototype",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ConnectionClosePrototype", targets: ["ConnectionClosePrototype"])],
    targets: [.executableTarget(name: "ConnectionClosePrototype", path: "Sources")]
)
