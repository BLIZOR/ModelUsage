import AppKit
import SwiftUI

// Identité : noir neutre translucide, gris neutres — le teal #00D4AA n'est
// qu'une couleur d'ACCENT (jauges, liens, verdicts), jamais une teinte de fond.
enum Theme {
    static let bg = Color(white: 0.04)
    static let raised = Color.white.opacity(0.045)
    static let track = Color.white.opacity(0.07)
    static let text = Color(white: 0.96)
    static let sub = Color(white: 0.62)
    static let faint = Color(white: 0.42)
    static let teal = Color(red: 0.0, green: 0.831, blue: 0.667)      // #00D4AA
    static let amber = Color(red: 1.0, green: 0.69, blue: 0.30)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.38)

    static func status(_ pct: Double?) -> Color {
        guard let p = pct else { return sub }
        if p >= 90 { return red }
        if p >= 75 { return amber }
        return teal
    }

    /// Allure de conso — seuils calés sur des débits in+out (cache exclu).
    /// Partagé entre la carte Burn rate et l'icône menubar.
    static func paceEmoji(_ tokPerMin: Int) -> String {
        switch tokPerMin {
        case ..<100: return "🚶"
        case ..<500: return "🚴"
        case ..<1_500: return "🚗"
        case ..<4_000: return "✈️"
        default: return "🚀"
        }
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
