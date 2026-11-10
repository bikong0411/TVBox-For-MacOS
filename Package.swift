// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TVBoxMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TVBoxMac", targets: ["TVBoxMac"])],
    targets: [
        .target(name: "TVBoxCore"),
        .executableTarget(name: "TVBoxMac", dependencies: ["TVBoxCore"]),
        .testTarget(name: "TVBoxCoreTests", dependencies: ["TVBoxCore"])
    ],
    swiftLanguageModes: [.v5]
)
