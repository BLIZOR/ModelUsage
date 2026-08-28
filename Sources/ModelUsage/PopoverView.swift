import ServiceManagement
import SwiftUI

// Structure calquée sur Claude Code Usage Monitor : titre centré (teal),
// cartes « Session actuelle / Token usage / Burn rate / Prédiction », puis
// semaine (hebdo + plafond Fable) et économie. Jauges fines, chiffres bruts,
// détails repliés. Panel borderless : fond noir translucide + radius 24.
struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @State private var showChart = false
    @State private var weekMode = false // toggle carte session : bloc 5 h ↔ hebdo
    @State private var addScheduleTick = 0
    // Hauteur mesurée du bloc au-dessus du fold (header → Économie) : la
    // fenêtre se cale dessus, les réglages restent invisibles sans scroll,
    // et le mode Semaine agrandit la fenêtre tout seul.
    @State private var foldHeight: CGFloat = 420

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                foldContent
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FoldHeightKey.self, value: g.size.height)
                    })
                // — sous le fold —
                card(header: {
                    HStack {
                        Text("Ouvrir au login")
                            .font(AppFont.bold(12))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        LaunchAtLoginToggle()
                    }
                }) { EmptyView() }
                card(header: {
                    HStack {
                        Text("Sessions Claude programmées")
                            .font(AppFont.bold(12))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) { addScheduleTick += 1 }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.teal)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }) { SchedulesList(addTick: $addScheduleTick) }
            }
            .padding(14)
        }
        .onPreferenceChange(FoldHeightKey.self) { foldHeight = $0 }
        // 14 de padding haut + 8 d'air : la card suivante (à +10) reste cachée
        .frame(width: 336, height: foldHeight + 22, alignment: .leading)
        .background {
            ZStack {
                VisualBlur()
                Theme.bg.opacity(0.45)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
    }

    private var foldContent: some View {
        VStack(alignment: .leading, spacing: 10) {
                header
                card(header: {
                    // toggle segmenté : deux pills dans une pill de fond
                    HStack(spacing: 2) {
                        titleButton("Session actuelle", active: !weekMode) { weekMode = false }
                        titleButton("Semaine", active: weekMode) { weekMode = true }
                    }
                    .padding(3)
                    .background(Capsule().fill(Theme.track))
                    .frame(maxWidth: .infinity)
                }) { sessionContent }
                card("Burn rate (dernière heure)") { burnContent }
                card("Prédiction") {
                    verdictLine(sessionVerdict.0, color: sessionVerdict.1, ok: sessionVerdict.2)
                }
                card("Économie \(monthName())") { costContent }
        }
    }

    // MARK: - header (titre centré, teal — quit discret à droite)

    private var header: some View {
        VStack(spacing: 3) {
            ZStack {
                HStack(spacing: 7) {
                    Text("ModelUsage")
                        .font(AppFont.black(15))
                        .foregroundStyle(Theme.teal)
                    if store.sub?.subscriptionType != nil {
                        Text(UsageStore.subscriptionLabel)
                            .font(AppFont.bold(10))
                            .foregroundStyle(Theme.teal)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.teal.opacity(0.14)))
                    }
                }
                .frame(maxWidth: .infinity)
                HStack {
                    Spacer()
                    Button { NSApp.terminate(nil) } label: {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.sub)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Quitter ModelUsage")
                }
            }
            if store.sub?.fiveHourResetsAt == nil {
                // un seul état explicite plutôt que des « — » muets partout
                Text("⏳ % officiels en attente")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - carte session (bloc 5 h officiel ↔ conso hebdo, jauge empilée)

    /// Pill du toggle de période : sélection remplie, l'autre transparente.
    private func titleButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeOut(duration: 0.18)) { action() } }) {
            Text(label)
                .font(AppFont.bold(11))
                .foregroundStyle(active ? Theme.text : Theme.sub)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(active ? Color.white.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var sessionContent: some View {
        let pct = weekMode ? store.sub?.sevenDayPercent
                           : (store.livePercent ?? store.sub?.fiveHourPercent)
        let color = Theme.status(pct)
        let shares = weekMode ? store.weekShares
                              : Dictionary(store.rows.map { ($0.label, $0.share) },
                                           uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: 9) {
            // Début · Durée · Reset (resets_at API — fenêtre 5 h ou 7 j)
            if let reset = weekMode ? store.sub?.sevenDayResetsAt : store.sub?.fiveHourResetsAt {
                let window: TimeInterval = weekMode ? 7 * 24 * 3600 : 5 * 3600
                let started = reset.addingTimeInterval(-window)
                let elapsed = max(0, Int(Date().timeIntervalSince(started)))
                HStack {
                    // 7 j : juste le jour (« mer. 6 ») — l'heure alourdit
                    sessionFact("DÉBUT", weekMode ? shortDayFmt(started) : hourFmt(started), .leading)
                    Spacer(minLength: 14)
                    sessionFact("DURÉE", elapsedLabel(elapsed), .center)
                    Spacer(minLength: 14)
                    sessionFact("RESET", weekMode ? shortDayFmt(reset) : hourFmt(reset), .trailing)
                }
            }
            // jauge fine empilée : chaque segment = la part d'un modèle
            HStack(spacing: 10) {
                stackedBar(totalPct: pct ?? 0, shares: shares, height: 6)
                    .overlay(alignment: .leading) {
                        // mode hebdo : repère blanc = part de la fenêtre écoulée
                        if weekMode, let e = weekElapsedFraction {
                            GeometryReader { geo in
                                Rectangle()
                                    .fill(Color.white.opacity(0.55))
                                    .frame(width: 2)
                                    .offset(x: geo.size.width * e)
                            }
                        }
                    }
                Text(pct.map { "\(Int($0)) %" } ?? "—")
                    .font(AppFont.bold(12))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.5), value: pct.map { Int($0) })
            }
            .help(weekMode ? weeklyDetail : sessionDetail)
            legend(shares: shares)
            // Conso hebdo par modèle. En mode session on ne garde que les
            // plafonds DÉDIÉS (Fable) : un quota à sec décide de ce qu'on peut
            // lancer TOUT DE SUITE, il ne doit pas se cacher derrière l'onglet
            // Semaine. En mode Semaine, tous les modèles.
            let caps = weekMode ? store.weekCaps : store.weekCaps.filter { isDedicated($0) }
            if !caps.isEmpty {
                Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 1)
                Text(weekMode ? "CONSO HEBDO PAR MODÈLE" : "PLAFOND HEBDO DÉDIÉ")
                    .font(AppFont.bold(9)).tracking(1.0)
                    .foregroundStyle(Theme.faint)
                // pas de ligne d'alerte : un 100 % rouge sur barre pleine se lit
                // tout seul, la phrase ne fait que répéter la jauge
                ForEach(caps) { cap in capRow(cap) }
            }
            // verdict d'allure hebdo (ex-carte Semaine)
            if weekMode {
                verdictLine(weeklyVerdict.0,
                            color: weeklyColor(pct: store.sub?.sevenDayPercent,
                                               elapsed: weekElapsedFraction),
                            ok: weeklyVerdict.1)
            }
        }
    }

    /// Seul Fable a un plafond hebdo DÉDIÉ (50 % du forfait). Les autres modèles
    /// n'ont pas de quota propre : on affiche leur part du forfait hebdo.
    private func isDedicated(_ cap: ModelCap) -> Bool { cap.name.hasPrefix("Fable") }

    /// Une ligne « modèle · quota » + sa jauge. Un plafond dédié se colore à
    /// l'état (teal / ambre / rouge) — c'est un compte à rebours. Une simple
    /// part du forfait garde la couleur du modèle : 40 % d'Opus n'est pas une
    /// alerte, juste une répartition.
    private func capRow(_ cap: ModelCap) -> some View {
        let dedicated = isDedicated(cap)
        let color = dedicated ? Theme.status(cap.percent) : capColor(cap.name)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(capColor(cap.name)).frame(width: 5, height: 5)
                Text(capLabel(cap))
                    .font(AppFont.bold(11)).foregroundStyle(Theme.text)
                Spacer()
                Text("\(cap.official ? "" : "≈")\(Int(cap.percent)) %")
                    .font(AppFont.bold(12)).foregroundStyle(color)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.5), value: Int(cap.percent))
            }
            bar(fraction: cap.percent / 100, color: color, height: 6)
        }
        .help(capDetail(cap))
    }

    /// « Fable » (display_name API) ou « Opus 5 » (label Pricing) → sa couleur.
    private func capColor(_ name: String) -> Color {
        Pricing.table.first { $0.label.hasPrefix(name) || name.hasPrefix($0.label) }?.color ?? Theme.teal
    }

    private func capLabel(_ cap: ModelCap) -> String {
        isDedicated(cap) ? "\(cap.name) · plafond 50 %" : "\(cap.name) · part du hebdo"
    }

    private func elapsedLabel(_ s: Int) -> String {
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        return d > 0 ? "\(d) j \(h) h" : "\(h) h \(String(format: "%02d", m))"
    }

    /// Une seule barre, remplie jusqu'au % total, découpée aux couleurs des
    /// modèles au prorata de leur part du coût.
    private func stackedBar(totalPct: Double, shares: [String: Double], height: CGFloat) -> some View {
        let fill = min(1, totalPct / 100)
        let segments: [(color: Color, w: Double)] = modelRows.compactMap { row in
            let s = shares[row.label] ?? 0
            return s > 0 ? (row.color, s * fill) : nil
        }
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        Rectangle()
                            .fill(seg.color)
                            .frame(width: max(0, geo.size.width * seg.w))
                    }
                }
                .clipShape(Capsule())
                .animation(.easeOut(duration: 0.5), value: totalPct)
            }
        }
        .frame(height: height)
    }

    /// Mini-légende des couleurs de la jauge empilée, avec la part de chacun.
    private func legend(shares: [String: Double]) -> some View {
        HStack(spacing: 12) {
            ForEach(modelRows.filter { (shares[$0.label] ?? 0) > 0.005 }) { row in
                HStack(spacing: 3) {
                    Circle().fill(row.color).frame(width: 5, height: 5)
                    Text(row.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.faint)
                    Text("\(Int((shares[row.label] ?? 0) * 100)) %")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.sub)
                }
            }
        }
    }


    /// (texte, couleur, ok) — ok pilote l'icône ✓ / ⚠
    private var sessionVerdict: (String, Color, Bool) {
        guard let depletes = store.depletesAt else {
            return store.hourIOTokens / 60 < 50
                ? ("à l'arrêt — rien ne brûle", Theme.sub, true) : ("mesure en cours…", Theme.faint, true)
        }
        if let reset = store.sub?.fiveHourResetsAt, depletes >= reset {
            return ("la session tiendra jusqu'au reset", Theme.teal, true)
        }
        let lasts = max(0, Int(depletes.timeIntervalSinceNow))
        return ("épuisée dans \(lasts / 3600) h \(String(format: "%02d", (lasts % 3600) / 60)) — avant le reset",
                Theme.amber, false)
    }

    private var sessionDetail: String {
        var s = "pondéré tous tokens : \(tokensFmt(store.sessionTokens))"
        if let limit = store.estimatedLimit { s += " / ≈\(tokensFmt(limit))" }
        if let rest = store.remainingTokens { s += " · reste ≈\(tokensFmt(rest))" }
        return s + "\néquiv. API : \(currency(store.sessionCost)) ce bloc · \(currency(store.dayCost)) aujourd'hui"
    }

    // MARK: - carte burn rate (moyenne sur la dernière heure, in+out)

    private var burnContent: some View {
        let perMin = store.hourIOTokens / 60
        // débit instantané = dernier point de la fenêtre glissante 30 s (1 Hz)
        let live = Int(store.burnHistory.last ?? 0)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(Theme.paceEmoji(perMin)).font(.system(size: 15))
                Text("\(grouped(live)) tokens/min")
                    .font(AppFont.bold(13))
                    .foregroundStyle(Theme.teal)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.4), value: live)
                Spacer()
            }
            burnSparkline
                .frame(height: 34)
                .padding(.vertical, 2)
            Text("moyenne 1 h : \(grouped(perMin)) tokens/min · \(grouped(store.hourIOTokens)) tokens")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.sub)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.4), value: store.hourIOTokens)
        }
        .help("tokens réels (input + output, cache exclu) — courbe : 2 dernières minutes, 1 point/s")
    }

    /// Courbe live du débit (fenêtre 2 min, 1 Hz). Échelle Y auto sur le max
    /// visible ; la courbe se remplit de droite à gauche tant que l'historique
    /// n'a pas ses 120 points.
    private var burnSparkline: some View {
        let pts = store.burnHistory
        return GeometryReader { geo in
            let maxY = max(pts.max() ?? 1, 1)
            let n = UsageStore.burnPoints
            let step = geo.size.width / CGFloat(max(n - 1, 1))
            // aligné à droite : le présent est au bord droit, le passé glisse à gauche
            let x0 = geo.size.width - CGFloat(max(pts.count - 1, 0)) * step
            let y = { (v: Double) in geo.size.height * (1 - CGFloat(v / maxY) * 0.92) }
            let line = Path { p in
                for (i, v) in pts.enumerated() {
                    let pt = CGPoint(x: x0 + CGFloat(i) * step, y: y(v))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
            }
            let fill = Path { p in
                p.addPath(line)
                p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                p.addLine(to: CGPoint(x: x0, y: geo.size.height))
                p.closeSubpath()
            }
            ZStack {
                if pts.count > 1 {
                    fill.fill(Theme.teal.opacity(0.14))
                    line.stroke(Theme.teal, style: StrokeStyle(lineWidth: 1.5,
                                                               lineCap: .round, lineJoin: .round))
                } else {
                    Text("mesure en cours…")
                        .font(.system(size: 10)).foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: - hebdo (affiché dans la carte session, mode « Semaine »)

    /// Part de la fenêtre 7 j déjà écoulée (0…1). nil tant que l'API n'a rien dit.
    private var weekElapsedFraction: Double? {
        guard let reset = store.sub?.sevenDayResetsAt else { return nil }
        return min(1, max(0, 1 - reset.timeIntervalSinceNow / (7 * 24 * 3600)))
    }

    /**
     * La couleur ne dit pas « combien reste-t-il » mais « suis-je en avance sur
     * mon budget ». 60 % consommés à mi-semaine = normal (vert) ; les mêmes 60 %
     * avec encore 4 jours avant le reset = rouge. Repère blanc = part de la
     * fenêtre 7 j écoulée, la barre devrait rester à sa hauteur.
     */
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

    private var weeklyVerdict: (String, Bool) {
        guard let pct = store.sub?.sevenDayPercent, let reset = store.sub?.sevenDayResetsAt else {
            return ("en attente des % officiels", true)
        }
        let left = remainingLabel(until: reset)
        if pct >= 95 { return ("plafond hebdo atteint — reset dans \(left)", false) }
        guard let elapsed = weekElapsedFraction, elapsed > 0.03 else { return ("reset dans \(left)", true) }
        if pct / 100 / elapsed < 1.05 { return ("dans le budget — reste \(left) avant reset", true) }
        if let cap = store.weekDepletesAt, cap < reset {
            return ("trop vite : plafond \(weekDayFmt(cap)), reset dans \(left)", false)
        }
        return ("\(Int(pct)) % brûlés en \(Int(elapsed * 100)) % de la semaine — reste \(left)", false)
    }

    private var weeklyDetail: String {
        var s = "repère blanc = part de la fenêtre 7 j écoulée"
        if let e = weekElapsedFraction { s += " (\(Int(e * 100)) %)" }
        if let reset = store.sub?.sevenDayResetsAt { s += "\nreset \(dayFmt(reset))" }
        if let cap = store.weekDepletesAt { s += "\nà ce rythme : plafond \(weekDayFmt(cap))" }
        return s
    }

    private func capDetail(_ cap: ModelCap) -> String {
        var s = isDedicated(cap)
            ? "Fable est limité à 50 % de la limite hebdo du forfait (pool partagé, pas une rallonge)."
            : "\(cap.name) n'a pas de plafond dédié : ce % est sa part du forfait hebdo déjà brûlée."
        if isDedicated(cap) {
            s += String(format: "\nFable = %.0f %% du coût 7 j local", store.fableWeekShare * 100)
        }
        if let pct = store.sub?.sevenDayPercent {
            s += String(format: "\nhebdo tous modèles %.0f %%", pct)
        }
        if let reset = store.sub?.sevenDayResetsAt { s += " · reset \(dayFmt(reset))" }
        s += cap.official ? "\n% officiel (API, limite dédiée \(cap.name))"
                          : "\nestimation coût-pondérée sur les transcripts locaux"
        return s
    }

    private func remainingLabel(until d: Date) -> String {
        let s = max(0, Int(d.timeIntervalSinceNow))
        let days = s / 86400, hours = (s % 86400) / 3600
        return days > 0 ? "\(days) j \(hours) h" : "\(hours) h"
    }

    // MARK: - par modèle (déplié depuis la carte token usage)

    // Toujours les mêmes 3 lignes — les modèles que Claude Code pilote — même à
    // 0 %, pour que la lecture ne bouge pas d'un bloc à l'autre. Tout autre
    // modèle qui aurait consommé s'ajoute à la suite.
    private static let pinnedModels = ["Opus 5", "Fable 5", "Haiku"]

    private var modelRows: [ModelRow] {
        let byLabel = Dictionary(store.rows.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = Self.pinnedModels.map { label in
            byLabel[label] ?? ModelRow(id: label, label: label,
                                       color: Pricing.table.first { $0.label == label }?.color ?? .gray,
                                       tokens: 0, inTok: 0, outTok: 0, cacheTok: 0, cost: 0, share: 0)
        }
        return pinned + store.rows.filter { !Self.pinnedModels.contains($0.label) }
    }

    // MARK: - carte économie du mois

    private var costContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.journalReady {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(currency(store.monthCost))
                        .font(AppFont.black(17))
                        .foregroundStyle(Theme.teal)
                    Text("×\(String(format: "%.1f", store.monthCost / UsageStore.subscriptionMonthly)) l'abonnement")
                        .font(AppFont.bold(11))
                        .foregroundStyle(Theme.text)
                    Spacer()
                }
                .help(costDetail)
                disclosure("Détail 14 jours", isOn: $showChart) { dailyChart }
            } else {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Analyse des transcripts…")
                        .font(.system(size: 11)).foregroundStyle(Theme.sub)
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
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(days) { d in
                let today = Calendar.current.isDateInToday(d.day)
                let dayNum = Calendar.current.component(.day, from: d.day)
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Theme.teal.opacity(today ? 0.95 : 0.45))
                        .frame(height: max(3, 40 * d.cost / maxCost))
                    // étiqueter clairsemé : lisible, pas un mur de chiffres
                    Text(today || dayNum == 1 || dayNum % 5 == 0 ? "\(dayNum)" : " ")
                        .font(.system(size: 8, weight: today ? .bold : .regular))
                        .foregroundStyle(today ? Theme.teal : Theme.faint)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 54, alignment: .bottom)
        .help(costDetail)
    }

    // MARK: - briques UI

    /// Carte titrée (titre blanc bold, façon Claude Code Usage Monitor).
    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        card(header: {
            Text(title)
                .font(AppFont.bold(12))
                .foregroundStyle(Theme.text)
        }, content: content)
    }

    /// Variante avec entête libre (ex : titres-toggle de la carte session).
    private func card(@ViewBuilder header: () -> some View,
                      @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header()
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised))
    }

    /// Ligne de statut : ✓ teal quand tout va bien, ⚠ sinon.
    private func verdictLine(_ text: String, color: Color, ok: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
    }

    /// Repli minimal (chevron + label teal), façon « Model Breakdown ».
    private func disclosure(_ label: String, isOn: Binding<Bool>,
                            @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isOn.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isOn.wrappedValue ? 90 : 0))
                    Text(label).font(AppFont.bold(11))
                }
                .foregroundStyle(Theme.teal)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            if isOn.wrappedValue { content() }
        }
    }

    private func sessionFact(_ label: String, _ value: String, _ align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 2) {
            Text(label)
                .font(AppFont.bold(9)).tracking(1.0)
                .foregroundStyle(Theme.faint)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

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
    // instancier un DateFormatter/NumberFormatter à chaque passage coûte plus
    // que tout le reste.
    private static let groupedF: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f
    }()
    private func grouped(_ n: Int) -> String {
        Self.groupedF.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static func fmt(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = pattern
        return f
    }
    private static let hourF = fmt("HH:mm")
    private static let dayF = fmt("EEE d · HH'h'")
    private static let shortDayF = fmt("EEE d")
    private static let weekDayF = fmt("EEEE HH'h'")
    private static let monthF = fmt("MMMM yyyy")

    private func hourFmt(_ d: Date) -> String { Self.hourF.string(from: d) }
    private func dayFmt(_ d: Date) -> String { Self.dayF.string(from: d) }
    private func shortDayFmt(_ d: Date) -> String { Self.shortDayF.string(from: d) }
    private func weekDayFmt(_ d: Date) -> String { Self.weekDayF.string(from: d) }
    private func monthName() -> String { Self.monthF.string(from: Date()) }
}

// Hauteur du bloc au-dessus du fold (mesurée par GeometryReader).
struct FoldHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// Flou système derrière la fenêtre (le panel est transparent).
struct VisualBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// Ouvrir au login (mécanisme système) — le libellé est le titre de la carte
struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("", isOn: $enabled)
        .labelsHidden()
        .toggleStyle(.switch).controlSize(.small)
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
