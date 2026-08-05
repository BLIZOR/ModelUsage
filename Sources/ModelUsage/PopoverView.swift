import ServiceManagement
import SwiftUI

// Un seul écran : session (forfait réel), courbe live, par-modèle, santé,
// semaine, économie du mois. Le détail chiffré est en tooltip (.help) — l'écran
// ne montre que ce qui se lit d'un coup d'œil.
struct PopoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            sessionHero
            heartMonitor
            if !store.rows.isEmpty { modelSection }
            weeklySection
            Divider().overlay(Color.white.opacity(0.06))
            costSection
            footer
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 10) {
            Text("ModelUsage")
                .font(AppFont.black(19))
                .foregroundStyle(Theme.text)
            if store.sub?.subscriptionType != nil {
                Text(UsageStore.subscriptionLabel)
                    .font(AppFont.bold(11))
                    .foregroundStyle(Theme.teal)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.teal.opacity(0.14)))
            }
            Spacer()
            if store.sub?.fiveHourResetsAt == nil {
                // un seul état explicite plutôt que des « — » muets partout
                Text("⏳ % officiels en attente")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    // MARK: - session (usage réel vs forfait)

    private var sessionHero: some View {
        let pct = store.livePercent ?? store.sub?.fiveHourPercent
        let color = Theme.status(pct)
        let fraction = (pct ?? 0) / 100
        return VStack(alignment: .leading, spacing: 8) {
            Text("SESSION 5 H")
                .font(AppFont.bold(11)).tracking(1.2)
                .foregroundStyle(Theme.faint)
            // Début · Durée · Reset — le bloc 5 h officiel (resets_at API)
            if let reset = store.sub?.fiveHourResetsAt {
                let started = reset.addingTimeInterval(-5 * 3600)
                let elapsed = max(0, Int(Date().timeIntervalSince(started)))
                HStack {
                    sessionFact("DÉBUT", hourFmt(started), .leading)
                    Spacer()
                    sessionFact("DURÉE", "\(elapsed / 3600) h \(String(format: "%02d", (elapsed % 3600) / 60))", .center)
                    Spacer()
                    sessionFact("RESET", hourFmt(reset), .trailing)
                }
                .padding(.vertical, 2)
            }
            // le % vit SUR la barre : un seul endroit où lire la conso
            ZStack(alignment: .trailing) {
                bar(fraction: fraction, color: color, height: 22)
                Text(pct.map { "\(Int($0)) %" } ?? "—")
                    .font(AppFont.black(14))
                    // au-delà de ~92 % le remplissage passe sous le texte
                    .foregroundStyle(fraction > 0.92 ? Theme.bg : color)
                    .padding(.trailing, 10)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.5), value: pct.map { Int($0) })
            }
            .help(sessionDetail)
            // seul reste de l'ancienne section « santé » : le verdict du bloc 5 h
            Text(sessionVerdict.0)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(sessionVerdict.1)
        }
    }

    private var sessionVerdict: (String, Color) {
        guard let depletes = store.depletesAt else {
            return (store.burnHistory.last ?? 0) < 1000
                ? ("à l'arrêt", Theme.sub) : ("mesure en cours…", Theme.faint)
        }
        if let reset = store.sub?.fiveHourResetsAt, depletes >= reset {
            return ("tiendra jusqu'au reset", Theme.teal)
        }
        let lasts = max(0, Int(depletes.timeIntervalSinceNow))
        return ("épuisée dans \(lasts / 3600) h \(String(format: "%02d", (lasts % 3600) / 60)) — avant le reset",
                Theme.amber)
    }

    private var sessionDetail: String {
        var s = "\(tokensFmt(store.sessionTokens)) tokens"
        if let limit = store.estimatedLimit { s += " / ≈\(tokensFmt(limit))" }
        if let rest = store.remainingTokens { s += " · reste ≈\(tokensFmt(rest))" }
        return s + "\néquiv. API : \(currency(store.sessionCost)) ce bloc · \(currency(store.dayCost)) aujourd'hui"
    }

    // MARK: - courbe live + allure (fusionnés : une seule lecture du débit)

    private var heartMonitor: some View {
        let live = store.burnHistory.last ?? store.burnPerMin
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("TOKENS LIVE")
                    .font(AppFont.bold(11)).tracking(1.2)
                    .foregroundStyle(Theme.faint)
                Spacer()
                Text(pace(live)).font(.system(size: 16))
                Text("\(tokensFmt(Int(live))) tok/min")
                    .font(AppFont.bold(13))
                    .foregroundStyle(Theme.teal)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.4), value: live)
            }
            HeartRateView(values: store.burnHistory)
                .frame(height: 52)
                .help("moyenne 1 h : \(tokensFmt(Int(store.burnPerMin))) tok/min · \(tokensFmt(Int(store.burnPerMin * 60))) tok/h")
        }
    }

    // MARK: - par modèle

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("PAR MODÈLE")
                .font(AppFont.bold(11)).tracking(1.2)
                .foregroundStyle(Theme.faint)
            HStack(spacing: 10) {
                ForEach(modelPills) { modelPill($0) }
            }
        }
    }

    // Toujours les mêmes 3 carrés — les modèles que Claude Code pilote — même à
    // 0 %, pour que la lecture ne bouge pas d'un bloc à l'autre. Tout autre
    // modèle qui aurait consommé s'ajoute à la suite.
    private static let pinnedModels = ["Opus 5", "Fable 5", "Haiku"]

    private var modelPills: [ModelRow] {
        let byLabel = Dictionary(store.rows.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = Self.pinnedModels.map { label in
            byLabel[label] ?? ModelRow(id: label, label: label,
                                       color: Pricing.table.first { $0.label == label }?.color ?? .gray,
                                       tokens: 0, inTok: 0, outTok: 0, cacheTok: 0, cost: 0, share: 0)
        }
        return pinned + store.rows.filter { !Self.pinnedModels.contains($0.label) }
    }

    // Pill carrée : remplissage de bas en haut = part du bloc courant.
    private func modelPill(_ row: ModelRow) -> some View {
        ZStack(alignment: .top) {
            GeometryReader { geo in
                Rectangle()
                    .fill(row.color.opacity(0.85))
                    .frame(height: geo.size.height * min(1, row.share))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .animation(.easeOut(duration: 0.6), value: row.share)
            }
            VStack(spacing: 2) {
                Text(row.label)
                    .font(AppFont.bold(12))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("\(Int(row.share * 100)) %")
                    .font(AppFont.black(20))
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.6), value: Int(row.share * 100))
            }
            // texte en haut : lisible sur le fond sombre comme sur le remplissage
            .foregroundStyle(Theme.text)
            .padding(.top, 10)
            .padding(.horizontal, 6)
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Theme.track)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .help("\(currency(row.cost)) · \(tokensFmt(row.tokens)) tokens — in \(tokensFmt(row.inTok)) · out \(tokensFmt(row.outTok)) · cache \(tokensFmt(row.cacheTok))")
    }

    // MARK: - conso hebdo (jauge d'ALLURE, pas de niveau)

    /**
     * La couleur ne dit pas « combien reste-t-il » mais « suis-je en avance sur
     * mon budget ». 60 % consommés à mi-semaine = normal (vert) ; les mêmes 60 %
     * avec encore 4 jours avant le reset = rouge. Repère = part de la fenêtre
     * 7 j écoulée, la barre devrait rester à sa hauteur.
     */
    private var weeklySection: some View {
        let pct = store.sub?.sevenDayPercent
        let elapsed = weekElapsedFraction
        let color = weeklyColor(pct: pct, elapsed: elapsed)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CONSO. HEBDO.")
                    .font(AppFont.bold(11)).tracking(1.2)
                    .foregroundStyle(Theme.faint)
                Spacer()
                Text(pct.map { "\(Int($0)) %" } ?? "—")
                    .font(AppFont.bold(15))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.5), value: pct.map { Int($0) })
            }
            bar(fraction: (pct ?? 0) / 100, color: color, height: 14)
                .overlay(alignment: .leading) {
                    if let e = elapsed {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(Color.white.opacity(0.55))
                                .frame(width: 2)
                                .offset(x: geo.size.width * e)
                        }
                    }
                }
                .help(weeklyDetail)
            Text(weeklyVerdict)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    /// Part de la fenêtre 7 j déjà écoulée (0…1). nil tant que l'API n'a rien dit.
    private var weekElapsedFraction: Double? {
        guard let reset = store.sub?.sevenDayResetsAt else { return nil }
        return min(1, max(0, 1 - reset.timeIntervalSinceNow / (7 * 24 * 3600)))
    }

    private func weeklyColor(pct: Double?, elapsed: Double?) -> Color {
        guard let pct else { return Theme.sub }
        if pct >= 95 { return Theme.red }
        // début de fenêtre : le ratio explose sur du bruit, on ne juge pas encore
        guard let elapsed, elapsed > 0.03 else { return Theme.teal }
        switch pct / 100 / elapsed { // 1 = pile dans le budget
        case ..<1.05: return Theme.teal
        case ..<1.35: return Theme.amber
        default: return Theme.red
        }
    }

    private var weeklyVerdict: String {
        guard let pct = store.sub?.sevenDayPercent, let reset = store.sub?.sevenDayResetsAt else {
            return "en attente des % officiels"
        }
        let left = remainingLabel(until: reset)
        if pct >= 95 { return "plafond hebdo atteint — reset dans \(left)" }
        guard let elapsed = weekElapsedFraction, elapsed > 0.03 else { return "reset dans \(left)" }
        if pct / 100 / elapsed < 1.05 { return "dans le budget — reste \(left) avant reset" }
        if let cap = store.weekDepletesAt, cap < reset {
            return "trop vite : plafond \(weekDayFmt(cap)), reset dans \(left)"
        }
        return "\(Int(pct)) % brûlés en \(Int(elapsed * 100)) % de la semaine — reste \(left)"
    }

    private var weeklyDetail: String {
        var s = "repère blanc = part de la fenêtre 7 j écoulée"
        if let e = weekElapsedFraction { s += " (\(Int(e * 100)) %)" }
        if let reset = store.sub?.sevenDayResetsAt { s += "\nreset \(dayFmt(reset))" }
        if let cap = store.weekDepletesAt { s += "\nà ce rythme : plafond \(weekDayFmt(cap))" }
        return s
    }

    private func remainingLabel(until d: Date) -> String {
        let s = max(0, Int(d.timeIntervalSinceNow))
        let days = s / 86400, hours = (s % 86400) / 3600
        return days > 0 ? "\(days) j \(hours) h" : "\(hours) h"
    }

    // MARK: - économie du mois (ex-Journal, condensé)

    private var costSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("ÉCONOMIE \(monthName().uppercased())")
                    .font(AppFont.bold(11)).tracking(1.2)
                    .foregroundStyle(Theme.faint)
                Spacer()
                if store.journalReady {
                    Text(currency(store.monthCost))
                        .font(AppFont.black(22))
                        .foregroundStyle(Theme.teal)
                    Text("×\(String(format: "%.1f", store.monthCost / UsageStore.subscriptionMonthly)) l'abonnement")
                        .font(AppFont.bold(12))
                        .foregroundStyle(Theme.text)
                }
            }
            if store.journalReady {
                dailyChart.help(costDetail)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyse des transcripts…")
                        .font(.system(size: 12)).foregroundStyle(Theme.sub)
                }
            }
        }
    }

    private var costDetail: String {
        let total = store.days.reduce(0) { $0 + $1.cost }
        let avg = store.days.isEmpty ? 0 : total / Double(store.days.count)
        var s = "30 j : \(currency(total)) · moyenne \(currency(avg))/j"
        s += "\nfin de mois ≈ \(currency(store.monthProjection)) — abonnement \(currency(UsageStore.subscriptionMonthly))"
        if !store.monthTopProjects.isEmpty {
            s += "\nprojets : " + store.monthTopProjects.map { "\($0.0) \(currency($0.1))" }.joined(separator: " · ")
        }
        if !store.monthTopModels.isEmpty {
            s += "\nmodèles : " + store.monthTopModels.map { "\($0.0) \(currency($0.1))" }.joined(separator: " · ")
        }
        return s
    }

    private var dailyChart: some View {
        let days = Array(store.days.suffix(14))
        let maxCost = max(days.map(\.cost).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(days) { d in
                let today = Calendar.current.isDateInToday(d.day)
                let dayNum = Calendar.current.component(.day, from: d.day)
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.teal.opacity(today ? 0.95 : 0.45))
                        .frame(height: max(4, 62 * d.cost / maxCost))
                    // étiqueter clairsemé : lisible, pas un mur de chiffres
                    Text(today || dayNum == 1 || dayNum % 5 == 0 ? "\(dayNum)" : " ")
                        .font(.system(size: 9, weight: today ? .bold : .regular))
                        .foregroundStyle(today ? Theme.teal : Theme.faint)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 80, alignment: .bottom)
    }

    // Allure de conso live : du piéton à la fusée (seuils calés sur les débits
    // réels observés, cache reads compris).
    private func pace(_ tokPerMin: Double) -> String {
        switch tokPerMin {
        case ..<10_000: return "🚶"
        case ..<150_000: return "🚴"
        case ..<600_000: return "🚗"
        case ..<1_500_000: return "✈️"
        default: return "🚀"
        }
    }

    private func sessionFact(_ label: String, _ value: String, _ align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 2) {
            Text(label)
                .font(AppFont.bold(10)).tracking(1.0)
                .foregroundStyle(Theme.faint)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.text)
        }
    }

    // MARK: - footer

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            LaunchAtLoginToggle()
            Button("Quitter") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .font(.system(size: 12))
                .foregroundStyle(Theme.sub)
        }
    }

    // MARK: - helpers

    private func bar(fraction: Double, color: Color, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(color)
                    // le minimum ne s'applique qu'à partir de 1 % : sinon une
                    // barre vide affiche un gros point (capsule de largeur = hauteur)
                    .frame(width: fraction <= 0 ? 0 : max(height, geo.size.width * min(1, fraction)))
                    .animation(.easeOut(duration: 0.5), value: fraction)
            }
        }
        .frame(height: height)
    }

    private func currency(_ v: Double) -> String {
        v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
    }

    private func tokensFmt(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    // Formatters mis en cache : le body est recalculé à chaque tick (1 Hz),
    // instancier un DateFormatter à chaque passage coûte plus que tout le reste.
    private static func fmt(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = pattern
        return f
    }
    private static let hourF = fmt("HH:mm")
    private static let dayF = fmt("EEE HH:mm")
    private static let weekDayF = fmt("EEEE HH'h'")
    private static let monthF = fmt("MMMM yyyy")

    private func hourFmt(_ d: Date) -> String { Self.hourF.string(from: d) }
    private func dayFmt(_ d: Date) -> String { Self.dayF.string(from: d) }
    private func weekDayFmt(_ d: Date) -> String { Self.weekDayF.string(from: d) }
    private func monthName() -> String { Self.monthF.string(from: Date()) }
}

