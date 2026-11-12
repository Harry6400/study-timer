import Foundation

public struct StudyInterval: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var start: Date
    public var end: Date
    public var source: String
    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    public init(id: UUID = UUID(), start: Date, end: Date, source: String = "timer") {
        self.id = id; self.start = start; self.end = end; self.source = source
    }
}

public enum TimerStatus: String, Codable, Sendable { case paused, running, completed }

public struct TimerState: Codable, Equatable, Sendable {
    public var target: TimeInterval?
    public var elapsed: TimeInterval = 0
    public var status: TimerStatus = .paused
    public var activeStart: Date?
    public var activeID: UUID?
    public var checkpoint: Date?
    public var checkpointElapsed: TimeInterval = 0
    public init(target: TimeInterval? = nil) { self.target = target }
}

public struct TimerUpdate: Sendable {
    public var state: TimerState
    public var interval: StudyInterval?
    public init(state: TimerState, interval: StudyInterval?) { self.state = state; self.interval = interval }
}

public enum TimerTheme: String, Codable, CaseIterable, Sendable {
    case glass, dark, light
    public var title: String {
        switch self { case .glass: "液态玻璃"; case .dark: "深色"; case .light: "浅色" }
    }
}

public enum StatisticsLayout: String, Codable, Sendable { case timeline, trend }

public struct Preferences: Codable, Equatable, Sendable {
    public var theme: TimerTheme = .glass
    public var glassOpacity: Double = 0.48
    public var alwaysOnTop = true
    public var menuBarTimer = true
    public var sound = true
    public var notifications = true
    public var statisticsLayout: StatisticsLayout = .timeline
    public var showTodayTotalOnFloatingWindow = false
    public var automaticBackups = true
    public var windowX: Double?
    public var windowY: Double?
    public var windowWidth: Double = 150
    public var windowHeight: Double = 58
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case theme, glassOpacity, alwaysOnTop, menuBarTimer, sound, notifications, statisticsLayout, showTodayTotalOnFloatingWindow
        case windowX, windowY, windowWidth, windowHeight, automaticBackups
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        automaticBackups = try c.decodeIfPresent(Bool.self, forKey: .automaticBackups) ?? true
        theme = try c.decodeIfPresent(TimerTheme.self, forKey: .theme) ?? .glass
        glassOpacity = try c.decodeIfPresent(Double.self, forKey: .glassOpacity) ?? 0.48
        alwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? true
        menuBarTimer = try c.decodeIfPresent(Bool.self, forKey: .menuBarTimer) ?? true
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
        statisticsLayout = try c.decodeIfPresent(StatisticsLayout.self, forKey: .statisticsLayout) ?? .timeline
        showTodayTotalOnFloatingWindow = try c.decodeIfPresent(Bool.self, forKey: .showTodayTotalOnFloatingWindow) ?? false
        windowX = try c.decodeIfPresent(Double.self, forKey: .windowX)
        windowY = try c.decodeIfPresent(Double.self, forKey: .windowY)
        windowWidth = try c.decodeIfPresent(Double.self, forKey: .windowWidth) ?? 150
        windowHeight = try c.decodeIfPresent(Double.self, forKey: .windowHeight) ?? 58
    }
}

public enum StudyError: LocalizedError {
    case invalidInput, invalidInterval, futureInterval, overlapping, invalidBackup, storage(String)
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "时间格式无效。"
        case .invalidInterval: "结束时间必须晚于开始时间。"
        case .futureInterval: "学习记录不能包含未来时间。"
        case .overlapping: "这段时间与已有记录重叠。"
        case .invalidBackup: "备份格式或内容无效，当前记录未被替换。"
        case .storage(let detail): "无法保存学习记录：\(detail)"
        }
    }
}

public enum TimeInput {
    public static func parse(_ text: String) throws -> TimeInterval? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "：", with: ":")
        let parts = clean.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Double($0)?.isFinite == true }) else { throw StudyError.invalidInput }
        let values = parts.compactMap { Double($0) }
        let seconds: Double
        if parts.count == 1 { seconds = values[0] * 60 }
        else {
            guard values.dropFirst().allSatisfy({ $0 < 60 }) else { throw StudyError.invalidInput }
            seconds = values.reduce(0) { $0 * 60 + $1 }
        }
        guard seconds.isFinite, seconds <= 31_536_000 else { throw StudyError.invalidInput }
        return seconds == 0 ? nil : seconds
    }

    public static func format(_ seconds: TimeInterval, roundUp: Bool = false) -> String {
        let total = Int(max(0, roundUp ? ceil(seconds) : floor(seconds)))
        if total < 3600 { return String(format: "%02d:%02d", total / 60, total % 60) }
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
