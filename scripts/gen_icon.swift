// Génère Assets/icon_1024.png — icône ModelUsage (identité Netwa :
// ink teinté teal, anneau de jauge teal, % en Netwa Neo Black).
import AppKit
import CoreText

let fontURL = URL(fileURLWithPath: "Fonts/NetwaNeo-Black.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// fond squircle ink
let inset: CGFloat = 100 // marge macOS Big Sur style
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSColor(red: 0.055, green: 0.09, blue: 0.082, alpha: 1).setFill()
bg.fill()

let center = NSPoint(x: size / 2, y: size / 2)
let teal = NSColor(red: 0, green: 0.831, blue: 0.667, alpha: 1)

// anneau : piste + arc de progression (~72 %)
let radius: CGFloat = 285
let track = NSBezierPath()
track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
track.lineWidth = 58
teal.withAlphaComponent(0.22).setStroke()
track.stroke()

let arc = NSBezierPath()
arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * 0.72, clockwise: true)
arc.lineWidth = 58
arc.lineCapStyle = .round
teal.setStroke()
arc.stroke()

// % en Netwa Neo Black au centre
let font = NSFont(name: "SwileNova-Black", size: 330) ?? NSFont.systemFont(ofSize: 330, weight: .black)
let str = NSAttributedString(string: "%", attributes: [
    .font: font,
    .foregroundColor: NSColor(red: 0.95, green: 0.97, blue: 0.96, alpha: 1),
])
let s = str.size()
str.draw(at: NSPoint(x: center.x - s.width / 2, y: center.y - s.height / 2))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png fail")
}
try! FileManager.default.createDirectory(atPath: "Assets", withIntermediateDirectories: true)
try! png.write(to: URL(fileURLWithPath: "Assets/icon_1024.png"))
print("ok Assets/icon_1024.png")
