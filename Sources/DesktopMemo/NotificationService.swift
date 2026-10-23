import Foundation
import Combine
import UserNotifications

@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var permissionText = "正在检查通知权限…"
    @Published private(set) var isAuthorized = false
    @Published private(set) var errorMessage: String?
    var onComplete: ((UUID) -> Void)?
    var onSnooze: ((UUID) -> Void)?
    var onOpen: (() -> Void)?
    private let center = UNUserNotificationCenter.current()
    private var queue: Task<Void, Never>?
    private var generation = 0
    private var catchUpPending = false
    private var contentUpdatePending = false
    private var knownRevisions: [String: String] = [:]

    override init() {
        super.init()
        center.delegate = self
        let done = UNNotificationAction(identifier: "DONE", title: "已完成", options: [])
        let later = UNNotificationAction(identifier: "LATER", title: "15 分钟后提醒", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "MEMO", actions: [done, later],
                                   intentIdentifiers: [], options: [])
        ])
    }

    func refreshPermission() async {
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            permissionText = "系统通知已开启"
        case .denied:
            permissionText = "通知被关闭，请在系统设置中开启"
        default:
            permissionText = "开启通知后，才能收到到期提醒"
        }
    }

    func requestPermission() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            errorMessage = nil
        } catch {
            errorMessage = "申请通知权限失败：\(error.localizedDescription)"
        }
        await refreshPermission()
    }

    /// Serialize all mutations so a refresh cannot put back a completed memo's alerts.
    func synchronize(_ memos: [Memo], catchUp: Bool = false, updateContent: Bool = false) {
        generation += 1
        let version = generation
        catchUpPending = catchUpPending || catchUp
        contentUpdatePending = contentUpdatePending || updateContent
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self, version == self.generation else { return }
            await self.apply(memos, version: version, catchUp: self.catchUpPending,
                             updateContent: self.contentUpdatePending)
        }
    }

    private func apply(_ memos: [Memo], version: Int, catchUp: Bool, updateContent: Bool) async {
        let now = Date()
        let active = memos.filter { !$0.isCompleted }
        let activeIDs = Set(active.map { $0.id.uuidString })
        let pending = await center.pendingNotificationRequests()
        guard version == generation else { return }
        let plan = ReminderPlan.alerts(for: memos, now: now)
        let plannedIDs = Set(plan.map(\.identifier))
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id.uuidString, $0) })
        let obsolete = pending.filter { request in
            guard let id = request.content.userInfo["memoID"] as? String,
                  let memo = byID[id] else { return true }
            // Editing/snoozing invalidates the old cadence, including near-due requests.
            let revision = request.content.userInfo["revision"] as? String
            if revision != Self.revision(memo) { return true }
            if request.identifier.hasSuffix(".catchup") { return false }
            if plannedIDs.contains(request.identifier) { return false }
            // Let an alert already due finish delivering; do not race the OS at its deadline.
            let fire = request.content.userInfo["fireAt"] as? Double ?? 0
            // After sleep, replace stale queued occurrences with one catch-up per memo.
            if catchUp && fire < now.timeIntervalSince1970 - 2 { return true }
            return fire > now.timeIntervalSince1970 + 2
        }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
        let delivered = await center.deliveredNotifications()
        guard version == generation else { return }
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
            guard let id = $0.request.content.userInfo["memoID"] as? String,
                  activeIDs.contains(id), let memo = byID[id] else { return true }
            return $0.request.content.userInfo["revision"] as? String != Self.revision(memo)
        }.map { $0.request.identifier })

        guard isAuthorized else { return }
        let remaining = Set(pending.map(\.identifier)).subtracting(obsolete)
        do {
            // Catch up once on launch/wake/permission grant. Keep the queue within 60 entries.
            let overdueCandidates = active.filter {
                $0.dueAt <= now && (catchUp || knownRevisions[$0.id.uuidString] != Self.revision($0))
            }
            let existingExtras = pending.filter {
                remaining.contains($0.identifier) && !plannedIDs.contains($0.identifier)
            }.count
            var availableExtras = max(0, ReminderPlan.capacity - existingExtras)
            let overdue = overdueCandidates.filter { memo in
                if remaining.contains("\(memo.id.uuidString).catchup") { return true }
                guard availableExtras > 0 else { return false }
                availableExtras -= 1
                return true
            }
            let catchUpIDs = Set(overdue.map { "\($0.id.uuidString).catchup" })
            let newExtras = catchUpIDs.subtracting(remaining).count
            let budget = max(0, ReminderPlan.capacity - existingExtras - newExtras)
            // Remove farthest future entries before inserting catch-up notices.
            let selected = Array(plan.prefix(budget))
            let selectedIDs = Set(selected.map(\.identifier))
            center.removePendingNotificationRequests(withIdentifiers:
                Array(plannedIDs.subtracting(selectedIDs).intersection(remaining)))
            for alert in selected where updateContent || !remaining.contains(alert.identifier) {
                guard version == generation else { return }
                try await add(memo: alert.memo, identifier: alert.identifier, fireAt: alert.fireAt)
                guard version == generation else { return }
            }
            for memo in overdue {
                guard version == generation else { return }
                let identifier = "\(memo.id.uuidString).catchup"
                if !remaining.contains(identifier) {
                    try await add(memo: memo, identifier: identifier, fireAt: now.addingTimeInterval(3))
                    guard version == generation else { return }
                }
            }
            knownRevisions = Dictionary(uniqueKeysWithValues: active.map { ($0.id.uuidString, Self.revision($0)) })
            catchUpPending = false
            contentUpdatePending = false
            errorMessage = nil
        } catch {
            guard version == generation else { return }
            errorMessage = "部分提醒未能安排，将自动重试：\(error.localizedDescription)"
        }
    }

    private static func revision(_ memo: Memo) -> String {
        "\(memo.dueAt.timeIntervalSince1970)-\(memo.repeatMinutes)"
    }

    private func add(memo: Memo, identifier: String, fireAt: Date) async throws {
        let content = UNMutableNotificationContent()
        content.title = memo.title
        content.body = memo.details.isEmpty ? "这件事还未完成。完成后勾选，即可停止提醒。" : memo.details
        content.sound = .default
        content.categoryIdentifier = "MEMO"
        content.threadIdentifier = memo.id.uuidString
        content.userInfo = ["memoID": memo.id.uuidString, "revision": Self.revision(memo),
                            "fireAt": fireAt.timeIntervalSince1970]
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, fireAt.timeIntervalSinceNow), repeats: false)
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let rawID = response.notification.request.content.userInfo["memoID"] as? String
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            if let rawID, let id = UUID(uuidString: rawID) {
                switch action {
                case "DONE": self?.onComplete?(id)
                case "LATER": self?.onSnooze?(id)
                default: self?.onOpen?()
                }
            }
            // A new change may supersede the task being awaited; wait for a stable batch.
            if let self {
                while true {
                    let version = self.generation
                    await self.queue?.value
                    if version == self.generation { break }
                }
            }
            completionHandler()
        }
    }
}
