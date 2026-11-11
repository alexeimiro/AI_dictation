// swift-tools-version: 6.2
import PackageDescription

// Draws Murmur's brand files (app icon, launch logo, asset colours) from MurmurBrand.
// Run it with scripts/build_brand.sh.
let package = Package(
    name: "BrandKit",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/MurmurKit"),
    ],
    targets: [
        .executableTarget(
            name: "brandkit",
            dependencies: [.product(name: "MurmurBrand", package: "MurmurKit")],
            path: "Sources/BrandKit"),
    ]
)
