import Foundation
import Testing
@testable import StudyTimerCore

private final class FakeTime: TimeSource {
    var date: Date
    var continuousSeconds: Double = 0
    init(_ date: Date = Date(timeIntervalSince1970: 1_780_000_000)) { self.date = date }
    func advance(_ seconds: Double) { date.addTimeInterval(seconds); continuousSeconds += seconds }
}

struct TimerTests {
    @Test func testDisplayOmitsZeroHoursAndKeepsHourBoundary() {
        #expect(TimeInput.format(0) == "00:00")
        #expect(TimeInput.format(3599.9) == "59:59")
        #expect(TimeInput.format(3600) == "01:00:00")
        #expect(TimeInput.format(3661) == "01:01:01")
        #expect(TimeInput.format(3599.1, roundUp: true) == "01:00:00")
    }
    @Test func testInputFormatsAndInvalidValues() throws {
        #expect((try TimeInput.parse("0")) == nil)
        #expect((try TimeInput.parse(" 5 ")) == (300))
        #expect((try TimeInput.parse("25:00")) == (1500))
        #expect((try TimeInput.parse("1：30：00")) == (5400))
        #expect((try TimeInput.parse("0:05")) == (5))
        for invalid in ["", "-1", "1.5", "1:60", "1::00", "1h", "1:2:3:4", "99999999999999999"] {
            #expect(throws: (any Error).self) { try TimeInput.parse(invalid) }
        }
    }
    @Test func testPauseExcludesGapAndResumeKeepsCounter() {
        let time = FakeTime()
        #expect((TimerEngine(time: time).display) == ("00:00"))
        let timer = TimerEngine(time: time)
        timer.start(target: nil); time.advance(12.5)
        let first = timer.pause()
        #expect(abs((first.interval!.duration) - (12.5)) <= 0.001)
        time.advance(100); #expect((timer.elapsed) == (12.5))
        timer.resume(); time.advance(7.5)
        #expect(abs((timer.pause().interval!.duration) - (7.5)) <= 0.001)
        #expect((timer.elapsed) == (20))
    }
    @Test func testCountdownCapsSleepOverrunAndFinishesOnlyOnce() {
        let time = FakeTime()
        let engine = TimerEngine(time: time)
        engine.start(target: 300); #expect((engine.display) == ("05:00"))
        time.advance(3600)
        let finished = engine.tick()
        #expect((finished?.interval?.duration) == (300))
        #expect((engine.state.status) == (.completed))
        #expect((engine.display) == ("00:00"))
        #expect((engine.tick()) == nil)
        engine.resume(); #expect((engine.elapsed) == (0))
    }
    @Test func testResetAndNewInputReturnPreviousSegment() {
        let time = FakeTime()
        let timer = TimerEngine(time: time)
        timer.start(target: 600); time.advance(20)
        #expect((timer.reset().interval?.duration) == (20))
        #expect((timer.state.status) == (.paused)); #expect((timer.display) == ("10:00"))
        timer.resume(); time.advance(10)
        #expect((timer.start(target: nil).interval?.duration) == (10))
        #expect((timer.state.target) == nil); #expect((timer.elapsed) == (0))
    }
    @Test func testCrashRestoresCheckpointPaused() {
        let time = FakeTime(), engine = TimerEngine(time: time)
        engine.start(target: nil); time.advance(15)
        let checkpoint = engine.checkpoint()
        time.advance(70)
        let recovered = TimerEngine(state: checkpoint.state, time: time)
        #expect((recovered.elapsed) == (15))
        #expect((recovered.state.status) == (.paused))
        #expect((recovered.recoveredAt) == (checkpoint.state.checkpoint))
        #expect((checkpoint.interval?.duration) == (15))
    }
    @Test func testCheckpointAtDeadlineCompletesAndDoesNotDuplicate() {
        let time = FakeTime(), engine = TimerEngine(time: time)
        engine.start(target: 5); time.advance(12)
        let update = engine.checkpoint()
        #expect(update.state.status == .completed)
        #expect(update.interval?.duration == 5)
        #expect(engine.checkpoint().interval == nil)
        #expect(engine.tick() == nil)
    }
    @Test func testContinuousClockIgnoresWallClockAdjustment() {
        let time = FakeTime(), engine = TimerEngine(time: time)
        engine.start(target: nil)
        time.continuousSeconds += 30; time.date.addTimeInterval(-1000)
        #expect((engine.elapsed) == (30))
        #expect((engine.pause().interval?.duration) == (30))
    }
}

