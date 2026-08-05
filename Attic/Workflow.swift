import AppKit
import ApplicationServices
import Foundation

// Sessions Claude Code ouvertes : process `claude` → cwd (lsof) → transcript
// le plus récent du projet → nom + état déduits du contenu.
struct ChoiceOption: Identifiable {
    let label: String
    let key: String        // digit à taper ("1"…) ; vide si escape
    let isEscape: Bool

    var id: String { label + key }
}

struct WorkSession: Identifiable {
    enum Status { case working, needsInput, needsApproval }

    let id: String          // chemin du transcript
    let name: String
    let project: String     // basename du cwd
    let dir: String
    let status: Status
    let age: TimeInterval   // depuis la dernière écriture
    let pending: String?    // question / dernier message en attente
    let model: String?
    let options: [ChoiceOption]  // choix fermé (question à options, validation)
    // Titres possibles de l'onglet Ghostty : Claude Code met ses lignes `summary`
    // en titre de terminal — on les garde toutes pour matcher l'onglet.
    let titleCandidates: [String]

    var needsAction: Bool { status != .working }

    var statusLabel: String {
        switch status {
        case .working: return "travaille"
        case .needsInput: return "attend ta réponse"
        case .needsApproval: return "attend validation"
        }
    }
}

// Tout process externe passe par ici : un binaire qui ne rend pas la main
// (prompt TCC, lsof coincé) est tué au timeout au lieu de geler l'app.
enum Proc {
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> (status: Int32, output: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }

        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        var data = Data()
        let reader = DispatchQueue(label: "proc.read")
        reader.async { data = pipe.fileHandleForReading.readDataToEndOfFile() }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            WorkflowLoader.mlog("TIMEOUT \(path) \(args.first ?? "")")
            return nil
        }
        reader.sync {} // attend la fin de lecture
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

enum WorkflowLoader {
    static func load() -> [WorkSession] {
        var sessions: [WorkSession] = []
        var seenTranscripts = Set<String>()
        for cwd in claudeCwds() {
            let slug = cwd.map { $0.isLetter || $0.isNumber ? $0 : Character("-") }
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects/\(String(slug))")
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            // transcript le plus récent du projet = la session de ce process
            let candidates = files.filter { $0.pathExtension == "jsonl" }
                .sorted { (mtime($0) ?? .distantPast) > (mtime($1) ?? .distantPast) }
            for candidate in candidates {
                guard !seenTranscripts.contains(candidate.path) else { continue }
                seenTranscripts.insert(candidate.path)
                if let s = inspect(transcript: candidate, cwd: cwd) { sessions.append(s) }
                break
            }
        }
        return sessions.sorted { $0.age < $1.age }
    }

    // MARK: process → cwd

