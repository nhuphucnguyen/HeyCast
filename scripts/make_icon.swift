// Renders the HeyCast app icon (gradient rounded square + bolt) and writes
// iconset PNGs; `make_app.sh` turns them into an .icns with iconutil.
// Usage: swift scripts/make_icon.swift <output-iconset-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/AppIcon.iconset"

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let gradient = NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.80, blue: 0.24, alpha: 1),
                          ending: NSColor(srgbRed: 0.97, green: 0.55, blue: 0.15, alpha: 1))!
let shape = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.05, dy: size * 0.05),
                         xRadius: size * 0.21, yRadius: size * 0.21)
gradient.draw(in: shape, angle: -55)

// dark inner card for contrast
let inner = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.22, dy: size * 0.22),
                         xRadius: size * 0.13, yRadius: size * 0.13)
NSColor(calibratedWhite: 0.09, alpha: 0.92).setFill()
inner.fill()

// bolt glyph
let bolt = NSMutableAttributedString(string: "⚡️")
bolt.setAttributes([.font: NSFont.systemFont(ofSize: size * 0.40)], range: NSRange(location: 0, length: 1))
let boltSize = bolt.size()
bolt.draw(at: NSPoint(x: (size - boltSize.width) / 2, y: (size - boltSize.height) / 2 - size * 0.02))

image.unlockFocus()

let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!

let scales: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32),
    ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256),
    ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]

for (name, pixels) in scales {
    let scaled = NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { _ in
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        return true
    }
    let scaledTiff = scaled.tiffRepresentation!
    let scaledRep = NSBitmapImageRep(data: scaledTiff)!
    let scaledPng = scaledRep.representation(using: .png, properties: [:])!
    try! scaledPng.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(name).png"))
}
print("iconset written to \(outDir)")
