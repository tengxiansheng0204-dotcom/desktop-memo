import Foundation
import XCTest
@testable import DesktopMemo

final class ReminderPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFutureMemoStartsAtItsDueTime() throws {
        let due = now.addingTimeInterval(120)
        let memo = Memo(title: "Future reminder", dueAt: due)

        let first = try XCTUnwrap(ReminderPlan.alerts(for: [memo], now: now).first)

        XCTAssertEqual(first.memo.id, memo.id)
        XCTAssertEqual(first.occurrence, 0)
        XCTAssertEqual(first.fireAt, due)
    }

    func testFutureRepeatsStayAnchoredToDueTime() {
        let due = now.addingTimeInterval(127)
        let memo = Memo(title: "Anchored reminder", dueAt: due, repeatMinutes: 15)

        let alerts = ReminderPlan.alerts(for: [memo], now: now)

        XCTAssertEqual(Array(alerts.prefix(4).map(\.occurrence)), [0, 1, 2, 3])
        XCTAssertEqual(Array(alerts.prefix(4).map(\.fireAt)),
                       [due, due.addingTimeInterval(900),
                        due.addingTimeInterval(1_800), due.addingTimeInterval(2_700)])
    }

    func testOverdueMemoSkipsExpiredOccurrences() throws {
        let due = now.addingTimeInterval(-1_901)
        let memo = Memo(title: "Overdue reminder", dueAt: due, repeatMinutes: 15)

        let alerts = ReminderPlan.alerts(for: [memo], now: now)
        let first = try XCTUnwrap(alerts.first)

        XCTAssertEqual(first.occurrence, 3)
        XCTAssertEqual(first.fireAt, due.addingTimeInterval(2_700))
        XCTAssertTrue(alerts.allSatisfy { $0.fireAt > now })
    }

    func testRefreshAtOccurrenceBoundarySchedulesOnlyFutureOccurrences() throws {
        let due = now.addingTimeInterval(-900)
        let memo = Memo(title: "Boundary reminder", dueAt: due, repeatMinutes: 15)

        let first = try XCTUnwrap(ReminderPlan.alerts(for: [memo], now: now).first)

        XCTAssertEqual(first.occurrence, 2)
        XCTAssertEqual(first.fireAt, now.addingTimeInterval(900))
    }

    func testCompletedMemosDoNotReceiveAlertsOrConsumeCapacity() {
        let active = Memo(title: "Active", dueAt: now.addingTimeInterval(60))
        let completed = Memo(title: "Completed", dueAt: now.addingTimeInterval(60),
                             completedAt: now)

        let alerts = ReminderPlan.alerts(for: [active, completed], now: now)

        XCTAssertEqual(alerts.count, ReminderPlan.capacity)
        XCTAssertTrue(alerts.allSatisfy { $0.memo.id == active.id })
        XCTAssertTrue(ReminderPlan.alerts(for: [completed], now: now).isEmpty)
    }

    func testTwentyActiveMemosReceiveEqualSharesWithinCapacity() {
        let memos = (0..<20).map { index in
            Memo(title: "Memo \(index)",
                 dueAt: now.addingTimeInterval(Double(index + 1) * 60),
                 repeatMinutes: Memo.intervals[index % Memo.intervals.count])
        }

        let alerts = ReminderPlan.alerts(for: memos, now: now)
        let grouped = Dictionary(grouping: alerts, by: { $0.memo.id })

        XCTAssertEqual(alerts.count, 60)
        XCTAssertLessThanOrEqual(alerts.count, ReminderPlan.capacity)
        XCTAssertEqual(grouped.count, 20)
        for memo in memos {
            XCTAssertEqual(grouped[memo.id]?.count, 3)
        }
        XCTAssertEqual(alerts.map(\.fireAt), alerts.map(\.fireAt).sorted())
        XCTAssertEqual(Set(alerts.map(\.identifier)).count, alerts.count)
    }

    func testPendingAlertIdentifiersRemainStableAcrossRefreshes() throws {
        let memo = Memo(title: "Persistent reminder", dueAt: now.addingTimeInterval(10))
        let before = ReminderPlan.alerts(for: [memo], now: now)
        let after = ReminderPlan.alerts(for: [memo], now: now.addingTimeInterval(20))
        let beforeByOccurrence = Dictionary(uniqueKeysWithValues:
            before.map { ($0.occurrence, $0) })

        XCTAssertEqual(after.first?.occurrence, 1)
        XCTAssertNotEqual(before.first?.identifier, after.first?.identifier)
        let overlapping = after.filter { beforeByOccurrence[$0.occurrence] != nil }
        XCTAssertEqual(overlapping.count, ReminderPlan.capacity - 1)
        for alert in overlapping {
            let previous = try XCTUnwrap(beforeByOccurrence[alert.occurrence])
            XCTAssertEqual(alert.identifier, previous.identifier)
            XCTAssertEqual(alert.fireAt, previous.fireAt)
        }
    }

    func testEmptyListProducesNoAlerts() {
        XCTAssertTrue(ReminderPlan.alerts(for: [], now: now).isEmpty)
    }
}
