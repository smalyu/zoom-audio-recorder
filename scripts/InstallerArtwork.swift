import AppKit

// The disk image window: 640 pt wide, ~400 pt visible under the title bar. The extra
// 20 pt at the bottom stays empty, so a taller title bar crops nothing that matters.
let size = NSSize(width: 640, height: 420)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.99, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
/// Draws centered text whose top edge is `top` points below the top of the window.
func text(_ value: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (value as NSString).draw(in: NSRect(x: 30, y: 420 - top - 65, width: 580, height: 65), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        .paragraphStyle: paragraph])
}
text("Zoom Audio Recorder", top: 40, size: 26, weight: .semibold, color: .init(calibratedWhite: 0.12, alpha: 1))
text("Перетащите приложение в папку «Программы»", top: 80, size: 15, weight: .regular, color: .init(calibratedWhite: 0.4, alpha: 1))
// Finder places icons up to ~26 pt lower on macOS 26+ than on earlier versions, so the
// arrow sits between both positions and nothing is drawn right under the icon labels.
let arrowY = 420 - 205.0
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 285, y: arrowY))
arrow.line(to: NSPoint(x: 355, y: arrowY))
arrow.move(to: NSPoint(x: 341, y: arrowY + 14))
arrow.line(to: NSPoint(x: 355, y: arrowY))
arrow.line(to: NSPoint(x: 341, y: arrowY - 14))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.95, alpha: 1).setStroke()
arrow.stroke()
text("Если macOS не открывает приложение: «Системные настройки» →\n«Конфиденциальность и безопасность» → «Все равно открыть».",
     top: 332, size: 11, weight: .regular, color: .init(calibratedWhite: 0.45, alpha: 1))
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
