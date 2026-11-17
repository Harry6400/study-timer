import Foundation

public protocol TimeSource: AnyObject {
    var date: Date { get }
    var continuousSeconds: TimeInterval { get }
}

public final class SystemTimeSource: TimeSource {
    private let origin = ContinuousClock.now
    public init() {}
    public var date: Date { Date() }
    public var continuousSeconds: TimeInterval {
        let value = origin.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}

public final class TimerEngine {
    public private(set) var state: TimerState
    public private(set) var recoveredAt: Date?
    public private(set) var initialUpdate: TimerUpdate?
    public private(set) var settledOnLoad = false
    private let time: any TimeSource
    private var calendar: StudyCalendar
    private var anchor: TimeInterval?

    public init(state: TimerState = TimerState(), time: any TimeSource = SystemTimeSource(), calendar: StudyCalendar = StudyCalendar()) {
        self.state = state; self.time = time; self.calendar = calendar
        self.state.studyDayStart = state.studyDayStart ?? calendar.dayStart(for: state.activeStart ?? state.checkpoint ?? time.date)
        if time.date >= nextStudyDayBoundary {
            // 程序未运行期间不补算：只截取已经保存的检查点段。
            var savedInterval: StudyInterval?
            if state.status == .running, let start = state.activeStart, let id = state.activeID {
                let end = start.addingTimeInterval(max(0, state.checkpointElapsed - state.elapsed))
                savedInterval = StudyInterval(id: id, start: start, end: end)
            }
            initialUpdate = settlement(interval: savedInterval)
            self.state = initialUpdate!.state
            settledOnLoad = true
        } else if state.status == .running {
            recoveredAt = state.checkpoint ?? state.activeStart
            self.state.elapsed = state.checkpointElapsed
            self.state.status = state.target.map { state.checkpointElapsed >= $0 } == true ? .completed : .paused
            self.state.activeStart = nil; self.state.activeID = nil
        }
        if initialUpdate == nil && self.state != state { initialUpdate = TimerUpdate(state: self.state, interval: nil) }
    }

    public var nextStudyDayBoundary: Date {
        calendar.nextDay(calendar.dayStart(for: state.studyDayStart ?? time.date))
    }

    /// 正常运行、唤醒和所有计时操作共用同一个幂等结算入口。
    @discardableResult public func settleDayIfNeeded(calendar: StudyCalendar? = nil) -> TimerUpdate? {
        if let calendar { self.calendar = calendar }
        guard time.date >= nextStudyDayBoundary else { return nil }
        let update = settlement(interval: liveInterval)
        state = update.state; anchor = nil
        return update
    }

    private func freshState(target: TimeInterval? = nil) -> TimerState {
        var value = TimerState(target: target)
        value.studyDayStart = calendar.dayStart(for: time.date)
        value.checkpoint = time.date
        return value
    }

    private func settlement(interval: StudyInterval?) -> TimerUpdate {
        var clipped = interval
        if var part = clipped {
            part.end = min(part.end, nextStudyDayBoundary)
            clipped = part.end > part.start ? part : nil
        }
        return TimerUpdate(state: freshState(), interval: clipped, isDaySettlement: true)
    }

    public var elapsed: TimeInterval {
        let value = state.elapsed + (anchor.map { max(0, time.continuousSeconds - $0) } ?? 0)
        return state.target.map { min($0, value) } ?? value
    }
    public var display: String {
        TimeInput.format(state.target.map { max(0, $0 - elapsed) } ?? elapsed, roundUp: state.target != nil)
    }
    public var liveInterval: StudyInterval? {
        guard state.status == .running, let start = state.activeStart, let id = state.activeID else { return nil }
        let end = start.addingTimeInterval(max(0, elapsed - state.elapsed))
        return end > start ? StudyInterval(id: id, start: start, end: end) : nil
    }

    /// 一次读取连续时钟，得到不影响实际计时的可恢复快照。
    public func snapshot() -> TimerUpdate {
        if time.date >= nextStudyDayBoundary { return settlement(interval: liveInterval) }
        let current = elapsed
        var saved = state
        let interval: StudyInterval?
        if state.status == .running, let start = state.activeStart, let id = state.activeID {
            let end = start.addingTimeInterval(max(0, current - state.elapsed))
            interval = end > start ? StudyInterval(id: id, start: start, end: end) : nil
            saved.status = state.target.map { current >= $0 } == true ? .completed : .paused
        } else { interval = nil }
        saved.elapsed = current; saved.checkpointElapsed = current; saved.checkpoint = time.date
        saved.activeStart = nil; saved.activeID = nil
        return TimerUpdate(state: saved, interval: interval)
    }

    @discardableResult public func start(target: TimeInterval?) -> TimerUpdate {
        let previous = settleDayIfNeeded()?.interval ?? pause().interval
        state = freshState(target: target)
        beginSegment()
        return TimerUpdate(state: state, interval: previous)
    }

    @discardableResult public func resume(allowNewDay: Bool = true) -> TimerUpdate {
        let settled = settleDayIfNeeded()
        if let settled, !allowNewDay { return settled }
        guard state.status != .running else { return checkpoint() }
        if state.status == .completed { state.elapsed = 0 }
        beginSegment()
        return TimerUpdate(state: state, interval: settled?.interval)
    }

    private func beginSegment() {
        state.status = .running; state.activeStart = time.date; state.activeID = UUID()
        state.checkpoint = time.date; state.checkpointElapsed = state.elapsed
        anchor = time.continuousSeconds
    }

    @discardableResult public func pause() -> TimerUpdate {
        if let settled = settleDayIfNeeded() { return settled }
        let interval = liveInterval
        let current = elapsed
        if state.status == .running {
            state.status = state.target.map { current >= $0 } == true ? .completed : .paused
            state.elapsed = current; state.activeStart = nil; state.activeID = nil; anchor = nil
        }
        state.checkpoint = time.date; state.checkpointElapsed = state.elapsed
        return TimerUpdate(state: state, interval: interval)
    }

    @discardableResult public func reset() -> TimerUpdate {
        let previous = pause().interval
        state = freshState(target: state.target)
        return TimerUpdate(state: state, interval: previous)
    }

    public func tick() -> TimerUpdate? {
        if let settled = settleDayIfNeeded() { return settled }
        guard state.status == .running, let target = state.target, elapsed >= target else { return nil }
        return pause()
    }

    @discardableResult public func checkpoint() -> TimerUpdate {
        if let settled = settleDayIfNeeded() { return settled }
        if let finished = tick() { return finished }
        state.checkpoint = time.date; state.checkpointElapsed = elapsed
        return TimerUpdate(state: state, interval: liveInterval)
    }
}
