import Foundation
import Testing
import SQLite3
import StudyTimerCore
@testable import StudyTimer

private final class ModelClock: TimeSource {
    var date: Date
    var continuousSeconds: Double = 0
    init(_ value: String = "2026-11-10T03:59:50+08:00") { date = ISO8601DateFormatter().date(from: value)! }
    func advance(_ seconds: Double) { date.addTimeInterval(seconds); continuousSeconds += seconds }
}

@MainActor struct DailySettlementAppTests {
    private let calendar = StudyCalendar(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("study-daily-test-" + UUID().uuidString) }
    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: "local.harry64.studytimer.verify." + directory.lastPathComponent)
    }
    private func execute(_ sql: String, in directory: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("history.sqlite3").path, &db) == SQLITE_OK else { throw StudyError.storage("test open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StudyError.storage("test SQL") }
    }

    @Test func wakeSettlesOldDayAndKeepsDailyBackupAndIndexConsistent() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock()
        let model = try AppModel(directoryOverride: dir, time: time, calendar: calendar)
        let oldDay = model.studyDay, reads = model.store.fullReadCount
        try model.start(text: "0"); time.advance(5); model.checkpoint()
        time.advance(8 * 3600); model.synchronizeTime()
        #expect(!model.isRunning && model.engine.display == "00:00" && model.pauseElapsed == nil)
        #expect(model.todayTotal == 0 && model.records.count == 1 && model.records[0].duration == 10)
        #expect(model.total(on: oldDay) == 10 && model.store.fullReadCount == reads)
        #expect(!model.canUndo && !model.settlementPending)
        model.synchronizeTime(); model.checkpoint()
        #expect(model.records.count == 1)
        #expect(try model.store.intervals().count == 1)
        #expect(await model.quit())
        let files = try FileManager.default.contentsOfDirectory(at: model.backupDirectory.appendingPathComponent("每日"), includingPropertiesForKeys: nil)
        let latest = try #require(files.sorted { $0.lastPathComponent < $1.lastPathComponent }.last)
        let backup = try Backup.decode(Data(contentsOf: latest))
        #expect(backup.intervals.count == 1 && backup.intervals[0].duration == 10)
        #expect(backup.timer.elapsed == 0 && backup.timer.target == nil)
    }

    @Test func sleepSavesTheActiveCountdownAndWakeKeepsItPaused() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock("2026-11-10T14:00:00+08:00")
        let model = try AppModel(directoryOverride: dir, time: time, calendar: calendar)
        try model.start(text: "5")
        time.advance(20)
        model.willSleep()
        #expect(try model.store.timerState().status == .paused)
        #expect(model.statusText == "休眠暂停")
        #expect(try model.store.intervals().map(\.duration) == [20])
        #expect(model.countdownReminderDelay == nil)

        time.advance(1_200)
        model.didWake()
        #expect(!model.isRunning && model.engine.elapsed == 20 && model.todayTotal == 20)
        model.toggle()
        #expect(model.isRunning && model.countdownReminderDelay == 280)
        time.advance(5)
        #expect(await model.quit())
        #expect(try model.store.intervals().map(\.duration) == [20, 5])
    }

    @Test func clockRollbackPreservesCountdownArchivesAndUndoesWithoutDoubleCounting() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock("2026-11-10T14:00:00+08:00")
        let start = time.date
        let model = try AppModel(directoryOverride: dir, time: time, calendar: calendar)
        try model.start(text: "5")
        time.advance(60); model.checkpoint()
        time.advance(120); time.date.addTimeInterval(-150)
        model.synchronizeTime()
        #expect(!model.isRunning && model.statusText == "时钟回拨")
        #expect(model.engine.elapsed == 180 && model.engine.display == "02:00")
        #expect(model.todayTotal == 30)
        let pending = try #require(model.pendingIntervals.first)
        #expect(pending.duration == 150)

        let url = dir.appendingPathComponent("roundtrip.json")
        try await model.exportBackup(to: url)
        let backup = try Backup.decode(Data(contentsOf: url), now: time.date)
        #expect(backup.version == 2 && backup.pending == [pending])
        model.toggle()
        time.advance(60); model.toggle()
        #expect(model.todayTotal == 90 && model.engine.display == "01:00")
        let corrected = StudyInterval(id: pending.id, start: start.addingTimeInterval(-3600),
                                      end: start.addingTimeInterval(-3600 + pending.duration))
        try await model.archive(pending, as: corrected)
        #expect(model.pendingIntervals.isEmpty && model.todayTotal == 240)
        try await model.undoRecord()
        #expect(model.pendingIntervals == [pending] && model.todayTotal == 90)
        try await model.redoRecord()
        #expect(model.pendingIntervals.isEmpty && model.todayTotal == 240)
        try await model.restore(from: url)
        #expect(model.pendingIntervals == [pending] && model.todayTotal == 30)
        #expect(await model.quit())
    }

    @Test func clockRollbackCommitRetriesTheOriginalRemainder() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock("2026-11-10T14:00:00+08:00")
        let model = try AppModel(directoryOverride: dir, time: time, calendar: calendar)
        try model.start(text: "0")
        time.advance(20); model.checkpoint()
        try execute("CREATE TRIGGER reject_clock BEFORE UPDATE ON metadata BEGIN SELECT RAISE(ABORT,'simulated failure'); END;", in: dir)
        time.advance(10); time.date.addTimeInterval(-45)
        model.synchronizeTime()
        #expect(model.clockRecoveryPending && !model.isRunning && model.pendingIntervals.isEmpty)
        #expect(try model.store.intervals().map(\.duration) == [20])
        #expect(throws: (any Error).self) { try model.start(text: "0") }
        try execute("DROP TRIGGER reject_clock", in: dir)
        time.advance(60); model.synchronizeTime(); model.synchronizeTime()
        #expect(!model.clockRecoveryPending && model.pendingIntervals.map(\.duration) == [30])
        #expect(try model.store.intervals().isEmpty)
        #expect(await model.quit())
    }

    @Test func resumingAcrossRollbackUsesTheCorrectedFourAMBoundary() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock("2026-11-10T04:01:00+08:00")
        let model = try AppModel(directoryOverride: dir, time: time, calendar: calendar)
        try model.start(text: "0")
        time.advance(30)
        time.date = ISO8601DateFormatter().date(from: "2026-11-10T03:59:50+08:00")!
        model.synchronizeTime()
        #expect(!model.isRunning && model.pendingIntervals.map(\.duration) == [30])
        model.toggle()
        time.advance(20); model.synchronizeTime()
        #expect(!model.isRunning && model.engine.display == "00:00")
        #expect(try model.store.intervals().map(\.duration) == [10])
        #expect(model.pendingIntervals.map(\.duration) == [30])
        #expect(await model.quit())
    }

    @Test func v1MigrationKeepsManualRecordsAndPreservesConflictingIDs() throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock("2026-11-10T14:00:00+08:00")
        let earlier = time.date.addingTimeInterval(-1800)
        let first = StudyInterval(start: earlier, end: earlier.addingTimeInterval(90))
        let manual = StudyInterval(start: earlier.addingTimeInterval(30), end: earlier.addingTimeInterval(120), source: "manual")
        let future = StudyInterval(start: time.date.addingTimeInterval(60), end: time.date.addingTimeInterval(100))
        do {
            let store = try HistoryStore(directory: dir, now: time.date)
            for entry in [first, manual, future] { try store.save(TimerUpdate(state: TimerState(), interval: entry)) }
            try execute("PRAGMA user_version=1", in: dir)
        }
        let migrated = try HistoryStore(directory: dir, now: time.date)
        #expect(try migrated.intervals() == [manual])
        #expect(try migrated.pendingIntervals().map(\.original) == [first, future])
    }

    @Test func sleepAcrossFourAMKeepsOnlyTheTimeBeforeSleep() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock()
        let model = try AppModel(directoryOverride: dir, time: time, calendar: calendar)
        let oldDay = model.studyDay
        try model.start(text: "0")
        time.advance(5)
        model.willSleep()
        time.advance(60)
        model.didWake()
        #expect(!model.isRunning && model.todayTotal == 0 && model.engine.elapsed == 0)
        #expect(model.total(on: oldDay) == 5)
        #expect(try model.store.intervals().map(\.duration) == [5])
        #expect(await model.quit())
    }

    @Test func lossOfConnectionPausesOnceAndOfflineStartAndResumeStillWork() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock("2026-11-10T14:00:00+08:00")
        let model = try AppModel(directoryOverride: dir, time: time, calendar: calendar)
        try model.start(text: "0")
        model.networkAvailabilityChanged(false)
        #expect(model.isRunning)
        time.advance(12)
        model.networkAvailabilityChanged(true)
        time.advance(3)
        model.networkAvailabilityChanged(false)
        #expect(!model.isRunning && model.engine.elapsed == 15)
        #expect(try model.store.timerState().status == .paused)

        time.advance(120)
        model.networkAvailabilityChanged(false)
        #expect(try model.store.intervals().map(\.duration) == [15])
        model.toggle()
        model.networkAvailabilityChanged(false)
        #expect(model.isRunning)
        time.advance(7)
        model.networkAvailabilityChanged(true)
        model.networkAvailabilityChanged(false)
        model.networkAvailabilityChanged(true)
        #expect(!model.isRunning && model.engine.elapsed == 22)
        #expect(try model.store.intervals().map(\.duration) == [15, 7])
        #expect(await model.quit())
    }

    @Test func statisticsReadoutCountsActiveTimeTowardTheDailyGoal() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock("2026-11-10T14:00:00+08:00")
        let model = try AppModel(directoryOverride: dir, time: time, calendar: calendar)
        let day = model.studyDay
        let record = StudyInterval(start: day, end: day.addingTimeInterval(28_798), source: "manual")
        try await model.saveInterval(record)
        model.statisticsVisible = true
        try model.start(text: "0")
        for seconds in [28_799, 28_800, 28_801] {
            time.advance(1)
            model.synchronizeTime()
            let live = model.statisticsReadout.interval
            let total = try #require(model.totals(on: [day], live: live).first)
            #expect(total.seconds == Double(seconds))
            #expect(model.preferences.hasReachedDailyGoal(seconds: total.seconds) == (seconds >= 28_800))
        }
        #expect(await model.quit())
    }

    @Test func failedSettlementRollsBackTransactionBlocksActionsAndRetriesOnce() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock()
        let model = try AppModel(directoryOverride: dir, time: time, calendar: calendar)
        let manual = StudyInterval(start: time.date.addingTimeInterval(-3600), end: time.date.addingTimeInterval(-3500), source: "manual")
        try await model.saveInterval(manual)
        try model.start(text: "0"); time.advance(5); model.checkpoint()
        let id = try #require(model.activeID)
        try execute("CREATE TRIGGER reject_state BEFORE UPDATE ON metadata BEGIN SELECT RAISE(ABORT,'simulated settlement failure'); END;", in: dir)
        time.advance(20); model.synchronizeTime()
        #expect(model.settlementPending && !model.isRunning && !model.shortcutEnabled)
        #expect(model.engine.display == "00:00" && model.message?.contains("结算尚未保存") == true)
        #expect(try model.store.timerState().status == .running)
        #expect(try model.store.interval(id: id)?.duration == 5) // 整个结算事务回滚。
        #expect(model.snapshot().intervals.first { $0.id == id }?.duration == 10)
        #expect(throws: (any Error).self) { try model.start(text: "0") }
        model.toggle(); model.reset()
        await #expect(throws: (any Error).self) { try await model.undoRecord() }
        #expect(model.canUndo && !model.canRedo && !model.isRunning)
        #expect(!(await model.quit()))
        try execute("DROP TRIGGER reject_state", in: dir)
        model.synchronizeTime(); model.synchronizeTime()
        #expect(!model.settlementPending && model.records.count == 2 && model.canUndo)
        #expect(try model.store.interval(id: id)?.duration == 10)
        #expect(try model.store.timerState().elapsed == 0)
        try model.start(text: "0"); time.advance(2); model.toggle()
        #expect(model.engine.elapsed == 2 && model.records.count == 3)
        #expect(await model.quit())
    }

    @Test func pendingPauseAndCountdownAreClearedAtBoundary() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock()
        let model = try AppModel(directoryOverride: dir, time: time, calendar: calendar)
        try model.start(text: "5"); time.advance(5); model.toggle()
        #expect(model.pauseElapsed != nil && model.engine.state.target == 300)
        time.advance(10); model.synchronizeTime()
        #expect(model.pauseElapsed == nil && model.engine.state.target == nil && model.engine.display == "00:00")
        #expect(model.records.count == 1 && model.records[0].duration == 5)
        #expect(await model.quit())
    }

    @Test func startupAndRestoreOfOldDayClearReadoutButPreserveHistory() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock("2026-11-10T08:00:00+08:00")
        let item = StudyInterval(start: time.date.addingTimeInterval(-86400), end: time.date.addingTimeInterval(-86000))
        var old = TimerState(target: 600)
        old.elapsed = 400; old.checkpointElapsed = 400; old.checkpoint = item.end
        do { let store = try HistoryStore(directory: dir); try store.save(TimerUpdate(state: old, interval: item)) }
        let model = try AppModel(directoryOverride: dir, time: time, calendar: calendar)
        #expect(model.engine.display == "00:00" && model.records == [item])
        model.resumeAfterUpdate()
        #expect(!model.isRunning)
        #expect(try model.store.timerState().studyDayStart == model.studyDay)
        let url = dir.appendingPathComponent("legacy-backup.json")
        try Backup(intervals: [item], timer: old, preferences: Preferences(), createdAt: item.end).encoded().write(to: url)
        try await model.restore(from: url)
        #expect(model.engine.display == "00:00" && model.engine.state.target == nil && model.records == [item])
        #expect(await model.quit())
    }

    @Test func countdownRemindersNeverExtendPastSettlement() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock("2026-11-10T03:30:00+08:00")
        let model = try AppModel(directoryOverride: dir, time: time, calendar: calendar)
        try model.start(text: "5"); #expect(model.countdownReminderDelay == 300)
        try model.start(text: "30"); #expect(model.countdownReminderDelay == nil)
        try model.start(text: "60"); #expect(model.countdownReminderDelay == nil)
        #expect(await model.quit())
    }

    @Test func updateResumeCannotRestartYesterdayAtBoundary() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock()
        let model = try AppModel(directoryOverride: dir, time: time, calendar: calendar)
        model.resumeAfterUpdate(); #expect(model.isRunning)
        time.advance(5); model.toggle()
        time.advance(20); model.resumeAfterUpdate()
        #expect(!model.isRunning && model.engine.display == "00:00" && model.pauseElapsed == nil)
        #expect(await model.quit())
    }

    @Test func openingStatisticsPublishesEveryRequestIncludingReopening() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let time = ModelClock()
        let model = try AppModel(directoryOverride: dir, time: time, calendar: calendar)
        model.openedStatistics(); let first = model.statisticsPresentation
        time.advance(30)
        model.openedStatistics()
        #expect(model.statisticsPresentation == first + 1 && model.studyDay == calendar.dayStart(for: time.date))
        #expect(await model.quit())
    }
}

