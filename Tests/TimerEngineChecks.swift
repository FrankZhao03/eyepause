import Foundation

@main
struct TimerEngineChecks {
    static let config = TimerConfiguration(workDuration: 1200, breakDuration: 20, idleGrace: 30,
                                            naturalBreakThreshold: 120, waterInterval: 3600, waterEnabled: true)
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        precondition(value(), "FAIL: " + name)
        checks += 1
        print("PASS: " + name)
    }
    static func tick(_ engine: inout TimerEngine, _ elapsed: Double = 0, at uptime: Double = 0,
                     idle: Double = 0, passive: Bool = false, suspended: Bool = false,
                     config: TimerConfiguration = config, date: Date = Date(timeIntervalSince1970: 1000)) -> TimerSnapshot {
        engine.tick(elapsed: elapsed, idleSeconds: idle, passiveScreenUse: passive, now: date,
                    configuration: config, uptime: uptime, suspended: suspended)
    }

    static func main() {
        var e = TimerEngine()
        check(tick(&e, 5).remainingWork == 1195, "Active input accumulates work")
        check(tick(&e, 5, idle: 30).activeSeconds == 5, "Idle grace boundary freezes")
        check(tick(&e, 5, idle: 119).phase == .idleGrace, "Before natural threshold stays frozen")
        check(tick(&e, 5, idle: 120).activeSeconds == 0, "Natural threshold resets work")
        check(tick(&e, 5, idle: 500, passive: true).activeSeconds == 5, "Passive use overrides input idle")
        check(tick(&e, 100).activeSeconds == 10, "Callback stall cannot invent active minutes")
        check(tick(&e, -10).activeSeconds == 10, "Negative elapsed ignored")

        e = TimerEngine()
        for i in 1...240 { _ = tick(&e, 5, at: Double(i * 5)) }
        check(tick(&e, at: 1200).shouldBeginBreak, "20 minutes of use requests a break")
        e.beginBreak(duration: 20, uptime: 1200)
        check(tick(&e, at: 1200).phase == .takingBreak(remaining: 20), "Break starts at 0:20")
        e.beginBreak(duration: 20, uptime: 1205)
        check(tick(&e, 5, at: 1205).phase == .takingBreak(remaining: 15), "Duplicate begin never restarts deadline")
        var values: [Int] = []
        for second in 6..<20 {
            let s = tick(&e, 1, at: 1200 + Double(second))
            if case .takingBreak(let remaining) = s.phase { values.append(Int(remaining)) }
            check(!s.shouldBeginBreak, "No retrigger during break second " + String(second))
        }
        check(values == Array(stride(from: 14, through: 1, by: -1)), "Countdown decreases every second")
        let finished = tick(&e, 1, at: 1220)
        check(finished.breaksTaken == 1 && finished.activeSeconds == 0, "Break ends once at exactly 20 seconds")
        check(finished.screenSecondsToday == 1200, "Rest interval is not screen-use time")
        check(tick(&e, 1, at: 1221).breaksTaken == 1, "Completion never counted twice")

        e = TimerEngine()
        e.beginBreak(duration: 20, uptime: 0)
        let stalled = tick(&e, 180, at: 180)
        check(stalled.breaksTaken == 1 && stalled.activeSeconds == 0, "Three-minute stalled callback still completes break")
        e.beginBreak(duration: 20, uptime: 200)
        check(tick(&e, 1, at: 210, date: Date.distantPast).phase == .takingBreak(remaining: 10),
              "Changing system date cannot stretch break")
        e.skipBreak()
        check(tick(&e, at: 211).breaksTaken == 1, "Skip does not count a completed break")
        e.pause(for: nil)
        check(tick(&e, 300).waterSeconds == stalled.waterSeconds + 1, "Manual pause freezes water clock")
        e.beginBreak(duration: 20, uptime: 400)
        check(tick(&e, at: 401).phase == .takingBreak(remaining: 19), "Manual break resumes a paused timer")

        e = TimerEngine()
        _ = tick(&e, 3600, idle: 45)
        check(tick(&e, idle: 45).shouldRemindWater, "Hourly water reminder still due when reading without input")
        e.markWaterReminderSent()
        check(!tick(&e).shouldRemindWater, "Pending water reminder does not spawn duplicates")
        e.acknowledgeWater()
        check(tick(&e).waterSeconds == 0, "Acknowledgement restarts hourly clock")
        e.snoozeWater(for: 600, configuration: config)
        check(!tick(&e, 599).shouldRemindWater, "Snooze does not fire early")
        check(tick(&e, 1).shouldRemindWater, "Snooze fires at 10 elapsed minutes")
        e.beginBreak(duration: 20, uptime: 0)
        check(!tick(&e, at: 5).shouldRemindWater, "Water deferred during eye break")
        check(tick(&e, at: 20).shouldRemindWater, "Deferred water due immediately after eye break")
        var disabled = config; disabled.waterEnabled = false
        check(!tick(&e, 60, config: disabled).shouldRemindWater, "Disabled water never requests popup")
        let before = e.waterSeconds
        check(tick(&e, 600, suspended: true).waterSeconds == before, "Suspension freezes water")
        check(tick(&e, 600, passive: true, suspended: true).phase == .suspended,
              "Suspension takes priority over passive video")

        e.restore(screenSecondsToday: 200, longestSession: 150, breaksTaken: 3,
                  activeSeconds: 100, currentSession: 100, waterSeconds: 3599)
        check(tick(&e, 1).shouldRemindWater, "Restored water progress survives relaunch")
        e.resetDay()
        check(e.screenSecondsToday == 0 && e.longestSession == 0 && e.breaksTaken == 0,
              "Midnight resets daily statistics")
        check(e.activeSeconds == 101 && e.waterSeconds == 3600, "Midnight preserves ongoing reminder cycles")
        var bad = config; bad.workDuration = 0; bad.breakDuration = .nan; bad.idleGrace = 90; bad.naturalBreakThreshold = 60
        check(bad.validated.workDuration > 0 && bad.validated.breakDuration == 20 &&
              bad.validated.naturalBreakThreshold == 90, "Invalid configuration sanitized")
        e.restore(screenSecondsToday: .nan, longestSession: -.infinity, breaksTaken: -1)
        check(e.screenSecondsToday == 0 && e.longestSession == 0 && e.breaksTaken == 0,
              "Invalid persisted statistics sanitized")
        print("Timer engine: " + String(checks) + " checks passed")
    }
}
