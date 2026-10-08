import AppKit
import UserNotifications

/// One low-quota notification to deliver.
struct QuotaAlert: Equatable, Sendable {
    var key: String
    var harnessId: String
    var providerTitle: String
    var windowLabel: String
    var threshold: Int
    var remainingPercent: Double
    var resetsAt: Date?
}

/// Pure decision: which windows just crossed 20% / 5% remaining. Each threshold fires
/// once per reset window (the key carries the window's reset time). A window without a
/// reset time re-arms once it is back above the threshold.
enum QuotaAlertPolicy {
    static let thresholds: [Int] = [20, 5]

    static func key(harnessId: String, window: QuotaWindow, threshold: Int) -> String {
        let period = window.resetsAt.map { String(Int(($0.timeIntervalSince1970 / 3600).rounded())) } ?? "-"
        return "\(harnessId)|\(window.id)|\(threshold)|\(period)"
    }

    static func evaluate(
        _ quotas: [ProviderQuota], fired: Set<String>, now: Date = Date()
    ) -> (alerts: [QuotaAlert], fired: Set<String>) {
        var fired = fired
        var alerts: [QuotaAlert] = []
        for quota in quotas.sorted(by: { $0.harnessId < $1.harnessId }) {
            let status = quota.effectiveStatus(now: now)
            guard status == .ok || status == .stale else { continue }
            for window in quota.rateWindows where !window.hasReset(now: now) {
                guard let remaining = window.remainingPercent else { continue }
                // Lowest threshold crossed wins; the higher ones are marked as done too,
                // so dropping straight from 30% to 3% sends one notification, not two.
                var crossed: Int?
                for threshold in thresholds {
                    let key = key(harnessId: quota.harnessId, window: window, threshold: threshold)
                    if remaining <= Double(threshold) {
                        if !fired.contains(key) { crossed = threshold }
                        fired.insert(key)
                    } else if window.resetsAt == nil {
                        fired.remove(key)
                    }
                }
                if let crossed {
                    alerts.append(QuotaAlert(
                        key: key(harnessId: quota.harnessId, window: window, threshold: crossed),
                        harnessId: quota.harnessId, providerTitle: quota.providerTitle,
                        windowLabel: window.label, threshold: crossed,
                        remainingPercent: remaining, resetsAt: window.resetsAt
                    ))
                }
            }
        }
        // Forget periods that have ended.
        let nowHour = Int(now.timeIntervalSince1970 / 3600)
        fired = fired.filter { key in
            guard let period = key.split(separator: "|").last, let hour = Int(period) else { return true }
            return hour >= nowHour - 1
        }
        return (alerts, fired)
    }
}

/// Delivers `QuotaAlertPolicy` alerts as system notifications. Off by default.
@MainActor
final class QuotaNotifier {
    static let enabledKey = "quotaNotifications"
    static let firedKey = "quotaAlertsFired"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Turning the setting on asks for permission right away (not at the first alert).
    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        guard enabled else { return }
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func quotasUpdated(_ quotas: [ProviderQuota]) {
        let fired = Set(defaults.stringArray(forKey: Self.firedKey) ?? [])
        let result = QuotaAlertPolicy.evaluate(quotas, fired: fired)
        // Keep tracking crossings even while off, so turning it on doesn't replay old ones.
        defaults.set(Array(result.fired).sorted(), forKey: Self.firedKey)
        guard Self.isEnabled(defaults) else { return }
        for alert in result.alerts { deliver(alert) }
    }

    /// Adapters label windows with short English tokens ("5h", "Weekly", "Gemini 5h").
    static func displayLabel(_ label: String) -> String {
        let tokens: [(String, String)] = [
            ("Code review", "代码审查"), ("Weekly", "每周"), ("Daily", "每日"), ("Credits", "余额"), ("5h", "5 小时"),
        ]
        var out = label
        for (token, key) in tokens { out = out.replacingOccurrences(of: token, with: key.localized) }
        return out
    }

    private func deliver(_ alert: QuotaAlert) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "%@ 额度快用完了".localized(alert.providerTitle)
        let left = "\(Int(alert.remainingPercent.rounded()))%"
        content.body = "%1$@ 还剩 %2$@".localized(Self.displayLabel(alert.windowLabel), left)
        content.sound = .default
        content.userInfo = ["quota": alert.harnessId]
        center.add(UNNotificationRequest(identifier: "quota." + alert.key, content: content, trigger: nil))
    }
}
