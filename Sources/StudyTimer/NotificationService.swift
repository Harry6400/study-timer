import AppKit
import UserNotifications
import StudyTimerCore

@MainActor final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var pending: Task<Void, Never>?
    private var scheduled = false
    private let identifier = "study-timer-finished"

    override init() { super.init(); center.delegate = self }
    func cancel() {
        pending?.cancel(); pending = nil; scheduled = false
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
    func schedule(after seconds: TimeInterval, preferences: Preferences) {
        cancel()
        guard preferences.notifications else { return }
        let requestedAt = ContinuousClock.now
        pending = Task {
            do {
                let allowed = try await center.requestAuthorization(options: [.alert, .sound])
                guard allowed, !Task.isCancelled else { return }
                let wait = requestedAt.duration(to: .now).components
                let remaining = seconds - Double(wait.seconds) - Double(wait.attoseconds) / 1e18
                guard remaining > 0 else { return }
                let content = UNMutableNotificationContent()
                content.title = "学习计时结束"; content.body = "这段学习已记录，休息一下吧。"
                if preferences.sound { content.sound = .default }
                let request = UNNotificationRequest(identifier: identifier, content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false))
                try await center.add(request)
                if Task.isCancelled { center.removePendingNotificationRequests(withIdentifiers: [identifier]) }
                else { scheduled = true }
            } catch { scheduled = false }
        }
    }
    func finished(preferences: Preferences) {
        pending?.cancel()
        if !scheduled && preferences.sound { NSSound(named: "Glass")?.play() }
        scheduled = false
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
