import Foundation
import SwiftUI

// Prix API $/1M tokens (source : docs Anthropic, cache 2026-06).
// Coût affiché = équivalent API — l'abonnement est forfaitaire, c'est informatif.
struct ModelPricing {
    let input: Double
    let output: Double
}

enum Pricing {
    static let table: [(prefix: String, label: String, price: ModelPricing, color: Color)] = [
        ("claude-fable-5",  "Fable 5",    .init(input: 10, output: 50), Color(red: 0.68, green: 0.45, blue: 1.0)),
        ("claude-mythos-5", "Mythos 5",   .init(input: 10, output: 50), Color(red: 0.68, green: 0.45, blue: 1.0)),
        ("claude-opus-5",   "Opus 5",     .init(input: 5,  output: 25), Color(red: 1.0,  green: 0.62, blue: 0.26)),
        ("claude-opus-4",   "Opus 4.x",   .init(input: 5,  output: 25), Color(red: 1.0,  green: 0.75, blue: 0.42)),
        ("claude-sonnet-5", "Sonnet 5",   .init(input: 2,  output: 10), Color(red: 0.35, green: 0.65, blue: 1.0)),
        ("claude-sonnet-4", "Sonnet 4.x", .init(input: 3,  output: 15), Color(red: 0.5,  green: 0.75, blue: 1.0)),
        ("claude-haiku",    "Haiku",      .init(input: 1,  output: 5),  Color(red: 0.3,  green: 0.85, blue: 0.6)),
    ]

    static func info(for modelId: String) -> (label: String, price: ModelPricing, color: Color)? {
        guard !modelId.hasPrefix("<") else { return nil } // "<synthetic>"
        for row in table where modelId.hasPrefix(row.prefix) {
            return (row.label, row.price, row.color)
        }
        // Modèle inconnu : prix Opus par défaut pour ne pas afficher 0
        return (modelId, .init(input: 5, output: 25), .gray)
    }

    // Cache write ×1.25 (5m) / ×2 (1h), cache read ×0.1 du prix input
    static func cost(price: ModelPricing, input: Int, output: Int,
                     cache5m: Int, cache1h: Int, cacheRead: Int) -> Double {
        let m = 1_000_000.0
        return Double(input) / m * price.input
            + Double(output) / m * price.output
            + Double(cache5m) / m * price.input * 1.25
            + Double(cache1h) / m * price.input * 2.0
            + Double(cacheRead) / m * price.input * 0.1
    }
}
