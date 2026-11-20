import Foundation
import Combine

enum MenuDisplayMode: String, CaseIterable, Identifiable {
    case compact
    case adaptive
    case always

    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: return "仅图标"
        case .adaptive: return "自适应"
        case .always: return "始终显示倒计时"
        }
    }
}

final class Preferences: ObservableObject {
    private enum Key {
        static let workMinutes = "workMinutes"
        static let breakSeconds = "breakSeconds"
        static let idleGraceSeconds = "idleGraceSeconds"
        static let naturalBreakMinutes = "naturalBreakMinutes"
        static let waterMinutes = "waterMinutes"
        static let waterEnabled = "waterEnabled"
        static let displayMode = "displayMode"
    }

    private let defaults: UserDefaults
    var storage: UserDefaults { defaults }

    @Published var workMinutes: Double { didSet { defaults.set(workMinutes, forKey: Key.workMinutes) } }
    @Published var breakSeconds: Double { didSet { defaults.set(breakSeconds, forKey: Key.breakSeconds) } }
    @Published var idleGraceSeconds: Double { didSet { defaults.set(idleGraceSeconds, forKey: Key.idleGraceSeconds) } }
    @Published var naturalBreakMinutes: Double { didSet { defaults.set(naturalBreakMinutes, forKey: Key.naturalBreakMinutes) } }
    @Published var waterMinutes: Double { didSet { defaults.set(waterMinutes, forKey: Key.waterMinutes) } }
    @Published var waterEnabled: Bool { didSet { defaults.set(waterEnabled, forKey: Key.waterEnabled) } }
    @Published var displayMode: MenuDisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.workMinutes: 20.0,
            Key.breakSeconds: 20.0,
            Key.idleGraceSeconds: 30.0,
            Key.naturalBreakMinutes: 2.0,
            Key.waterMinutes: 60.0,
            Key.waterEnabled: true,
            Key.displayMode: MenuDisplayMode.adaptive.rawValue
        ])
        func read(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
            let value = defaults.double(forKey: key)
            return value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        workMinutes = read(Key.workMinutes, fallback: 20, range: 5...60)
        breakSeconds = read(Key.breakSeconds, fallback: 20, range: 10...120)
        idleGraceSeconds = read(Key.idleGraceSeconds, fallback: 30, range: 10...90)
        naturalBreakMinutes = read(Key.naturalBreakMinutes, fallback: 2, range: 1...10)
        waterMinutes = read(Key.waterMinutes, fallback: 60, range: 30...180)
        waterEnabled = defaults.bool(forKey: Key.waterEnabled)
        displayMode = MenuDisplayMode(rawValue: defaults.string(forKey: Key.displayMode) ?? "") ?? .adaptive
    }

    var configuration: TimerConfiguration {
        TimerConfiguration(
            workDuration: workMinutes * 60,
            breakDuration: breakSeconds,
            idleGrace: idleGraceSeconds,
            naturalBreakThreshold: naturalBreakMinutes * 60,
            waterInterval: waterMinutes * 60,
            waterEnabled: waterEnabled
        ).validated
    }
}
