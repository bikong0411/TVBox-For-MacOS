// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TVBoxMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TVBoxMac", targets: ["TVBoxMac"])],
    targets: [
        .binaryTarget(name: "VLCKit", path: "Vendor/VLCKit.xcframework"),
        .target(name: "TVBoxCore"),
        .executableTarget(name: "TVBoxMac", dependencies: ["TVBoxCore", "VLCKit"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "TVBoxCoreTests", dependencies: ["TVBoxCore"])
    ],
    swiftLanguageModes: [.v5]
)
