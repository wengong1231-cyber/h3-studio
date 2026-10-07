// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WanshenjiH3Studio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WanshenjiH3Studio", targets: ["WanshenjiH3Studio"])],
    targets: [.executableTarget(name: "WanshenjiH3Studio", path: "Sources")],
    swiftLanguageModes: [.v5]
)
