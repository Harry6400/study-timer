import Foundation
import Testing
@testable import StudyTimerCore

private final class SettlementClock: TimeSource {
    var date: Date
    var continuousSeconds: Double = 0
    init(_ value: String) { date = ISO8601DateFormatter().date(from: value)! }
    func advance(_ seconds: Double) { date.addTimeInterval(seconds); continuousSeconds += seconds }
}

struct DailySettlementTests {
    private let calendar = StudyCalendar(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func stopsAtFourAndSettlesOnlyOnce() throws {
        let time = SettlementClock("2026-11-10T03:59:59+08:00")
        let engine = TimerEngine(time: time, calendar: calendar)
        engine.start(target: nil)
        #expect(engine.settleDayIfNeeded() == nil)
        time.advance(1)
        let update = try #require(engine.settleDayIfNeeded())
        #expect(update.isDaySettlement && update.interval?.duration == 1)
        #expect(update.interval?.end == date("2026-11-10T04:00:00+08:00"))
        #expect(engine.display == "00:00" && engine.state.status == .paused)
        #expect(engine.state.activeID == nil && engine.state.target == nil)
        #expect(engine.settleDayIfNeeded() == nil)
        engine.resume(); time.advance(20)
        #expect(engine.pause().interval?.duration == 20)
    }

    @Test func sleepAcrossSeveralDaysStopsAtFirstBoundary() throws {
        let time = SettlementClock("2026-11-10T03:30:00+08:00")
        let engine = TimerEngine(time: time, calendar: calendar)
        engine.start(target: nil); time.advance(3 * 86400 + 3600)
        let update = try #require(engine.settleDayIfNeeded())
        #expect(update.interval?.duration == 1800)
        #expect(update.interval?.end == date("2026-11-10T04:00:00+08:00"))
        #expect(engine.state.studyDayStart == date("2026-11-13T04:00:00+08:00"))
        #expect(engine.settleDayIfNeeded() == nil && engine.display == "00:00")
    }

    @Test func pausedAndCompletedReadoutsAlsoReset() {
        for completed in [false, true] {
            let time = SettlementClock("2026-11-10T03:58:00+08:00")
            let engine = TimerEngine(time: time, calendar: calendar)
            engine.start(target: 30); time.advance(completed ? 30 : 10)
            if completed { _ = engine.tick() } else { _ = engine.pause() }
            time.advance(300)
            let result = engine.settleDayIfNeeded()
            #expect(result != nil && result?.interval == nil)
            #expect(engine.state.status == .paused && engine.state.target == nil)
            #expect(engine.display == "00:00")
        }
    }

    @Test func countdownUsesEarlierOfDeadlineAndBoundary() throws {
        for target in [300.0, 1800.0, 3600.0] {
            let time = SettlementClock("2026-11-10T03:30:00+08:00")
            let engine = TimerEngine(time: time, calendar: calendar)
            engine.start(target: target); time.advance(6 * 3600)
            let result = try #require(engine.tick())
            #expect(result.isDaySettlement)
            #expect(result.interval?.duration == min(target, 1800))
            #expect(engine.state.target == nil && engine.display == "00:00")
        }
    }

    @Test func restartUsesSavedCheckpointAndNeverAddsOfflineTime() throws {
        let time = SettlementClock("2026-11-10T03:50:00+08:00")
        let running = TimerEngine(time: time, calendar: calendar)
        running.start(target: nil); time.advance(120)
        let saved = running.checkpoint()
        time.advance(8 * 3600)
        let loaded = TimerEngine(state: saved.state, time: time, calendar: calendar)
        let update = try #require(loaded.initialUpdate)
        #expect(loaded.settledOnLoad && update.interval?.duration == 120)
        #expect(update.interval?.id == saved.interval?.id)
        #expect(loaded.state.status == .paused && loaded.display == "00:00")
    }

    @Test func legacyCrossDayCheckpointIsClippedWithoutChangingItsID() throws {
        var saved = TimerState()
        saved.activeStart = date("2026-11-10T03:50:00+08:00")
        saved.activeID = UUID(); saved.status = .running
        saved.checkpoint = date("2026-11-10T08:00:00+08:00")
        saved.checkpointElapsed = 4 * 3600 + 600
        let time = SettlementClock("2026-11-10T09:00:00+08:00")
        let loaded = TimerEngine(state: saved, time: time, calendar: calendar)
        let update = try #require(loaded.initialUpdate)
        #expect(update.interval?.duration == 600 && update.interval?.id == saved.activeID)
        #expect(loaded.display == "00:00")
    }

    @Test func sameDayCrashStillRecoversPausedAtCheckpoint() {
        let time = SettlementClock("2026-11-10T00:30:00+08:00")
        let engine = TimerEngine(time: time, calendar: calendar)
        engine.start(target: nil); time.advance(50)
        let saved = engine.checkpoint()
        time.advance(60)
        let loaded = TimerEngine(state: saved.state, time: time, calendar: calendar)
        #expect(!loaded.settledOnLoad && loaded.elapsed == 50)
        #expect(loaded.recoveredAt == saved.state.checkpoint && loaded.state.status == .paused)
    }

    @Test func snapshotAfterBoundaryIsSafeWithoutMutatingLiveEngine() throws {
        let time = SettlementClock("2026-11-10T03:59:00+08:00")
        let engine = TimerEngine(time: time, calendar: calendar)
        engine.start(target: nil); time.advance(600)
        let snapshot = engine.snapshot()
        #expect(snapshot.interval?.duration == 60 && snapshot.state.elapsed == 0)
        #expect(snapshot.state.target == nil && snapshot.state.status == .paused)
        #expect(engine.state.status == .running)
        #expect(try #require(engine.settleDayIfNeeded()).interval?.duration == 60)
    }

    @Test func clockRollbackDoesNotRepeatSettlement() {
        let time = SettlementClock("2026-11-10T03:59:00+08:00")
        let engine = TimerEngine(time: time, calendar: calendar)
        engine.start(target: nil); time.advance(120)
        #expect(engine.settleDayIfNeeded() != nil)
        time.date = date("2026-11-10T03:59:00+08:00")
        #expect(engine.settleDayIfNeeded() == nil)
        time.advance(120)
        #expect(engine.settleDayIfNeeded() == nil)
    }

    @Test func nextBoundaryUsesCalendarAcrossDaylightSaving() {
        let ny = StudyCalendar(timeZone: TimeZone(identifier: "America/New_York")!)
        let spring = SettlementClock("2026-03-07T04:00:00-05:00")
        let autumn = SettlementClock("2026-10-31T04:00:00-04:00")
        #expect(TimerEngine(time: spring, calendar: ny).nextStudyDayBoundary.timeIntervalSince(spring.date) == 23 * 3600)
        #expect(TimerEngine(time: autumn, calendar: ny).nextStudyDayBoundary.timeIntervalSince(autumn.date) == 25 * 3600)
    }

    @Test func oldBackupDecodesAndInfersDayWithoutVersionChange() throws {
        var state = TimerState(target: 600)
        state.elapsed = 20; state.checkpointElapsed = 20
        state.checkpoint = date("2026-11-10T02:00:00+08:00")
        var backup = Backup(intervals: [], timer: state, preferences: Preferences(), createdAt: state.checkpoint!)
        backup.version = 1
        let decoded = try Backup.decode(backup.encoded(), now: date("2026-11-10T08:00:00+08:00"))
        #expect(decoded.version == 1 && decoded.timer.studyDayStart == nil)
        let loaded = TimerEngine(state: decoded.timer, time: SettlementClock("2026-11-10T08:00:00+08:00"), calendar: calendar)
        #expect(loaded.settledOnLoad && loaded.display == "00:00")
    }
}
