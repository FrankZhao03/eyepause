import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    var isVisible: Bool { window?.isVisible == true }
    func close() { window?.close() }
    func minimize() { window?.miniaturize(nil) }

    func show(model: EyePauseModel, preferences: Preferences) {
        if window == nil {
            let hostingController = NSHostingController(
                rootView: SettingsView(model: model, preferences: preferences)
            )
            let window = NSWindow(contentViewController: hostingController)
            window.title = "EyePause 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.center()
            self.window = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class WaterReminderController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private weak var model: EyePauseModel?
    var isVisible: Bool { panel?.isVisible == true }
    func close() { panel?.performClose(nil) }

    func show(model: EyePauseModel) {
        guard panel?.isVisible != true else { return }
        self.model = model

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 196),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "喝口水"
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: WaterReminderView(
            model: model,
            dismiss: { [weak self] in self?.dismiss() }
        ))
        panel.center()
        self.panel = panel
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.snoozeWater()
    }
}

private struct WaterReminderView: View {
    @ObservedObject var model: EyePauseModel
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "drop.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tint)
            Text("喝口水吧")
                .font(.title3.weight(.semibold))
            Text("到喝水时间了，记得补充水分。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("10 分钟后提醒") {
                    model.snoozeWater()
                    dismiss()
                }
                .buttonStyle(.bordered)
                Button("我喝了") {
                    model.acknowledgeWater()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 340, height: 196)
    }
}
