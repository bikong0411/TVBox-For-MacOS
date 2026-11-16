// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TVBoxMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TVBoxMac", targets: ["TVBoxMac"])],
    targets: [
        .binaryTarget(name: "VLCKit", path: "Vendor/VLCKit.xcframework"),
        .target(name: "TVBoxCore"),
        .target(name: "MPVBridge", exclude: ["MPV-API-LICENSE.txt"], publicHeadersPath: "include"),
        .executableTarget(name: "TVBoxMac", dependencies: ["TVBoxCore", "VLCKit", "MPVBridge"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "TVBoxCoreTests", dependencies: ["TVBoxCore"])
    ],
    swiftLanguageModes: [.v5]
)
