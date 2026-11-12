import AppKit
import StudyTimerCore

@MainActor final class FloatingBadgeView: NSView {
    private let glass = NSGlassEffectView()
    private let solid = NSView()
    private let title = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "00:00")
    private let outline = CAShapeLayer()
    private let surfaceMask = CAShapeLayer()
    private var initialPoint = NSPoint.zero
    private var initialBody = NSRect.zero
    private var moved = false
    private var appliedStyle: FloatingAppearance?
    var bodyFrame: (() -> NSRect)?
    var moveBody: ((NSRect) -> Void)?
    var didMove: (() -> Void)?
    var clicked: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.style = .clear
        solid.wantsLayer = true
        addSubview(glass); addSubview(solid); addSubview(title); addSubview(value)
        title.alignment = .center; value.alignment = .center
        title.setAccessibilityElement(false); value.setAccessibilityElement(false)
        layer?.mask = surfaceMask; layer?.addSublayer(outline); outline.zPosition = 10
        outline.fillColor = NSColor.clear.cgColor; outline.lineWidth = 0.75
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func update(title text: String, value reading: String, preferences: Preferences) {
        if title.stringValue != text || value.stringValue != reading {
            title.stringValue = text; value.stringValue = reading
            setAccessibilityLabel("\(text)，\(reading)")
        }
        let style = FloatingAppearance(preferences)
        guard style != appliedStyle else { return }
        appliedStyle = style
        let light = preferences.theme == .light
        appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let isSolid = preferences.theme != .glass || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        glass.isHidden = isSolid; solid.isHidden = !isSolid
        solid.layer?.backgroundColor = NSColor(calibratedWhite: light ? 0.96 : 0.095, alpha: 1).cgColor
        glass.tintColor = NSColor(calibratedWhite: 0.05, alpha: preferences.glassOpacity)
        value.textColor = light ? .black : .white
        title.textColor = (light ? NSColor.black : .white).withAlphaComponent(0.62)
        outline.strokeColor = (light ? NSColor.black.withAlphaComponent(0.2) : NSColor.white.withAlphaComponent(0.35)).cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        glass.frame = bounds; solid.frame = bounds
        let scale = bounds.width / 84, neck = 6 * scale, r = 7 * scale
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + r, y: neck))
        path.addLine(to: CGPoint(x: rect.midX - 5 * scale, y: neck))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + 5 * scale, y: neck))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: neck))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: neck + r), control: CGPoint(x: rect.maxX, y: neck))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: neck + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: neck), control: CGPoint(x: rect.minX, y: neck))
        path.closeSubpath()
        surfaceMask.frame = bounds; outline.frame = bounds
        let backing = window?.backingScaleFactor ?? 2
        surfaceMask.contentsScale = backing; outline.contentsScale = backing
        surfaceMask.path = path; outline.path = path
        title.font = .systemFont(ofSize: 9 * scale, weight: .medium)
        value.font = .monospacedDigitSystemFont(ofSize: 12 * scale, weight: .semibold)
        title.frame = NSRect(x: 5 * scale, y: 25 * scale, width: bounds.width - 10 * scale, height: 12 * scale)
        value.frame = NSRect(x: 5 * scale, y: 9 * scale, width: bounds.width - 10 * scale, height: 17 * scale)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func accessibilityPerformPress() -> Bool { clicked?(); return true }
    override func mouseDown(with event: NSEvent) {
        initialPoint = NSEvent.mouseLocation; initialBody = bodyFrame?() ?? .zero; moved = false
    }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - initialPoint.x, dy = p.y - initialPoint.y
        guard moved || hypot(dx, dy) > 4 else { return }
        moved = true; NSCursor.closedHand.set(); moveBody?(initialBody.offsetBy(dx: dx, dy: dy))
    }
    override func mouseUp(with event: NSEvent) {
        if moved { didMove?() } else { clicked?() }
        NSCursor.openHand.set()
    }
}
