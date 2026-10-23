import Foundation
import XCTest
@testable import DesktopMemo

final class MemoStoreTests: XCTestCase {
    private func makeFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopMemoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("memos.json")
    }

    func testSaveAndEditSurviveReloadWithoutDuplicatingMemo() async throws {
        let fileURL = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        try await MainActor.run {
            let store = MemoStore(fileURL: fileURL)
            XCTAssertFalse(store.readOnly)
            XCTAssertTrue(store.memos.isEmpty)
            var changes = 0
            store.onChange = { changes += 1 }
            var memo = Memo(title: "  Buy groceries \n", details: "Milk and bread",
                            dueAt: Date(timeIntervalSince1970: 1_800_000_000), repeatMinutes: 30)

            XCTAssertTrue(store.save(memo))
            XCTAssertEqual(changes, 1)
            XCTAssertEqual(store.memos.first?.title, "Buy groceries")
            let firstReload = MemoStore(fileURL: fileURL)
            XCTAssertEqual(firstReload.memos, store.memos)
            XCTAssertFalse(firstReload.readOnly)

            memo.title = "Buy groceries and fruit"
            memo.repeatMinutes = 60
            XCTAssertTrue(store.save(memo))
            XCTAssertEqual(changes, 2)
            XCTAssertEqual(store.memos.count, 1)
            let reloaded = MemoStore(fileURL: fileURL)
            let saved = try XCTUnwrap(reloaded.memos.first)
            XCTAssertEqual(saved.id, memo.id)
            XCTAssertEqual(saved.title, memo.title)
            XCTAssertEqual(saved.details, memo.details)
            XCTAssertEqual(saved.repeatMinutes, 60)
            XCTAssertEqual(reloaded.memos, store.memos)
        }
    }

    func testCompletionSnoozeRestoreAndDeletePersistAndNotify() async throws {
        let fileURL = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        try await MainActor.run {
            let store = MemoStore(fileURL: fileURL)
            var changes = 0
            store.onChange = { changes += 1 }
            let memo = Memo(title: "Call family", dueAt: Date().addingTimeInterval(-60))
            XCTAssertTrue(store.save(memo))

            let beforeSnooze = Date()
            store.snooze(memo.id)
            let afterSnooze = Date()
            let snoozed = try XCTUnwrap(store.memos.first)
            XCTAssertFalse(snoozed.isCompleted)
            XCTAssertGreaterThanOrEqual(snoozed.dueAt, beforeSnooze.addingTimeInterval(900))
            XCTAssertLessThanOrEqual(snoozed.dueAt, afterSnooze.addingTimeInterval(900))
            XCTAssertEqual(MemoStore(fileURL: fileURL).memos, store.memos)
            XCTAssertEqual(changes, 2)

            let beforeComplete = Date()
            store.complete(memo.id)
            let completed = try XCTUnwrap(store.memos.first)
            XCTAssertTrue(completed.isCompleted)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(completed.completedAt), beforeComplete)
            XCTAssertEqual(store.activeCount, 0)
            XCTAssertEqual(MemoStore(fileURL: fileURL).memos, store.memos)
            XCTAssertEqual(changes, 3)

            store.snooze(memo.id)
            XCTAssertEqual(store.memos.first, completed)
            XCTAssertEqual(changes, 3, "Snoozing a completed memo must not reactivate it")

            let beforeRestore = Date()
            store.restore(memo.id)
            let afterRestore = Date()
            let restored = try XCTUnwrap(store.memos.first)
            XCTAssertFalse(restored.isCompleted)
            XCTAssertEqual(store.activeCount, 1)
            XCTAssertGreaterThanOrEqual(restored.dueAt, beforeRestore.addingTimeInterval(900))
            XCTAssertLessThanOrEqual(restored.dueAt, afterRestore.addingTimeInterval(900))
            XCTAssertEqual(MemoStore(fileURL: fileURL).memos, store.memos)
            XCTAssertEqual(changes, 4)

            store.delete(memo.id)
            XCTAssertTrue(store.memos.isEmpty)
            XCTAssertTrue(MemoStore(fileURL: fileURL).memos.isEmpty)
            XCTAssertEqual(changes, 5)
        }
    }

    func testTwentyActiveMemoLimitRejectsExtraWithoutChangingDisk() async throws {
        let fileURL = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        try await MainActor.run {
            let store = MemoStore(fileURL: fileURL)
            var changes = 0
            store.onChange = { changes += 1 }
            for index in 0..<20 {
                XCTAssertTrue(store.save(Memo(title: "Memo \(index)", dueAt: Date())))
            }
            XCTAssertEqual(store.activeCount, 20)
            let originalData = try Data(contentsOf: fileURL)
            let extra = Memo(title: "Twenty-first memo", dueAt: Date())

            XCTAssertFalse(store.save(extra))
            XCTAssertEqual(store.activeCount, 20)
            XCTAssertFalse(store.memos.contains { $0.id == extra.id })
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(changes, 20)
            XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
            XCTAssertEqual(MemoStore(fileURL: fileURL).activeCount, 20)

            let firstID = try XCTUnwrap(store.memos.first?.id)
            store.complete(firstID)
            XCTAssertTrue(store.save(extra), "Completing a memo must free an active slot")
            XCTAssertEqual(store.activeCount, 20)
            XCTAssertEqual(store.memos.count, 21)
            XCTAssertEqual(changes, 22)
            XCTAssertEqual(MemoStore(fileURL: fileURL).memos, store.memos)

            let beforeRestore = try Data(contentsOf: fileURL)
            store.restore(firstID)
            XCTAssertTrue(try XCTUnwrap(store.memos.first { $0.id == firstID }).isCompleted)
            XCTAssertEqual(changes, 22, "A rejected restore must not announce a saved change")
            XCTAssertEqual(try Data(contentsOf: fileURL), beforeRestore)
        }
    }

    func testCorruptedFileRemainsReadOnlyAndPreservesOriginalBytes() async throws {
        let fileURL = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let originalData = Data("{not valid JSON: original user data}".utf8)
        try originalData.write(to: fileURL)

        try await MainActor.run {
            let store = MemoStore(fileURL: fileURL)
            var changes = 0
            store.onChange = { changes += 1 }
            XCTAssertTrue(store.readOnly)
            XCTAssertTrue(store.memos.isEmpty)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertTrue(store.errorMessage?.contains(fileURL.path) == true)

            XCTAssertFalse(store.save(Memo(title: "Do not overwrite", dueAt: Date())))
            store.delete(UUID())
            XCTAssertTrue(store.readOnly)
            XCTAssertTrue(store.memos.isEmpty)
            XCTAssertEqual(changes, 0)
            XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
        }
    }

    func testWriteFailureDoesNotPublishUnsavedChanges() async throws {
        let fileURL = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        try await MainActor.run {
            let store = MemoStore(fileURL: fileURL)
            var changes = 0
            store.onChange = { changes += 1 }
            let memo = Memo(title: "Saved memo", dueAt: Date())
            XCTAssertTrue(store.save(memo))
            let original = store.memos
            // A directory at the destination deterministically blocks a JSON file write,
            // without relying on user privileges or filesystem permission behavior.
            try FileManager.default.removeItem(at: fileURL)
            try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)

            store.complete(memo.id)
            XCTAssertEqual(store.memos, original)
            XCTAssertEqual(changes, 1)
            XCTAssertNotNil(store.errorMessage)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
    }
}
