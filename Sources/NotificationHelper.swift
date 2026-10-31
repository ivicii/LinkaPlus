import UserNotifications

/// Fires local notifications for lock events (alarm, siren, bad-PAC attempts,
/// critically low battery). Works while the app runs or is backgrounded with
/// an active Bluetooth connection (bluetooth-central background mode).
@MainActor
final class LockNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LockNotifier()
    private(set) var authorized = false
    private var askedOnce = false

    /// Ask for permission once (safe to call repeatedly).
    func requestAuth() {
        UNUserNotificationCenter.current().delegate = self
        guard !askedOnce else { return }
        askedOnce = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    func notify(title: String, body: String, id: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let req = UNNotificationRequest(identifier: id, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Show the banner even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
