// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MurmurKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        // Shared by the app and the keyboard. Foundation-only so the keyboard stays lean.
        .library(name: "MurmurCore", targets: ["MurmurCore"]),
        // The colours, the mark and the echo rings, for the app, the keyboard and the widgets.
        // SwiftUI only, no resources.
        .library(name: "MurmurBrand", targets: ["MurmurBrand"]),
        // Type, buttons and components used by the app.
        .library(name: "MurmurUI", targets: ["MurmurUI"]),
    ],
    targets: [
        .target(name: "MurmurCore"),
        .target(name: "MurmurBrand"),
        .target(name: "MurmurUI", dependencies: ["MurmurBrand"]),
        .testTarget(name: "MurmurCoreTests", dependencies: ["MurmurCore"]),
        .testTarget(name: "MurmurBrandTests", dependencies: ["MurmurBrand"]),
    ]
)
