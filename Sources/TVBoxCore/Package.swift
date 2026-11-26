// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TVBoxCore",
    platforms: [.macOS(.v13), .tvOS(.v17)],
    products: [.library(name: "TVBoxCore", targets: ["TVBoxCore"])],
    targets: [.target(name: "TVBoxCore", path: ".", exclude: ["Package.swift"])],
    swiftLanguageModes: [.v5]
)
