import Foundation
import SwiftUI

struct ModelRow: Identifiable {
    let id: String
    let label: String
    let color: Color
    let tokens: Int
    let inTok: Int
    let outTok: Int
    let cacheTok: Int
    let cost: Double
    var share: Double // part du coût du bloc courant
}

struct DayCost: Identifiable {
    let id: Date
    let day: Date
    let cost: Double
}

@MainActor
final class UsageStore: ObservableObject {
    // Abonnement Claude Max 20× — à ajuster si le plan change
    static let subscriptionMonthly = 200.0
    static let subscriptionLabel = "Max 20×"

    @Published var sub: SubscriptionUsage?
    @Published var rows: [ModelRow] = []
    @Published var sessionTokens = 0
    // Tokens « réels » in+out (SANS cache reads) — c'est l'échelle lisible,
    // comparable au compteur de Claude Code Usage Monitor (~ /1M sur Max 20×).
    @Published var sessionIOTokens = 0     // bloc 5 h courant
    @Published var hourIOTokens = 0        // dernière heure écoulée
    @Published var sessionCost = 0.0
    @Published var dayCost = 0.0
    @Published var burnPerMin = 0.0        // tokens/min sur la dernière heure
    // Courbe « heart monitor » : un point par tick (1 Hz), fenêtre ~2 min.
    @Published var burnHistory: [Double] = []
    @Published var depletesAt: Date?       // projection épuisement session
    @Published var livePercent: Double?    // % session estimé en temps réel entre deux appels API
    // Plafond RÉEL du forfait, estimé depuis le % officiel de l'API :
    // limite = tokens comptés localement ÷ (pct/100). Recalé à chaque appel API.
    @Published var estimatedLimit: Int?
    @Published var lastRefresh: Date?

    // Journal
    @Published var journalReady = false
    @Published var days: [DayCost] = []          // 30 derniers jours
    @Published var monthCost = 0.0               // mois calendaire en cours
    @Published var monthProjection = 0.0         // extrapolation fin de mois
    @Published var monthTopProjects: [(String, Double)] = []
    @Published var monthTopModels: [(String, Double)] = []
    // Projection hebdo : à ce rythme, quand le plafond 7 j sera atteint.
    @Published var weekDepletesAt: Date?
    // Conso hebdo par modèle. Deux natures dans la même liste (cf. ModelCap) :
    // - officiel : plafond dédié publié par l'API (Fable = 50 % du forfait,
    //   pool partagé et pas une rallonge — support.claude.com art. 15424964) ;
    // - estimé : les modèles SANS plafond dédié (Opus, Sonnet…), dont la conso
    //   s'exprime en part du forfait hebdo tous modèles = part du coût 7 j local
    //   × % hebdo officiel.
    @Published var weekCaps: [ModelCap] = []
    @Published var fableWeekShare = 0.0    // part de Fable dans le coût 7 j
    @Published var weekShares: [String: Double] = [:] // part du coût 7 j par modèle
    private var weekSamples: [(Date, Double)] = []

    private nonisolated(unsafe) let scanner = TranscriptScanner()
    private var samples: [(Date, Double)] = []
    private var isRefreshing = false
    private var didFullScan = false
    private var lastJournal = Date.distantPast

    // Tout le travail scanner passe par ce guard : le scanner n'est PAS
    // thread-safe, il ne doit jamais tourner deux fois en parallèle.
    // includeAPI: false = scan local seul (tick 15 s, pas d'appel réseau —
    // l'endpoint OAuth rate-limite vite).
    private var refreshStartedAt: Date?

