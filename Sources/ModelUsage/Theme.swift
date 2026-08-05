import AppKit
import SwiftUI

// Identité : ink teinté teal, accent #00D4AA, police système Apple (SF).
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

enum AppFont {
    /// SF Pro semibold — labels et titres.
    static func bold(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold)
    }
    /// SF Pro Rounded black — gros chiffres (rendu « compteur »).
    static func black(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black, design: .rounded)
    }
}