struct StatisticsTests {
    private let calendar = StudyCalendar(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    @Test func testFourAMBoundaryAndMidnight() {
        let entry = StudyInterval(start: date("2026-11-09T23:30:00+08:00"), end: date("2026-11-10T04:30:00+08:00"))
        let parts = calendar.split(entry)
        #expect((parts.count) == (2))
        #expect((parts[0].day) == (date("2026-11-09T04:00:00+08:00")))
        #expect((parts[0].interval.duration) == (4.5 * 3600))
        #expect((parts[1].interval.duration) == (1800))
        #expect((parts.reduce(0) { $0 + $1.interval.duration }) == (entry.duration))
    }
    @Test func testWeekStartsMondayAndEarlyMondayBelongsToSunday() {
        let days = calendar.days(containing: date("2026-11-09T03:00:00+08:00"), period: .weekOfYear)
        #expect((days.count) == (7))
        #expect((days.first) == (date("2026-11-02T04:00:00+08:00")))
        #expect((calendar.days(containing: date("2026-11-10T12:00:00+08:00"), period: .month).count) == (30))
    }
    @Test func testCSVUsesSameDailySplitAsStatistics() {
        let entry = StudyInterval(start: date("2026-11-10T03:59:00+08:00"), end: date("2026-11-10T04:01:00+08:00"))
        let csv = calendar.csv([entry])
        #expect(csv.hasPrefix("\u{feff}"))
        #expect(csv.contains("2026-11-09")); #expect(csv.contains("2026-11-10"))
        #expect((csv.components(separatedBy: ",60.000,计时").count) == (3))
        #expect((calendar.totals(containing: entry.end, period: .day, records: [entry]).first?.seconds) == (60))
    }
    @Test func testDSTDayStillSplitsWithoutLosingTime() {
        let dst = StudyCalendar(timeZone: TimeZone(identifier: "America/New_York")!)
        let entry = StudyInterval(start: date("2026-10-31T12:00:00-04:00"), end: date("2026-11-02T12:00:00-05:00"))
        #expect((dst.split(entry).reduce(0) { $0 + $1.interval.duration }) == (entry.duration))
    }
}

struct StoreTests {
    @Test func testLegacyPreferencesDefaultToTimelineAndLayoutBacksUp() throws {
        let data = Data("{\"theme\":\"dark\",\"alwaysOnTop\":false}".utf8)
        let legacy = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(legacy.statisticsLayout == .timeline)
        #expect(legacy.theme == .dark && !legacy.alwaysOnTop)
        var prefs = legacy; prefs.statisticsLayout = .trend
        let backup = Backup(intervals: [], timer: TimerState(), preferences: prefs)
        #expect(try Backup.decode(backup.encoded()).preferences.statisticsLayout == .trend)
    }
    @Test func testDailyGoalUsesExactSecondsAndDecodesOlderPreferences() throws {
        let legacy = try JSONDecoder().decode(Preferences.self, from: Data("{\"theme\":\"dark\"}".utf8))
        #expect(legacy.dailyGoalMinutes == 480)
        #expect(!legacy.hasReachedDailyGoal(seconds: 28_799))
        #expect(legacy.hasReachedDailyGoal(seconds: 28_800))
        #expect(legacy.hasReachedDailyGoal(seconds: 28_801))
        var preferences = legacy
        preferences.dailyGoalMinutes = 510
        #expect(!preferences.hasReachedDailyGoal(seconds: 28_801))
        #expect(preferences.hasReachedDailyGoal(seconds: 30_600))
        let backup = Backup(intervals: [], timer: TimerState(), preferences: preferences)
        #expect(try Backup.decode(backup.encoded()).preferences.dailyGoalMinutes == 510)
    }
    private func withStore(_ body: (HistoryStore) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(HistoryStore(directory: url))
    }
    @Test func testCheckpointIsAtomicAndUpsertsOneSegment() throws {
        try withStore { store in
            let time = FakeTime(), engine = TimerEngine(time: time)
            try store.save(engine.start(target: 120))
            time.advance(15); try store.save(engine.checkpoint())
            time.advance(15); try store.save(engine.checkpoint())
            #expect((try store.intervals().count) == (1))
            #expect((try store.intervals().first?.duration) == (30))
            #expect((try store.timerState().checkpointElapsed) == (30))
            time.advance(10); try store.save(engine.pause())
            #expect((try store.intervals().first?.duration) == (40))
            #expect((try store.timerState().status) == (.paused))
        }
    }
    @Test func testEditingValidationAndDeletion() throws {
        try withStore { store in
            let start = Date().addingTimeInterval(-3600)
            var entry = StudyInterval(start: start, end: start.addingTimeInterval(600), source: "manual")
            try store.upsert(entry)
            #expect(throws: (any Error).self) { try store.upsert(StudyInterval(start: start.addingTimeInterval(300), end: start.addingTimeInterval(900))) }
            #expect(throws: (any Error).self) { try store.upsert(StudyInterval(start: start, end: start)) }
            #expect(throws: (any Error).self) { try store.upsert(StudyInterval(start: .now, end: Date().addingTimeInterval(100))) }
            entry.end = start.addingTimeInterval(900); try store.upsert(entry)
            #expect((try store.intervals().first?.duration) == (900))
            try store.delete(id: entry.id); #expect(try store.intervals().isEmpty)
        }
    }
    @Test func testBackupRoundTripAndRejectedRestorePreservesRecords() throws {
        try withStore { store in
            let entry = StudyInterval(start: Date().addingTimeInterval(-100), end: Date().addingTimeInterval(-50))
            try store.upsert(entry)
            let backup = Backup(intervals: [entry], timer: TimerState(target: 300), preferences: Preferences())
            let decoded = try Backup.decode(backup.encoded())
            #expect(decoded.intervals.map(\.id) == [entry.id])
            #expect(abs(decoded.intervals[0].start.timeIntervalSince(entry.start)) < 0.000001)
            #expect(abs(decoded.intervals[0].end.timeIntervalSince(entry.end)) < 0.000001)
            #expect((decoded.preferences) == (Preferences()))
            try store.restore(decoded)
            let restored = try store.intervals()
            #expect(restored.map(\.id) == [entry.id])
            #expect(abs(restored[0].duration - entry.duration) < 0.000001)
            var invalid = backup; invalid.version = 99
            #expect(throws: (any Error).self) { try store.restore(invalid) }; #expect((try store.intervals()) == (restored))
            invalid = backup; invalid.intervals.append(entry)
            #expect(throws: (any Error).self) { try store.restore(invalid) }; #expect((try store.intervals()) == (restored))
            #expect(throws: (any Error).self) { try Backup.decode(Data("broken".utf8)) }
        }
    }
    @Test func testRestoreRunningBackupDoesNotCountOfflineGap() throws {
        try withStore { store in
            let time = FakeTime(), engine = TimerEngine(time: time)
            engine.start(target: nil); time.advance(20)
            let update = engine.checkpoint()
            let backup = Backup(intervals: [update.interval!], timer: update.state, preferences: Preferences())
            try store.restore(backup)
            #expect((try store.timerState().status) == (.paused))
            #expect((try store.timerState().elapsed) == (20))
            #expect((try store.timerState().activeStart) == nil)
        }
    }
}