    // Une VRAIE session TUI = process `claude` au premier plan de son terminal
    // (stat avec « + », tty réel). Exclut : subagents/headless (tty ??) et
    // sessions suspendues par Ctrl+Z (stat T) — sinon on liste des fantômes.
    private static func claudeCwds() -> [String] {
        guard let out = run("/bin/ps", ["-axo", "pid=,tty=,stat=,args="]) else { return [] }
        var cwds: [String] = []
        for line in out.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int(parts[0]) else { continue }
            let tty = String(parts[1]), stat = String(parts[2])
            guard tty != "??", stat.contains("+") else { continue }
            let exe = parts[3].split(separator: " ").first.map(String.init) ?? ""
            guard (exe as NSString).lastPathComponent == "claude" else { continue }
            if let cwd = cwdOf(pid: pid) { cwds.append(cwd) }
        }
        return cwds
    }

    private static func cwdOf(pid: Int) -> String? {
        guard let out = run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { return nil }
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        Proc.run(path, args)?.output
    }

    private static func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: transcript → nom + état

    private static func inspect(transcript: URL, cwd: String) -> WorkSession? {
        guard let modified = mtime(transcript) else { return nil }
        let age = Date().timeIntervalSince(modified)
        // session considérée fermée si rien depuis 6 h
        guard age < 6 * 3600 else { return nil }

        let tail = readWindow(transcript, fromEnd: true, size: 131_072)
        let head = readWindow(transcript, fromEnd: false, size: 65_536)

        var model: String?
        var lastAssistantText: String?
        var pendingQuestion: String?
        var hasPendingToolUse = false
        var choiceOptions: [ChoiceOption] = []
        // Activité TEMPS RÉEL : ce que la session fait là, maintenant — la
        // description du dernier outil lancé (Bash/Task portent une phrase
        // d'action), sinon le fichier en cours d'édition.
        var activity: String?
        var firstAssistantDone = false
        var toolAlreadyAnswered = false
        var scanned = 0

        func activityFrom(_ block: [String: Any]) -> String? {
            guard let input = block["input"] as? [String: Any] else { return nil }
            if let d = input["description"] as? String, d.count > 5 { return d }
            if let f = input["file_path"] as? String {
                return "Édite \((f as NSString).lastPathComponent)"
            }
            if let p = input["pattern"] as? String { return "Cherche « \(p) »" }
            if let prompt = input["prompt"] as? String, prompt.count > 10 {
                return "Sous-agent : \(String(prompt.prefix(50)))"
            }
            return nil
        }

        for line in tail.split(separator: "\n").reversed() {
            scanned += 1
            if firstAssistantDone && (activity != nil || scanned > 400) { break }
            guard let obj = parse(line) else { continue }
            let type = obj["type"] as? String
            if type == "assistant", firstAssistantDone, activity == nil,
               let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                // messages assistants plus anciens : on ne cherche que l'activité
                for block in content where block["type"] as? String == "tool_use" {
                    if let a = activityFrom(block) { activity = a; break }
                }
                continue
            }
            if type == "assistant", let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                if model == nil { model = message["model"] as? String }
                for block in content {
                    switch block["type"] as? String {
                    case "tool_use":
                        if activity == nil { activity = activityFrom(block) }
                        hasPendingToolUse = true
                        let tool = block["name"] as? String ?? "outil"
                        if tool == "AskUserQuestion",
                           let input = block["input"] as? [String: Any],
                           let questions = input["questions"] as? [[String: Any]],
                           let first = questions.first,
                           let q = first["question"] as? String {
                            pendingQuestion = q
                            if let opts = first["options"] as? [[String: Any]] {
                                choiceOptions = opts.enumerated().compactMap { i, o in
                                    (o["label"] as? String).map { ChoiceOption(label: $0, key: "\(i + 1)", isEscape: false) }
                                }
                            }
                        } else if tool == "ExitPlanMode" {
                            pendingQuestion = "Plan prêt — à approuver"
                            choiceOptions = [
                                ChoiceOption(label: "Approuver le plan", key: "1", isEscape: false),
                                ChoiceOption(label: "Refuser", key: "", isEscape: true),
                            ]
                        } else if pendingQuestion == nil {
                            pendingQuestion = "Autorisation demandée : \(tool)"
                            choiceOptions = [
                                ChoiceOption(label: "Autoriser", key: "1", isEscape: false),
                                ChoiceOption(label: "Refuser", key: "", isEscape: true),
                            ]
                        }
                    case "text":
                        if lastAssistantText == nil, let t = block["text"] as? String,
                           t.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 {
                            lastAssistantText = t
                        }
                    default: break
                    }
                }
                firstAssistantDone = true
                continue // le scan continue uniquement pour trouver l'activité
            }
            // un tool_result plus récent que le dernier assistant = l'outil a
            // déjà tourné : rien de pendant, mais on continue pour model/activité
            if type == "user", !firstAssistantDone {
                toolAlreadyAnswered = true
                continue
            }
        }
        if toolAlreadyAnswered {
            hasPendingToolUse = false
            pendingQuestion = nil
            choiceOptions = []
        }

        let status: WorkSession.Status
        if age < 30 {
            status = .working
        } else if hasPendingToolUse {
            status = .needsApproval
        } else {
            status = .needsInput
        }

        let pending = pendingQuestion ?? (status == .working ? nil : lastAssistantText.map { clean($0, max: 160) })
        let titles = sessionTitles(head: head, tail: tail)
        // Nom temps réel : session au travail → l'ACTIVITÉ en cours ;
        // en attente → la tâche demandée.
        let name = (status == .working ? activity.map { clean($0, max: 64) } : nil)
            ?? titles.first ?? (cwd as NSString).lastPathComponent
        return WorkSession(id: transcript.path,
                           name: name,
                           project: (cwd as NSString).lastPathComponent,
                           dir: cwd, status: status, age: age,
                           pending: pending,
                           model: model.flatMap { Pricing.info(for: $0)?.label },
                           options: status == .working ? [] : choiceOptions,
                           titleCandidates: titles)
    }

    // Nom intelligent : summaries Claude Code si présentes, sinon la DERNIÈRE
    // vraie demande utilisateur (le travail en cours), sinon la première ;
    // les « continue », commandes slash, chemins et interruptions sont écartés.
    private static func sessionTitles(head: String, tail: String) -> [String] {
        var titles: [String] = []
        func push(_ s: String) {
            let cleaned = clean(s, max: 64)
            if !cleaned.isEmpty, !titles.contains(cleaned) { titles.append(cleaned) }
        }
        // 1) summaries (titres générés) — prioritaires
        for text in [tail, head] {
            for line in text.split(separator: "\n").reversed() {
                guard line.contains("\"summary\""), let obj = parse(line),
                      obj["type"] as? String == "summary",
                      let s = obj["summary"] as? String, !s.isEmpty else { continue }
                push(s)
                if titles.count >= 6 { return titles }
            }
        }
        // 2) demandes utilisateur : dernières (tail, travail en cours) puis premières (head)
        for (text, reversed) in [(tail, true), (head, false)] {
            let lines = text.split(separator: "\n")
            for line in (reversed ? Array(lines.reversed()) : Array(lines)) {
                guard line.contains("\"user\""), let obj = parse(line),
                      obj["type"] as? String == "user",
                      let message = obj["message"] as? [String: Any] else { continue }
                var t: String?
                if let s = message["content"] as? String { t = s }
                else if let blocks = message["content"] as? [[String: Any]] {
                    t = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.first
                }
                if let t, isMeaningfulPrompt(t) {
                    push(t)
                    break // une par zone suffit
                }
            }
        }
        return titles
    }

    // Une « vraie demande » : une phrase, pas une relance ni une commande.
    private static func isMeaningfulPrompt(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 15, t.count < 4000 else { return false }
        for prefix in ["<", "Caveat", "$", "/", "[", "Base directory", "text #", "# "] {
            if t.hasPrefix(prefix) { return false }
        }
        if t.contains("/Users/") || t.contains("/Volumes/") { return false }
        let lower = t.lowercased()
        for junk in ["continue", "vas-y", "go", "ok", "oui", "non", "merci", "fix it", "reprise"] {
            if lower == junk { return false }
        }
        return true
    }

    private static func parse(_ line: Substring) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    private static func readWindow(_ url: URL, fromEnd: Bool, size: UInt64) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        let total = (try? fh.seekToEnd()) ?? 0
        if fromEnd {
            try? fh.seek(toOffset: total > size ? total - size : 0)
            return (try? fh.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        } else {
            try? fh.seek(toOffset: 0)
            return (try? fh.read(upToCount: Int(size))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    private static func clean(_ s: String, max: Int) -> String {
        var collapsed = s
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "ultrathink", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count > max {
            // coupe sur une frontière de mot, pas au milieu
            let hard = String(collapsed.prefix(max))
            collapsed = (hard.lastIndex(of: " ").map { String(hard[..<$0]) } ?? hard) + "…"
        }
        return collapsed.prefix(1).uppercased() + collapsed.dropFirst()
    }

    // MARK: actions → Ghostty
    // Ghostty n'expose qu'UNE fenêtre AX ; les onglets sont des radio buttons
    // d'un tab group. On lit les titres, on matche en Swift, on clique l'onglet.

    private static let ghosttyID = "com.mitchellh.ghostty"

    static func mlog(_ s: String) {
        let line = "\(Date()) \(s)\n"
        let url = URL(fileURLWithPath: "/tmp/modelusage.log")
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // L'activation part IMMÉDIATEMENT (les appels AX peuvent bloquer sur une
    // autorisation macOS) ; la sélection d'onglet suit en arrière-plan.
    static func focus(_ session: WorkSession) {
        mlog("focus() \(session.name)")
        activateGhostty()
        DispatchQueue.global().async { selectTab(for: session) }
    }

    // Frappe uniquement si l'onglet de la session a été sélectionné —
    // sinon risque d'écrire dans le mauvais terminal → presse-papier.
    static func send(_ text: String, to session: WorkSession) {
        activateGhostty()
        let matched = selectTab(for: session)
        if matched {
            usleep(500_000)
            typeText(text)
            pressKey(36) // Entrée
        } else {
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }
    }

    // NON BRANCHÉ (blizor a préféré le focus simple) — split Ghostty ⟷ Chrome
    // conservé au cas où : dev server détecté via transcript, onglets dédupliqués.
    static func openSplit(for session: WorkSession) {
        mlog("openSplit \(session.project)")
        activateGhostty()
        // dimensions écran (main thread requis pour NSScreen)
        var frame = CGRect.zero, top: CGFloat = 25
        let readScreen = {
            if let s = NSScreen.main {
                frame = s.visibleFrame
                top = s.frame.maxY - s.visibleFrame.maxY
            }
        }
        if Thread.isMainThread { readScreen() } else { DispatchQueue.main.sync(execute: readScreen) }
        selectTab(for: session)

        let port = devPort(for: session)
        mlog("openSplit port=\(port.map(String.init) ?? "aucun")")

        let leftW = Int(frame.width / 2)
        let x0 = Int(frame.minX), y0 = Int(top), h = Int(frame.height)

        if let port {
            // Chrome : fermer les onglets localhost:port (doublons), ouvrir le frais
            let url = "http://localhost:\(port)"
            runScript("""
            tell application "Google Chrome"
                activate
                if (count of windows) = 0 then make new window
                repeat with w in windows
                    repeat with i from (count of tabs of w) to 1 by -1
                        set u to URL of tab i of w
                        if (u is "\(url)") or (u starts with "\(url)/") then close tab i of w
                    end repeat
                end repeat
                tell front window
                    make new tab with properties {URL:"\(url)"}
                    set bounds to {\(x0 + leftW), \(y0), \(x0 + leftW * 2), \(y0 + h)}
                end tell
            end tell
            """)
        }

        // Ghostty à gauche (via AX), puis focus clavier sur Claude
        runScript("""
        tell application "System Events" to tell process "Ghostty"
            set position of window 1 to {\(x0), \(y0)}
            set size of window 1 to {\(leftW), \(h)}
        end tell
        """)
        activateGhostty()
    }

    // dev server de la session, trois pistes dans l'ordre :
    // 1) dernier "localhost:PORT" mentionné dans le transcript (le plus fiable —
    //    le cwd du process claude est souvent le repo principal alors que le
    //    server tourne dans une worktree)
    // 2) dernier chemin de worktree cité dans le transcript → listener sur ce cwd
    // 3) matching cwd session ↔ cwd listener
    private static func devPort(for session: WorkSession) -> Int? {
        let tail = readWindow(URL(fileURLWithPath: session.id), fromEnd: true, size: 131_072)

        // 1) localhost:PORT le plus récent qui écoute vraiment
        if let regex = try? NSRegularExpression(pattern: #"localhost:(\d{4})"#) {
            let matches = regex.matches(in: tail, range: NSRange(tail.startIndex..., in: tail))
            var seen = Set<Int>()
            for m in matches.reversed() {
                guard let r = Range(m.range(at: 1), in: tail), let port = Int(tail[r]),
                      seen.insert(port).inserted else { continue }
                if isListening(port) {
                    mlog("port via transcript: \(port)")
                    return port
                }
            }
        }
        // 2) worktree citée dans le transcript
        if let regex = try? NSRegularExpression(pattern: #"(/(?:Volumes|Users)/[\w./-]+?)/(?:src|app|apps|packages|components)/"#) {
            let matches = regex.matches(in: tail, range: NSRange(tail.startIndex..., in: tail))
            var roots: [String] = []
            for m in matches.reversed() {
                if let r = Range(m.range(at: 1), in: tail) { roots.append(String(tail[r])) }
            }
            for root in roots {
                if let port = listenerPort(matchingDir: root) {
                    mlog("port via worktree \(root): \(port)")
                    return port
                }
            }
        }
        // 3) cwd de la session
        return listenerPort(matchingDir: session.dir)
    }

    private static func isListening(_ port: Int) -> Bool {
        Proc.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"], timeout: 5)
            .map { !$0.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    }

    private static func listenerPort(matchingDir dir: String) -> Int? {
        guard let out = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]) else { return nil }
        var pid = 0, command = ""
        var listeners: [(pid: Int, ports: [Int])] = []
        var current: [Int] = []
        func flush() {
            if pid > 0, !current.isEmpty,
               command.range(of: "node|next|bun|deno", options: .regularExpression) != nil {
                listeners.append((pid, current))
            }
            current = []
        }
        for line in out.split(separator: "\n") {
            switch line.first {
            case "p": flush(); pid = Int(line.dropFirst()) ?? 0
            case "c": command = String(line.dropFirst()).lowercased()
            case "n":
                if let portStr = line.split(separator: ":").last, let port = Int(portStr) {
                    current.append(port)
                }
            default: break
            }
        }
        flush()

        // match le plus spécifique : cwd du server préfixe du dir de la session ou l'inverse
        var best: (cwdLen: Int, ports: [Int])?
        for l in listeners {
            guard let cwd = cwdOf(pid: l.pid) else { continue }
            guard dir.hasPrefix(cwd) || cwd.hasPrefix(dir) else { continue }
            if cwd.count > (best?.cwdLen ?? -1) { best = (cwd.count, l.ports) }
        }
        let ports = (best?.ports ?? []).filter { (1024..<10000).contains($0) }
        return ports.first { (3000..<4000).contains($0) } ?? ports.min()
    }

    // Choix fermé : tape le chiffre de l'option + Entrée (ou Échap pour refuser)
    static func sendChoice(_ option: ChoiceOption, to session: WorkSession) {
        activateGhostty()
        let matched = selectTab(for: session)
        guard matched else { return }
        usleep(500_000)
        if option.isEscape {
            pressKey(53) // Échap
        } else {
            typeText(option.key)
            usleep(150_000)
            pressKey(36) // Entrée
        }
    }

    private static func activateGhostty() {
        DispatchQueue.main.async {
            // macOS 14+ : l'app active doit céder l'activation, sinon refus silencieux
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: ghosttyID)
            NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyID).first?
                .activate(from: .current, options: [.activateIgnoringOtherApps])
            mlog("activate: yield+activate posté")
        }
        // filet LaunchServices — insensible aux règles d'activation coopérative
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", ghosttyID]
        do { try p.run(); mlog("activate: open -b lancé") } catch { mlog("activate: open -b ÉCHEC \(error)") }
    }

    // MARK: accès aux onglets via l'API Accessibility (AUCUN Apple Event : seule
    // la permission Accessibilité — déjà accordée — est requise ; l'AppleScript
    // System Events exigeait l'Automation, jamais accordée → échec silencieux).

    private struct TabRef { let button: AXUIElement; let window: AXUIElement; let title: String }

    private static func axAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    private static func ghosttyTabs() -> [TabRef] {
        guard AXIsProcessTrusted() else { mlog("AX: Accessibilité non accordée"); return [] }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyID).first?.processIdentifier else { return [] }
        let app = AXUIElementCreateApplication(pid)
        guard let windows = axAttr(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var out: [TabRef] = []
        for w in windows {
            var foundTabs = false
            func walk(_ el: AXUIElement, depth: Int) {
                guard depth < 6 else { return }
                for c in (axAttr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    let role = axAttr(c, kAXRoleAttribute) as? String
                    if role == "AXRadioButton", let t = axAttr(c, kAXTitleAttribute) as? String, !t.isEmpty {
                        out.append(TabRef(button: c, window: w, title: t))
                        foundTabs = true
                    } else if role == "AXTabGroup" || role == "AXGroup" {
                        walk(c, depth: depth + 1)
                    }
                }
            }
            walk(w, depth: 0)
            if !foundTabs, let t = axAttr(w, kAXTitleAttribute) as? String, !t.isEmpty {
                out.append(TabRef(button: w, window: w, title: t)) // fenêtre sans onglets
            }
        }
        return out
    }

    @discardableResult
    private static func selectTab(for session: WorkSession) -> Bool {
        let tabs = ghosttyTabs()
        let titles = tabs.map(\.title)
        guard !titles.isEmpty else { mlog("selectTab: aucun onglet lisible"); return false }
        // 1) blizor nomme ses onglets avec le PORT du dev server (« agent 3000 »,
        //    « arbitrage what'sapp3020 ») : port de la session → onglet qui le contient.
        var matched: String?
        if let port = devPort(for: session), let t = titles.first(where: { $0.contains("\(port)") }) {
            matched = t
        }
        // 2) sinon titre ≈ candidats du transcript (égalité normalisée puis fuzzy)
        let candidates = session.titleCandidates + [session.project]
        guard let best = matched ?? bestMatch(titles: titles, candidates: candidates),
              let tab = tabs.first(where: { $0.title == best }) else {
            mlog("selectTab: pas de match — onglets \(titles) vs candidats \(candidates.prefix(3))")
            return false
        }
        mlog("selectTab: → \(best)")
        AXUIElementPerformAction(tab.button, kAXPressAction as CFString)
        AXUIElementPerformAction(tab.window, "AXRaise" as CFString)
        return true
    }

    // MARK: frappes clavier via CGEvent (Accessibilité seule, pas d'Automation)

    static func typeText(_ text: String) {
        for ch in text.unicodeScalars {
            var utf16 = Array(String(ch).utf16)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up?.post(tap: .cghidEventTap)
            usleep(8000)
        }
    }

    static func pressKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            ev?.flags = flags
            ev?.post(tap: .cghidEventTap)
            usleep(30000)
        }
    }

    // 1) égalité normalisée stricte (le titre d'onglet EST une summary Claude Code),
    // 2) sinon fuzzy : mots communs (≥3 lettres, sans accents) + bonus inclusion.
    private static func bestMatch(titles: [String], candidates: [String]) -> String? {
        func norm(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for candidate in candidates {
            if let exact = titles.first(where: { norm($0) == norm(candidate) && !candidate.isEmpty }) {
                return exact
            }
        }
        func words(_ s: String) -> Set<String> {
            Set(norm(s).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })
        }
        var best: (title: String, score: Int)?
        for title in Set(titles) {
            let tWords = words(title)
            guard !tWords.isEmpty else { continue }
            var score = 0
            for candidate in candidates where !candidate.isEmpty {
                score = max(score, tWords.intersection(words(candidate)).count * 2
                    + (norm(candidate).contains(norm(title)) || norm(title).contains(norm(candidate)) ? 3 : 0))
            }
            if score > 0, score > (best?.score ?? 0) { best = (title, score) }
        }
        return best?.title
    }

    @discardableResult
    private static func runScript(_ script: String) -> Bool {
        Proc.run("/usr/bin/osascript", ["-e", script], timeout: 15)?.status == 0
    }

    private static func runScriptOutput(_ script: String) -> String? {
        guard let r = Proc.run("/usr/bin/osascript", ["-e", script], timeout: 15), r.status == 0 else { return nil }
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
