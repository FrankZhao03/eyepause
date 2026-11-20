import Foundation

struct TimerConfiguration: Equatable {
    var workDuration: TimeInterval
    var breakDuration: TimeInterval
    var idleGrace: TimeInterval
    var naturalBreakThreshold: TimeInterval
    var waterInterval: TimeInterval
    var waterEnabled: Bool

    var validated: Self {
        func safe(_ value: Double, fallback: Double, minimum: Double) -> Double {
            value.isFinite ? max(value, minimum) : fallback
        }
        let grace = safe(idleGrace, fallback: 30, minimum: 1)
        return Self(workDuration: safe(workDuration, fallback: 1200, minimum: 1),
                    breakDuration: safe(breakDuration, fallback: 20, minimum: 1),
                    idleGrace: grace,
                    naturalBreakThreshold: max(safe(naturalBreakThreshold, fallback: 120, minimum: 1), grace),
                    waterInterval: safe(waterInterval, fallback: 3600, minimum: 1),
                    waterEnabled: waterEnabled)
    }
}

enum ActivityPhase: Equatable {
    case active, idleGrace, naturalBreak, suspended
    case paused(until: Date?)
    case takingBreak(remaining: TimeInterval)
}

struct TimerSnapshot: Equatable {
    var phase: ActivityPhase
    var activeSeconds, screenSecondsToday, longestSession, currentSession: TimeInterval
    var breaksTaken: Int
    var waterSeconds: TimeInterval
    var waterReminderPending = false
    var remainingWork: TimeInterval
    var workProgress: Double
    var shouldBeginBreak, shouldRemindWater: Bool
}

/// The only owner of time and state. Windows render snapshots, never run clocks.
struct TimerEngine {
    private(set) var activeSeconds: TimeInterval = 0
    private(set) var screenSecondsToday: TimeInterval = 0
    private(set) var longestSession: TimeInterval = 0
    private(set) var currentSession: TimeInterval = 0
    private(set) var breaksTaken = 0
    private(set) var waterSeconds: TimeInterval = 0
    private(set) var waterReminderPending = false
    private(set) var pauseUntil: Date?
    private(set) var indefinitelyPaused = false
    private var breakDeadline: TimeInterval?

    mutating func tick(elapsed: TimeInterval, idleSeconds: TimeInterval,
                       passiveScreenUse: Bool, now: Date,
                       configuration raw: TimerConfiguration,
                       uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                       suspended: Bool = false) -> TimerSnapshot {
        let configuration = raw.validated
        let elapsed = elapsed.isFinite ? max(elapsed, 0) : 0
        if let until = pauseUntil, now >= until { pauseUntil = nil }
        if suspended { return snapshot(phase: .suspended, configuration: configuration) }
        if indefinitelyPaused || pauseUntil != nil {
            return snapshot(phase: .paused(until: pauseUntil), configuration: configuration)
        }
        // Water has its own hourly clock: idle reading and eye breaks count,
        // but sleep, lock and manual pause do not. No water countdown window.
        if configuration.waterEnabled { waterSeconds += elapsed }
        if let deadline = breakDeadline {
            let remaining = max(deadline - uptime, 0)
            if remaining > 0 {
                return snapshot(phase: .takingBreak(remaining: remaining), configuration: configuration)
            }
            finishBreak()
            // Do not count the interval spent resting as screen-use time.
            return snapshot(phase: phase(idleSeconds: idleSeconds, passive: passiveScreenUse,
                                         configuration: configuration), configuration: configuration)
        }
        let phase = phase(idleSeconds: idleSeconds, passive: passiveScreenUse, configuration: configuration)
        if phase == .active {
            let delta = min(elapsed, 5)
            activeSeconds += delta
            screenSecondsToday += delta
            currentSession += delta
            longestSession = max(longestSession, currentSession)
        } else if phase == .naturalBreak {
            resetWorkCycle()
        }
        return snapshot(phase: phase, configuration: configuration)
    }