    func refresh(includeAPI: Bool = true) async {
        if isRefreshing {
            // watchdog : un refresh coincé >120 s ne doit jamais geler l'app pour de bon
            if let t = refreshStartedAt, Date().timeIntervalSince(t) > 120 {
                mlog("watchdog: refresh bloqué depuis \(Int(Date().timeIntervalSince(t))) s — déblocage")
                isRefreshing = false
            } else {
                return
            }
        }
        isRefreshing = true
        refreshStartedAt = Date()
        defer { isRefreshing = false; refreshStartedAt = nil }
        mlog("refresh start (api=\(includeAPI))")
        defer { mlog("refresh end") }

        // échec API (rate limit, réseau) → on garde la dernière valeur connue
        let apiResult = includeAPI ? await UsageAPI.fetch() : nil
        let fetched = apiResult ?? sub
        let apiFresh = apiResult != nil
        let scanner = self.scanner

        if !didFullScan {
            // Boot : cache disque → historique restauré + rebuild du live 24 h
            // en ~1 s. Sans cache : ancien chemin (24 h vite, puis 30 j).
            let cached = await Task.detached(priority: .utility) { scanner.loadCache() }.value
            if cached {
                await Task.detached(priority: .utility) { scanner.rebuildLive() }.value
            } else {
                await Task.detached(priority: .utility) { scanner.refresh(maxAgeHours: 24) }.value
                publishLive(fetched, apiFresh: apiFresh)
                await Task.detached(priority: .utility) { scanner.refresh(maxAgeHours: 720) }.value
            }
            didFullScan = true
        }
        await Task.detached(priority: .utility) { scanner.refresh(maxAgeHours: 720) }.value

        publishLive(fetched, apiFresh: apiFresh)
        // Journal + cache disque au plus une fois par minute : le coût/jour bouge
        // lentement, et ça garde le tick live (1 Hz) sans agrégat ni écriture.
        if Date().timeIntervalSince(lastJournal) > 60 {
            lastJournal = Date()
            aggregateJournal()
            journalReady = true
            await Task.detached(priority: .utility) { scanner.saveCache() }.value
        }
        checkAlerts()
    }

    /**
     * Tick live (1 Hz) : scan incrémental des seuls transcripts touchés récemment.
     * Pas de réseau (l'endpoint OAuth rate-limite), pas de journal, pas d'écriture
     * disque — ~10 ms hors main actor, c'est ce qui rend le monitor fluide.
     */
    func tick() async {
        guard didFullScan, !isRefreshing else { return }
        isRefreshing = true
        refreshStartedAt = Date()
        defer { isRefreshing = false; refreshStartedAt = nil }
        let scanner = self.scanner
        // 2 h : seul un fichier écrit récemment peut avoir de nouveaux octets.
        await Task.detached(priority: .utility) { scanner.refresh(maxAgeHours: 2) }.value
        publishLive(sub, apiFresh: false)
        // pas de mlog ici : à 1 Hz ça noierait le journal de debug
    }

    private func publishLive(_ fetched: SubscriptionUsage?, apiFresh: Bool) {
        if let pct = fetched?.fiveHourPercent, samples.last?.1 != pct || samples.isEmpty {
            samples.append((Date(), pct))
            samples.removeAll { $0.0 < Date().addingTimeInterval(-3600) }
            if let last = samples.last, samples.contains(where: { $0.1 > last.1 + 5 }) {
                samples = [last] // reset de bloc
            }
        }
        sub = fetched
        aggregate()
        updateLivePercent(apiFresh: apiFresh)
        updateBurnHistory()
        updateWeekProjection(apiFresh: apiFresh)
        lastRefresh = Date()
    }

    // MARK: alertes système — utiles sans ouvrir l'app

    private var notifiedThreshold = 0
    private var notifiedDepletion = false

    private func checkAlerts() {
        guard let pct = livePercent ?? sub?.fiveHourPercent else { return }
        if pct < 50 { notifiedThreshold = 0; notifiedDepletion = false } // nouveau bloc
        for threshold in [95, 80] where Int(pct) >= threshold && notifiedThreshold < threshold {
            notifiedThreshold = threshold
            Notifier.send(title: "Session à \(Int(pct)) %",
                          body: threshold == 95 ? "Presque à sec — reset \(resetLabel())."
                                                : "80 % du forfait consommés — reset \(resetLabel()).")
            break
        }
        if let depletes = depletesAt, let reset = sub?.fiveHourResetsAt {
            if depletes < reset, !notifiedDepletion {
                notifiedDepletion = true
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                Notifier.send(title: "Épuisement avant le reset",
                              body: "À ce rythme, tokens épuisés vers \(f.string(from: depletes)) (reset \(f.string(from: reset))).")
            } else if depletes >= reset {
                notifiedDepletion = false
            }
        }
    }