struct StatisticsSelectionTests {
    private let today = Date(timeIntervalSince1970: 1_794_254_400)
    @Test func hoveringRetainsDetailWithoutMovingChartRange() {
        var selection = StatisticsSelection(today: today)
        let historical = today.addingTimeInterval(-3 * 86400)
        selection.preview(historical)
        #expect(selection.date == today && selection.detailDate == historical)
        selection.preview(today.addingTimeInterval(86400))
        #expect(selection.date == today && selection.detailDate > today)
    }
    @Test func directTimelineAndReopeningSelectTodayWhileClickKeepsRequestedDay() {
        var selection = StatisticsSelection(today: today)
        let historical = today.addingTimeInterval(-86400)
        selection.navigate(to: historical)
        #expect(selection.date == historical && selection.detailDate == historical)
        selection.showToday(today)
        #expect(selection.date == today && selection.detailDate == today)
    }
    @Test func dayChangeFollowsTodayAndPreservesDeliberateHistoricalSelection() {
        var selection = StatisticsSelection(today: today)
        let tomorrow = today.addingTimeInterval(86400)
        selection.dayChanged(from: today, to: tomorrow)
        #expect(selection.date == tomorrow && selection.detailDate == tomorrow)
        selection.navigate(to: today.addingTimeInterval(-86400))
        selection.dayChanged(from: tomorrow, to: tomorrow.addingTimeInterval(86400))
        #expect(selection.date == today.addingTimeInterval(-86400))
    }
}
