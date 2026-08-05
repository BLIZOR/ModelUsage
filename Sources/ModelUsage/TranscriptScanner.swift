import Foundation

struct UsageEntry {
    let date: Date
    let model: String
    let input: Int
    let output: Int
    let cache5m: Int
    let cache1h: Int
    let cacheRead: Int
    let cost: Double

    var totalTokens: Int { input + output + cache5m + cache1h + cacheRead }
}

// Scan incrémental des transcripts ~/.claude/projects/**/*.jsonl.
// Une réponse API = plusieurs lignes avec le même message.id + requestId
// et le même bloc usage → dédup obligatoire.
// Thread : appelé hors main actor (Task.detached), un seul appel à la fois
// (guard isRefreshing côté store).
final class TranscriptScanner: @unchecked Sendable {
    private var offsets: [String: UInt64] = [:]
    private var seen = Set<String>()
    private(set) var entries: [UsageEntry] = []       // fenêtre 24 h (live)
    private(set) var dailyCosts: [Date: Double] = [:] // jour (startOfDay) → coût équiv. API
    // Coûts du mois par projet et par modèle — clé "yyyy-MM|nom".
    private(set) var projectCosts: [String: Double] = [:]
    private(set) var modelCosts: [String: Double] = [:]
    // Compteur cumulatif jamais purgé — sert au débit instantané (courbe live).
    private(set) var cumulativeTokens = 0

    private let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    // MARK: cache disque — évite de relire 30 j de JSONL (>1 GB) à chaque boot

    private struct ScanCache: Codable {
        var offsets: [String: UInt64]
        var dailyCosts: [String: Double]
        var projectCosts: [String: Double]
        var modelCosts: [String: Double]
    }

    private static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ModelUsage/scan-cache.json")

    // 🚨 Fuseau LOCAL obligatoire : les clés de dailyCosts sont des
    // `Calendar.current.startOfDay` (minuit local). Un ISO8601DateFormatter
    // relisait "2026-08-05" en minuit UTC → 2 h d'écart → au rechargement du
    // cache chaque journée se dédoublait en deux buckets (deux barres pour le
    // même jour, moyenne/j fausse).
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /** Charge le cache. `true` = historique restauré, seul le live 24 h est à reconstruire. */
    func loadCache() -> Bool {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let c = try? JSONDecoder().decode(ScanCache.self, from: data) else { return false }
        offsets = c.offsets
        projectCosts = c.projectCosts
        modelCosts = c.modelCosts
        let f = Self.dayKeyFormatter
        for (k, v) in c.dailyCosts { if let d = f.date(from: k) { dailyCosts[d, default: 0] += v } }
        return true
    }

