import AppKit
import Combine
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import ServiceManagement

struct ActivityInput {
    var idleSeconds: TimeInterval = 0
    var passiveScreenUse = false
    var suspended = false
}

@MainActor
final class EyePauseModel: ObservableObject {
    @Published private(set) var snapshot = TimerSnapshot(
        phase: .active, activeSeconds: 0, screenSecondsToday: 0, longestSession: 0,
        currentSession: 0, breaksTaken: 0, waterSeconds: 0, remainingWork: 1200,
        workProgress: 0, shouldBeginBreak: false, shouldRemindWater: false)
    @Published private(set) var launchAtLogin = false
    @Published var settingsError: String?

    let preferences: Preferences
    var onBreakRequested: (() -> Void)?
    var onBreakEnded: (() -> Void)?
    var onWaterReminderRequested: (() -> Void)?
    var onWaterReminderDismissed: (() -> Void)?

    private var engine = TimerEngine()
    private var ticker: DispatchSourceTimer?
    private var timerActivity: NSObjectProtocol?
    private var lastUptime: TimeInterval
    private var lastSave: TimeInterval = 0
    private var statisticsDay: Date
    private var lastInput = ActivityInput()
    private var suspensionReasons = Set<String>()
    private var suspendedAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private let defaults: UserDefaults
    private let calendar = Calendar.current
    private let dateProvider: () -> Date
    private let uptimeProvider: () -> TimeInterval
    private let activityProvider: (() -> ActivityInput)?

    init(preferences: Preferences = Preferences(), defaults: UserDefaults? = nil,
         observeSystem: Bool = true, dateProvider: @escaping () -> Date = { Date() },
         uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         activityProvider: (() -> ActivityInput)? = nil) {
        self.preferences = preferences
        self.defaults = defaults ?? preferences.storage
        self.dateProvider = dateProvider
        self.uptimeProvider = uptimeProvider
        self.activityProvider = activityProvider
        lastUptime = uptimeProvider()
        statisticsDay = dateProvider()
        restore()
        lastInput = activityProvider?() ?? (observeSystem ? Self.systemActivity() : ActivityInput())
        refreshImmediately()
        if observeSystem {
            refreshLaunchAtLogin()
            let center = NSWorkspace.shared.notificationCenter
            center.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
            center.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
            center.addObserver(self, selector: #selector(sessionBecameInactive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(sessionBecameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(displayDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
            center.addObserver(self, selector: #selector(displayDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
            // Supplemental lock signals; session/display notifications remain independent.
            let distributed = DistributedNotificationCenter.default()
            distributed.addObserver(self, selector: #selector(screenLocked), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
            distributed.addObserver(self, selector: #selector(screenUnlocked), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        }
        preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.preferences.waterEnabled {
                    self.engine.requeueWaterReminder()
                    self.onWaterReminderDismissed?()
                }
                self.refreshImmediately()
                self.persist()
            }
        }.store(in: &cancellables)
    }

    deinit {
        ticker?.cancel()
        if let timerActivity { ProcessInfo.processInfo.endActivity(timerActivity) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func start() {
        guard ticker == nil else { return }
        lastUptime = uptimeProvider()
        // Menu-bar utilities otherwise qualify for App Nap. Keep timely callbacks
        // without preventing normal system sleep.
        timerActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "EyePause reminder timing")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in self?.tick() }
        ticker = timer
        timer.resume()
    }

    func stop() {
        ticker?.setEventHandler {}
        ticker?.cancel()
        ticker = nil
        if let timerActivity {
            ProcessInfo.processInfo.endActivity(timerActivity)
            self.timerActivity = nil
        }
        persist()
    }

    func takeBreakNow() {
        guard !isSuspended else { return }
        engine.beginBreak(duration: preferences.configuration.breakDuration, uptime: uptimeProvider())
        refreshImmediately()
        persist()
    }

    func skipBreak() { engine.skipBreak(); refreshImmediately(); persist() }
    func pause(minutes: Double?) {
        engine.pause(for: minutes.map { $0 * 60 }, now: dateProvider())
        hideWaterForInterruption()
        refreshImmediately()
        persist()
    }
    func resume() {
        engine.resume()
        lastUptime = uptimeProvider()
        refreshImmediately()
        persist()
    }
    func acknowledgeWater() {
        engine.acknowledgeWater()
        onWaterReminderDismissed?()
        refreshImmediately()
        persist()
    }
    func snoozeWater(minutes: Double = 10) {
        engine.snoozeWater(for: minutes * 60, configuration: preferences.configuration)
        onWaterReminderDismissed?()
        refreshImmediately()
        persist()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            settingsError = nil
        } catch { settingsError = "无法更改登录启动：\(error.localizedDescription)" }
        refreshLaunchAtLogin()
    }

    var statusTitle: String {
        if preferences.displayMode == .compact { return "" }
        switch snapshot.phase {
        case .paused, .suspended, .naturalBreak: return ""
        case .takingBreak(let remaining): return formatClock(remaining)
        default:
            return preferences.displayMode == .always || snapshot.remainingWork <= 120
                ? formatClock(snapshot.remainingWork) : ""
        }
    }
    var phaseLabel: String {
        switch snapshot.phase {
        case .active: return "正在按实际使用时间计时"
        case .idleGrace: return "暂时没有输入，计时已冻结"
        case .naturalBreak: return "检测到自然休息，下轮已重置"
        case .suspended: return "电脑已锁屏、睡眠或屏幕关闭，不计时"
        case .paused(let until):
            return until.map { "暂停至 \($0.formatted(date: .omitted, time: .shortened))" } ?? "已暂停"
        case .takingBreak: return "看看 6 米外，让眼睛放松"
        }
    }
    func formatClock(_ seconds: TimeInterval) -> String {
        let value = seconds.isFinite ? Int(min(max(seconds.rounded(.up), 0), 86400 * 365)) : 0
        return String(format: "%d:%02d", value / 60, value % 60)
    }
    func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = seconds.isFinite ? Int(min(max(seconds, 0), 86400 * 365)) / 60 : 0
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60, remainder = minutes % 60
        return remainder == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainder) 分"
    }

