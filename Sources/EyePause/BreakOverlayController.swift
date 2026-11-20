import AppKit
import Combine

private final class BreakPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class BreakOverlayController {
    private var panels: [NSPanel] = []
    private var countdownLabels: [NSTextField] = []
    private var subscription: AnyCancellable?
    private weak var model: EyePauseModel?
    var visiblePanelCount: Int { panels.filter { $0.isVisible }.count }
    var displayedCountdowns: [String] { countdownLabels.map { $0.stringValue } }

    func show(model: EyePauseModel) {
        if !panels.isEmpty { render(model.snapshot); return }
        guard case .takingBreak = model.snapshot.phase else { return }
        hide()
        self.model = model

        for screen in NSScreen.screens {
            let isPrimary = screen == NSScreen.main
            let panel = makePanel(for: screen, isPrimary: isPrimary)
            panel.orderFrontRegardless()
            panels.append(panel)
            if isPrimary { panel.makeKeyAndOrderFront(nil) }
        }

        // The model's monotonic deadline is the sole clock. No window timer.
        subscription = model.$snapshot.sink { [weak self] snapshot in
            self?.render(snapshot)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func hide() {
        subscription?.cancel()
        subscription = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        countdownLabels.removeAll()
    }

    private func makePanel(for screen: NSScreen, isPrimary: Bool) -> NSPanel {
        let panel = BreakPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.94)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = !isPrimary
        panel.contentView = makeContentView(isPrimary: isPrimary)
        return panel
    }

    private func makeContentView(isPrimary: Bool) -> NSView {
        let root = NSView()
        root.wantsLayer = true

        let symbol = NSImage(systemSymbolName: "binoculars.fill", accessibilityDescription: "看向远处") ?? NSImage()
        let icon = NSImageView(image: symbol)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 42, weight: .medium)
        icon.contentTintColor = .white

        let title = label("看看远处", font: .systemFont(ofSize: 34, weight: .semibold), color: .white)
        let countdown = label("0:20", font: .monospacedDigitSystemFont(ofSize: 58, weight: .medium), color: .white)
        countdownLabels.append(countdown)
        let subtitle = label("望向大约 6 米外，让眼睛放松", font: .systemFont(ofSize: 20), color: .lightGray)

        var arrangedViews: [NSView] = [icon, title, countdown, subtitle]
        if isPrimary {
            let skipButton = NSButton(title: "跳过这次休息", target: self, action: #selector(skipBreak))
            skipButton.bezelStyle = .rounded
            skipButton.keyEquivalent = "\u{1b}"
            arrangedViews.append(skipButton)
        }

        let stack = NSStackView(views: arrangedViews)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
        return root
    }

    private func label(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = font
        label.textColor = color
        label.alignment = .center
        return label
    }

    private func render(_ snapshot: TimerSnapshot) {
        guard case .takingBreak(let remaining) = snapshot.phase else { hide(); return }
        let text = model?.formatClock(remaining) ?? ""
        countdownLabels.forEach { $0.stringValue = text }
    }

    @objc func skipBreak() {
        model?.skipBreak()
        hide()
    }
}
