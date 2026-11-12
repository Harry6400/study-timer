import Foundation

public struct DayTotal: Identifiable, Sendable {
    public let date: Date
    public let seconds: TimeInterval
    public var id: Date { date }
    public var hoursLabel: String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds / 3600) }
}

public struct StudyCalendar: Sendable {
    public var calendar: Calendar
    public init(timeZone: TimeZone = .current) {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone; value.firstWeekday = 2; value.minimumDaysInFirstWeek = 4
        calendar = value
    }
    public func dayStart(for date: Date) -> Date {
        let midnight = calendar.startOfDay(for: date)
        let boundary = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: midnight)!
        return date >= boundary ? boundary : calendar.date(byAdding: .day, value: -1, to: boundary)!
    }
    public func nextDay(_ date: Date) -> Date { calendar.date(byAdding: .day, value: 1, to: date)! }
    public func dateAtFour(on date: Date) -> Date {
        calendar.date(bySettingHour: 4, minute: 0, second: 0, of: date)!
    }
    public func movedDay(_ date: Date, component: Calendar.Component, value: Int, now: Date = Date()) -> Date {
        let result = calendar.date(byAdding: component, value: value, to: dateAtFour(on: date)) ?? date
        return min(dateAtFour(on: result), dayStart(for: now))
    }
    public func recentSevenDays(endingAt now: Date) -> [Date] {
        let end = dayStart(for: now)
        return (-6...0).map { calendar.date(byAdding: .day, value: $0, to: end)! }
    }
    public func monthStart(containing date: Date) -> Date {
        dateAtFour(on: calendar.dateInterval(of: .month, for: date)!.start)
    }
    public func monthGrid(containing date: Date) -> [Date] {
        let first = monthStart(containing: date)
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: first)!.count
        let cells = ((leading + count + 6) / 7) * 7
        return (0..<cells).map { calendar.date(byAdding: .day, value: $0 - leading, to: first)! }
    }
    public func split(_ interval: StudyInterval) -> [(day: Date, interval: StudyInterval)] {
        var result: [(Date, StudyInterval)] = []
        var cursor = interval.start
        while cursor < interval.end {
            let day = dayStart(for: cursor)
            let end = min(interval.end, nextDay(day))
            result.append((day, StudyInterval(id: interval.id, start: cursor, end: end, source: interval.source)))
            cursor = end
        }
        return result
    }
    public func intervals(on date: Date, from records: [StudyInterval]) -> [StudyInterval] {
        let start = dayStart(for: date), end = nextDay(start)
        return records.compactMap { entry in
            let a = max(start, entry.start), b = min(end, entry.end)
            return b > a ? StudyInterval(id: entry.id, start: a, end: b, source: entry.source) : nil
        }.sorted { $0.start < $1.start }
    }
    public func days(containing date: Date, period: Calendar.Component) -> [Date] {
        let studyDay = dayStart(for: date)
        if period == .day { return [studyDay] }
        let range = calendar.dateInterval(of: period, for: studyDay)!
        var cursor = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: range.start)!
        var result: [Date] = []
        while cursor < range.end { result.append(cursor); cursor = nextDay(cursor) }
        return result
    }
    public func totals(containing date: Date, period: Calendar.Component, records: [StudyInterval]) -> [DayTotal] {
        totals(on: days(containing: date, period: period), records: records)
    }
    public func totals(on days: [Date], records: [StudyInterval]) -> [DayTotal] {
        days.map { day in
            DayTotal(date: day, seconds: intervals(on: day, from: records).reduce(0) { $0 + $1.duration })
        }
    }
    public func csv(_ records: [StudyInterval]) -> String {
        let day = DateFormatter(); day.calendar = calendar; day.timeZone = calendar.timeZone; day.dateFormat = "yyyy-MM-dd"
        let stamp = ISO8601DateFormatter(); stamp.timeZone = calendar.timeZone
        var lines = ["记录编号,学习日,开始时间,结束时间,时长秒,来源"]
        for record in records.sorted(by: { $0.start < $1.start }) {
            for part in split(record) {
                lines.append([record.id.uuidString, day.string(from: part.day), stamp.string(from: part.interval.start),
                              stamp.string(from: part.interval.end), String(format: "%.3f", part.interval.duration),
                              record.source == "manual" ? "补记" : "计时"].joined(separator: ","))
            }
        }
        return "\u{feff}" + lines.joined(separator: "\r\n") + "\r\n"
    }
}
