import SwiftUI
import AppKit
import StudyTimerCore
import UserNotifications

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let backup: () -> Void
    let csv: () -> Void
    let restore: () -> Void
    @State private var notificationStatus = ""
    var body: some View {
        Form {
            Section("悬浮窗") {
                Picker("外观", selection: $model.preferences.theme) {
                    ForEach(TimerTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.preferences.theme == .glass {
                    HStack {
                        Text("玻璃深浅")
                        Slider(value: $model.preferences.glassOpacity, in: 0.15...0.85).frame(width: 190)
                    }
                }
                Toggle("始终置顶", isOn: $model.preferences.alwaysOnTop)
                Toggle("菜单栏显示计时", isOn: $model.preferences.menuBarTimer)
            }
            Section("倒计时提醒") {
                Toggle("一次提示音", isOn: $model.preferences.sound)
                    .onChange(of: model.preferences.sound) { model.reminderPreferencesChanged() }
                Toggle("系统通知", isOn: $model.preferences.notifications)
                    .onChange(of: model.preferences.notifications) { model.reminderPreferencesChanged() }
                if !notificationStatus.isEmpty {
                    Text(notificationStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("学习数据") {
                Toggle("自动本地备份", isOn: $model.preferences.automaticBackups)
                HStack {
                    if let last = model.lastBackup {
                        Text("最近备份 \(last.formatted(.dateTime.month().day().hour().minute()))")
                    } else { Text("尚无自动备份") }
                    Spacer()
                    Button("打开备份文件夹") {
                        do {
                            try FileManager.default.createDirectory(at: model.backupDirectory, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(model.backupDirectory)
                        } catch { model.message = error.localizedDescription }
                    }
                }.font(.caption).foregroundStyle(.secondary)
                if let error = model.backupError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Button("完整备份…", action: backup)
                    Button("恢复备份…", action: restore).disabled(model.isMutating)
                    Button("导出 CSV…", action: csv)
                }
            }
        }.formStyle(.grouped).frame(width: 470, height: 470)
            .task(id: model.preferences.notifications) {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    notificationStatus = settings.alertSetting == .enabled ? "系统通知已允许" : "系统通知横幅未启用"
                case .denied: notificationStatus = "系统通知未允许"
                case .notDetermined: notificationStatus = "通知权限未设置"
                @unknown default: notificationStatus = "通知权限未知"
                }
            }
    }
}
