import Foundation

/**
 * Conso hebdo d'un modèle.
 * - official = plafond DÉDIÉ publié par l'API (limits[] weekly_scoped, ex. Fable
 *   à 50 % du forfait) : percent = remplissage de ce plafond.
 * - sinon = pas de plafond dédié (Opus, Sonnet…) : percent = part estimée du
 *   forfait hebdo tous modèles déjà brûlée par ce modèle.
 */
struct ModelCap: Identifiable {
    let name: String       // display_name API (« Fable ») ou label Pricing (« Opus 5 »)
    let percent: Double
    var official = true
    var id: String { name }
}

// Limites réelles de l'abonnement via l'endpoint OAuth de Claude Code.
struct SubscriptionUsage {
    var fiveHourPercent: Double?
    var fiveHourResetsAt: Date?
    var sevenDayPercent: Double?
    var sevenDayResetsAt: Date?
    // Plafonds hebdo par modèle — % OFFICIELS publiés par l'API dans limits[]
    // (kind=weekly_scoped, scope.model.display_name). Fable est plafonné à 50 %
    // du forfait ; Opus a son propre plafond hebdo sur les plans Max.
    var weekCaps: [ModelCap] = []
    var subscriptionType: String?
}

enum UsageAPI {
    // Le token vit dans le Keychain, posé par Claude Code.
    // 1er accès : macOS demande l'autorisation → « Toujours autoriser ».
    private static func accessToken() -> (token: String, subscription: String?)? {
        guard let r = Proc.run("/usr/bin/security",
                               ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
                               timeout: 15),
              r.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return (token, oauth["subscriptionType"] as? String)
    }

    static func fetch() async -> SubscriptionUsage? {
        guard let cred = accessToken() else { return nil }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var usage = SubscriptionUsage(subscriptionType: cred.subscription)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()

        func parse(_ key: String) -> (Double, Date?)? {
            guard let block = json[key] as? [String: Any],
                  let pct = block["utilization"] as? Double else { return nil }
            var reset: Date?
            if let s = block["resets_at"] as? String {
                reset = iso.date(from: s) ?? isoNoFrac.date(from: s)
            }
            return (pct, reset)
        }
        if let (p, r) = parse("five_hour") { usage.fiveHourPercent = p; usage.fiveHourResetsAt = r }
        if let (p, r) = parse("seven_day") { usage.sevenDayPercent = p; usage.sevenDayResetsAt = r }
        if let limits = json["limits"] as? [[String: Any]] {
            for l in limits where (l["kind"] as? String) == "weekly_scoped" {
                guard let scope = l["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = model["display_name"] as? String,
                      // le champ a changé de nom selon les versions de l'endpoint
                      let pct = (l["percent"] ?? l["utilization"]) as? Double else { continue }
                usage.weekCaps.append(ModelCap(name: name, percent: pct))
            }
        }
        // Blocs dédiés que l'endpoint publie à part quand le plan en a un
        // (null sur Max 20× aujourd'hui : seul Fable a un plafond scopé).
        for (key, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
            guard let (p, _) = parse(key),
                  !usage.weekCaps.contains(where: { $0.name.hasPrefix(name) }) else { continue }
            usage.weekCaps.append(ModelCap(name: name, percent: p))
        }
        // le plus entamé d'abord : un quota à sec doit sauter aux yeux
        usage.weekCaps.sort { $0.percent > $1.percent }
        mlog("caps: " + usage.weekCaps.map { "\($0.name) \(Int($0.percent))%" }
                                      .joined(separator: " · "))
        return usage
    }
}
