import AppKit
import Foundation
import SwiftUI

// Sessions Claude Code programmées (UX calquée sur Claude Code Usage Monitor) :
// à l'heure dite, ouvre un onglet Ghostty, `cd` dans le dossier et tape la
// commande. Persistance UserDefaults, tir vérifié toutes les 30 s.
// Nécessite Accessibilité + Automation (prompt macOS au 1er tir).
struct ClaudeSchedule: Codable, Identifiable, Equatable {
    var id = UUID()
    var time = "09:00"      // "HH:mm"
    var directory = ""      // ex: /Users/blizor/Developer/x
    var command = "claude"
    var enabled = false

    var fullCommand: String {
        directory.isEmpty ? command : "cd \(directory) && \(command)"
    }
}

enum ScheduleStore {
    private static let key = "claudeSchedules2" // v2 : + directory

    static func load() -> [ClaudeSchedule] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([ClaudeSchedule].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [ClaudeSchedule]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

@MainActor
final class Scheduler {
    private var timer: Timer?
    private var fired: [UUID: String] = [:] // id → jour+heure déjà tiré

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let now = f.string(from: Date())
        let dayKey = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date())) + now
        for s in ScheduleStore.load() where s.enabled && s.time == now {
            guard fired[s.id] != dayKey else { continue }
            fired[s.id] = dayKey
            mlog("schedule fire: \(s.time) \(s.fullCommand)")
            Self.openInGhostty(s.fullCommand)
        }
    }

    /// Nouvel onglet Ghostty + collage de la commande. Le collage (Cmd+V)
    /// remplace la frappe caractère par caractère : une frappe lancée avant
    /// que l'onglet soit prêt perdait le début (« cd /Users/ » avalé).
    nonisolated static func openInGhostty(_ command: String) {
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            let saved = pb.string(forType: .string)
            pb.clearContents()
            pb.setString(command, forType: .string)
            let script = """
            tell application "Ghostty" to activate
            delay 0.5
            tell application "System Events"
                keystroke "t" using command down
                delay 1.0
                keystroke "v" using command down
                delay 0.3
                key code 36
            end tell
            """
            DispatchQueue.global().async {
                Proc.run("/usr/bin/osascript", ["-e", script], timeout: 25)
                // le collage est fait : rendre son presse-papier à l'utilisateur
                if let saved {
                    DispatchQueue.main.async {
                        pb.clearContents()
                        pb.setString(saved, forType: .string)
                    }
                }
            }
        }
    }
}

// MARK: - contenu de la carte (le bouton « + » vit dans l'entête, PopoverView)

struct SchedulesList: View {
    /// Incrémenté par le « + » de l'entête → ajoute une ligne dépliée.
    @Binding var addTick: Int
    @State private var schedules = ScheduleStore.load()
    @State private var expanded: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if schedules.isEmpty {
                Text("Aucune session programmée")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            ForEach($schedules) { $s in
                row($s)
                if expanded == s.id { editor($s) }
            }
        }
        .onChange(of: addTick) {
            let new = ClaudeSchedule(directory: NSHomeDirectory())
            schedules.append(new)
            expanded = new.id
        }
    }

    // Ligne repliée : toggle · heure · commande · chevron · supprimer
    private func row(_ s: Binding<ClaudeSchedule>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: s.enabled)
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .onChange(of: s.wrappedValue.enabled) { ScheduleStore.save(schedules) }
            Text(s.wrappedValue.time)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.teal)
            Text(s.wrappedValue.command)
                .font(.system(size: 11))
                .foregroundStyle(s.wrappedValue.enabled ? Theme.text : Theme.faint)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    expanded = expanded == s.wrappedValue.id ? nil : s.wrappedValue.id
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(expanded == s.wrappedValue.id ? 180 : 0))
                    .foregroundStyle(Theme.sub)
            }
            .buttonStyle(.plain).focusEffectDisabled()
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    schedules.removeAll { $0.id == s.wrappedValue.id }
                    ScheduleStore.save(schedules)
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(Theme.red)
            }
            .buttonStyle(.plain).focusEffectDisabled()
        }
    }

    // Éditeur déplié : Heure · Dossier · Commande · Tester / Enregistrer
    private func editor(_ s: Binding<ClaudeSchedule>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                fieldLabel("Heure")
                TextField("09:00", text: s.time)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .frame(width: 44)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.track))
            }
            HStack(spacing: 8) {
                fieldLabel("Dossier")
                TextField("/Users/…", text: s.directory)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.track))
                Button {
                    chooseFolder(into: s)
                } label: {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.teal)
                }
                .buttonStyle(.plain).focusEffectDisabled()
                .help("Choisir le dossier…")
            }
            HStack(spacing: 8) {
                fieldLabel("Commande")
                TextField("claude", text: s.command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.track))
                Menu {
                    ForEach(Self.suggestions, id: \.1) { label, cmd in
                        Button(label) { s.wrappedValue.command = cmd }
                    }
                } label: {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.teal)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18)
                .help("Suggestions de commandes")
            }
            HStack {
                Button("Tester maintenant") {
                    Scheduler.openInGhostty(s.wrappedValue.fullCommand)
                }
                .buttonStyle(.plain).focusEffectDisabled()
                .font(AppFont.bold(11)).foregroundStyle(Theme.teal)
                Spacer()
                Button {
                    let t = s.wrappedValue.time.trimmingCharacters(in: .whitespaces)
                    guard t.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil,
                          !s.wrappedValue.command.trimmingCharacters(in: .whitespaces).isEmpty
                    else { return }
                    if t.count == 4 { s.wrappedValue.time = "0" + t }
                    ScheduleStore.save(schedules)
                    withAnimation(.easeOut(duration: 0.18)) { expanded = nil }
                } label: {
                    Text("Enregistrer")
                        .font(AppFont.bold(11))
                        .foregroundStyle(Theme.bg)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.teal))
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }
        }
        .padding(.leading, 4)
    }

    // Actions utiles prêtes à l'emploi (label → commande)
    private static let suggestions: [(String, String)] = [
        ("Session Claude", "claude"),
        ("Reprendre la dernière session", "claude --resume"),
        ("Session bypass permissions", "claude --dangerously-skip-permissions"),
        ("/reprendre (netwa, aligné prod)", "claude \"/reprendre\""),
        ("/recall (reprise archivée)", "claude \"/recall\""),
        ("Pull puis Claude", "git pull && claude"),
    ]

    private func chooseFolder(into s: Binding<ClaudeSchedule>) {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "Choisir"
        let current = s.wrappedValue.directory
        p.directoryURL = URL(fileURLWithPath: current.isEmpty ? NSHomeDirectory() : current)
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let url = p.url {
            s.wrappedValue.directory = url.path
        }
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.sub)
            .frame(width: 60, alignment: .leading)
    }
}
