import AppKit

let size = NSSize(width: 640, height: 460)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.99, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (value as NSString).draw(in: NSRect(x: 30, y: y, width: 580, height: 65), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        .paragraphStyle: paragraph])
}
text("Zoom Audio Recorder", y: 342, size: 28, weight: .semibold, color: .init(calibratedWhite: 0.12, alpha: 1))
text("Перетащите приложение в папку «Программы»", y: 302, size: 15, weight: .regular, color: .init(calibratedWhite: 0.4, alpha: 1))
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 285, y: 210))
arrow.line(to: NSPoint(x: 355, y: 210))
arrow.move(to: NSPoint(x: 341, y: 224))
arrow.line(to: NSPoint(x: 355, y: 210))
arrow.line(to: NSPoint(x: 341, y: 196))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.95, alpha: 1).setStroke()
arrow.stroke()
text("Затем откройте приложение из «Программ»", y: 68, size: 13, weight: .medium, color: .init(calibratedWhite: 0.3, alpha: 1))
text("Если macOS заблокирует первый запуск: «Конфиденциальность\nи безопасность» → «Все равно открыть».", y: 8, size: 11, weight: .regular, color: .init(calibratedWhite: 0.45, alpha: 1))
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
