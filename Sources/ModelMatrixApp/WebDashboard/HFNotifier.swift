import Foundation
import UserNotifications

/// Posts macOS notifications for Hugging Face downloads (finished, ready,
/// waiting for an engine, failed). macOS asks the user once, the first time
/// there is something to say. Builds run outside an `.app` bundle (for example
/// `swift run`) have no notification identity, so they post nothing.
@MainActor
final class HFNotifier {
    static let shared = HFNotifier()

    private var authorization: Task<Bool, Never>?

    var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func post(id: String, title: String, body: String) {
        guard available else { return }
        let allowed = authorization ?? Task {
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        }
        authorization = allowed
        Task {
            guard await allowed.value else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = "modelmatrix.downloads"
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