    func saveCache() {
        let f = Self.dayKeyFormatter
        // deux Date distinctes peuvent formater le même jour → fusion, jamais fatal
        let c = ScanCache(offsets: offsets,
                          dailyCosts: Dictionary(dailyCosts.map { (f.string(from: $0.key), $0.value) },
                                                 uniquingKeysWith: +),
                          projectCosts: projectCosts, modelCosts: modelCosts)
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL)
    }

    /**
     * Reconstruit UNIQUEMENT la fenêtre live 24 h (entries) après restauration du
     * cache : relit les fichiers récents sans toucher aux agrégats ni aux offsets
     * (leurs octets ont déjà nourri l'historique lors des sessions précédentes).
     */
    func rebuildLive() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        guard let en = fm.enumerator(at: projectsDir,
                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in en {
            guard url.pathExtension == "jsonl",
                  let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = rv.contentModificationDate, mtime > cutoff else { continue }
            // seulement les octets DÉJÀ agrégés (≤ offset persisté) : les nouveaux
            // seront lus par le refresh incrémental, qui alimente aussi l'historique
            let limit = offsets[url.path] ?? 0
            guard limit > 0 else { continue }
            scan(url: url, from: 0, upTo: limit, entriesOnly: true)
        }
    }

    // maxAgeHours : 24 au 1er passage (live rapide), 720 ensuite (journal 30 j).
    // Les offsets rendent les passages suivants incrémentaux.
    func refresh(maxAgeHours: Double) {
        let fm = FileManager.default
        let fileCutoff = Date().addingTimeInterval(-maxAgeHours * 3600)
        guard let en = fm.enumerator(at: projectsDir,
                                     includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = rv.contentModificationDate, mtime > fileCutoff,
                  let size = rv.fileSize else { continue }
            let key = url.path
            let offset = offsets[key] ?? 0
            guard UInt64(size) > offset else { continue }
            scan(url: url, from: offset)
            offsets[key] = UInt64(size)
        }
        let liveCutoff = Date().addingTimeInterval(-24 * 3600)
        entries.removeAll { $0.date < liveCutoff }
        let dayCutoff = Calendar.current.startOfDay(for: Date().addingTimeInterval(-31 * 24 * 3600))
        dailyCosts = dailyCosts.filter { $0.key >= dayCutoff }
        // ne garder que le mois courant et le précédent
        let months = Set([monthKey(Date()), monthKey(Date().addingTimeInterval(-31 * 24 * 3600))])
        projectCosts = projectCosts.filter { k, _ in months.contains(String(k.prefix(7))) }
        modelCosts = modelCosts.filter { k, _ in months.contains(String(k.prefix(7))) }
    }

    // appelé une fois par ligne scannée : instancier le formatter ici coûtait
    // plus cher que le parsing JSON lui-même
    private let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f
    }()

    private func monthKey(_ d: Date) -> String { monthFormatter.string(from: d) }

    /** Nom de projet lisible depuis le dossier slug du transcript. */
    private func projectName(of url: URL) -> String {
        let slug = url.deletingLastPathComponent().lastPathComponent
        let parts = slug.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        guard let last = parts.last else { return slug }
        if last.count < 5, parts.count >= 2 {
            return parts.suffix(2).joined(separator: "-")
        }
        return last
    }

    private func scan(url: URL, from offset: UInt64, upTo: UInt64? = nil, entriesOnly: Bool = false) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        let raw: Data? = upTo.map { end in
            end > offset ? (try? fh.read(upToCount: Int(end - offset))) ?? Data() : Data()
        } ?? (try? fh.readToEnd())
        guard let data = raw, !data.isEmpty else { return }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let liveCutoff = Date().addingTimeInterval(-24 * 3600)
        let usageMarker = Data("\"usage\"".utf8)
        let calendar = Calendar.current

        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            defer { start = end < data.endIndex ? data.index(after: end) : data.endIndex }
            let line = data[start..<end]
            guard line.count > 50 else { continue }
            guard line.range(of: usageMarker) != nil else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  !model.hasPrefix("<"),
                  let usage = message["usage"] as? [String: Any],
                  let ts = obj["timestamp"] as? String,
                  let date = iso.date(from: ts) else { continue }

            let msgId = message["id"] as? String ?? ""
            let reqId = obj["requestId"] as? String ?? ""
            if !msgId.isEmpty || !reqId.isEmpty {
                guard seen.insert(msgId + ":" + reqId).inserted else { continue }
            }

            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cacheCreateTotal = usage["cache_creation_input_tokens"] as? Int ?? 0
            var cache5m = 0, cache1h = 0
            if let cc = usage["cache_creation"] as? [String: Any] {
                cache5m = cc["ephemeral_5m_input_tokens"] as? Int ?? 0
                cache1h = cc["ephemeral_1h_input_tokens"] as? Int ?? 0
            }
            if cache5m + cache1h == 0 { cache5m = cacheCreateTotal }
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

            guard let info = Pricing.info(for: model) else { continue }
            let cost = Pricing.cost(price: info.price, input: input, output: output,
                                    cache5m: cache5m, cache1h: cache1h, cacheRead: cacheRead)

            if !entriesOnly {
                dailyCosts[calendar.startOfDay(for: date), default: 0] += cost
                let mk = monthKey(date)
                projectCosts["\(mk)|\(projectName(of: url))", default: 0] += cost
                modelCosts["\(mk)|\(info.label)", default: 0] += cost
            }
            cumulativeTokens += input + output + cache5m + cache1h + cacheRead

            if date >= liveCutoff {
                entries.append(UsageEntry(date: date, model: model, input: input, output: output,
                                          cache5m: cache5m, cache1h: cache1h, cacheRead: cacheRead,
                                          cost: cost))
            }
        }
    }
}
