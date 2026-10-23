import SwiftUI
import AppKit
import ServiceManagement

@main
@MainActor
struct DesktopMemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = MemoStore()
    private let notifications = NotificationService()
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        notifications.onComplete = { [weak self] in self?.store.complete($0) }
        notifications.onSnooze = { [weak self] in self?.store.snooze($0) }
        notifications.onOpen = { [weak self] in self?.showWindow() }
        store.onChange = { [weak self] in
            guard let self else { return }
            self.notifications.synchronize(self.store.memos, updateContent: true)
            self.updateBadge()
        }

        let content = BoardView(store: store, notifications: notifications,
                                onPin: { [weak self] in self?.setPinned($0) })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "桌面备忘"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.contentView = NSHostingView(rootView: content)
        window.minSize = NSSize(width: 370, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        window.setFrameAutosaveName("DesktopMemo.Board")
        setPinned(UserDefaults.standard.object(forKey: "pinned") as? Bool ?? true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "桌面备忘")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "显示备忘录", action: #selector(showWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出桌面备忘…", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
        updateBadge()
        showWindow()

        timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(catchUp: false) }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh(catchUp: true) }
            }
        Task { await refresh(catchUp: true) }
    }

    private func refresh(catchUp: Bool) async {
        let wasAuthorized = notifications.isAuthorized
        await notifications.refreshPermission()
        notifications.synchronize(store.readOnly ? [] : store.memos,
                                  catchUp: catchUp || (!wasAuthorized && notifications.isAuthorized))
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await refresh(catchUp: false) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc func showWindow() {
        guard window != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func setPinned(_ pinned: Bool) {
        window?.level = pinned ? .floating : .normal
    }

    private func updateBadge() {
        statusItem?.button?.title = store.activeCount == 0 ? "" : " \(store.activeCount)"
    }

    @objc private func quitApp() {
        let alert = NSAlert()
        alert.messageText = "退出桌面备忘？"
        alert.informativeText = "退出后无法持续补充重复提醒，已安排的有限几次系统通知仍可能出现。关闭便签窗口即可保持后台提醒。"
        alert.addButton(withTitle: "留在后台")
        alert.addButton(withTitle: "退出")
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
    }
}

@MainActor
final class LoginPreference: ObservableObject {
    @Published private(set) var enabled = SMAppService.mainApp.status == .enabled
    @Published var errorMessage: String?

    func setEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            enabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                errorMessage = "请在系统设置 → 通用 → 登录项中允许桌面备忘。"
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            enabled = SMAppService.mainApp.status == .enabled
            errorMessage = "开机启动设置失败：\(error.localizedDescription)"
        }
    }

    func refresh() { enabled = SMAppService.mainApp.status == .enabled }
}
