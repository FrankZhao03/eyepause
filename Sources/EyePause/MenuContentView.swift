import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: EyePauseModel
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 12)
            stats
            if model.preferences.waterEnabled {
                Divider().padding(.vertical, 12)
                waterRow
            }
            Divider().padding(.vertical, 12)
            controls
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: model.snapshot.workProgress)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: phaseIcon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(primaryLabel)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(model.phaseLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var stats: some View {
        VStack(spacing: 9) {
            statRow("今日屏幕时间", value: model.formatDuration(model.snapshot.screenSecondsToday))
            statRow("最长连续使用", value: model.formatDuration(model.snapshot.longestSession))
            statRow("完成眼睛休息", value: "\(model.snapshot.breaksTaken) 次")
        }
    }

    private var waterRow: some View {
        HStack {
            Label("喝水", systemImage: "drop.fill")
                .foregroundStyle(.secondary)
            Spacer()
            Text(model.snapshot.waterReminderPending ? "该喝水了" : "约 \(max(Int(ceil((model.preferences.configuration.waterInterval - model.snapshot.waterSeconds) / 60)), 0)) 分钟后")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("已喝") { model.acknowledgeWater() }
                .buttonStyle(.borderless)
        }
        .font(.callout)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Button {
                model.takeBreakNow()
            } label: {
                Label("现在休息 \(Int(model.preferences.breakSeconds)) 秒", systemImage: "binoculars.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 8) {
                switch model.snapshot.phase {
                case .paused:
                    Button("继续计时") { model.resume() }
                        .frame(maxWidth: .infinity)
                default:
                    Menu("暂停") {
                        Button("30 分钟") { model.pause(minutes: 30) }
                        Button("1 小时") { model.pause(minutes: 60) }
                        Button("直到我继续") { model.pause(minutes: nil) }
                    }
                    .frame(maxWidth: .infinity)
                }
                Button("设置…") { openSettings() }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button("退出 EyePause") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private func statRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    private var primaryLabel: String {
        switch model.snapshot.phase {
        case .takingBreak(let remaining): return "休息 \(model.formatClock(remaining))"
        case .paused: return "计时已暂停"
        case .suspended: return "系统已暂停计时"
        case .naturalBreak: return "自然休息"
        default: return "距离休息 \(model.formatClock(model.snapshot.remainingWork))"
        }
    }

    private var phaseIcon: String {
        switch model.snapshot.phase {
        case .paused: return "pause.fill"
        case .suspended: return "moon.fill"
        case .naturalBreak: return "leaf.fill"
        case .takingBreak: return "binoculars.fill"
        default: return "binoculars.fill"
        }
    }
}
