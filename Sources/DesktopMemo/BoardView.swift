import SwiftUI
import AppKit

@MainActor
struct BoardView: View {
    @ObservedObject var store: MemoStore
    @ObservedObject var notifications: NotificationService
    var onPin: (Bool) -> Void
    @AppStorage("pinned") private var pinned = true
    @StateObject private var login = LoginPreference()
    @State private var showCompleted = false
    @State private var draft: Memo?
    @State private var pendingDelete: Memo?
    private let accent = Color(red: 0.17, green: 0.46, blue: 0.37)

    private var visible: [Memo] {
        store.memos.filter { $0.isCompleted == showCompleted }.sorted {
            showCompleted ? ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
                          : $0.dueAt < $1.dueAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("桌面备忘").font(.system(size: 25, weight: .bold, design: .rounded))
                    Text(store.activeCount == 0 ? "给重要的小事，留一个位置。" : "还有 \(store.activeCount) 件事，慢慢来。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    pinned.toggle()
                    onPin(pinned)
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .foregroundStyle(pinned ? accent : .secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .help(pinned ? "取消置顶" : "始终置顶")
                Menu {
                    Toggle("开机启动", isOn: Binding(get: { login.enabled }, set: { login.setEnabled($0) }))
                    Button("打开系统通知设置") { openNotificationSettings() }
                    Divider()
                    Text("关闭窗口后，仍在菜单栏运行")
                    Text("第一版支持 20 条未完成事项")
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if !notifications.isAuthorized {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge").foregroundStyle(accent)
                    Text(notifications.permissionText).font(.caption)
                    Spacer(minLength: 0)
                    Button("开启") {
                        Task {
                            await notifications.requestPermission()
                            if notifications.isAuthorized {
                                notifications.synchronize(store.memos, catchUp: true)
                            } else { openNotificationSettings() }
                        }
                    }.controlSize(.small)
                }
                .padding(12).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }

            if let error = notifications.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if store.readOnly {
                Label("数据读取失败，编辑和提醒已暂停。请按使用说明恢复备份。", systemImage: "lock")
                    .font(.caption).foregroundStyle(.red)
            }

            Picker("查看事项", selection: $showCompleted) {
                Text("待完成 · \(store.activeCount)").tag(false)
                Text("已完成 · \(store.memos.count - store.activeCount)").tag(true)
            }.pickerStyle(.segmented)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if visible.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: showCompleted ? "checkmark.seal" : "leaf")
                                .font(.system(size: 38, weight: .light)).foregroundStyle(accent.opacity(0.7))
                            Text(showCompleted ? "做完的小事，会收在这里" : "现在，留点空白也很好")
                                .font(.headline)
                            Text(showCompleted ? "在待完成列表勾选事项即可归档。" : "添加一件事，设置时间，剩下的交给提醒。")
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 65)
                    }
                    ForEach(visible) { memo in
                        MemoCard(memo: memo,
                                 complete: { store.complete(memo.id) },
                                 snooze: { store.snooze(memo.id) },
                                 edit: { draft = memo },
                                 restore: { store.restore(memo.id) },
                                 delete: { pendingDelete = memo })
                    }
                }.padding(.vertical, 2)
            }

            VStack(spacing: 9) {
                Button {
                    draft = Memo(title: "", dueAt: Date().addingTimeInterval(15 * 60))
                } label: {
                    Label("添加备忘录", systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent).tint(accent)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(store.readOnly || store.activeCount >= Memo.activeLimit)
                Text(store.activeCount >= Memo.activeLimit
                     ? "已达到 20 条待办上限，完成一些后可继续添加"
                     : "未完成会重复提醒 · 勾选后停止 · 数据仅保存在本机")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(minWidth: 370, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $draft) { memo in MemoEditor(memo: memo, store: store) }
        .alert("删除这条备忘录？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) {
                    if let memo = pendingDelete { store.delete(memo.id) }
                    pendingDelete = nil
                }
            } message: { Text("删除后将停止提醒，此操作无法撤销。") }
        .alert("需要处理", isPresented: Binding(
            get: { store.errorMessage != nil || login.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil; login.errorMessage = nil } })) {
                Button("知道了") { store.errorMessage = nil; login.errorMessage = nil }
            } message: { Text(store.errorMessage ?? login.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct MemoCard: View {
    let memo: Memo
    let complete: () -> Void
    let snooze: () -> Void
    let edit: () -> Void
    let restore: () -> Void
    let delete: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let overdue = !memo.isCompleted && memo.dueAt <= context.date
            HStack(alignment: .top, spacing: 12) {
                Button(action: memo.isCompleted ? restore : complete) {
                    Image(systemName: memo.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21, weight: .light))
                        .foregroundStyle(memo.isCompleted ? Color.green : Color.secondary)
                }.buttonStyle(.plain)
                    .help(memo.isCompleted ? "恢复为待办，15 分钟后提醒" : "标记已完成并停止提醒")
                    .accessibilityLabel(memo.isCompleted ? "恢复 \(memo.title)" : "完成 \(memo.title)")
                VStack(alignment: .leading, spacing: 8) {
                    Text(memo.title).font(.system(size: 14, weight: .medium))
                        .strikethrough(memo.isCompleted).lineLimit(3)
                    if !memo.details.isEmpty {
                        Text(memo.details).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if memo.isCompleted {
                        Text("已完成").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Label {
                            Text(memo.dueAt, format: .dateTime.month().day().hour().minute())
                        } icon: { Image(systemName: overdue ? "bell.badge.fill" : "clock") }
                        .font(.system(size: 11)).foregroundStyle(overdue ? Color.orange : Color.secondary)
                        Text("\(overdue ? "已到期 · " : "")未完成每 \(memo.repeatMinutes) 分钟提醒")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    if !memo.isCompleted {
                        Button("编辑", action: edit)
                        Button("15 分钟后提醒", action: snooze)
                        Button("标记完成", action: complete)
                    } else {
                        Button("恢复为待办", action: restore)
                    }
                    Divider()
                    Button("删除", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(14)
            .background(overdue ? Color.orange.opacity(0.07) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(overdue ? Color.orange.opacity(0.18) : Color.primary.opacity(0.05)))
        }
    }
}

@MainActor
private struct MemoEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: MemoStore
    @State private var draft: Memo
    @State private var validation: String?
    @FocusState private var titleFocused: Bool
    private let isNew: Bool

    init(memo: Memo, store: MemoStore) {
        self.store = store
        _draft = State(initialValue: memo)
        isNew = !store.memos.contains(where: { $0.id == memo.id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "记下一件事" : "编辑备忘录").font(.title2.bold())
            TextField("例如：给家人打个电话", text: $draft.title)
                .textFieldStyle(.roundedBorder).focused($titleFocused)
            VStack(alignment: .leading, spacing: 6) {
                Text("补充说明（可选）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.details).font(.body)
                    .frame(height: 80).padding(5)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)))
            }
            DatePicker("首次提醒", selection: $draft.dueAt, displayedComponents: [.date, .hourAndMinute])
            Picker("未完成时", selection: $draft.repeatMinutes) {
                ForEach(Memo.intervals, id: \.self) { value in
                    Text("每 \(value) 分钟提醒").tag(value)
                }
            }
            Text("到期后会按此间隔重复提醒，勾选完成即可停止。")
                .font(.caption).foregroundStyle(.secondary)
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    if isNew && draft.dueAt <= Date() {
                        validation = "请选择一个未来的首次提醒时间。"
                    } else if draft.title.count > 200 || draft.details.count > 2000 {
                        validation = "标题最多 200 字，补充说明最多 2000 字。"
                    } else if store.save(draft) {
                        dismiss()
                    } else {
                        validation = store.errorMessage ?? "请输入备忘录标题。"
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 390)
            .onAppear { titleFocused = true }
    }
}
