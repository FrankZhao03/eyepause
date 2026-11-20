import AppKit
import Foundation

@MainActor
private final class TestClock {
    var date = Date()
    var uptime: TimeInterval = 0
}

@main
@MainActor
struct IntegrationChecks {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        precondition(value(), "FAIL: " + name)
        checks += 1
        print("PASS: " + name)
        fflush(stdout)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await run()
            app.terminate(nil)
        }
        app.run()
    }

    static func run() async {
        let domain = "com.local.EyePause.Audit." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        // Only our fresh, unique test domain is removed. Production defaults
        // are never opened by this harness.
        defer { defaults.removePersistentDomain(forName: domain) }
        let prefs = Preferences(defaults: defaults)
        let clock = TestClock()
        let model = EyePauseModel(preferences: prefs, defaults: defaults, observeSystem: false,
                                  dateProvider: { clock.date }, uptimeProvider: { clock.uptime })
        let overlay = BreakOverlayController()
        let water = WaterReminderController()
        let settings = SettingsWindowController()
        var starts = 0, ends = 0, waterShows = 0
        model.onBreakRequested = { starts += 1; overlay.show(model: model) }
        model.onBreakEnded = { ends += 1; overlay.hide() }
        model.onWaterReminderRequested = { waterShows += 1; water.show(model: model) }
        model.onWaterReminderDismissed = { water.dismiss() }
        func advance(_ seconds: Double, input: ActivityInput = ActivityInput()) {
            clock.uptime += seconds
            clock.date += seconds
            model.advance(elapsed: seconds, now: clock.date, uptime: clock.uptime, input: input)
        }

        check(!NSScreen.screens.isEmpty, "Window server supplies at least one screen")
        settings.show(model: model, preferences: prefs)
        check(settings.isVisible, "Settings window opens")
        settings.close()
        check(!settings.isVisible, "Settings window closes")
        settings.show(model: model, preferences: prefs)
        check(settings.isVisible, "Settings reopens after close")
        settings.minimize()
        settings.show(model: model, preferences: prefs)
        check(settings.isVisible, "Settings reopens after minimize")
        settings.close()

        for _ in 0..<240 { advance(5) }
        check(starts == 1, "Model schedules exactly one break at 20 minutes")
        check(overlay.visiblePanelCount == NSScreen.screens.count, "Overlay windows created for connected screens")
        check(overlay.displayedCountdowns.allSatisfy { $0 == "0:20" }, "Real window labels start at 0:20")
        overlay.show(model: model)
        model.takeBreakNow()
        check(starts == 1, "Repeated show/manual command cannot restart break")
        for second in 1..<20 {
            advance(1)
            check(overlay.displayedCountdowns.allSatisfy { $0 == model.formatClock(Double(20 - second)) },
                  "Window label matches model at second " + String(second))
        }
        advance(1)
        check(overlay.visiblePanelCount == 0 && ends == 1 && model.snapshot.breaksTaken == 1,
              "Overlay closes and stats update at 20 seconds")
        check(model.snapshot.activeSeconds == 0, "Next work cycle starts fresh")

        advance(3600 - model.snapshot.waterSeconds, input: ActivityInput(idleSeconds: 45))
        check(water.isVisible && waterShows == 1, "Hourly reminder opens a real water window while input is idle")
        advance(1, input: ActivityInput(idleSeconds: 45))
        check(waterShows == 1, "Water popup does not duplicate")
        water.close()
        check(!water.isVisible && !model.snapshot.waterReminderPending, "Closing water window snoozes")
        advance(599, input: ActivityInput(idleSeconds: 45))
        check(!water.isVisible, "Snoozed window stays closed before 10 minutes")
        advance(1, input: ActivityInput(idleSeconds: 45))
        check(water.isVisible && waterShows == 2, "Snoozed water window reopens at 10 minutes")
        model.acknowledgeWater()
        check(!water.isVisible && model.snapshot.waterSeconds == 0, "Acknowledgement closes window and resets water")

        model.takeBreakNow()
        advance(180)
        check(overlay.visiblePanelCount == 0 && model.snapshot.breaksTaken == 2,
              "Three-minute callback delay cannot leave overlay stuck")
        model.takeBreakNow()
        overlay.skipBreak()
        check(overlay.visiblePanelCount == 0 && model.snapshot.breaksTaken == 2, "Skip closes without completion credit")
        model.pause(minutes: nil)
        let waterBefore = model.snapshot.waterSeconds
        advance(400)
        check(model.snapshot.waterSeconds == waterBefore, "Paused model freezes water")
        model.takeBreakNow()
        check(overlay.visiblePanelCount > 0, "Manual break works even after pause")
        model.setSuspended(true, reason: "test-lock")
        check(overlay.visiblePanelCount == 0 && model.snapshot.phase == .suspended, "Lock transition hides overlay")
        model.setSuspended(true, reason: "test-sleep")
        model.setSuspended(false, reason: "test-sleep")
        check(model.snapshot.phase == .suspended, "Waking does not clear a still-locked session")
        let screenBefore = model.snapshot.screenSecondsToday
        advance(600, input: ActivityInput(passiveScreenUse: true))
        check(model.snapshot.screenSecondsToday == screenBefore && model.snapshot.waterSeconds == waterBefore,
              "No screen or water accounting while suspended, even with video")
        model.setSuspended(false, reason: "test-lock")
        check(model.snapshot.activeSeconds == 0, "Long lock grants natural rest")

        advance(5, input: ActivityInput(idleSeconds: 125))
        model.acknowledgeWater()
        check(model.snapshot.phase == .naturalBreak, "Action refresh does not fabricate input activity")
        clock.date = Calendar.current.startOfDay(for: clock.date).addingTimeInterval(86400 + 1)
        advance(1)
        check(model.snapshot.screenSecondsToday == 1 && model.snapshot.longestSession == 1, "Day rollover resets once")
        advance(1)
        check(model.snapshot.screenSecondsToday == 2 && model.snapshot.longestSession == 2, "Subsequent midnight tick keeps accumulating")
        prefs.displayMode = .compact
        model.pause(minutes: nil)
        check(model.statusTitle.isEmpty, "Compact mode always stays icon-only")
        model.stop()
        let restored = EyePauseModel(preferences: prefs, defaults: defaults, observeSystem: false,
                                     dateProvider: { clock.date }, uptimeProvider: { clock.uptime })
        check(restored.snapshot.screenSecondsToday == 2, "Normal stop/relaunch preserves exact statistics")
        if case .paused = restored.snapshot.phase { check(true, "Manual pause survives relaunch") }
        else { check(false, "Manual pause survives relaunch") }

        let dueDomain = "com.local.EyePause.Audit.RestoredDue." + UUID().uuidString
        let dueDefaults = UserDefaults(suiteName: dueDomain)!
        defer { dueDefaults.removePersistentDomain(forName: dueDomain) }
        dueDefaults.set(clock.date, forKey: "statisticsDay")
        dueDefaults.set(1200.0, forKey: "activeSeconds")
        dueDefaults.set(3600.0, forKey: "waterSeconds")
        let duePrefs = Preferences(defaults: dueDefaults)
        let dueModel = EyePauseModel(preferences: duePrefs, defaults: dueDefaults, observeSystem: false,
                                     dateProvider: { clock.date }, uptimeProvider: { clock.uptime })
        check(dueModel.snapshot.shouldBeginBreak, "Restored due break waits for UI callbacks")
        var restoredStarts = 0, restoredWaters = 0
        dueModel.onBreakRequested = { restoredStarts += 1 }
        dueModel.onWaterReminderRequested = { restoredWaters += 1 }
        dueModel.advance(elapsed: 0, now: clock.date, uptime: clock.uptime, input: ActivityInput())
        check(restoredStarts == 1 && restoredWaters == 0, "Cold-start due break opens once and water waits")
        dueModel.advance(elapsed: 20, now: clock.date + 20, uptime: clock.uptime + 20, input: ActivityInput())
        check(restoredStarts == 1 && restoredWaters == 1, "Cold-start deferred water delivered after rest")

        // Real-time test uses the exact production dispatch ticker for 20 seconds.
        // It is not an accelerated fake-clock check.
        let liveDomain = "com.local.EyePause.Audit.Live." + UUID().uuidString
        let liveDefaults = UserDefaults(suiteName: liveDomain)!
        defer { liveDefaults.removePersistentDomain(forName: liveDomain) }
        liveDefaults.set(Date(), forKey: "statisticsDay")
        liveDefaults.set(3580.0, forKey: "waterSeconds")
        let livePrefs = Preferences(defaults: liveDefaults)
        let live = EyePauseModel(preferences: livePrefs, defaults: liveDefaults, observeSystem: false,
                                 activityProvider: { ActivityInput() })
        let liveOverlay = BreakOverlayController()
        let liveWater = WaterReminderController()
        live.onBreakRequested = { liveOverlay.show(model: live) }
        live.onBreakEnded = { liveOverlay.hide() }
        live.onWaterReminderRequested = { liveWater.show(model: live) }
        live.onWaterReminderDismissed = { liveWater.dismiss() }
        live.start()
        live.takeBreakNow()
        let began = ProcessInfo.processInfo.systemUptime
        print("LIVE: 20-second production ticker started")
        for _ in 0..<4 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            print("LIVE: elapsed=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - began)), labels=\(liveOverlay.displayedCountdowns)")
            fflush(stdout)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        check(liveOverlay.visiblePanelCount == 0 && live.snapshot.breaksTaken == 1, "Real 20-second ticker completes and closes overlay")
        check(liveWater.isVisible, "Real ticker releases deferred hourly water popup after break")
        live.acknowledgeWater()
        live.stop()
        print("Integration: " + String(checks) + " checks passed")
    }
}
