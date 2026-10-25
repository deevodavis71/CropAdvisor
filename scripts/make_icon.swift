// Renders the Crop Advisor app icon (1024×1024 PNG).
// Usage: swift scripts/make_icon.swift <out.png>   (see scripts/make_icon.sh)
import AppKit
import CoreGraphics

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: 824pt rounded square centred on a 1024 canvas.
let content = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: content, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(rgb(0x1B1F3B))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// Dusk sky.
let sky = CGGradient(colorsSpace: space,
                     colors: [rgb(0xF9C46B), rgb(0xEC6A3E), rgb(0x8E3B6E), rgb(0x2A1B5C)] as CFArray,
                     locations: [0.0, 0.3, 0.62, 1.0])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 380), end: CGPoint(x: 0, y: 924), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Crop frame (3:2) and its thirds; the sun sits on the upper-right power point.
let crop = CGRect(x: 222, y: 318, width: 580, height: 387)
let thirdX = [crop.minX + crop.width / 3, crop.minX + crop.width * 2 / 3]
let thirdY = [crop.minY + crop.height / 3, crop.minY + crop.height * 2 / 3]
let sun = CGPoint(x: thirdX[1], y: thirdY[1])

let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFE8A3, 0.9), rgb(0xFFB55E, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 40, endCenter: sun, endRadius: 210, options: [])
ctx.setFillColor(rgb(0xFFF1C9))
ctx.fillEllipse(in: CGRect(x: sun.x - 62, y: sun.y - 62, width: 124, height: 124))

func mountains(_ pts: [(CGFloat, CGFloat)], _ color: CGColor) {
    ctx.move(to: CGPoint(x: 80, y: 80))
    for (x, y) in pts { ctx.addLine(to: CGPoint(x: x, y: y)) }
    ctx.addLine(to: CGPoint(x: 944, y: 80))
    ctx.closePath()
    ctx.setFillColor(color)
    ctx.fillPath()
}
mountains([(80, 430), (250, 575), (370, 480), (470, 600), (690, 430), (830, 540), (944, 470)], rgb(0x3B2A63))
mountains([(80, 330), (300, 445), (470, 360), (640, 430), (790, 350), (944, 410)], rgb(0x1A1736))

// Dim everything outside the crop, like the app's Before view.
ctx.addRect(content)
ctx.addRect(crop)
ctx.setFillColor(rgb(0x000000, 0.5))
ctx.fillPath(using: .evenOdd)

// Thirds grid.
ctx.setStrokeColor(rgb(0xFFFFFF, 0.45))
ctx.setLineWidth(4)
for x in thirdX { ctx.move(to: CGPoint(x: x, y: crop.minY)); ctx.addLine(to: CGPoint(x: x, y: crop.maxY)) }
for y in thirdY { ctx.move(to: CGPoint(x: crop.minX, y: y)); ctx.addLine(to: CGPoint(x: crop.maxX, y: y)) }
ctx.strokePath()

// Crop border and corner handles.
ctx.setStrokeColor(rgb(0xFFFFFF, 0.9))
ctx.setLineWidth(5)
ctx.stroke(crop)
ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.setLineWidth(20)
ctx.setLineCap(.square)
let arm: CGFloat = 78
for (cx, cy, dx, dy) in [(crop.minX, crop.minY, 1.0, 1.0), (crop.maxX, crop.minY, -1.0, 1.0),
                         (crop.minX, crop.maxY, 1.0, -1.0), (crop.maxX, crop.maxY, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
    let ox = cx - dx * 6, oy = cy - dy * 6
    ctx.move(to: CGPoint(x: ox + dx * arm, y: oy))
    ctx.addLine(to: CGPoint(x: ox, y: oy))
    ctx.addLine(to: CGPoint(x: ox, y: oy + dy * arm))
}
ctx.strokePath()

// Focal-point marker on the sun.
ctx.setStrokeColor(rgb(0xFFD60A))
ctx.setLineWidth(9)
ctx.strokeEllipse(in: CGRect(x: sun.x - 88, y: sun.y - 88, width: 176, height: 176))

// Subtle top sheen.
let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 640), options: [])
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
