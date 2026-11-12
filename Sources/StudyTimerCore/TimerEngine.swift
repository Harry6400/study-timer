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
    private let time: any TimeSource
    private var anchor: TimeInterval?

    public init(state: TimerState = TimerState(), time: any TimeSource = SystemTimeSource()) {
        self.state = state; self.time = time
        if state.status == .running {
            recoveredAt = state.checkpoint ?? state.activeStart
            self.state.elapsed = state.checkpointElapsed
            self.state.status = state.target.map { state.checkpointElapsed >= $0 } == true ? .completed : .paused
            self.state.activeStart = nil; self.state.activeID = nil
        }
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
        let previous = pause().interval
        state = TimerState(target: target)
        beginSegment()
        return TimerUpdate(state: state, interval: previous)
    }

    @discardableResult public func resume() -> TimerUpdate {
        guard state.status != .running else { return checkpoint() }
        if state.status == .completed { state.elapsed = 0 }
        beginSegment()
        return TimerUpdate(state: state, interval: nil)
    }

    private func beginSegment() {
        state.status = .running; state.activeStart = time.date; state.activeID = UUID()
        state.checkpoint = time.date; state.checkpointElapsed = state.elapsed
        anchor = time.continuousSeconds
    }

    @discardableResult public func pause() -> TimerUpdate {
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
        state = TimerState(target: state.target)
        return TimerUpdate(state: state, interval: previous)
    }

    public func tick() -> TimerUpdate? {
        guard state.status == .running, let target = state.target, elapsed >= target else { return nil }
        return pause()
    }

    @discardableResult public func checkpoint() -> TimerUpdate {
        if let finished = tick() { return finished }
        state.checkpoint = time.date; state.checkpointElapsed = elapsed
        return TimerUpdate(state: state, interval: liveInterval)
    }
}
