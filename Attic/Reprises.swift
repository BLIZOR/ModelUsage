import AppKit
import Foundation

// Conversations à reprendre : ~/.claude/reprise/<projet>.txt, une commande
// par fichier ("cd <dir> && claude --resume <uuid>"), écrite par le hook
// UserPromptSubmit de Claude Code.
struct Reprise: Identifiable {
    let id: String        // nom du fichier sans extension
    let command: String
    let directory: String
    let modified: Date
    let summary: String?  // travail restant, extrait du transcript de la session

    var projectName: String { id }
    var shortDir: String {
        (directory as NSString).abbreviatingWithTildeInPath
    }
}

enum RepriseLoader {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/reprise")

    static func load() -> [Reprise] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files
            .filter { $0.pathExtension == "txt" }
            .compactMap { url -> Reprise? in
                guard let command = try? String(contentsOf: url, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !command.isEmpty else { return nil }
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                var directory = ""
                if command.hasPrefix("cd "), let range = command.range(of: " && ") {
                    directory = String(command[command.index(command.startIndex, offsetBy: 3)..<range.lowerBound])
                }
                return Reprise(id: url.deletingPathExtension().lastPathComponent,
                               command: command, directory: directory, modified: mtime,
                               summary: taskSummary(command: command))
            }
            .sorted { $0.modified > $1.modified }
    }

    // Travail restant : ligne « Pour terminer : … » du protocole de reprise
    // dans le transcript de la session, sinon le dernier message assistant.
    private static func taskSummary(command: String) -> String? {
        guard let r = command.range(of: "--resume ") else { return nil }
        let uuid = String(command[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uuid.isEmpty, let transcript = findTranscript(uuid: uuid) else { return nil }

        // queue du fichier seulement — les transcripts peuvent faire des centaines de Mo
        guard let fh = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let window: UInt64 = 262_144
        try? fh.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var lastAssistant: String?
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"assistant\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            let joined = texts.joined(separator: " ")
            guard joined.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else { continue }
            if let pr = joined.range(of: "Pour terminer :") {
                var task = String(joined[pr.upperBound...])
                for stop in ["///", "\n"] {
                    if let s = task.range(of: stop) { task = String(task[..<s.lowerBound]) }
                }
                return clean(task)
            }
            if lastAssistant == nil { lastAssistant = joined }
        }
        return lastAssistant.map { clean($0) }
    }

    private static func findTranscript(uuid: String) -> URL? {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(uuid).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func clean(_ s: String) -> String {
        let collapsed = s
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(220))
    }

    // Nouvel onglet Ghostty + commande tapée — via CGEvent (Accessibilité seule,
    // pas d'Automation). Sans permission : Ghostty devant + commande au presse-papier.
    static func openInGhostty(_ reprise: Reprise) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", "com.mitchellh.ghostty"]
        try? p.run()
        usleep(600_000)
        guard AXIsProcessTrusted() else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(reprise.command, forType: .string)
            return
        }
        WorkflowLoader.pressKey(17, flags: .maskCommand) // Cmd+T : nouvel onglet
        usleep(500_000)
        WorkflowLoader.typeText(reprise.command)
        WorkflowLoader.pressKey(36) // Entrée
    }
}
