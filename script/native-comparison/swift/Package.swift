// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "NativeTerminalBaselinePrototype",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../Vendor/SwiftTerm")],
    targets: [.executableTarget(name: "Baseline", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")])]
)