    private func resetLabel() -> String {
        guard let r = sub?.fiveHourResetsAt else { return "—" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return "à \(f.string(from: r))"
    }

    // Les tokens n'arrivent pas en continu : une réponse qui se termine écrit
    // 50k d'un coup. Un débit calculé d'un tick à l'autre serait donc un peigne
    // de pics et de zéros. On mesure sur une fenêtre glissante de 30 s du
    // compteur cumulatif, ré-échantillonnée à chaque tick : lisse et exact.
    private var burnSamples: [(date: Date, tokens: Int)] = []
    private static let burnWindow: TimeInterval = 30
    static let burnPoints = 120 // ~2 min à 1 Hz

    private func updateBurnHistory() {
        let now = Date(), cum = scanner.cumulativeTokens
        burnSamples.append((now, cum))
        burnSamples.removeAll { $0.date < now.addingTimeInterval(-2 * Self.burnWindow) }
        // référence = le plus récent échantillon assez vieux pour couvrir la fenêtre
        guard let ref = burnSamples.last(where: { now.timeIntervalSince($0.date) >= Self.burnWindow })
                ?? burnSamples.first else { return }
        let dt = now.timeIntervalSince(ref.date)
        guard dt > 0.5 else { return } // 1er échantillon : pas encore de débit
        burnHistory.append(max(0, Double(cum - ref.tokens) / dt * 60))
        if burnHistory.count > Self.burnPoints {
            burnHistory.removeFirst(burnHistory.count - Self.burnPoints)
        }
    }

    // % temps réel : base = dernier % API, interpolé entre deux appels avec les
    // tokens locaux (limite estimée = tokens_au_moment_du_sample / %). Approximatif
    // (les limites Anthropic pondèrent par modèle/cache) mais la dérive est
    // recalée à chaque appel API (60 s).
    private var apiBaseline: (pct: Double, tokens: Int)?

    private func updateLivePercent(apiFresh: Bool) {
        if apiFresh, let pct = sub?.fiveHourPercent {
            apiBaseline = (pct, sessionTokens)
        }
        if let base = apiBaseline, sessionTokens < base.tokens {
            apiBaseline = nil // reset de bloc
        }
        guard let base = apiBaseline, base.pct > 0, base.tokens > 0 else {
            livePercent = sub?.fiveHourPercent
            estimatedLimit = nil
            return
        }
        let limit = Double(base.tokens) / (base.pct / 100)
        let delta = Double(sessionTokens - base.tokens)
        livePercent = min(100, base.pct + delta / limit * 100)
        estimatedLimit = Int(limit)
    }

    /** Tokens restants estimés sur la fenêtre 5 h (forfait réel). */
    var remainingTokens: Int? {
        estimatedLimit.map { max(0, $0 - sessionTokens) }
    }

    private func aggregate() {
        let now = Date()
        let blockStart: Date
        if let reset = sub?.fiveHourResetsAt {
            blockStart = reset.addingTimeInterval(-5 * 3600)
        } else {
            let recent = scanner.entries.filter { $0.date > now.addingTimeInterval(-5 * 3600) }
            if let first = recent.map(\.date).min() {
                blockStart = Date(timeIntervalSince1970: (first.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
            } else {
                blockStart = now
            }
        }

        struct Agg { var tokens = 0; var inTok = 0; var outTok = 0; var cacheTok = 0; var cost = 0.0 }
        var byModel: [String: Agg] = [:]
        var sessTokens = 0, hourTokens = 0
        var sessIO = 0, hourIO = 0
        var sessCost = 0.0, dCost = 0.0
        var weekCost = 0.0, fableCost = 0.0
        var weekCostByLabel: [String: Double] = [:]
        let dayStart = Calendar.current.startOfDay(for: now)
        let hourAgo = now.addingTimeInterval(-3600)
        let weekStart = sub?.sevenDayResetsAt.map { $0.addingTimeInterval(-7 * 24 * 3600) }
            ?? now.addingTimeInterval(-7 * 24 * 3600)

        for e in scanner.entries {
            if e.date >= dayStart { dCost += e.cost }
            if e.date >= hourAgo {
                hourTokens += e.totalTokens
                hourIO += e.input + e.output
            }
            if e.date >= weekStart {
                weekCost += e.cost
                if let info = Pricing.info(for: e.model) {
                    weekCostByLabel[info.label, default: 0] += e.cost
                }
                if e.model.hasPrefix("claude-fable") || e.model.hasPrefix("claude-mythos") {
                    fableCost += e.cost
                }
            }
            guard e.date >= blockStart else { continue }
            guard let info = Pricing.info(for: e.model) else { continue }
            sessTokens += e.totalTokens
            sessIO += e.input + e.output
            sessCost += e.cost
            var agg = byModel[info.label] ?? Agg()
            agg.tokens += e.totalTokens
            agg.inTok += e.input
            agg.outTok += e.output
            agg.cacheTok += e.cache5m + e.cache1h + e.cacheRead
            agg.cost += e.cost
            byModel[info.label] = agg
        }

        sessionTokens = sessTokens
        sessionIOTokens = sessIO
        hourIOTokens = hourIO
        sessionCost = sessCost
        dayCost = dCost
        burnPerMin = Double(hourTokens) / 60.0

        let colorFor: (String) -> Color = { label in
            Pricing.table.first { $0.label == label }?.color ?? .gray
        }
        rows = byModel.map { label, agg in
            ModelRow(id: label, label: label, color: colorFor(label), tokens: agg.tokens,
                     inTok: agg.inTok, outTok: agg.outTok, cacheTok: agg.cacheTok,
                     cost: agg.cost, share: sessCost > 0 ? agg.cost / sessCost : 0)
        }
        .sorted { $0.cost > $1.cost }

        fableWeekShare = weekCost > 0 ? fableCost / weekCost : 0
        weekShares = weekCost > 0 ? weekCostByLabel.mapValues { $0 / weekCost } : [:]
        var caps = sub?.weekCaps ?? []   // plafonds dédiés officiels (Fable)
        if let week = sub?.sevenDayPercent {
            // API muette sur le plafond Fable : l'estimer (2 × part × % hebdo).
            if caps.isEmpty, fableWeekShare > 0 {
                caps.append(ModelCap(name: "Fable", percent: min(100, 2 * fableWeekShare * week),
                                     official: false))
            }
            // Modèles sans plafond dédié : leur conso = part du forfait hebdo.
            for (label, share) in weekShares where share > 0.005
                && !caps.contains(where: { label.hasPrefix($0.name) || $0.name.hasPrefix(label) }) {
                caps.append(ModelCap(name: label, percent: min(100, share * week), official: false))
            }
        }
        weekCaps = caps.sorted { $0.percent > $1.percent }

        depletesAt = projectDepletion(now: now, sessionTokens: sessTokens)
    }

    private func aggregateJournal() {
        let cal = Calendar.current
        let now = Date()
        days = scanner.dailyCosts
            .map { DayCost(id: $0.key, day: $0.key, cost: $0.value) }
            .sorted { $0.day < $1.day }

        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        monthCost = days.filter { $0.day >= monthStart }.reduce(0) { $0 + $1.cost }
        let elapsed = max(1.0, now.timeIntervalSince(monthStart) / 86400)
        let daysInMonth = Double(cal.range(of: .day, in: .month, for: now)!.count)
        monthProjection = monthCost / elapsed * daysInMonth

        // top projets / modèles du mois courant
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"
        let mk = f.string(from: now) + "|"
        func top(_ dict: [String: Double]) -> [(String, Double)] {
            dict.filter { $0.key.hasPrefix(mk) }
                .map { (String($0.key.dropFirst(mk.count)), $0.value) }
                .sorted { $0.1 > $1.1 }
                .prefix(3).map { $0 }
        }
        monthTopProjects = top(scanner.projectCosts)
        monthTopModels = top(scanner.modelCosts)
    }

    // Pente du % hebdo → date estimée du plafond. ≥ 4 h d'écart pour une pente fiable.
    private func updateWeekProjection(apiFresh: Bool) {
        guard apiFresh, let pct = sub?.sevenDayPercent else { return }
        weekSamples.append((Date(), pct))
        weekSamples.removeAll { $0.0 < Date().addingTimeInterval(-48 * 3600) }
        if let last = weekSamples.last, weekSamples.contains(where: { $0.1 > last.1 + 5 }) {
            weekSamples = [last] // reset hebdo
        }
        guard let first = weekSamples.first, let last = weekSamples.last,
              last.0.timeIntervalSince(first.0) > 4 * 3600, last.1 > first.1, last.1 < 100 else {
            weekDepletesAt = nil
            return
        }
        let slopePerSec = (last.1 - first.1) / last.0.timeIntervalSince(first.0)
        weekDepletesAt = Date().addingTimeInterval((100 - last.1) / slopePerSec)
    }

    private func projectDepletion(now: Date, sessionTokens: Int) -> Date? {
        guard let pct = sub?.fiveHourPercent, pct > 0, pct < 100 else { return nil }
        if let first = samples.first, let last = samples.last,
           last.0.timeIntervalSince(first.0) > 180, last.1 > first.1 {
            let slopePerSec = (last.1 - first.1) / last.0.timeIntervalSince(first.0)
            return now.addingTimeInterval((100 - last.1) / slopePerSec)
        }
        guard burnPerMin > 0, sessionTokens > 0 else { return nil }
        let estimatedLimit = Double(sessionTokens) / (pct / 100)
        let remaining = estimatedLimit * (1 - pct / 100)
        return now.addingTimeInterval(remaining / burnPerMin * 60)
    }
}
