import AppKit
import SwiftUI

// UX Vibe Island intégrée à la topbar : l'ITEM de menubar est l'île (cadran +
// points de sessions, dessinés dans main.swift) ; son SURVOL déploie ce panneau
// sous la barre — sessions, choix fermés, répondre, saut Ghostty. Le clic garde
// le popover complet.
@MainActor
final class IslandPanel {
    static let width: CGFloat = 400

    private let panel: NSPanel
    private let store: UsageStore
    private var hideTimer: Timer?
    private(set) var mouseInside = false

    init(store: UsageStore) {
        self.store = store
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        let view = IslandView(store: store) { [weak self] inside in
            self?.mouseInside = inside
            if inside { self?.cancelHide() } else { self?.scheduleHide() }
        }
        panel.contentView = NSHostingView(rootView: view)
    }

    /** Déploie le panneau sous l'item de menubar (aligné sur lui, clampé à l'écran). */
    func show(under button: NSStatusBarButton) {
        cancelHide()
        guard let win = button.window, let screen = win.screen ?? NSScreen.main else { return }
        let sessions = min(max(store.workSessions.count, 1), 6)
        let height: CGFloat = 64 + CGFloat(sessions) * 72
        let anchor = win.frame // frame de l'item dans la barre
        var x = anchor.midX - Self.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - Self.width - 8)
        let y = anchor.minY - height - 4
        panel.setFrame(NSRect(x: x, y: y, width: Self.width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    func scheduleHide(after delay: TimeInterval = 0.35) {
        cancelHide()
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.mouseInside else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    func hideNow() { cancelHide(); panel.orderOut(nil) }

    private func cancelHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }
}

struct IslandView: View {
    @ObservedObject var store: UsageStore
    let onHoverChange: (Bool) -> Void
    @State private var replyText: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                let pct = store.livePercent ?? store.sub?.fiveHourPercent
                Text("Session \(pct.map { "\(Int($0)) %" } ?? "–")")
                    .font(NetwaFont.bold(13))
                    .foregroundStyle(Theme.status(pct))
                if !store.burnHistory.isEmpty {
                    MiniSpark(values: Array(store.burnHistory.suffix(20)))
                        .frame(width: 56, height: 14)
                }
                Spacer()
                if let last = store.burnHistory.last {
                    Text("\(fmt(last)) tok/min")
                        .font(.system(size: 11)).foregroundStyle(Theme.sub)
                }
            }
            if !store.axTrusted { AXBanner() }
            if store.workSessions.isEmpty {
                Text("Aucune session Claude Code ouverte.")
                    .font(.system(size: 12)).foregroundStyle(Theme.sub)
            }
            ForEach(store.workSessions.prefix(6)) { s in
                islandRow(s)
            }
        }
        .padding(12)
        .frame(width: IslandPanel.width, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(red: 0.05, green: 0.07, blue: 0.065).opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
        .onHover(perform: onHoverChange)
        .preferredColorScheme(.dark)
    }

    private func islandRow(_ s: WorkSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                DispatchQueue.global().async { WorkflowLoader.focus(s) }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(statusColor(s)).frame(width: 7, height: 7)
                    Text(s.name).font(NetwaFont.bold(12))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Text(s.statusLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusColor(s))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            if s.needsAction {
                HStack(spacing: 5) {
                    ForEach(s.options.prefix(3)) { option in
                        Button {
                            DispatchQueue.global().async { WorkflowLoader.sendChoice(option, to: s) }
                        } label: {
                            Text(option.isEscape ? "✕" : option.label)
                                .font(NetwaFont.bold(10.5))
                                .foregroundStyle(option.isEscape ? Theme.sub : Theme.bg)
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(option.isEscape ? Theme.track : Theme.teal))
                        }
                        .buttonStyle(.plain).focusEffectDisabled()
                    }
                    TextField("répondre…", text: Binding(
                        get: { replyText[s.id] ?? "" },
                        set: { replyText[s.id] = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.track))
                        .onSubmit {
                            let t = (replyText[s.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            replyText[s.id] = ""
                            DispatchQueue.global().async { WorkflowLoader.send(t, to: s) }
                        }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
    }

    private func fmt(_ v: Double) -> String {
        v >= 1_000_000 ? String(format: "%.1fM", v / 1_000_000)
            : v >= 1_000 ? String(format: "%.0fk", v / 1_000) : String(format: "%.0f", v)
    }

    private func statusColor(_ s: WorkSession) -> Color {
        switch s.status {
        case .working: return Theme.teal
        case .needsApproval: return Theme.amber
        case .needsInput: return Color(red: 0.35, green: 0.65, blue: 1.0)
        }
    }
}

// Sans Accessibilité, impossible de lire/cliquer les onglets Ghostty et de
// taper les réponses : on le DIT au lieu d'échouer en silence.
struct AXBanner: View {
    var body: some View {
        Button {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.amber)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Accessibilité requise pour piloter Ghostty")
                        .font(NetwaFont.bold(12)).foregroundStyle(Theme.text)
                    Text("Retire l'ancienne entrée ModelUsage (−) puis re-coche l'app — clic pour ouvrir les Réglages")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.sub)
                }
                Spacer()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.amber.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

// Mini sparkline du débit dans l'en-tête du panneau.
private struct MiniSpark: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxV = max(values.max() ?? 1, 1)
            Path { p in
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: w * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                                     y: h - 1 - (h - 2) * CGFloat(v / maxV))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            .stroke(Theme.teal.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
