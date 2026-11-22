import Foundation

/// Wall-clock positions within a study day, starting at 04:00.
public struct StudyClock: Sendable {
    public static let halfDay: Double = 43_200
    public static let seamAngle = Double.pi / 6
    public let day: Date
    public let calendar: StudyCalendar

    public init(day: Date, calendar: StudyCalendar = StudyCalendar()) {
        self.calendar = calendar
        self.day = calendar.dayStart(for: day)
    }

    public func offset(for date: Date) -> Double {
        let cal = calendar.calendar
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: day), to: cal.startOfDay(for: date)).day!
        let time = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let daySeconds = days * 86_400 - 14_400
        let clockSeconds = time.hour! * 3600 + time.minute! * 60 + time.second!
        let fraction = Double(time.nanosecond ?? 0) / 1_000_000_000
        return Double(daySeconds + clockSeconds) + fraction
    }

    public static func angle(for offset: Double) -> Double {
        seamAngle + offset / halfDay * 2 * .pi
    }

    public func date(atAngle angle: Double, ring: Int) -> Date? {
        let circle = 2 * Double.pi
        let phase = (angle - Self.seamAngle).truncatingRemainder(dividingBy: circle)
        let offset = Double(ring) * Self.halfDay + (phase < 0 ? phase + circle : phase) / circle * Self.halfDay
        let minute = Int(offset / 60) + 240
        let cal = calendar.calendar
        guard let civilDay = cal.date(byAdding: .day, value: minute / 1440, to: cal.startOfDay(for: day)) else { return nil }
        return cal.date(bySettingHour: minute / 60 % 24, minute: minute % 60, second: 0, of: civilDay)
    }

    public func currentOffset(at now: Date, ring: Int) -> Double? {
        guard calendar.dayStart(for: now) == day else { return nil }
        let offset = floor(offset(for: now) / 60) * 60
        let lower = Double(ring) * Self.halfDay
        return offset >= lower && offset < lower + Self.halfDay ? offset : nil
    }

    public func clippedOffsets(_ interval: StudyInterval, ring: Int) -> ClosedRange<Double>? {
        let lower = Double(ring) * Self.halfDay, upper = lower + Self.halfDay
        let a = max(lower, offset(for: interval.start)), b = min(upper, offset(for: interval.end))
        return b > a ? a...b : nil
    }

    public static func angularStep(from: Double, to: Double) -> Double {
        atan2(sin(to - from), cos(to - from))
    }

    public enum DragTarget: Sendable, Equatable { case start, end, move }

    public static func adjusted(_ original: StudyInterval, target: DragTarget,
                                seconds: Double, fine: Bool) -> StudyInterval {
        var value = original
        guard abs(seconds) > 0.0001 else { return value }
        let step: Double = fine ? 1 : 60
        switch target {
        case .start:
            let candidate = original.start.addingTimeInterval(seconds).timeIntervalSinceReferenceDate
            value.start = min(Date(timeIntervalSinceReferenceDate: (candidate / step).rounded() * step), original.end.addingTimeInterval(-1))
        case .end:
            let candidate = original.end.addingTimeInterval(seconds).timeIntervalSinceReferenceDate
            value.end = max(Date(timeIntervalSinceReferenceDate: (candidate / step).rounded() * step), original.start.addingTimeInterval(1))
        case .move:
            let delta = (seconds / step).rounded() * step
            value.start = original.start.addingTimeInterval(delta)
            value.end = original.end.addingTimeInterval(delta)
        }
        return value
    }
}

public extension StudyCalendar {
    func draft(on date: Date, at point: Date? = nil, occupied: [StudyInterval], now: Date,
               duration: TimeInterval = 1800, locked: Bool = false) -> StudyInterval? {
        let start = dayStart(for: date)
        let end = min(nextDay(start), now)
        guard end.timeIntervalSince(start) >= (locked ? duration : 1) else { return nil }
        let blocks = intervals(on: start, from: occupied).sorted { $0.start < $1.start }
        var cursor = start
        var gaps: [Range<Date>] = []
        for block in blocks where block.start < end {
            if block.start > cursor { gaps.append(cursor..<block.start) }
            cursor = max(cursor, block.end)
        }
        if cursor < end { gaps.append(cursor..<end) }
        if let point {
            guard let gap = gaps.first(where: { $0.contains(point) }) else { return nil }
            let length = min(duration, gap.upperBound.timeIntervalSince(point))
            guard length >= 1, !locked || length == duration else { return nil }
            return StudyInterval(start: point, end: point.addingTimeInterval(length), source: "manual")
        }
        let reference = blocks.filter { $0.end <= end }.last?.end
            ?? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: start) ?? start
        let candidates = gaps.compactMap { gap -> StudyInterval? in
            let length = min(duration, gap.upperBound.timeIntervalSince(gap.lowerBound))
            guard length >= 1, !locked || length == duration else { return nil }
            let anchor = min(max(reference, gap.lowerBound), gap.upperBound.addingTimeInterval(-length))
            return StudyInterval(start: anchor, end: anchor.addingTimeInterval(length), source: "manual")
        }
        return candidates.min { lhs, rhs in
            let a = abs(lhs.start.timeIntervalSince(reference)), b = abs(rhs.start.timeIntervalSince(reference))
            return a == b ? lhs.start > rhs.start : a < b
        }
    }
}

public struct ClockDrag: Sendable {
    public private(set) var seconds: Double = 0
    private var previousAngle: Double
    public init(angle: Double) { previousAngle = angle }
    public mutating func update(angle: Double, fine: Bool) {
        seconds += StudyClock.angularStep(from: previousAngle, to: angle) / (2 * .pi)
            * StudyClock.halfDay / (fine ? 60 : 1)
        previousAngle = angle
    }
}

public enum StudyDayPalette {
    public static let stops: [(hour: Double, hex: UInt32)] = [
        (4, 0x000000), (7.5, 0x2EA692), (12, 0xBBDFFC), (16, 0xF1C27A),
        (18.5, 0x5A3A2B), (21, 0x79529C), (24, 0x142447), (28, 0x000000)
    ]
    public static func rgb(at hour: Double) -> (Double, Double, Double) {
        let h = min(28, max(4, hour))
        let upper = stops.firstIndex { $0.hour >= h } ?? stops.count - 1
        let lower = max(0, upper - 1)
        let a = stops[lower], b = stops[upper]
        let t = b.hour == a.hour ? 0 : (h - a.hour) / (b.hour - a.hour)
        func channel(_ shift: UInt32) -> Double {
            let x = Double((a.hex >> shift) & 255), y = Double((b.hex >> shift) & 255)
            return (x + (y - x) * t) / 255
        }
        return (channel(16), channel(8), channel(0))
    }
}
