import Foundation
import UserNotifications
import AppKit

@available(macOS 26.0, *)
@MainActor
final class CaptionNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CaptionNotificationManager()

    private var hasRequestedAuth = false

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Prompt user for notification authorization upon starting background caption work.
    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuth else { return }
        hasRequestedAuth = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post completion notification to macOS Notification Center when background transcription finishes.
    func postCompletionNotification(for task: CaptionTaskCenter.Task, error: Error?) {
        guard !(error is CancellationError) else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        if let error {
            content.title = L("captions.notify.failedTitle")
            content.body = L("captions.notify.failedBody", task.mediaName, error.localizedDescription)
        } else {
            content.title = L("captions.notify.successTitle")
            content.body = L("captions.notify.successBody", task.mediaName)
        }
        content.sound = .default
        content.userInfo = ["mediaURL": task.mediaURL.absoluteString]

        let request = UNNotificationRequest(identifier: "app.khua.captions.\(UUID().uuidString)",
                                            content: content,
                                            trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    /// Handle notification click: activates Khua and opens the media.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let urlStr = response.notification.request.content.userInfo["mediaURL"] as? String,
              let url = URL(string: urlStr) else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.application(NSApp, open: [url])
            }
        }
    }
}
