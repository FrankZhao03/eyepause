import SwiftUI
import AppKit

@MainActor
final class EyePauseAppDelegate: NSObject, NSApplicationDelegate {
    let preferences: Preferences
    private let auditDomain: String?
    lazy var model = EyePauseModel(preferences: preferences)
    let overlay = BreakOverlayController()
    let settings = SettingsWindowController()
    let water = WaterReminderController()

    override init() {
        if ProcessInfo.processInfo.arguments.contains("--audit-startup") {
            let domain = "com.local.EyePause.Audit.Startup." + UUID().uuidString
            auditDomain = domain
            preferences = Preferences(defaults: UserDefaults(suiteName: domain)!)
        } else {
            auditDomain = nil
            preferences = Preferences()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onBreakRequested = { [weak self] in
            guard let self else { return }
            self.overlay.show(model: self.model)
        }
        model.onBreakEnded = { [weak self] in self?.overlay.hide() }
        model.onWaterReminderRequested = { [weak self] in
            guard let self else { return }
            self.water.show(model: self.model)
        }
        model.onWaterReminderDismissed = { [weak self] in self?.water.dismiss() }
        model.start()
        if auditDomain != nil {
            print("STARTUP: launched bundle " + (Bundle.main.bundleIdentifier ?? "unknown"))
            print("STARTUP: isolated preferences; no production statistics touched")
            print("STARTUP: Dock hidden = " + String(NSApp.activationPolicy() == .accessory))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.settings.show(model: self.model, preferences: self.preferences)
                print("STARTUP: settings visible = " + String(self.settings.isVisible))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                print("STARTUP: clean exit")
                NSApp.terminate(nil)
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.stop() // Flush progress, including manual pause, on normal quit.
        if let auditDomain {
            UserDefaults(suiteName: auditDomain)?.removePersistentDomain(forName: auditDomain)
        }
    }
}

@main
@MainActor
struct EyePauseApp: App {
    @NSApplicationDelegateAdaptor(EyePauseAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: delegate.model, openSettings: {
                delegate.settings.show(model: delegate.model, preferences: delegate.preferences)
            })
        } label: {
            EyePauseMenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct EyePauseMenuBarLabel: View {
    @ObservedObject var model: EyePauseModel
    var body: some View {
        Group {
            if model.statusTitle.isEmpty {
                Image(systemName: "binoculars.fill")
            } else {
                Label(model.statusTitle, systemImage: "binoculars.fill")
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--audit-startup") {
                print("STARTUP: menu label rendered; symbol available = " +
                      String(NSImage(systemSymbolName: "binoculars.fill", accessibilityDescription: nil) != nil))
            }
        }
    }
}
