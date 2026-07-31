// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lumen",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // Shared by the macOS app and any future iOS app.
        .library(name: "LumenCore", targets: ["LumenCore"]),
        .library(name: "LumenUI", targets: ["LumenUI"]),
    ],
    targets: [
        // Model + networking. Foundation/Combine only — no UI, no platform code.
        .target(name: "LumenCore"),
        // Cross-platform SwiftUI views built on LumenCore.
        .target(name: "LumenUI", dependencies: ["LumenCore"]),
        // macOS menu-bar shell (composition root).
        .executableTarget(name: "Lumen", dependencies: ["LumenCore", "LumenUI"]),
    ]
)
