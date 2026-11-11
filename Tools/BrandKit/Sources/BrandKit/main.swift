import AppKit
import Foundation
import ImageIO
import MurmurBrand
import UniformTypeIdentifiers

// Murmur's brand files, drawn from MurmurBrand so the app icon, the launch screen and the asset
// catalog's colours never drift from the app.
//
//   brandkit <repo root>          writes every file that changed
//   brandkit <repo root> --check  writes nothing; fails if a file is missing or out of date

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: brandkit <repo root> [--check]")
    exit(2)
}
let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
let checking = arguments.contains("--check")

var outputs: [(path: String, data: Data)] = []
@MainActor func add(_ path: String, _ data: Data) { outputs.append((path, data)) }
@MainActor func add(_ path: String, text: String) { add(path, Data(text.utf8)) }

// MARK: - Drawing

extension BrandRGB {
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: opacity) }
}

/// Draws the mark, a dot inside a ring, centred in `rect`.
func drawMark(_ context: CGContext, in rect: CGRect, color: BrandRGB) {
    let ring = MarkGeometry.ring(in: rect)
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(ring.lineWidth)
    context.strokeEllipse(in: ring.rect)
    context.setFillColor(color.cgColor)
    context.fillEllipse(in: MarkGeometry.dot(in: rect))
}

/// A PNG. Opaque images carry no alpha channel (the App Store rejects an icon that has one).
func png(width: Int, height: Int, opaque: Bool, _ draw: (CGContext) -> Void) -> Data {
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    draw(context)
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// The app icon: the mark on a full-bleed background (iOS rounds the corners).
func icon(size: Int, background: BrandRGB, mark: BrandRGB) -> Data {
    png(width: size, height: size, opaque: true) { context in
        let side = CGFloat(size)
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        drawMark(context, in: CGRect(x: side * 0.2, y: side * 0.2, width: side * 0.6, height: side * 0.6), color: mark)
    }
}

// MARK: - Text formats

func colorset(_ light: BrandRGB, dark: BrandRGB? = nil) -> String {
    func color(_ rgb: BrandRGB) -> String {
        let r = (rgb.hex >> 16) & 0xFF, g = (rgb.hex >> 8) & 0xFF, b = rgb.hex & 0xFF
        return String(format: "\"color\" : { \"color-space\" : \"srgb\", \"components\" : { \"alpha\" : \"1.000\", "
                      + "\"blue\" : \"0x%02X\", \"green\" : \"0x%02X\", \"red\" : \"0x%02X\" } }", b, g, r)
    }
    var entries = ["    { \(color(light)), \"idiom\" : \"universal\" }"]
    if let dark {
        entries.append("    { \"appearances\" : [ { \"appearance\" : \"luminosity\", \"value\" : \"dark\" } ], "
                       + "\(color(dark)), \"idiom\" : \"universal\" }")
    }
    return "{\n  \"colors\" : [\n" + entries.joined(separator: ",\n")
        + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
}

// MARK: - The files

let catalog = "App/Resources/Assets.xcassets"
let white = BrandRGB(0xFFFFFF)
let black = BrandRGB(0x000000)

add("\(catalog)/AppIcon.appiconset/AppIcon.png", icon(size: 1024, background: BrandToken.ink.light, mark: white))
add("\(catalog)/AppIcon.appiconset/AppIcon-Dark.png", icon(size: 1024, background: black, mark: white))
// Greys only: iOS lays the user's tint over it.
add("\(catalog)/AppIcon.appiconset/AppIcon-Tinted.png", icon(size: 1024, background: black, mark: BrandRGB(0xD0D0D0)))
add("\(catalog)/AppIcon.appiconset/Contents.json", text: """
    {
      "images" : [
        { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
        { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "AppIcon-Dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
        { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ], "filename" : "AppIcon-Tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """)

// The launch screen: the mark in ink, 72 pt, on the canvas.
for scale in [2, 3] {
    let side = 72 * scale
    add("\(catalog)/LaunchLogo.imageset/LaunchLogo@\(scale)x.png", png(width: side, height: side, opaque: false) { context in
        drawMark(context, in: CGRect(x: 0, y: 0, width: side, height: side), color: BrandToken.ink.light)
    })
}
add("\(catalog)/LaunchLogo.imageset/Contents.json", text: """
    {
      "images" : [
        { "idiom" : "universal", "scale" : "1x" },
        { "filename" : "LaunchLogo@2x.png", "idiom" : "universal", "scale" : "2x" },
        { "filename" : "LaunchLogo@3x.png", "idiom" : "universal", "scale" : "3x" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """)
add("\(catalog)/LaunchBackground.colorset/Contents.json", text: colorset(BrandToken.canvas.light))
// The system tint (links, switches, text buttons) is ink.
add("\(catalog)/AccentColor.colorset/Contents.json", text: colorset(BrandToken.ink.light))

// MARK: - Write or check

var stale: [String] = []
for output in outputs {
    let url = root.appendingPathComponent(output.path)
    if (try? Data(contentsOf: url)) == output.data { continue }
    if checking {
        stale.append(output.path)
        continue
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try output.data.write(to: url)
    print("wrote \(output.path)")
}
if checking {
    guard stale.isEmpty else {
        print("Out of date (run scripts/build_brand.sh):\n" + stale.map { "  " + $0 }.joined(separator: "\n"))
        exit(1)
    }
    print("All \(outputs.count) brand files are up to date.")
}
