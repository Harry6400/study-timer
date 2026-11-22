import Foundation

struct FloatingAppearance: Equatable {
    let theme: TimerTheme
    let opacity: Double
    let reduceTransparency: Bool
    @MainActor init(_ preferences: Preferences) {
        theme = preferences.theme; opacity = preferences.glassOpacity
        reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}

import AppKit
import SwiftUI
import StudyTimerCore

final class TimerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class FloatingView: NSView {
    private let glass = NSGlassEffectView()
    private let content = NSView()
    private let label = NSTextField(labelWithString: "00:00:00")
    var clicked: (() -> Void)?
    var frameChanged: (() -> Void)?
    var frameChanging: (() -> Void)?
    var clampFrame: ((NSRect) -> NSRect)?
    private var initialFrame = NSRect.zero
    private var initialPoint = NSPoint.zero
    private var edges = (left: false, right: false, bottom: false, top: false)
    private var moved = false
    private var tracking: NSTrackingArea?
    private var appliedStyle: FloatingAppearance?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.style = .clear; glass.contentView = content
        content.wantsLayer = true; content.addSubview(label); addSubview(glass)
        label.alignment = .center; label.lineBreakMode = .byClipping
        label.setAccessibilityElement(false)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityHelp("单击打开控制面板；在中间拖动，在边缘调整大小。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func accessibilityPerformPress() -> Bool { clicked?(); return true }
    func update(text: String, preferences: Preferences) {
        if label.stringValue != text {
            let changedLength = label.stringValue.count != text.count
            label.stringValue = text; setAccessibilityLabel("学习计时器，\(text)")
            if changedLength { needsLayout = true }
        }
        let style = FloatingAppearance(preferences)
        guard style != appliedStyle else { return }
        appliedStyle = style
        let solid = preferences.theme != .glass || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        appearance = NSAppearance(named: preferences.theme == .light ? .aqua : .darkAqua)
        glass.isHidden = solid
        if solid {
            if content.superview !== self { glass.contentView = nil; content.removeFromSuperview(); addSubview(content) }
            content.layer?.backgroundColor = (preferences.theme == .light ? NSColor(calibratedWhite: 0.96, alpha: 1) : NSColor(calibratedWhite: 0.095, alpha: 1)).cgColor
        } else {
            if content.superview === self { content.removeFromSuperview(); glass.contentView = content }
            content.layer?.backgroundColor = NSColor.black.withAlphaComponent(preferences.glassOpacity * 0.55).cgColor
            glass.tintColor = NSColor(calibratedWhite: 0.05, alpha: preferences.glassOpacity)
        }
        label.textColor = preferences.theme == .light ? .black : .white
        content.layer?.borderWidth = 0.75
        content.layer?.borderColor = (preferences.theme == .light ? NSColor.black.withAlphaComponent(0.2) : NSColor.white.withAlphaComponent(0.35)).cgColor
        needsLayout = true
    }
    override func layout() {
        super.layout(); glass.frame = bounds; content.frame = bounds
        let radius = min(12, max(6, bounds.height * 0.12))
        glass.cornerRadius = radius; content.layer?.cornerRadius = radius
        let text = label.stringValue as NSString
        var size = max(12, min(bounds.height * 0.52, bounds.width / 4.7))
        var font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        while text.size(withAttributes: [.font: font]).width > bounds.width - 16 && size > 10 {
            size -= 0.5; font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        }
        label.font = font
        let height = ceil(font.ascender - font.descender + 4)
        label.frame = NSRect(x: 4, y: (bounds.height - height) / 2 - 1, width: bounds.width - 8, height: height)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.x < 6 || p.x > bounds.width - 6 { NSCursor.resizeLeftRight.set() }
        else if p.y < 6 || p.y > bounds.height - 6 { NSCursor.resizeUpDown.set() }
        else { NSCursor.openHand.set() }
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialFrame = window.frame; initialPoint = NSEvent.mouseLocation; moved = false
        let p = convert(event.locationInWindow, from: nil)
        edges = (p.x < 6, p.x > bounds.width - 6, p.y < 6, p.y > bounds.height - 6)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let p = NSEvent.mouseLocation, dx = p.x - initialPoint.x, dy = p.y - initialPoint.y
        guard moved || hypot(dx, dy) > 4 else { return }; moved = true
        var frame = initialFrame
        if edges.left || edges.right || edges.bottom || edges.top {
            if edges.left {
                frame.size.width = min(800, max(100, initialFrame.width - dx)); frame.origin.x = initialFrame.maxX - frame.width
            }
            if edges.right { frame.size.width = min(800, max(100, initialFrame.width + dx)) }
            if edges.bottom {
                frame.size.height = min(400, max(38, initialFrame.height - dy)); frame.origin.y = initialFrame.maxY - frame.height
            }
            if edges.top { frame.size.height = min(400, max(38, initialFrame.height + dy)) }
        } else { frame.origin.x += dx; frame.origin.y += dy; NSCursor.closedHand.set() }
        window.setFrame(clampFrame?(frame) ?? Self.clamp(frame), display: true)
        frameChanging?()
    }
    override func mouseUp(with event: NSEvent) {
        if moved { frameChanged?() } else if !edges.left && !edges.right && !edges.bottom && !edges.top { clicked?() }
        NSCursor.openHand.set()
    }
    static func clamp(_ original: NSRect) -> NSRect {
        let screen = NSScreen.screens.max { a, b in
            original.intersection(a.frame).width * original.intersection(a.frame).height < original.intersection(b.frame).width * original.intersection(b.frame).height
        } ?? NSScreen.main!
        var frame = original
        frame.size.width = min(frame.width, screen.frame.width - 12)
        frame.size.height = min(frame.height, screen.visibleFrame.height - 12)
        frame.origin.x = max(screen.frame.minX + 6, min(frame.minX, screen.frame.maxX - frame.width - 6))
        frame.origin.y = max(screen.frame.minY + 6, min(frame.minY, screen.visibleFrame.maxY - frame.height - 6))
        return frame
    }
}

@MainActor final class FloatingController {
    let panel: TimerPanel
    let view: FloatingView
    private let model: AppModel
    private let popover = NSPopover()
    private var badges: [(panel: NSPanel, view: FloatingBadgeView)] = []
    private var lastBadgeCount = 0
    private var lastBodyFrame = NSRect.zero
    private weak var popoverAnchor: NSView?
    var showStatistics: (() -> Void)?
    var showSettings: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        let prefs = model.preferences, screen = NSScreen.main!
        let frame = FloatingView.clamp(NSRect(x: prefs.windowX ?? screen.frame.minX + 20,
            y: prefs.windowY ?? screen.frame.minY + 12, width: prefs.windowWidth, height: prefs.windowHeight))
        panel = TimerPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = FloatingView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = view; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.setAccessibilityRole(.window); panel.setAccessibilitySubrole(.floatingWindow)
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        panel.title = "学习计时器"
        view.clicked = { [weak self] in self?.toggleControls() }
        view.frameChanged = { [weak self] in self?.rememberFrame() }
        view.frameChanging = { [weak self] in self?.updateBadges() }
        view.clampFrame = { [weak self] frame in self?.clampedBody(frame) ?? frame }
        for _ in 0..<2 {
            let badge = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            let content = FloatingBadgeView(frame: .zero)
            badge.contentView = content; badge.isOpaque = false; badge.backgroundColor = .clear
            badge.hasShadow = true; badge.hidesOnDeactivate = false; badge.isReleasedWhenClosed = false
            badge.isFloatingPanel = true; badge.collectionBehavior = panel.collectionBehavior
            badge.setAccessibilityRole(.window); badge.setAccessibilitySubrole(.floatingWindow)
            content.bodyFrame = { [weak self] in self?.panel.frame ?? .zero }
            content.moveBody = { [weak self] frame in
                guard let self else { return }
                self.panel.setFrame(self.clampedBody(frame), display: true); self.updateBadges()
            }
            content.didMove = { [weak self] in self?.rememberFrame() }
            content.clicked = { [weak self] in self?.toggleControls() }
            badges.append((badge, content))
        }
        popover.behavior = .transient
        panel.orderFrontRegardless(); update()
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    func update() {
        view.update(text: model.engine.display, preferences: model.preferences)
        let level: NSWindow.Level = model.preferences.alwaysOnTop ? .floating : .normal
        if panel.level != level { panel.level = level }
        updateBadges()
    }
    private var badgeReadings: [(String, String)] {
        var values: [(String, String)] = []
        if let elapsed = model.pauseElapsed { values.append((model.engine.state.pauseReason?.title ?? "暂停", TimeInput.format(elapsed))) }
        if model.preferences.showTodayTotalOnFloatingWindow { values.append(("今日", TimeInput.format(model.todayTotal))) }
        return values
    }
    private func clampedBody(_ proposed: NSRect) -> NSRect {
        let body = FloatingView.clamp(proposed)
        let screen = NSScreen.screens.max { a, b in
            body.intersection(a.frame).width * body.intersection(a.frame).height < body.intersection(b.frame).width * body.intersection(b.frame).height
        } ?? NSScreen.main!
        let workspace = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width,
                               height: screen.visibleFrame.maxY - screen.frame.minY)
        return FloatingBadgeLayout.clampedBody(body, count: badgeReadings.count, workspace: workspace)
    }
    private func updateBadges() {
        let readings = badgeReadings
        let reposition = popover.isShown && lastBadgeCount != readings.count
        let needsGeometry = lastBodyFrame != panel.frame || lastBadgeCount != readings.count
        if needsGeometry {
            let safe = clampedBody(panel.frame)
            if panel.isVisible && safe != panel.frame { panel.setFrame(safe, display: true) }
        }
        let frames = needsGeometry ? FloatingBadgeLayout.frames(above: panel.frame, count: readings.count) : []
        for index in badges.indices {
            let item = badges[index]
            if panel.isVisible && index < readings.count {
                item.panel.title = readings[index].0 == "今日" ? "今日累计" : readings[index].0
                item.view.update(title: readings[index].0, value: readings[index].1, preferences: model.preferences)
                if item.panel.level != panel.level { item.panel.level = panel.level }
                if needsGeometry && item.panel.frame != frames[index] { item.panel.setFrame(frames[index], display: true) }
                if item.panel.parent !== panel { panel.addChildWindow(item.panel, ordered: .above) }
                if !item.panel.isVisible { item.panel.orderFrontRegardless() }
            } else {
                if item.panel.parent != nil { panel.removeChildWindow(item.panel) }
                item.panel.orderOut(nil)
            }
        }
        if reposition { positionPopover() }
        lastBadgeCount = readings.count; lastBodyFrame = panel.frame
    }
    private func positionPopover() {
        let above = panel.frame.midY < (panel.screen?.frame.midY ?? 400)
        let anchor: NSView = above && !badgeReadings.isEmpty ? badges[0].view : view
        let animate = popover.animates
        if popover.isShown && popoverAnchor !== anchor {
            popover.animates = false
            popover.close()
        }
        popoverAnchor = anchor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: above ? .maxY : .minY)
        popover.animates = animate
        popover.contentViewController?.view.window?.makeKey()
    }
    func toggleVisibility() {
        if panel.isVisible { popover.close(); panel.orderOut(nil) }
        else { panel.orderFrontRegardless() }
        updateBadges()
    }
    func toggleControls() {
        if popover.isShown { popover.performClose(nil); return }
        let controller = NSHostingController(rootView: ControlsView(model: model,
            statistics: { [weak self] in self?.popover.close(); self?.showStatistics?() },
            settings: { [weak self] in self?.popover.close(); self?.showSettings?() }))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 324, height: 184)
        popover.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
        positionPopover()
        popover.contentViewController?.view.window?.makeKey()
    }
    func rememberFrame() {
        var prefs = model.preferences
        prefs.windowX = panel.frame.minX; prefs.windowY = panel.frame.minY
        prefs.windowWidth = panel.frame.width; prefs.windowHeight = panel.frame.height
        model.preferences = prefs
        if popover.isShown { positionPopover() }
    }
    func restoreFrameFromPreferences() {
        let prefs = model.preferences
        if let x = prefs.windowX, let y = prefs.windowY {
            panel.setFrame(clampedBody(NSRect(x: x, y: y, width: prefs.windowWidth, height: prefs.windowHeight)), display: true)
            updateBadges()
        }
    }
    @objc private func screenChanged() { panel.setFrame(clampedBody(panel.frame), display: true); rememberFrame() }
    @objc private func accessibilityChanged() { update() }
}

