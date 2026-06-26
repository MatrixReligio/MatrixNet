// Generates the MatrixNet app icon as PNGs at all macOS sizes, plus the
// AppIcon.appiconset Contents.json. Concept: a phosphor-green node-link graph
// (network connections) over a faint "matrix" dot grid on a warm dark-green tile.
// Run: swift Tools/IconGen/main.swift
import AppKit
import CoreGraphics
import Foundation

let outputDir = "App/Resources/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func draw(size: CGFloat) -> CGImage {
    let scale = size / 1024.0
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high

    // Rounded tile.
    let inset: CGFloat = 88 * scale
    let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius: CGFloat = 185 * scale
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow beneath the tile.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -10 * scale),
        blur: 28 * scale,
        color: NSColor.black.withAlphaComponent(0.35).cgColor
    )
    context.addPath(tilePath)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    // Tile gradient: warm dark-green-black, tinted (never pure black).
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: [
        NSColor(red: 0.060, green: 0.105, blue: 0.085, alpha: 1).cgColor,
        NSColor(red: 0.020, green: 0.050, blue: 0.038, alpha: 1).cgColor
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: tile.minX, y: tile.maxY),
        end: CGPoint(x: tile.minX, y: tile.minY),
        options: []
    )

    // Faint "matrix" dot grid.
    let phosphor = NSColor(red: 0.34, green: 0.86, blue: 0.58, alpha: 1)
    let step: CGFloat = 64 * scale
    let dotR: CGFloat = 3.2 * scale
    context.setFillColor(phosphor.withAlphaComponent(0.07).cgColor)
    var gy = tile.minY + step / 2
    while gy < tile.maxY {
        var gx = tile.minX + step / 2
        while gx < tile.maxX {
            context.fillEllipse(in: CGRect(x: gx - dotR, y: gy - dotR, width: dotR * 2, height: dotR * 2))
            gx += step
        }
        gy += step
    }
    context.restoreGState()

    /// Node-link graph (network connections).
    func point(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
        CGPoint(x: tile.minX + tile.width * nx, y: tile.minY + tile.height * ny)
    }
    let hub = point(0.50, 0.52)
    let nodes = [point(0.28, 0.70), point(0.70, 0.74), point(0.76, 0.40), point(0.30, 0.34)]
    let edges = [
        (hub, nodes[0]),
        (hub, nodes[1]),
        (hub, nodes[2]),
        (hub, nodes[3]),
        (nodes[0], nodes[3]),
        (nodes[1], nodes[2])
    ]

    context.saveGState()
    context.setShadow(offset: .zero, blur: 22 * scale, color: phosphor.withAlphaComponent(0.55).cgColor)
    context.setStrokeColor(phosphor.withAlphaComponent(0.85).cgColor)
    context.setLineWidth(12 * scale)
    context.setLineCap(.round)
    for edge in edges {
        context.move(to: edge.0)
        context.addLine(to: edge.1)
    }
    context.strokePath()

    // Satellite nodes.
    for node in nodes {
        let r: CGFloat = 34 * scale
        context.setFillColor(phosphor.withAlphaComponent(0.95).cgColor)
        context.fillEllipse(in: CGRect(x: node.x - r, y: node.y - r, width: r * 2, height: r * 2))
    }
    // Hub node (brighter, ringed).
    let hubR: CGFloat = 64 * scale
    context.setShadow(offset: .zero, blur: 40 * scale, color: phosphor.withAlphaComponent(0.85).cgColor)
    context.setFillColor(NSColor(red: 0.78, green: 0.98, blue: 0.86, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: hub.x - hubR, y: hub.y - hubR, width: hubR * 2, height: hubR * 2))
    context.restoreGState()

    context.setStrokeColor(phosphor.withAlphaComponent(0.9).cgColor)
    context.setLineWidth(10 * scale)
    let ringR = hubR + 26 * scale
    context.strokeEllipse(in: CGRect(x: hub.x - ringR, y: hub.y - ringR, width: ringR * 2, height: ringR * 2))

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

struct Entry { let size: Int
    let scale: Int
}

let entries = [
    Entry(size: 16, scale: 1),
    Entry(size: 16, scale: 2),
    Entry(size: 32, scale: 1),
    Entry(size: 32, scale: 2),
    Entry(size: 128, scale: 1),
    Entry(size: 128, scale: 2),
    Entry(size: 256, scale: 1),
    Entry(size: 256, scale: 2),
    Entry(size: 512, scale: 1),
    Entry(size: 512, scale: 2)
]

var images = [[String: String]]()
for entry in entries {
    let pixels = CGFloat(entry.size * entry.scale)
    let filename = "icon_\(entry.size)x\(entry.size)@\(entry.scale)x.png"
    writePNG(draw(size: pixels), to: "\(outputDir)/\(filename)")
    images.append([
        "size": "\(entry.size)x\(entry.size)",
        "idiom": "mac",
        "filename": filename,
        "scale": "\(entry.scale)x"
    ])
}

let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "matrixnet-icongen"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: "\(outputDir)/Contents.json"))
print("wrote \(entries.count) icon PNGs + Contents.json to \(outputDir)")
