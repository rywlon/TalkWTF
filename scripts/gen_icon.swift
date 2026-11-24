//! Renders the TalkWTF app icon: a macOS squircle with a monochrome waveform.
//!
//! ```sh
//! swift scripts/gen_icon.swift docs/assets/app-icon.png
//! # then rebuild AppIcon.icns:
//! mkdir -p /tmp/AppIcon.iconset
//! for s in 16 32 128 256 512; do
//!   sips -z $s $s docs/assets/app-icon.png --out /tmp/AppIcon.iconset/icon_${s}x${s}.png
//!   sips -z $((s*2)) $((s*2)) docs/assets/app-icon.png --out /tmp/AppIcon.iconset/icon_${s}x${s}@2x.png
//! done
//! iconutil -c icns /tmp/AppIcon.iconset -o macos/TalkWTF/AppIcon.icns
//! ```

import AppKit
import CoreGraphics
import Foundation

// macOS icon grid: artwork in a squircle inset from the canvas edge.
let size = 1024.0
let inset = 100.0
let side = size - inset * 2
let radius = side * 0.2237

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
    bytesPerRow: 0, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

let squircle = CGPath(
    roundedRect: CGRect(x: inset, y: inset, width: side, height: side),
    cornerWidth: radius, cornerHeight: radius, transform: nil
)

// Soft neutral background: light at the top, a touch darker at the bottom.
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let bg = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.976, green: 0.976, blue: 0.984, alpha: 1),
        CGColor(red: 0.902, green: 0.906, blue: 0.925, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    bg,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: 0),
    options: []
)
ctx.restoreGState()

// Hairline edge so the shape reads on light backgrounds.
ctx.addPath(squircle)
ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.08))
ctx.setLineWidth(2)
ctx.strokePath()

// Monochrome waveform: five rounded bars, tallest in the middle.
let barWidth = side * 0.072
let gap = side * 0.048
let heights: [CGFloat] = [0.26, 0.46, 0.62, 0.46, 0.26]
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (size - totalWidth) / 2

ctx.setFillColor(CGColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1))
for factor in heights {
    let height = side * factor
    let bar = CGPath(
        roundedRect: CGRect(x: x, y: (size - height) / 2, width: barWidth, height: height),
        cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil
    )
    ctx.addPath(bar)
    ctx.fillPath()
    x += barWidth + gap
}

guard let image = ctx.makeImage() else { exit(1) }
// Usage: swift scripts/gen_icon.swift [out.png]  (default: docs/assets/app-icon.png)
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/assets/app-icon.png"
let out = URL(fileURLWithPath: outPath)
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