private struct ControlsView: View {
    @ObservedObject var model: AppModel
    let statistics: () -> Void
    let settings: () -> Void
    @State private var input = ""
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("时间", text: $input)
                .font(.system(size: 23, weight: .medium)).textFieldStyle(.plain)
                .focused($focused).onSubmit(start).accessibilityLabel("计时时间")
                .disabled(model.timerWriteBlocked)
            Divider()
            HStack(spacing: 10) {
                control(model.isRunning ? "pause.fill" : "play.fill", model.isRunning ? "暂停" : "继续", model.toggle)
                    .disabled(model.timerWriteBlocked)
                control("arrow.counterclockwise", "重置", model.reset)
                    .disabled(model.timerWriteBlocked)
                control("chart.bar.xaxis", "学习统计", statistics)
                control("gearshape", "设置", settings)
                control(model.preferences.alwaysOnTop ? "pin.fill" : "pin.slash", "切换置顶") { model.preferences.alwaysOnTop.toggle() }
            }
            HStack {
                Text("今日累计").foregroundStyle(.secondary)
                ReadoutContent(readout: model.controlsReadout) { _, _ in
                    Text(TimeInput.format(model.todayTotal)).monospacedDigit().fontWeight(.medium)
                }
                Button { model.preferences.showTodayTotalOnFloatingWindow.toggle() } label: {
                    Image(systemName: model.preferences.showTodayTotalOnFloatingWindow ? "eye.fill" : "eye.slash")
                }.buttonStyle(.borderless)
                    .help("悬浮显示今日累计")
                    .accessibilityLabel("悬浮显示今日累计")
                    .accessibilityValue(model.preferences.showTodayTotalOnFloatingWindow ? "已开启" : "已关闭")
                Spacer(); Text(model.statusText).foregroundStyle(.secondary)
            }.font(.system(size: 12))
            if !model.isRunning, model.engine.state.pauseReason != nil, !model.timerWriteBlocked {
                VStack(alignment: .leading, spacing: 3) {
                    if let saved = model.engine.state.savedThrough {
                        Text("记录已保存至 \(saved.formatted(.dateTime.month().day().hour().minute().second()))")
                    }
                    if !model.pendingIntervals.isEmpty {
                        Text("待校对 \(TimeInput.format(model.pendingIntervals.reduce(0) { $0 + $1.duration }))")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let message = model.message {
                HStack(alignment: .top) {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示")
                }
            }
        }.padding(18).frame(width: 288).fixedSize(horizontal: false, vertical: true)
            .onAppear { focused = true }
    }
    private func start() {
        do { try model.start(text: input); input = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func control(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 36, height: 30) }
            .buttonStyle(.bordered).help(title).accessibilityLabel(title)
    }
}
