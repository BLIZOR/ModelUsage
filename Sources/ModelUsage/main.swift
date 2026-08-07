import AppKit
import SwiftUI

// Fenêtre borderless : le fond translucide + corner radius vivent dans la vue
// SwiftUI, le panel lui-même est transparent.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var clickMonitor: Any?
    private var sizeObs: NSKeyValueObservation?
    private let store = UsageStore()
    private let scheduler = Scheduler()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestAuthorization()
        // Prompt Accessibilité si absente (signature stable → à accorder UNE fois)
        let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        mlog("launch — AX trusted: \(AXIsProcessTrustedWithOptions(axOpts))")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.burnIcon(emoji: "🚶", pct: nil)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        let hosting = NSHostingController(rootView: PopoverView(store: store))
        hosting.sizingOptions = .preferredContentSize
        panel = FloatingPanel(contentRect: .zero,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false // défaut NSPanel = true → fenêtre invisible (app .accessory jamais active)
        // .fullScreenAuxiliary : sans lui le panel ne peut pas rejoindre un
        // Space fullscreen (Ghostty plein écran) → isVisible mais jamais affiché
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        // les replis (« par modèle », chart) changent la hauteur du contenu :
        // suivre preferredContentSize et redimensionner ancré en haut
        sizeObs = hosting.observe(\.preferredContentSize) { [weak self] vc, _ in
            let size = vc.preferredContentSize
            Task { @MainActor in self?.resizePanel(to: size) }
        }

        scheduler.start()
        Task { await self.refresh(includeAPI: true) }
        // Tick 1 Hz : scan incrémental local (~10 ms) → monitor live fluide.
        // Popover fermé : 1 tick sur 5 suffit pour le cadran menubar.
        // API + journal strictement toutes les 60 s — l'endpoint rate-limite
        // agressivement, un retry plus rapide entretient le blocage.
        var tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            tick += 1
            guard let self else { return }
            let t = tick
            Task { @MainActor in
                if t % 60 == 0 {
                    await self.refresh(includeAPI: true)
                } else if self.panel.isVisible || t % 5 == 0 {
                    await self.store.tick()
                    self.updateGauge()
                }
            }
        }
        // le timer doit continuer à tourner pendant qu'on interagit avec le popover
        RunLoop.main.add(timer!, forMode: .common)
    }

    private var gaugeShown: String?

    @MainActor
    private func updateGauge() {
        let emoji = Theme.paceEmoji(store.hourIOTokens / 60)
        let pct = (store.livePercent ?? store.sub?.fiveHourPercent).map { Int($0) }
        let key = "\(emoji)|\(pct.map(String.init) ?? "—")"
        guard gaugeShown != key else { return } // pas de redraw pour rien
        gaugeShown = key
        statusItem.button?.image = Self.burnIcon(emoji: emoji, pct: pct)
        statusItem.button?.title = ""
    }

    @MainActor
    private func refresh(includeAPI: Bool) async {
        await store.refresh(includeAPI: includeAPI)
        updateGauge()
    }

    // Icône menubar : emoji d'allure + % de la session en cours (blanc).
    private static func burnIcon(emoji: String, pct: Int?) -> NSImage {
        let h: CGFloat = 20
        let emojiW: CGFloat = 18, gap: CGFloat = 3
        let emojiStr = NSAttributedString(string: emoji,
                                          attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let pctStr = NSAttributedString(string: pct.map { "\($0) %" } ?? "—", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let w = emojiW + gap + pctStr.size().width + 2
        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let es = emojiStr.size()
            emojiStr.draw(at: NSPoint(x: (emojiW - es.width) / 2, y: (h - es.height) / 2))
            let ps = pctStr.size()
            pctStr.draw(at: NSPoint(x: emojiW + gap, y: (h - ps.height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func togglePopover() {
        if panel.isVisible {
            closePanel()
        } else if let button = statusItem.button, let btnWindow = button.window {
            Task { await self.refresh(includeAPI: false) }
            panel.layoutIfNeeded()
            // la fenêtre du status item EST l'icône, déjà en coordonnées écran
            let btnFrame = btnWindow.frame
            let size = panel.contentViewController?.view.fittingSize ?? panel.frame.size
            var origin = NSPoint(x: btnFrame.midX - size.width / 2, y: btnFrame.minY - size.height - 8)
            // ne jamais déborder de l'écran — et si la menubar est en auto-hide
            // (app fullscreen), la status window est HORS écran (y négatif) :
            // on ancre alors en haut de l'écran visible
            // window hors écran → .screen nil ; app accessory → .main nil aussi
            if let screen = btnWindow.screen ?? NSScreen.main ?? NSScreen.screens.first {
                let vf = screen.visibleFrame
                if btnFrame.minY < vf.minY || btnFrame.minY > screen.frame.maxY {
                    origin.y = vf.maxY - size.height - 8
                }
                origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
                origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
            }
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            panel.makeKeyAndOrderFront(nil)
            mlog("panel show — frame \(panel.frame) visible \(panel.isVisible)")
            // clic hors de la fenêtre → fermeture (comportement popover)
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.closePanel() }
            }
        }
    }

    private func resizePanel(to size: NSSize) {
        guard panel.isVisible, size.width > 0, size.height > 0,
              abs(panel.frame.height - size.height) > 0.5 else { return }
        var f = panel.frame
        f.origin.y = f.maxY - size.height // le bord haut ne bouge pas
        f.size = size
        panel.setFrame(f, display: true)
    }

    private func closePanel() {
        panel.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
