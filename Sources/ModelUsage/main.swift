import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = UsageStore()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NetwaFont.register()
        Notifier.requestAuthorization()
        // Prompt Accessibilité si absente (signature stable → à accorder UNE fois)
        let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        mlog("launch — AX trusted: \(AXIsProcessTrustedWithOptions(axOpts))")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.gaugeIcon(pct: nil)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingController(rootView: PopoverView(store: store))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting

        Task { await self.refresh(includeAPI: true) }
        // scan local toutes les 15 s (menubar temps réel), API toutes les 60 s
        var tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            tick += 1
            guard let self else { return }
            let t = tick
            Task { @MainActor in
                // API strictement toutes les 60 s — l'endpoint rate-limite
                // agressivement, un retry plus rapide entretient le blocage
                await self.refresh(includeAPI: t % 4 == 0)
            }
        }
    }

    @MainActor
    private func updateGauge() {
        let pct = store.livePercent ?? store.sub?.fiveHourPercent
        statusItem.button?.image = Self.gaugeIcon(pct: pct)
        statusItem.button?.title = ""
    }

    @MainActor
    private func refresh(includeAPI: Bool) async {
        await store.refresh(includeAPI: includeAPI)
        updateGauge()
    }

    // Mini-logo de menubar : anneau de progression avec le % à l'intérieur.
    private static func gaugeIcon(pct: Double?) -> NSImage {
        let teal = NSColor(red: 0, green: 0.831, blue: 0.667, alpha: 1)
        let color: NSColor = pct.map {
            $0 >= 90 ? .systemRed : $0 >= 75 ? .systemOrange : teal
        } ?? .tertiaryLabelColor
        let side: CGFloat = 20
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let center = NSPoint(x: side / 2, y: side / 2)
            let radius: CGFloat = 8.4

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.8
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            track.stroke()

            if let p = pct, p > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: 90, endAngle: 90 - 360 * min(p, 100) / 100,
                              clockwise: true)
                arc.lineWidth = 1.8
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }

            let text = pct.map { "\(Int($0))" } ?? "–"
            let fontSize: CGFloat = text.count >= 3 ? 6.5 : 8.5
            let str = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ])
            let s = str.size()
            str.draw(at: NSPoint(x: center.x - s.width / 2, y: center.y - s.height / 2 - 0.5))

            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
                Task { await self.refresh(includeAPI: false) }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
