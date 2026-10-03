import AppKit
import UserNotifications

/// Tells the user when a session they aren't looking at needs them: a system
/// notification for new permission / plan / question requests (and finished
/// turns while the app is in the background), plus a Dock badge count.
@MainActor
final class AttentionNotifier: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    var onActivate: ((UUID) -> Void)?

    private var lastPending: [UUID: String] = [:]
    private var lastStreaming: Set<UUID> = []
    private var authorized: Bool?
    private var badge = 0

    /// UNUserNotificationCenter needs a real bundle (not unit-test hosts).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        center?.delegate = self
    }

    func update(sessions: [ChatSession], selectedID: UUID?) {
        let appActive = NSApp?.isActive ?? true
        var pending: [UUID: String] = [:]
        var streaming: Set<UUID> = []
        for session in sessions {
            if session.isStreaming { streaming.insert(session.id) }
            if let prompt = session.pendingPermission {
                pending[session.id] = "permission:" + prompt.title
            } else if session.pendingPlanApproval != nil {
                pending[session.id] = "plan"
            } else if session.pendingUserQuestion != nil {
                pending[session.id] = "question"
            }
        }
        for session in sessions {
            let visible = appActive && session.id == selectedID
            if let key = pending[session.id], lastPending[session.id] != key, !visible {
                let body: String
                if let prompt = session.pendingPermission {
                    body = "%@ 请求批准：%@".localized(session.agent.title, prompt.title)
                } else if key == "plan" {
                    body = "%@ 的计划已就绪，等待你批准".localized(session.agent.title)
                } else {
                    body = "%@ 有问题需要你回答".localized(session.agent.title)
                }
                notify(id: session.id, title: session.title, body: body)
            } else if lastStreaming.contains(session.id), !streaming.contains(session.id),
                      pending[session.id] == nil, !appActive {
                notify(id: session.id, title: session.title, body: "%@ 已完成".localized(session.agent.title))
            }
        }
        lastPending = pending
        lastStreaming = streaming
        let count = pending.keys.filter { $0 != selectedID || !appActive }.count
        if count != badge {
            badge = count
            NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
    }

    private func notify(id: UUID, title: String, body: String) {
        guard let center else { return }
        if authorized == true { deliver(id: id, title: title, body: body); return }
        if authorized == false { return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.authorized = granted
                    if granted { self.deliver(id: id, title: title, body: body) }
                }
            }
        }
    }

    private func deliver(id: UUID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Aureways" : title
        content.body = body
        content.sound = .default
        content.userInfo = ["session": id.uuidString]
        center?.add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["session"] as? String,
              let id = UUID(uuidString: raw) else { return }
        onActivate?(id)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
