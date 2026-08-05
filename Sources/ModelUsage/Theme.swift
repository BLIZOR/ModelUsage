import AppKit
import SwiftUI

// Identité Netwa : ink teinté teal, accent #00D4AA, Netwa Neo (PS: SwileNova).
enum Theme {
    static let bg = Color(red: 0.047, green: 0.078, blue: 0.071)      // ink teal-tinté
    static let raised = Color.white.opacity(0.045)
    static let track = Color.white.opacity(0.07)
    static let text = Color(red: 0.95, green: 0.97, blue: 0.96)
    static let sub = Color(red: 0.56, green: 0.65, blue: 0.62)
    static let faint = Color(red: 0.38, green: 0.46, blue: 0.43)
    static let teal = Color(red: 0.0, green: 0.831, blue: 0.667)      // #00D4AA
    static let amber = Color(red: 1.0, green: 0.69, blue: 0.30)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.38)

    static func status(_ pct: Double?) -> Color {
        guard let p = pct else { return sub }
        if p >= 90 { return red }
        if p >= 75 { return amber }
        return teal
    }
}

enum NetwaFont {
    static private(set) var available = false

    static func register() {
        guard let dir = Bundle.main.resourceURL else { return }
        for name in ["NetwaNeo-Bold", "NetwaNeo-Black"] {
            let url = dir.appendingPathComponent("\(name).ttf")
            if FileManager.default.fileExists(atPath: url.path) {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                available = true
            }
        }
    }

    // Netwa Neo n'a que Bold et Black
    static func bold(_ size: CGFloat) -> Font {
        available ? .custom("SwileNova-Bold", size: size) : .system(size: size, weight: .semibold)
    }
    static func black(_ size: CGFloat) -> Font {
        available ? .custom("SwileNova-Black", size: size) : .system(size: size, weight: .black)
    }
}
