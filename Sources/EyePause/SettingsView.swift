import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: EyePauseModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("眼睛休息") {
                LabeledContent("连续使用") {
                    Stepper("\(Int(preferences.workMinutes)) 分钟", value: $preferences.workMinutes, in: 5...60, step: 5)
                }
                LabeledContent("休息时长") {
                    Stepper("\(Int(preferences.breakSeconds)) 秒", value: $preferences.breakSeconds, in: 10...120, step: 5)
                }
            }

            Section("智能检测") {
                LabeledContent("无输入后冻结") {
                    Stepper("\(Int(preferences.idleGraceSeconds)) 秒", value: $preferences.idleGraceSeconds, in: 10...90, step: 5)
                }
                LabeledContent("自然休息阈值") {
                    Stepper("\(preferences.naturalBreakMinutes, specifier: "%.1f") 分钟", value: $preferences.naturalBreakMinutes, in: 1...10, step: 0.5)
                }
                Text("冻结期间不累计使用时间；达到自然休息阈值后，下一轮计时会重置。视频会议、播放器和演示 App 仍会算作屏幕使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("无输入不等于眼睛没在看屏幕；视频检测是近似判断，可能误判。自然休息阈值不会小于冻结阈值。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("菜单栏与提醒") {
                Picker("菜单栏显示", selection: $preferences.displayMode) {
                    ForEach(MenuDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("喝水提醒", isOn: $preferences.waterEnabled)
                if preferences.waterEnabled {
                    LabeledContent("提醒间隔") {
                        Stepper("\(Int(preferences.waterMinutes)) 分钟", value: $preferences.waterMinutes, in: 30...180, step: 15)
                    }
                    Text("按电脑醒着且未锁屏的时间提醒，阅读不操作也计时；手动暂停时不提醒。眼睛休息期间到点，结束后再弹窗。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("系统") {
                Toggle("登录 Mac 时自动打开", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let error = model.settingsError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 520, height: 640)
    }
}
