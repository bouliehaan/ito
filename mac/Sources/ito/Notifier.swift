import AppKit
import Foundation
import UserNotifications

/// Banners for texts (reply right from the banner), calls and missed calls.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    weak var model: AppModel?
    private let center: UNUserNotificationCenter?

    override init() {
        // UNUserNotificationCenter needs a real app bundle; `swift run` has none.
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        guard let center else { return }
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "reply", options: [], textInputButtonTitle: "send", textInputPlaceholder: "")
        let answer = UNNotificationAction(identifier: "answer", title: "answer", options: [])
        let decline = UNNotificationAction(identifier: "decline", title: "decline", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "text", actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: "call", actions: [answer, decline], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func text(title: String, body: String, thread: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.threadIdentifier = thread
        c.categoryIdentifier = "text"
        c.userInfo = ["thread": thread]
        post("t-\(thread)-\(UUID().uuidString)", c)
    }

    func ringing(from who: String) {
        let c = UNMutableNotificationContent()
        c.title = who
        c.body = "calling"
        c.sound = .default
        c.categoryIdentifier = "call"
        c.interruptionLevel = .timeSensitive
        post("call", c)
    }

    func missedCall(from who: String) {
        let c = UNMutableNotificationContent()
        c.title = who
        c.body = "missed call"
        post("missed-\(UUID().uuidString)", c)
    }

    func clearCall() {
        center?.removeDeliveredNotifications(withIdentifiers: ["call"])
        center?.removePendingNotificationRequests(withIdentifiers: ["call"])
    }

    func clear(thread: String) {
        guard let center else { return }
        center.getDeliveredNotifications { list in
            let ids = list.filter { $0.request.content.threadIdentifier == thread }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    private func post(_ id: String, _ c: UNMutableNotificationContent) {
        center?.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let thread = response.notification.request.content.userInfo["thread"] as? String
        let action = response.actionIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            guard let model = self.model else { return done() }
            switch action {
            case "reply": if let thread, let typed { model.send(typed, to: thread) }
            case "answer": model.answer()
            case "decline": model.decline()
            default:
                if let thread {
                    model.section = .messages
                    model.selected = thread
                }
                NSApp.activate()
            }
            done()
        }
    }
}
