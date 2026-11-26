// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TVBoxMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TVBoxMac", targets: ["TVBoxMac"])],
    dependencies: [.package(path: "Sources/TVBoxCore")],
    targets: [
        .binaryTarget(name: "VLCKit", path: "Vendor/VLCKit.xcframework"),
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle.xcframework"),
        .target(name: "MPVBridge", exclude: ["MPV-API-LICENSE.txt"], publicHeadersPath: "include"),
        .executableTarget(name: "TVBoxMac", dependencies: [.product(name: "TVBoxCore", package: "TVBoxCore"), "VLCKit", "Sparkle", "MPVBridge"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "TVBoxCoreTests", dependencies: [.product(name: "TVBoxCore", package: "TVBoxCore")])
    ],
    swiftLanguageModes: [.v5]
)
