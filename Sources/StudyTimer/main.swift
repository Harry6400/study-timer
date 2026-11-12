import AppKit
import SwiftUI
import UniformTypeIdentifiers
import StudyTimerCore

@MainActor final class RecordWindow: NSWindow {
    var undoRecordAction: (() -> Void)?
    var redoRecordAction: (() -> Void)?
    var canUndoRecord: (() -> Bool)?
    var canRedoRecord: (() -> Bool)?
    @objc(undo:) func undoRecord(_ sender: Any?) { undoRecordAction?() }
    @objc(redo:) func redoRecord(_ sender: Any?) { redoRecordAction?() }
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undoRecord(_:)) { return canUndoRecord?() ?? false }
        if item.action == #selector(redoRecord(_:)) { return canRedoRecord?() ?? false }
        return super.validateMenuItem(item)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var model: AppModel!
    private var floating: FloatingController!
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var visibilityItem: NSMenuItem!
    private var statisticsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var terminationStarted = false
    private var occlusionObservers: [NSObjectProtocol] = []
    private var lastMenuBarTimer: Bool?
    private var lastStatus: TimerStatus?
    private var lastVisibility: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let verification = CommandLine.arguments.contains("--data-directory") || Bundle.main.object(forInfoDictionaryKey: "StudyTimerVerificationDirectory") != nil
        NSApp.setActivationPolicy(verification ? .regular : .accessory)
        configureMainMenu()
        do { model = try AppModel() }
        catch {
            alert("无法打开学习记录", detail: error.localizedDescription); NSApp.terminate(nil); return
        }
        if model.isVerification {
            if CommandLine.arguments.contains("--verification-run") { try? model.start(text: "0") }
            if CommandLine.arguments.contains("--verification-month") { model.preferences.statisticsLayout = .trend }
        }
        if CommandLine.arguments.contains("--resume-after-update"), model.engine.state.status == .paused {
            model.toggle()
        }
        floating = FloatingController(model: model)
        floating.showStatistics = { [weak self] in self?.showStatistics() }
        floating.showSettings = { [weak self] in self?.showSettings() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        pauseItem = item("继续计时", action: #selector(toggle), menu: menu, shortcut: "P")
        visibilityItem = item("隐藏悬浮窗", action: #selector(toggleVisibility), menu: menu)
        menu.addItem(.separator())
        _ = item("学习统计…", action: #selector(showStatistics), menu: menu, shortcut: "1")
        _ = item("设置…", action: #selector(showSettings), menu: menu, shortcut: ",")
        menu.addItem(.separator())
        _ = item("退出学习计时器", action: #selector(quit), menu: menu, shortcut: "q")
        statusItem.menu = menu
        model.onUpdate = { [weak self] in self?.update() }
        update()
        if CommandLine.arguments.contains("--statistics") { showStatistics() }
    }
    private func item(_ title: String, action: Selector, menu: NSMenu, shortcut: String = "") -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: shortcut)
        if shortcut == "P" { value.keyEquivalent = "p"; value.keyEquivalentModifierMask = [.command, .shift] }
        value.target = self; menu.addItem(value); return value
    }
    private func configureMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(), appMenu = NSMenu(title: "学习计时器")
        _ = item("设置…", action: #selector(showSettings), menu: appMenu, shortcut: ",")
        _ = item("暂停／继续计时", action: #selector(toggle), menu: appMenu, shortcut: "P")
        appMenu.addItem(.separator())
        _ = item("退出学习计时器", action: #selector(quit), menu: appMenu, shortcut: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(), editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("拷贝", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        let redo = NSMenuItem(title: "重做", action: #selector(redo(_:)), keyEquivalent: "Z")
        redo.keyEquivalent = "z"; redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.insertItem(redo, at: 1)
        editItem.submenu = editMenu; main.addItem(editItem)
        let windowItem = NSMenuItem(), windowMenu = NSMenu(title: "窗口")
        _ = item("学习统计…", action: #selector(showStatistics), menu: windowMenu, shortcut: "1")
        windowItem.submenu = windowMenu; main.addItem(windowItem)
        NSApp.mainMenu = main
    }
    private func update() {
        guard model != nil, statusItem != nil else { return }
        floating.update()
        if lastMenuBarTimer != model.preferences.menuBarTimer {
            statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            statusItem.button?.image = model.preferences.menuBarTimer ? nil : NSImage(systemSymbolName: "timer", accessibilityDescription: "学习计时器")
            lastMenuBarTimer = model.preferences.menuBarTimer
        }
        let title = model.preferences.menuBarTimer ? model.engine.display : ""
        if statusItem.button?.title != title { statusItem.button?.title = title }
        if lastStatus != model.engine.state.status {
            statusItem.button?.toolTip = "学习计时器 · \(model.statusText)"
            pauseItem.title = model.isRunning ? "暂停计时" : model.engine.state.status == .completed ? "重新开始" : "继续计时"
            lastStatus = model.engine.state.status
        }
        if lastVisibility != floating.panel.isVisible {
            visibilityItem.title = floating.panel.isVisible ? "隐藏悬浮窗" : "显示悬浮窗"
            lastVisibility = floating.panel.isVisible
        }
    }
    @objc private func toggle() { if model.shortcutEnabled { model.toggle() } }
    @objc func undo(_ sender: Any?) { recordHistory(undo: true) }
    @objc func redo(_ sender: Any?) { recordHistory(undo: false) }
    private func recordHistory(undo: Bool) {
        guard model.shortcutEnabled, NSApp.keyWindow === statisticsWindow else { return }
        Task {
            do { if undo { try await model.undoRecord() } else { try await model.redoRecord() } }
            catch { alert("无法修改记录", detail: error.localizedDescription) }
        }
    }
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggle) { return model?.shortcutEnabled == true }
        if item.action == #selector(undo(_:)) { return model.canUndo && model.shortcutEnabled && NSApp.keyWindow === statisticsWindow }
        if item.action == #selector(redo(_:)) { return model.canRedo && model.shortcutEnabled && NSApp.keyWindow === statisticsWindow }
        return true
    }
    @objc private func toggleVisibility() { floating.toggleVisibility(); update() }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationStarted else { return .terminateCancel }
        guard model != nil else { return .terminateNow }
        guard !model.isMutating else { return .terminateCancel }
        terminationStarted = true
        Task { await model.quit(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        floating.panel.orderFrontRegardless(); update(); return true
    }
    private func window(title: String, size: NSSize, resizable: Bool, controller: NSViewController, recordEditing: Bool = false) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let value: NSWindow
        if recordEditing {
            let recordWindow = RecordWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
            recordWindow.undoRecordAction = { [weak self] in self?.recordHistory(undo: true) }
            recordWindow.redoRecordAction = { [weak self] in self?.recordHistory(undo: false) }
            recordWindow.canUndoRecord = { [weak self] in self?.model.canUndo == true && self?.model.shortcutEnabled == true }
            recordWindow.canRedoRecord = { [weak self] in self?.model.canRedo == true && self?.model.shortcutEnabled == true }
            value = recordWindow
        } else { value = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false) }
        value.title = title; value.contentViewController = controller; value.isReleasedWhenClosed = false
        value.setContentSize(size)
        value.setFrameAutosaveName("StudyTimer.\(title).v1.\(model.isVerification ? "verification" : "main")")
        value.setContentSize(size); value.center(); return value
    }
    @objc private func showStatistics() {
        if statisticsWindow == nil {
            let controller = NSHostingController(rootView: StatisticsView(model: model))
            controller.sizingOptions = []
            statisticsWindow = window(title: "学习统计", size: NSSize(width: 920, height: 650), resizable: true,
                controller: controller, recordEditing: true)
            statisticsWindow?.contentMinSize = NSSize(width: 780, height: 620)
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                let observer = NotificationCenter.default.addObserver(forName: name, object: statisticsWindow, queue: .main) { [weak self] notification in
                    let isClosing = notification.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated {
                        guard let self, let window = self.statisticsWindow else { return }
                        self.model.statisticsVisible = !isClosing && window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized
                    }
                }
                occlusionObservers.append(observer)
            }
        }
        NSApp.activate(ignoringOtherApps: true); statisticsWindow?.makeKeyAndOrderFront(nil)
        model.statisticsVisible = true
        if model.isVerification && CommandLine.arguments.contains("--verification-minimum") {
            statisticsWindow?.setContentSize(NSSize(width: 780, height: 620))
        }
    }
    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = window(title: "设置", size: NSSize(width: 470, height: 470), resizable: false,
                controller: NSHostingController(rootView: SettingsView(model: model,
                    backup: { [weak self] in self?.exportBackup() }, csv: { [weak self] in self?.exportCSV() }, restore: { [weak self] in self?.restoreBackup() })))
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private func savePanel(name: String, type: UTType) -> URL? {
        model.modalDepth += 1; defer { model.modalDepth = max(0, model.modalDepth - 1) }
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true; NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func exportBackup() {
        guard let url = savePanel(name: "学习计时器备份.json", type: .json) else { return }
        Task { do { try await model.exportBackup(to: url) } catch { alert("备份失败", detail: error.localizedDescription) } }
    }
    private func exportCSV() {
        guard let url = savePanel(name: "学习时间.csv", type: .commaSeparatedText) else { return }
        do { try model.exportCSV(to: url) } catch { alert("导出失败", detail: error.localizedDescription) }
    }
    private func restoreBackup() {
        model.modalDepth += 1; defer { model.modalDepth = max(0, model.modalDepth - 1) }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try Backup.decode(Data(contentsOf: url))
            let confirm = NSAlert(); confirm.messageText = "用备份替换目前的学习记录和设置？"
            confirm.informativeText = "当前数据会先完整备份到“自动备份／操作前”文件夹。恢复后计时保持暂停。"
            confirm.addButton(withTitle: "取消"); confirm.addButton(withTitle: "恢复备份")
            guard confirm.runModal() == .alertSecondButtonReturn else { return }
            Task {
                do { try await model.restore(from: url); floating.restoreFrameFromPreferences() }
                catch { alert("恢复失败", detail: error.localizedDescription) }
            }
        } catch { alert("恢复失败", detail: error.localizedDescription) }
    }
    private func alert(_ title: String, detail: String) {
        if model != nil { model.modalDepth += 1 }
        defer { if model != nil { model.modalDepth = max(0, model.modalDepth - 1) } }
        let value = NSAlert(); value.messageText = title; value.informativeText = detail; value.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true); value.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
