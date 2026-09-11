// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AmzSigning",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AmzSigning", targets: ["AmzSigning"]),
        .executable(name: "AmzSigningAgent", targets: ["AmzSigningAgent"])
    ],
    targets: [
        .target(name: "AmzSigningCore"),
        .executableTarget(name: "AmzSigning", dependencies: ["AmzSigningCore"]),
        .executableTarget(name: "AmzSigningAgent", dependencies: ["AmzSigningCore"]),
        .testTarget(name: "AmzSigningCoreTests", dependencies: ["AmzSigningCore"])
    ]
)
