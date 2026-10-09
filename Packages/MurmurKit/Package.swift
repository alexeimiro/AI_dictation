// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MurmurKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        // Shared by the app, keyboard and widgets. Foundation-only so the keyboard stays lean.
        .library(name: "MurmurCore", targets: ["MurmurCore"]),
        // Design tokens and components used by the app (and widgets).
        .library(name: "MurmurUI", targets: ["MurmurUI"]),
    ],
    targets: [
        .target(name: "MurmurCore"),
        .target(name: "MurmurUI", dependencies: ["MurmurCore"]),
        .testTarget(name: "MurmurCoreTests", dependencies: ["MurmurCore"]),
    ]
)
