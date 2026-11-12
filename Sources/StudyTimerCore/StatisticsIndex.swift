import Foundation

/// 已结束记录的学习日索引；实时段只在查询时叠加。
public struct StatisticsIndex: Sendable {
    public private(set) var studyCalendar: StudyCalendar
    private var originals: [UUID: StudyInterval] = [:]
    private var parts: [Date: [UUID: StudyInterval]] = [:]
    private var seconds: [Date: TimeInterval] = [:]
    public init(records: [StudyInterval] = [], calendar: StudyCalendar = StudyCalendar()) {
        studyCalendar = calendar
        for record in records { replace(id: record.id, with: record) }
    }
    public var records: [StudyInterval] { originals.values.sorted { $0.start < $1.start } }
    public func record(id: UUID) -> StudyInterval? { originals[id] }
    public mutating func replace(id: UUID, with replacement: StudyInterval?) {
        if let old = originals.removeValue(forKey: id) {
            for part in studyCalendar.split(old) {
                parts[part.day]?.removeValue(forKey: id)
                seconds[part.day, default: 0] -= part.interval.duration
                if parts[part.day]?.isEmpty == true { parts.removeValue(forKey: part.day); seconds.removeValue(forKey: part.day) }
            }
        }
        guard let replacement else { return }
        originals[id] = replacement
        for part in studyCalendar.split(replacement) {
            parts[part.day, default: [:]][id] = part.interval
            seconds[part.day, default: 0] += part.interval.duration
        }
    }
    public func intervals(on date: Date, live: StudyInterval? = nil) -> [StudyInterval] {
        let day = studyCalendar.dayStart(for: date)
        var result = Array((parts[day] ?? [:]).values)
        if let live {
            result.removeAll { $0.id == live.id }
            result += studyCalendar.intervals(on: day, from: [live])
        }
        return result.sorted { $0.start < $1.start }
    }
    public func total(on date: Date, live: StudyInterval? = nil) -> TimeInterval {
        let day = studyCalendar.dayStart(for: date)
        var result = seconds[day, default: 0]
        if let live {
            result -= parts[day]?[live.id]?.duration ?? 0
            result += studyCalendar.intervals(on: day, from: [live]).first?.duration ?? 0
        }
        return max(0, result)
    }
    public func totals(on days: [Date], live: StudyInterval? = nil) -> [DayTotal] {
        days.map { DayTotal(date: $0, seconds: total(on: $0, live: live)) }
    }
}
