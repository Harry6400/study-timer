import Foundation
import StudyTimerCore

enum StudyDayPart: Int, CaseIterable {
    case earlyMorning = 240
    case morning = 450
    case midday = 730
    case afternoon = 840
    case dinner = 1060
    case evening = 1110
    case lateNight = 1365

    var name: String {
        switch self {
        case .earlyMorning: "清晨"
        case .morning: "上午"
        case .midday: "中午"
        case .afternoon: "下午"
        case .dinner: "晚饭"
        case .evening: "晚上"
        case .lateNight: "深夜"
        }
    }

    static func markerMinutes(onRing ring: Int) -> [Int] {
        let minutesPerRing = Int(StudyClock.halfDay / 60)
        let start = earlyMorning.rawValue + ring * minutesPerRing
        return [start] + allCases.map(\.rawValue).filter { $0 > start && $0 < start + minutesPerRing }
    }
}

struct StudyDayParts {
    private let bands: [(part: StudyDayPart, time: Range<Date>)]

    init(clock: StudyClock) {
        let calendar = clock.calendar
        let starts = StudyDayPart.allCases.map { part in
            calendar.calendar.date(bySettingHour: part.rawValue / 60, minute: part.rawValue % 60,
                                   second: 0, of: clock.day)!
        }
        let ends = starts.dropFirst() + [calendar.nextDay(clock.day)]
        bands = zip(StudyDayPart.allCases, zip(starts, ends)).map { part, bounds in
            (part, bounds.0..<bounds.1)
        }
    }

    func names(overlapping entry: StudyInterval) -> [String] {
        bands.compactMap { part, time in
            let matches = entry.end > entry.start
                ? entry.start < time.upperBound && entry.end > time.lowerBound
                : time.contains(entry.start)
            return matches ? part.name : nil
        }
    }
}
