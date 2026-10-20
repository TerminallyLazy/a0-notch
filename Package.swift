// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "a0_notch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "A0Notch", targets: ["A0Notch"]),
        .library(name: "NotchCore", targets: ["NotchCore"])
    ],
    targets: [
        .target(name: "NotchCore", path: "app/Sources/NotchCore"),
        .executableTarget(name: "A0Notch", dependencies: ["NotchCore"], path: "app/Sources/A0Notch", resources: [.copy("Resources/Branding")]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"], path: "app/Tests/NotchCoreTests")
    ]
)
