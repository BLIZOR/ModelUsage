import ServiceManagement
import SwiftUI

// Un seul écran, sans onglets ni effets de survol : session (forfait réel),
// courbe live, par-modèle, burn/prévision, semaine, coûts équiv. API.
struct PopoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            sessionHero
            heartMonitor
            if !store.rows.isEmpty { modelSection }
            predictionSection
            weekSection
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
            if let reset = store.sub?.fiveHourResetsAt {
                Text("reset \(countdown(to: reset))")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
            } else {
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(pct.map { "\(Int($0)) %" } ?? "—")
                    .font(AppFont.black(42))
                    .foregroundStyle(color)
                Spacer()
                Text("SESSION 5 H")
                    .font(AppFont.bold(11)).tracking(1.2)
                    .foregroundStyle(Theme.faint)
            }
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
            bar(fraction: (pct ?? 0) / 100, color: color, height: 14)
            HStack {
                if let limit = store.estimatedLimit {
                    Text("\(tokensFmt(store.sessionTokens)) / ≈\(tokensFmt(limit)) tokens")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.sub)
                } else {
                    Text("\(tokensFmt(store.sessionTokens)) tokens consommés")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.sub)
                }
                Spacer()
                if let rest = store.remainingTokens {
                    Text("reste ≈\(tokensFmt(rest))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                }
            }
        }
    }

    // MARK: - courbe live + allure (fusionnés : une seule lecture du débit)

    private var heartMonitor: some View {
        let live = store.burnHistory.last ?? store.burnPerMin
        let (emoji, label) = pace(live)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("TOKENS LIVE")
                    .font(AppFont.bold(11)).tracking(1.2)
                    .foregroundStyle(Theme.faint)
                Spacer()
                Text(emoji).font(.system(size: 16))
                Text("\(tokensFmt(Int(live))) tok/min")
                    .font(AppFont.bold(13))
                    .foregroundStyle(Theme.teal)
                Text("· \(label)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)
            }
            HeartRateView(values: store.burnHistory)
                .frame(height: 52)
            Text("moyenne 1 h : \(tokensFmt(Int(store.burnPerMin))) tok/min · \(tokensFmt(Int(store.burnPerMin * 60))) tok/h")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
        }
    }

    // MARK: - par modèle

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("PAR MODÈLE — BLOC COURANT")
                .font(AppFont.bold(11)).tracking(1.2)
                .foregroundStyle(Theme.faint)
            ForEach(store.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle().fill(row.color).frame(width: 8, height: 8)
                        Text(row.label)
                            .font(AppFont.bold(15))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Text("\(tokensFmt(row.tokens)) tok")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.sub)
                        Text(currency(row.cost))
                            .font(AppFont.bold(14))
                            .foregroundStyle(Theme.text)
                    }
                    bar(fraction: row.share, color: row.color, height: 12)
                }
            }
        }
    }

    // MARK: - prévision (Tokens restants · Tiendra · badge)

    private var predictionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PRÉVISION")
                .font(AppFont.bold(11)).tracking(1.2)
                .foregroundStyle(Theme.faint)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TOKENS RESTANTS")
                        .font(AppFont.bold(10)).tracking(1.0)
                        .foregroundStyle(Theme.faint)
                    Text(store.remainingTokens.map { "≈\(tokensFmt($0))" } ?? "—")
                        .font(AppFont.black(20))
                        .foregroundStyle(Theme.text)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("TIENDRA")
                        .font(AppFont.bold(10)).tracking(1.0)
                        .foregroundStyle(Theme.faint)
                    if let depletes = store.depletesAt {
                        let lasts = max(0, Int(depletes.timeIntervalSinceNow))
                        Text("\(lasts / 3600) h \(String(format: "%02d", (lasts % 3600) / 60))")
                            .font(AppFont.black(20))
                            .foregroundStyle(Theme.text)
                    } else {
                        Text("—").font(AppFont.black(20)).foregroundStyle(Theme.faint)
                    }
                }
            }
            if let depletes = store.depletesAt {
                if let reset = store.sub?.fiveHourResetsAt, depletes >= reset {
                    Label("Les tokens tiendront jusqu'au reset", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    Label("Épuisés vers \(hourFmt(depletes)) — avant le reset", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                }
            } else if (store.burnHistory.last ?? 0) < 1000 {
                // rien ne brûle : pas une mesure en cours, un vrai repos
                Label("À l'arrêt — aucun épuisement en vue", systemImage: "moon.zzz.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.sub)
            } else {
                Text("mesure en cours…")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
        }
    }

    // MARK: - semaine

    private var weekSection: some View {
        let pct = store.sub?.sevenDayPercent
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SEMAINE")
                    .font(AppFont.bold(11)).tracking(1.2)
                    .foregroundStyle(Theme.faint)
                Spacer()
                if let reset = store.sub?.sevenDayResetsAt {
                    Text("reset \(dayFmt(reset))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                }
                Text(pct.map { "\(Int($0)) %" } ?? "—")
                    .font(AppFont.bold(15))
                    .foregroundStyle(Theme.status(pct))
            }
            bar(fraction: (pct ?? 0) / 100, color: Theme.status(pct), height: 10)
            // à ce rythme : quand le plafond hebdo tombe (pente sur ≥ 4 h)
            if let cap = store.weekDepletesAt {
                let hitsBeforeReset = (store.sub?.sevenDayResetsAt).map { cap < $0 } ?? false
                Text("à ce rythme : plafond \(weekDayFmt(cap))")
                    .font(.system(size: 11.5, weight: hitsBeforeReset ? .semibold : .regular))
                    .foregroundStyle(hitsBeforeReset ? Theme.amber : Theme.faint)
            }
        }
    }

    // MARK: - coûts (ex-Journal, condensé)

    private var costSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("ÉQUIV. API — \(monthName().uppercased())")
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
                dailyChart
                HStack {
                    fact("30 JOURS", currency(store.days.reduce(0) { $0 + $1.cost }))
                    Spacer()
                    fact("MOYENNE / J", currency(store.days.isEmpty ? 0 : store.days.reduce(0) { $0 + $1.cost } / Double(store.days.count)))
                    Spacer()
                    fact("FIN DE MOIS ≈", currency(store.monthProjection))
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyse des transcripts…")
                        .font(.system(size: 12)).foregroundStyle(Theme.sub)
                }
            }
            if !store.monthTopProjects.isEmpty {
                Text("Projets : " + store.monthTopProjects.map { "\($0.0) \(currency($0.1))" }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            if !store.monthTopModels.isEmpty {
                Text("Modèles : " + store.monthTopModels.map { "\($0.0) \(currency($0.1))" }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
            }
        }
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
    private func pace(_ tokPerMin: Double) -> (String, String) {
        switch tokPerMin {
        case ..<10_000: return ("🚶", "Tranquille")
        case ..<150_000: return ("🚴", "Actif")
        case ..<600_000: return ("🚗", "Rapide")
        case ..<1_500_000: return ("✈️", "Très rapide")
        default: return ("🚀", "Extrême")
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

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(AppFont.bold(10)).tracking(1.0)
                .foregroundStyle(Theme.faint)
            Text(value)
                .font(AppFont.bold(15))
                .foregroundStyle(Theme.text)
        }
    }

    // MARK: - footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text("session \(currency(store.sessionCost)) · jour \(currency(store.dayCost))")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
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
                    .frame(width: max(height, geo.size.width * min(1, fraction)))
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

    private func countdown(to date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    private func hourFmt(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    private func dayFmt(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE HH:mm"; return f.string(from: d)
    }

    private func weekDayFmt(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE HH'h'"; return f.string(from: d)
    }

    private func monthName() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "MMMM"; return f.string(from: Date())
    }
}

// Tracé façon moniteur cardiaque : ligne teal avec léger glow, grille faible,
// point pulsant au bout. Un point toutes les 15 s, fenêtre ~12 min.
struct HeartRateView: View {
    let values: [Double]
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let slots = 48
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
