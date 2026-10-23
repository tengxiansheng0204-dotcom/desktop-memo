import Foundation
import Combine

@MainActor
final class MemoStore: ObservableObject {
    @Published private(set) var memos: [Memo] = []
    @Published var errorMessage: String?
    @Published private(set) var readOnly = false
    var onChange: (() -> Void)?
    private let fileURL: URL

    init(fileURL customFileURL: URL? = nil) {
        if let customFileURL {
            fileURL = customFileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            fileURL = support.appendingPathComponent("DesktopMemo", isDirectory: true)
                .appendingPathComponent("memos.json")
        }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let loaded = try JSONDecoder().decode([Memo].self, from: Data(contentsOf: fileURL))
                guard Set(loaded.map(\.id)).count == loaded.count,
                      loaded.filter({ !$0.isCompleted }).count <= Memo.activeLimit,
                      loaded.allSatisfy({ Memo.intervals.contains($0.repeatMinutes)
                          && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && $0.dueAt.timeIntervalSince1970.isFinite
                          && (-62_135_596_800...253_402_300_799).contains($0.dueAt.timeIntervalSince1970) }) else {
                    throw StoreError.invalidData
                }
                memos = loaded
            }
        } catch {
            readOnly = true
            errorMessage = "无法读取备忘录，已暂停编辑和提醒，原文件保留。\n\(fileURL.path)\n\(error.localizedDescription)"
        }
    }

    var activeCount: Int { memos.filter { !$0.isCompleted }.count }

    @discardableResult
    func save(_ memo: Memo) -> Bool {
        var clean = memo
        clean.title = memo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.title.isEmpty, Memo.intervals.contains(clean.repeatMinutes),
              clean.dueAt.timeIntervalSince1970.isFinite,
              (-62_135_596_800...253_402_300_799).contains(clean.dueAt.timeIntervalSince1970) else {
            errorMessage = "标题、日期或提醒间隔无效。"
            return false
        }
        var next = memos
        if let index = next.firstIndex(where: { $0.id == clean.id }) {
            next[index] = clean
        } else {
            next.append(clean)
        }
        return commit(next)
    }

    func complete(_ id: UUID) {
        guard var memo = memos.first(where: { $0.id == id }) else { return }
        memo.completedAt = Date()
        save(memo)
    }

    func restore(_ id: UUID) {
        guard var memo = memos.first(where: { $0.id == id }) else { return }
        memo.completedAt = nil
        memo.dueAt = Date().addingTimeInterval(15 * 60)
        save(memo)
    }

    func snooze(_ id: UUID) {
        guard var memo = memos.first(where: { $0.id == id }), !memo.isCompleted else { return }
        memo.dueAt = Date().addingTimeInterval(15 * 60)
        save(memo)
    }

    func delete(_ id: UUID) { commit(memos.filter { $0.id != id }) }

    @discardableResult
    private func commit(_ next: [Memo]) -> Bool {
        guard !readOnly else { return false }
        guard next.filter({ !$0.isCompleted }).count <= Memo.activeLimit else {
            errorMessage = "第一版最多支持 20 条未完成事项；请先完成或删除一些事项。"
            return false
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(next).write(to: fileURL, options: .atomic)
            memos = next
            onChange?()
            return true
        } catch {
            errorMessage = "保存失败，本次修改未生效：\(error.localizedDescription)"
            return false
        }
    }

    private enum StoreError: LocalizedError {
        case invalidData
        var errorDescription: String? { "备忘录文件格式或内容无效。" }
    }
}
