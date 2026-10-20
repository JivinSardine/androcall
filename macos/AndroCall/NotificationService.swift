import Foundation
import UserNotifications

/// Delivers native macOS notifications for incoming and ended calls.
public final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    public static let incomingCategory = "androcall.incoming"
    public static let callEndedCategory = "androcall.ended"

    private let center = UNUserNotificationCenter.current()

    public override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    /// Ask the user for permission to post notifications.
    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            DiagnosticsLog.shared.log("Notification authorisation failed: \(error.localizedDescription)", level: .warning)
            return false
        }
    }

    /// The current authorisation status.
    public func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    private func registerCategories() {
        let answer = UNNotificationAction(
            identifier: "ANDROCALL_ANSWER",
            title: "Answer",
            options: [.foreground]
        )
        let decline = UNNotificationAction(
            identifier: "androcall_DECLINE",
            title: "Decline",
            options: [.destructive]
        )
        let incoming = UNNotificationCategory(
            identifier: Self.incomingCategory,
            actions: [answer, decline],
            intentIdentifiers: [],
            options: []
        )
        let ended = UNNotificationCategory(
            identifier: Self.callEndedCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([incoming, ended])
    }

    /// Post an incoming-call notification.
    public func postIncomingCall(caller: String, number: String?, callId: String) {
        let content = UNMutableNotificationContent()
        content.title = "Incoming call"
        content.body = caller
        content.categoryIdentifier = Self.incomingCategory
        content.sound = .default
        content.userInfo = ["callId": callId]
        content.threadIdentifier = callId
        let request = UNNotificationRequest(
            identifier: "androcall-incoming-\(callId)",
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    /// Post a "call ended" notification.
    public func postCallEnded(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Call ended"
        content.body = reason.isEmpty ? "The call has ended." : reason
        content.categoryIdentifier = Self.callEndedCategory
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "androcall-ended-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the notification even while the app is in the foreground so a
        // call is never missed.
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let callId = response.notification.request.content.userInfo["callId"] as? String
        NotificationRouter.shared.handle(responseIdentifier: response.actionIdentifier, callId: callId)
        completionHandler()
    }
}

/// Routes notification actions back into the application.
public final class NotificationRouter {
    public static let shared = NotificationRouter()

    /// Called with the action identifier and the call identifier.
    public var handler: ((String, String?) -> Void)?

    private init() {}

    public func handle(responseIdentifier: String, callId: String?) {
        handler?(responseIdentifier, callId)
    }
}