// Tracé façon moniteur cardiaque : ligne teal avec léger glow, grille faible,
// point pulsant au bout. Un point par seconde, fenêtre ~2 min.
struct HeartRateView: View {
    let values: [Double]
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let slots = UsageStore.burnPoints
            let maxV = max(values.max() ?? 1, 1)
            let points: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: w * CGFloat(slots - values.count + i) / CGFloat(slots - 1),
                        y: h - 4 - (h - 12) * CGFloat(v / maxV))
            }
            ZStack(alignment: .leading) {
                ForEach(1..<3) { i in
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h * CGFloat(i) / 3))
                        p.addLine(to: CGPoint(x: w, y: h * CGFloat(i) / 3))
                    }
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
                }
                if points.count > 1 {
                    Path { p in
                        p.move(to: points[0])
                        for pt in points.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(Theme.teal, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .shadow(color: Theme.teal.opacity(0.6), radius: 3)
                }
                if let last = points.last {
                    Circle()
                        .fill(Theme.teal)
                        .frame(width: 6, height: 6)
                        .scaleEffect(pulse ? 1.8 : 1)
                        .opacity(pulse ? 0.3 : 1)
                        .position(last)
                        .animation(.easeOut(duration: 1).repeatForever(autoreverses: false), value: pulse)
                }
                if points.count < 2 {
                    Text("mesure en cours…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
        .onAppear { pulse = true }
    }
}

// Ouvrir au login (mécanisme système)
struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle(isOn: $enabled) {
            Text("Login")
                .font(.system(size: 12)).foregroundStyle(Theme.sub)
        }
        .toggleStyle(.switch).controlSize(.mini)
        .onChange(of: enabled) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                mlog("launch-at-login: \(error)")
                enabled = SMAppService.mainApp.status == .enabled
            }
        }
    }
}
