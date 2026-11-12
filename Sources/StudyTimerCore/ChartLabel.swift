import Foundation

public struct ChartLabel: Identifiable, Sendable {
    public let id: Int
    public let x: Double
    public var y: Double
    public let width: Double
    public init(id: Int, x: Double, y: Double, width: Double) { self.id = id; self.x = x; self.y = y; self.width = width }
    public var rect: CGRect { CGRect(x: x - width / 2, y: y - 7, width: width, height: 14) }
    public static func arranged(_ labels: [ChartLabel]) -> [ChartLabel] {
        var placed: [ChartLabel] = []
        for var label in labels.sorted(by: { $0.x < $1.x }) {
            while placed.contains(where: { $0.rect.insetBy(dx: -1, dy: -1).intersects(label.rect) }) { label.y -= 16 }
            placed.append(label)
        }
        return placed
    }
}