    private var isSuspended: Bool { !suspensionReasons.isEmpty || lastInput.suspended }

    private func tick() {
        let uptime = uptimeProvider(), now = dateProvider()
        let input = activityProvider?() ?? Self.systemActivity()
        advance(elapsed: max(uptime - lastUptime, 0), now: now, uptime: uptime, input: input)
        lastUptime = uptime
        if uptime - lastSave >= 30 { persist(); lastSave = uptime }
    }

    /// Test seam: exactly the same transition path as the production ticker.
    func advance(elapsed: TimeInterval, now: Date, uptime: TimeInterval, input: ActivityInput) {
        let wasSuspended = isSuspended
        lastInput = input
        if !wasSuspended && isSuspended {
            suspendedAt = now
            engine.interruptBreak()
            hideWaterForInterruption()
        } else if wasSuspended && !isSuspended {
            if let suspendedAt, now.timeIntervalSince(suspendedAt) >= preferences.configuration.naturalBreakThreshold {
                engine.resetWorkCycle()
            }
            suspendedAt = nil
        }
        if !calendar.isDate(now, inSameDayAs: statisticsDay) {
            engine.resetDay()
            statisticsDay = now // Roll over once, not every tick until the next save.
        }
        update(elapsed: wasSuspended || isSuspended ? 0 : elapsed, now: now, uptime: uptime)
    }

    private func refreshImmediately() {
        update(elapsed: 0, now: dateProvider(), uptime: uptimeProvider())
    }

    private func update(elapsed: TimeInterval, now: Date, uptime: TimeInterval) {
        let wasBreaking: Bool
        if case .takingBreak = snapshot.phase { wasBreaking = true } else { wasBreaking = false }
        var next = engine.tick(elapsed: elapsed, idleSeconds: lastInput.idleSeconds,
                               passiveScreenUse: lastInput.passiveScreenUse, now: now,
                               configuration: preferences.configuration, uptime: uptime, suspended: isSuspended)
        // Restored progress can already be due during initialization. Wait for
        // the app delegate to attach its window callbacks before starting.
        if next.shouldBeginBreak && onBreakRequested != nil {
            engine.beginBreak(duration: preferences.configuration.breakDuration, uptime: uptime)
            next = engine.tick(elapsed: 0, idleSeconds: lastInput.idleSeconds,
                               passiveScreenUse: lastInput.passiveScreenUse, now: now,
                               configuration: preferences.configuration, uptime: uptime, suspended: isSuspended)
        }
        let isBreaking: Bool
        if case .takingBreak = next.phase { isBreaking = true } else { isBreaking = false }
        if isBreaking && !wasBreaking { hideWaterForInterruption() }
        let showWater = next.shouldRemindWater && onWaterReminderRequested != nil
        if showWater {
            engine.markWaterReminderSent()
            next.waterReminderPending = true
            next.shouldRemindWater = false
        }
        snapshot = next
        if isBreaking && !wasBreaking { onBreakRequested?(); persist() }
        if !isBreaking && wasBreaking { onBreakEnded?(); persist() }
        if showWater { onWaterReminderRequested?(); persist() }
    }

