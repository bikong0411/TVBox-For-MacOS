import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("TVBox.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        let bounds = NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: p * 0.20, yRadius: p * 0.20)
        NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.21, blue: 0.29, alpha: 1), ending: NSColor(calibratedRed: 0.035, green: 0.05, blue: 0.08, alpha: 1))!.draw(in: shape, angle: -65)
        let orange = NSColor(calibratedRed: 1, green: 0.54, blue: 0.31, alpha: 1)
        orange.setStroke()
        let screen = NSBezierPath(roundedRect: NSRect(x: p * 0.21, y: p * 0.28, width: p * 0.58, height: p * 0.43), xRadius: p * 0.075, yRadius: p * 0.075)
        screen.lineWidth = p * 0.035; screen.stroke()
        orange.setFill()
        let triangle = NSBezierPath(); triangle.move(to: NSPoint(x: p * 0.45, y: p * 0.39)); triangle.line(to: NSPoint(x: p * 0.45, y: p * 0.60)); triangle.line(to: NSPoint(x: p * 0.62, y: p * 0.495)); triangle.close(); triangle.fill()
        let stand = NSBezierPath(); stand.move(to: NSPoint(x: p * 0.40, y: p * 0.20)); stand.line(to: NSPoint(x: p * 0.60, y: p * 0.20)); stand.lineWidth = p * 0.03; stand.lineCapStyle = .round; stand.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
