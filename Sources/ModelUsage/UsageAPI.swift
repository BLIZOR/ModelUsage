import Foundation

// Limites réelles de l'abonnement via l'endpoint OAuth de Claude Code.
struct SubscriptionUsage {
    var fiveHourPercent: Double?
    var fiveHourResetsAt: Date?
    var sevenDayPercent: Double?
    var sevenDayResetsAt: Date?
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
        return usage
    }
}
