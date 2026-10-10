import AppKit

let canvas = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: canvas,
                              pixelsHigh: canvas,
                              bitsPerSample: 8,
                              samplesPerPixel: 4,
                              hasAlpha: true,
                              isPlanar: false,
                              colorSpaceName: .deviceRGB,
                              bytesPerRow: 0,
                              bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()

let background = NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 964, height: 964),
                              xRadius: 206, yRadius: 206)
NSGradient(starting: NSColor(srgbRed: 0.06, green: 0.45, blue: 0.94, alpha: 1),
           ending: NSColor(srgbRed: 0.03, green: 0.19, blue: 0.62, alpha: 1))!
    .draw(in: background, angle: -55)

func screen(_ frame: NSRect) {
    let outline = NSBezierPath(roundedRect: frame, xRadius: 31, yRadius: 31)
    NSColor.white.setStroke()
    outline.lineWidth = 31
    outline.stroke()

    let inner = NSBezierPath(roundedRect: frame.insetBy(dx: 27, dy: 27),
                             xRadius: 13, yRadius: 13)
    NSColor(srgbRed: 0.55, green: 0.81, blue: 1.0, alpha: 0.42).setFill()
    inner.fill()

    let stand = NSBezierPath()
    stand.lineWidth = 25
    stand.lineCapStyle = .round
    let mid = frame.midX
    stand.move(to: NSPoint(x: mid, y: frame.minY - 13))
    stand.line(to: NSPoint(x: mid, y: frame.minY - 77))
    stand.move(to: NSPoint(x: mid - 77, y: frame.minY - 78))
    stand.line(to: NSPoint(x: mid + 77, y: frame.minY - 78))
    NSColor.white.setStroke()
    stand.stroke()
}

screen(NSRect(x: 139, y: 375, width: 318, height: 270))
screen(NSRect(x: 567, y: 375, width: 318, height: 270))

let slashShadow = NSBezierPath()
slashShadow.lineWidth = 80
slashShadow.lineCapStyle = .round
slashShadow.move(to: NSPoint(x: 468, y: 257))
slashShadow.line(to: NSPoint(x: 556, y: 754))
NSColor(srgbRed: 0.03, green: 0.26, blue: 0.72, alpha: 0.78).setStroke()
slashShadow.stroke()

let slash = NSBezierPath()
slash.lineWidth = 37
slash.lineCapStyle = .round
slash.move(to: NSPoint(x: 468, y: 257))
slash.line(to: NSPoint(x: 556, y: 754))
NSColor.white.setStroke()
slash.stroke()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
