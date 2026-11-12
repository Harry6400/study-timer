import Foundation
import CoreGraphics

/// An in-memory stopwatch. It has no serializable state or history records.
public final class TransientPauseTimer {
    private let time: any TimeSource
    private var anchor: Double?
    public init(time: any TimeSource = SystemTimeSource()) { self.time = time }
    public var isActive: Bool { anchor != nil }
    public var elapsed: TimeInterval? { anchor.map { max(0, time.continuousSeconds - $0) } }
    public func start() { anchor = time.continuousSeconds }
    public func clear() { anchor = nil }
}

public enum FloatingBadgeLayout {
    public static func frames(above body: CGRect, count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let scale: CGFloat = min(1.5, max(1, body.height / 58))
        let size = CGSize(width: 84 * scale, height: 42 * scale)
        let gap = 4 * scale
        let width = size.width * CGFloat(count) + gap * CGFloat(count - 1)
        return (0..<count).map { index in
            let x = body.midX - width / 2 + CGFloat(index) * (size.width + gap)
            return CGRect(x: x, y: body.maxY - 1, width: size.width, height: size.height)
        }
    }
    public static func groupBounds(body: CGRect, count: Int) -> CGRect {
        frames(above: body, count: count).reduce(body) { $0.union($1) }
    }
    public static func clampedBody(_ body: CGRect, count: Int, workspace: CGRect) -> CGRect {
        let safe = workspace.insetBy(dx: 6, dy: 6)
        var fitted = body
        if let badge = frames(above: body, count: count).first {
            fitted.size.height = min(body.height, max(38, safe.height - badge.height + 1))
        }
        let group = groupBounds(body: fitted, count: count)
        let x = min(max(group.minX, safe.minX), safe.maxX - group.width)
        let y = min(max(group.minY, safe.minY), safe.maxY - group.height)
        return fitted.offsetBy(dx: x - group.minX, dy: y - group.minY)
    }
}
