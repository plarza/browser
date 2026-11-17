import Foundation
import UserNotifications

/// GM_notification, as the system's notifications. Browser asks permission
/// for them the first time a script sends one.
@MainActor
final class GMNotifications: NSObject {
    /// A notification on screen, and the copy of the script that sent it.
    private struct Shown {
        /// The script's own id for it.
        let id: String
        let sender: UserscriptInstance
    }

    private static let category = "userscript"
    /// By the identifier the system knows each by.
    private var shown: [String: Shown] = [:]

    /// Hears of clicks and dismissals from here on: once at launch.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Dismissals are reported too, so `ondone` hears a notification swept away.
        center.setNotificationCategories([UNNotificationCategory(identifier: GMNotifications.category, actions: [],
                                                                 intentIdentifiers: [], options: [.customDismissAction])])
    }

    /// Shows the notification and answers with the system's identifier for
    /// it, which `remove()` hands back.
    func show(_ call: UserscriptCall) async throws(UserscriptRefusal) -> Any? {
        guard call.grants.contains("notification"), let id = call.string("nid") else { throw .notGranted }
        let center = UNUserNotificationCenter.current()
        let sender = call.instance
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
            Task { await sender.push(GMNotifications.event("done", id)) }
            return nil
        }
        let content = UNMutableNotificationContent()
        content.title = call.string("title") ?? call.script.name
        content.body = call.string("text") ?? ""
        content.categoryIdentifier = GMNotifications.category
        if !(call.arguments["silent"] as? Bool ?? false) { content.sound = .default }
        if let image = call.string("image").flatMap(URL.init(string:)), let attachment = await GMNotifications.attachment(image) {
            content.attachments = [attachment]
        }
        // A tag replaces the script's last notification with that tag.
        let identifier = call.string("tag").map { "\(call.script.id)/tag/\($0)" } ?? "\(call.script.id)/\(id)"
        if let replaced = shown[identifier], replaced.id != id {
            Task { await replaced.sender.push(GMNotifications.event("done", replaced.id)) }
        }
        shown[identifier] = Shown(id: id, sender: sender)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        if let timeout = call.arguments["timeout"] as? Double, timeout > 0 {
            Task {
                try? await Task.sleep(for: .milliseconds(Int(timeout)))
                guard shown[identifier]?.id == id else { return }
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                ended(identifier, clicked: false)
            }
        }
        return identifier
    }

    /// `remove()` on what GM_notification returned. A script can take down
    /// only its own.
    func remove(_ call: UserscriptCall) {
        guard let identifier = call.string("identifier"), identifier.hasPrefix(call.script.id + "/") else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        ended(identifier, clicked: false)
    }

    /// Clicked (`onclick`, then `ondone`) or gone (`ondone`).
    private func ended(_ identifier: String, clicked: Bool) {
        guard let notification = shown.removeValue(forKey: identifier) else { return }
        Task {
            if clicked { await notification.sender.push(GMNotifications.event("click", notification.id)) }
            await notification.sender.push(GMNotifications.event("done", notification.id))
        }
    }

    private static func event(_ event: String, _ id: String) -> [String: Any] {
        ["type": "notification", "nid": id, "event": event]
    }

    /// A notification's picture, fetched into a file of its own, which is
    /// how the system takes one.
    private static func attachment(_ url: URL) async -> UNNotificationAttachment? {
        let session = Engine.session(timeout: 15)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, mime) = try? await UserscriptFetch.file(at: url, in: session) else { return nil }
        let type = mime.split(separator: "/").last.map(String.init) ?? "png"
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + (type == "jpeg" ? "jpg" : type))
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: UUID().uuidString, url: file)
    }
}

extension GMNotifications: UNUserNotificationCenterDelegate {
    /// Shown even while Browser is in front, which is when scripts run.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        let clicked = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        await ended(identifier, clicked: clicked)
    }
}
