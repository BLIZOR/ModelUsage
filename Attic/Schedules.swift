import AppKit
import Foundation
import ServiceManagement
import SwiftUI

// Sessions Claude Code programmées : à l'heure dite, ouvre un onglet Ghostty
// et tape la commande (quotidien). Persistance UserDefaults, tir vérifié
// chaque 30 s par l'AppDelegate. Nécessite l'Accessibilité (comme Reprises).
struct ClaudeSchedule: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: String      // "HH:mm"
    var command: String   // ex: cd ~/Developer/x && claude
    var enabled = true
}

enum ScheduleStore {
    private static let key = "claudeSchedules"

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
    private var fired: [UUID: String] = [:] // id → "yyyy-MM-dd HH:mm" déjà tiré

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
    }

    private func tick() {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let now = f.string(from: Date())
        let dayKey = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date())) + now
        for s in ScheduleStore.load() where s.enabled && s.time == now {
            guard fired[s.id] != dayKey else { continue }
            fired[s.id] = dayKey
            WorkflowLoader.mlog("schedule fire: \(s.time) \(s.command)")
            let command = s.command
            DispatchQueue.global().async {
                RepriseLoader.openInGhostty(Reprise(id: "schedule", command: command,
                                                    directory: "", modified: Date(), summary: nil))
            }
        }
    }
}

// MARK: - UI (section de l'onglet Reprises)

struct SchedulesSection: View {
    @State private var schedules = ScheduleStore.load()
    @State private var newTime = "09:00"
    @State private var newCommand = "claude"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SESSIONS PROGRAMMÉES")
                .font(NetwaFont.bold(11)).tracking(1.2)
                .foregroundStyle(Theme.faint)
            if schedules.isEmpty {
                Text("Aucune session programmée — l'heure venue, un onglet Ghostty s'ouvre avec la commande.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.faint)
            }
            ForEach($schedules) { $s in
                HStack(spacing: 8) {
                    Toggle("", isOn: $s.enabled)
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .onChange(of: s.enabled) { ScheduleStore.save(schedules) }
                    Text(s.time)
                        .font(NetwaFont.bold(13)).foregroundStyle(Theme.teal)
                    Text(s.command)
                        .font(.system(size: 12)).foregroundStyle(s.enabled ? Theme.text : Theme.faint)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        schedules.removeAll { $0.id == s.id }
                        ScheduleStore.save(schedules)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11)).foregroundStyle(Theme.faint)
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 8) {
                TextField("09:00", text: $newTime)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 48)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.track))
                TextField("commande (ex: cd ~/dev/x && claude)", text: $newCommand)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.track))
                Button {
                    let t = newTime.trimmingCharacters(in: .whitespaces)
                    guard t.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil,
                          !newCommand.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    let padded = t.count == 4 ? "0" + t : t
                    schedules.append(ClaudeSchedule(time: padded, command: newCommand))
                    ScheduleStore.save(schedules)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18)).foregroundStyle(Theme.teal)
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }
        }
    }
}

// MARK: - Ouvrir au login

struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle(isOn: $enabled) {
            Text("Ouvrir au login")
                .font(.system(size: 12)).foregroundStyle(Theme.sub)
        }
        .toggleStyle(.switch).controlSize(.mini)
        .onChange(of: enabled) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                WorkflowLoader.mlog("launch-at-login: \(error)")
                enabled = SMAppService.mainApp.status == .enabled
            }
        }
    }
}
