// swift-tools-version: 6.0
import PackageDescription

// BitMachineKit holds everything that isn't UI, so `swift test` covers it headless. The app (project.yml) links it
// as a local package; Sparkle is an Xcode-only dependency and stays out of here.
let package = Package(
    name: "BitMachine",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "BitMachineKit", targets: ["BitMachineKit"]),
    ],
    targets: [
        .target(name: "BitMachineKit"),
        .testTarget(name: "BitMachineKitTests", dependencies: ["BitMachineKit"]),
    ]
)
