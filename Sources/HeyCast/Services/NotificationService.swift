import AppKit
import UserNotifications

/// macOS notifications for finished agent requests. The delegate forwards
/// notification clicks so the launcher can reopen on that message.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// Called with the assistant message id when a notification is clicked.
    var onOpenMessage: ((Int64) -> Void)?

    private var accessRequested = false

    /// Must run before the app finishes launching so click handling works.
    func setup() {
        UNUserNotificationCenter.current().delegate = self
    }

    private func requestAccess() async -> Bool {
        if accessRequested { return true }
        accessRequested = true
        return (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(title: String, body: String, messageID: Int64) {
        Task { [weak self] in
            guard let self, await self.requestAccess() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = ["assistantMessageID": messageID]
            content.sound = .default
            let request = UNNotificationRequest(identifier: "assistant-\(messageID)-\(Int(Date().timeIntervalSince1970 * 1000))",
                                                content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["assistantMessageID"] as? Int64 else {
            return
        }
        await MainActor.run { self.onOpenMessage?(id) }
    }

    /// Show banners even though HeyCast is a background (LSUIElement) app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }
}
