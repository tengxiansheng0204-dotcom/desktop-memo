import Foundation

struct Memo: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var details: String = ""
    var dueAt: Date
    var repeatMinutes: Int = 15
    var completedAt: Date?
    var createdAt = Date()

    var isCompleted: Bool { completedAt != nil }
    static let intervals = [5, 15, 30, 60, 120]
    static let activeLimit = 20
}

/// Stable identifiers prevent the refresh timer from rescheduling or duplicating alerts.
struct PlannedAlert: Equatable {
    let memo: Memo
    let fireAt: Date
    let occurrence: Int
    var identifier: String {
        "\(memo.id.uuidString).\(Int64(memo.dueAt.timeIntervalSince1970 * 1000)).\(occurrence)"
    }
}

enum ReminderPlan {
    static let capacity = 60

    static func alerts(for memos: [Memo], now: Date) -> [PlannedAlert] {
        let active = memos.filter { !$0.isCompleted }
        guard !active.isEmpty else { return [] }
        // Reserve an equal number of pending notifications for each active memo.
        // The resident app replenishes this finite queue every 20 seconds.
        let countPerMemo = capacity / active.count
        return active.flatMap { memo -> [PlannedAlert] in
            let interval = TimeInterval(memo.repeatMinutes * 60)
            guard interval >= 60, countPerMemo > 0 else { return [] }
            let elapsed = now.timeIntervalSince(memo.dueAt)
            let first = elapsed < 0 ? 0 : Int(floor(elapsed / interval)) + 1
            return (first..<(first + countPerMemo)).map { occurrence in
                PlannedAlert(memo: memo,
                             fireAt: memo.dueAt.addingTimeInterval(Double(occurrence) * interval),
                             occurrence: occurrence)
            }
        }.sorted { $0.fireAt < $1.fireAt }
    }
}