    /// Idempotent: duplicate callbacks must never restart a countdown.
    mutating func beginBreak(duration: TimeInterval,
                             uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard breakDeadline == nil else { return }
        resume()
        breakDeadline = uptime + (duration.isFinite ? max(duration, 1) : 20)
    }

    private mutating func finishBreak() {
        guard breakDeadline != nil else { return }
        breaksTaken += 1
        breakDeadline = nil
        resetWorkCycle()
    }

    mutating func skipBreak() {
        guard breakDeadline != nil else { return }
        breakDeadline = nil
        resetWorkCycle()
    }
    mutating func interruptBreak() { skipBreak() }
    mutating func resetWorkCycle() { activeSeconds = 0; currentSession = 0 }

    mutating func pause(for duration: TimeInterval?, now: Date = Date()) {
        interruptBreak()
        pauseUntil = duration.map { now.addingTimeInterval(max($0, 0)) }
        indefinitelyPaused = duration == nil
    }
    mutating func resume() { pauseUntil = nil; indefinitelyPaused = false }
    mutating func acknowledgeWater() { waterSeconds = 0; waterReminderPending = false }
    mutating func snoozeWater(for duration: TimeInterval, configuration: TimerConfiguration) {
        waterSeconds = configuration.validated.waterInterval - max(duration, 0)
        waterReminderPending = false
    }
    mutating func markWaterReminderSent() { waterReminderPending = true }
    mutating func requeueWaterReminder() { waterReminderPending = false }

    mutating func restore(screenSecondsToday: TimeInterval, longestSession: TimeInterval,
                          breaksTaken: Int, activeSeconds: TimeInterval = 0,
                          currentSession: TimeInterval = 0, waterSeconds: TimeInterval = 0,
                          pauseUntil: Date? = nil, indefinitelyPaused: Bool = false) {
        func safe(_ value: Double) -> Double { value.isFinite ? max(value, 0) : 0 }
        self.screenSecondsToday = safe(screenSecondsToday)
        self.longestSession = safe(longestSession)
        self.breaksTaken = max(breaksTaken, 0)
        self.activeSeconds = safe(activeSeconds)
        self.currentSession = safe(currentSession)
        self.waterSeconds = waterSeconds.isFinite ? waterSeconds : 0
        self.pauseUntil = pauseUntil
        self.indefinitelyPaused = indefinitelyPaused
    }

    mutating func resetDay() {
        screenSecondsToday = 0
        longestSession = 0
        currentSession = 0
        breaksTaken = 0
    }

    private func phase(idleSeconds: TimeInterval, passive: Bool,
                       configuration: TimerConfiguration) -> ActivityPhase {
        if passive || idleSeconds < configuration.idleGrace { return .active }
        return idleSeconds >= configuration.naturalBreakThreshold ? .naturalBreak : .idleGrace
    }

    private func snapshot(phase: ActivityPhase, configuration: TimerConfiguration) -> TimerSnapshot {
        let breakDue = phase == .active && activeSeconds >= configuration.workDuration
        let waterAvailable: Bool
        switch phase {
        case .active, .idleGrace, .naturalBreak: waterAvailable = !breakDue
        default: waterAvailable = false
        }
        return TimerSnapshot(phase: phase, activeSeconds: activeSeconds,
                             screenSecondsToday: screenSecondsToday, longestSession: longestSession,
                             currentSession: currentSession, breaksTaken: breaksTaken,
                             waterSeconds: waterSeconds, waterReminderPending: waterReminderPending,
                             remainingWork: max(configuration.workDuration - activeSeconds, 0),
                             workProgress: min(activeSeconds / configuration.workDuration, 1),
                             shouldBeginBreak: breakDue,
                             shouldRemindWater: configuration.waterEnabled && waterAvailable &&
                                waterSeconds >= configuration.waterInterval && !waterReminderPending)
    }
}