    private func hideWaterForInterruption() {
        engine.requeueWaterReminder()
        onWaterReminderDismissed?()
    }

    func setSuspended(_ suspended: Bool, reason: String) {
        let wasSuspended = isSuspended
        if suspended { suspensionReasons.insert(reason) } else { suspensionReasons.remove(reason) }
        if !wasSuspended && isSuspended {
            suspendedAt = dateProvider()
            engine.interruptBreak()
            hideWaterForInterruption()
        } else if wasSuspended && !isSuspended {
            if let suspendedAt, dateProvider().timeIntervalSince(suspendedAt) >= preferences.configuration.naturalBreakThreshold {
                engine.resetWorkCycle()
            }
            suspendedAt = nil
        }
        lastUptime = uptimeProvider()
        refreshImmediately()
        persist()
    }
    @objc private func systemWillSleep() { setSuspended(true, reason: "sleep") }
    @objc private func systemDidWake() { setSuspended(false, reason: "sleep") }
    @objc private func sessionBecameInactive() { setSuspended(true, reason: "session") }
    @objc private func sessionBecameActive() { setSuspended(false, reason: "session") }
    @objc private func displayDidSleep() { setSuspended(true, reason: "display") }
    @objc private func displayDidWake() { setSuspended(false, reason: "display") }
    @objc private func screenLocked() { setSuspended(true, reason: "lock") }
    @objc private func screenUnlocked() { setSuspended(false, reason: "lock") }

    private static func systemActivity() -> ActivityInput {
        let anyInputEvent = CGEventType(rawValue: UInt32.max)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let onConsole = session?[kCGSessionOnConsoleKey as String] as? Bool ?? false
        // This optional lock key is supplemental, not a documented API guarantee.
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return ActivityInput(idleSeconds: idle, passiveScreenUse: isPassiveScreenUse(),
                             suspended: !onConsole || locked)
    }

    private static func isPassiveScreenUse() -> Bool {
        let appID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let apps: Set<String> = ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
                                "com.apple.TV", "org.videolan.vlc", "com.apple.Keynote",
                                "com.microsoft.Powerpoint", "com.colliderli.iina"]
        if apps.contains(appID) { return true }
        let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary",
                                    "company.thebrowser.Browser", "com.microsoft.edgemac", "org.mozilla.firefox",
                                    "com.brave.Browser", "com.kagi.kagimacOS"]
        guard browsers.contains(appID) else { return false }
        // A system assertion is only a hint, not proof of video or attention.
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&unmanaged) == kIOReturnSuccess,
              let status = unmanaged?.takeRetainedValue() as? [String: NSNumber] else { return false }
        return status[kIOPMAssertionTypePreventUserIdleDisplaySleep as String]?.boolValue == true
    }

    private func restore() {
        let now = dateProvider()
        let saved = defaults.object(forKey: "statisticsDay") as? Date ?? now
        let sameDay = calendar.isDate(now, inSameDayAs: saved)
        engine.restore(screenSecondsToday: sameDay ? defaults.double(forKey: "screenSecondsToday") : 0,
                       longestSession: sameDay ? defaults.double(forKey: "longestSession") : 0,
                       breaksTaken: sameDay ? defaults.integer(forKey: "breaksTaken") : 0,
                       activeSeconds: sameDay ? defaults.double(forKey: "activeSeconds") : 0,
                       currentSession: sameDay ? defaults.double(forKey: "currentSession") : 0,
                       waterSeconds: defaults.double(forKey: "waterSeconds"),
                       pauseUntil: defaults.object(forKey: "pauseUntil") as? Date,
                       indefinitelyPaused: defaults.bool(forKey: "indefinitelyPaused"))
        if now.timeIntervalSince(saved) >= preferences.configuration.naturalBreakThreshold { engine.resetWorkCycle() }
    }

    func persist() {
        defaults.set(dateProvider(), forKey: "statisticsDay")
        defaults.set(snapshot.screenSecondsToday, forKey: "screenSecondsToday")
        defaults.set(snapshot.longestSession, forKey: "longestSession")
        defaults.set(snapshot.breaksTaken, forKey: "breaksTaken")
        defaults.set(snapshot.activeSeconds, forKey: "activeSeconds")
        defaults.set(snapshot.currentSession, forKey: "currentSession")
        defaults.set(snapshot.waterSeconds, forKey: "waterSeconds")
        defaults.set(engine.pauseUntil, forKey: "pauseUntil")
        defaults.set(engine.indefinitelyPaused, forKey: "indefinitelyPaused")
    }
    private func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        if status == .requiresApproval {
            settingsError = "需要在系统设置 → 通用 → 登录项中允许 EyePause。"
        }
    }
}
