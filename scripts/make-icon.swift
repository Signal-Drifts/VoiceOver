import AppKit
let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let shape = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 190, yRadius: 190)
NSGradient(starting: NSColor(red: 1, green: 0.42, blue: 0.01, alpha: 1), ending: NSColor(red: 0.93, green: 0.31, blue: 0, alpha: 1))!.draw(in: shape, angle: -70)
NSColor.white.setStroke()
let v = NSBezierPath()
v.lineWidth = 86
v.lineCapStyle = .round
v.lineJoinStyle = .round
v.move(to: NSPoint(x: 220, y: 738))
v.line(to: NSPoint(x: 466, y: 282))
v.line(to: NSPoint(x: 711, y: 738))
v.stroke()
NSColor.white.setFill()
for (x, height) in [(628.0, 116.0), (680.0, 216.0), (732.0, 316.0), (784.0, 184.0), (836.0, 84.0)] {
    NSBezierPath(roundedRect: NSRect(x: x, y: 512 - height / 2, width: 30, height: height), xRadius: 15, yRadius: 15).fill()
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
