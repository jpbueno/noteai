import UserNotifications

/// Delivers meeting summary notifications via macOS notification center.
final class NotificationDelivery {
    func sendSummaryReady(meetingTitle: String) async {
        // UNUserNotificationCenter requires a valid app bundle
        guard Bundle.main.bundleIdentifier != nil else {
            print("Summary ready: \(meetingTitle) (notifications unavailable outside app bundle)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Meeting Summary Ready"
        content.body = "Your summary for \"\(meetingTitle)\" is ready to view."
        content.sound = .default
        content.categoryIdentifier = "MEETING_SUMMARY"

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("Failed to send notification: \(error)")
        }
    }
}
