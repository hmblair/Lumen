// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HueKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // Shared by the macOS app and any future iOS app.
        .library(name: "HueCore", targets: ["HueCore"]),
        .library(name: "HueUI", targets: ["HueUI"]),
    ],
    targets: [
        // Model + networking. Foundation/Combine only — no UI, no platform code.
        .target(name: "HueCore"),
        // Cross-platform SwiftUI views built on HueCore.
        .target(name: "HueUI", dependencies: ["HueCore"]),
        // macOS menu-bar shell (composition root).
        .executableTarget(name: "HueBar", dependencies: ["HueCore", "HueUI"]),
    ]
)
