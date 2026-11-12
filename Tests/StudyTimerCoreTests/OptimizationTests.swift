import Foundation
import Testing
@testable import StudyTimerCore

struct OptimizationTests {
    let calendar = StudyCalendar(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    @Test func indexMatchesReferenceAcrossDaysAndEdits() {
        let first = date("2026-01-01T03:30:00+08:00")
        let records = (0..<180).map { i in
            StudyInterval(start: first.addingTimeInterval(Double(i) * 36_000),
                          end: first.addingTimeInterval(Double(i) * 36_000 + Double((i % 8) + 1) * 4200))
        }
        var index = StatisticsIndex(records: records, calendar: calendar)
        var expected = records
        let edited = StudyInterval(id: records[12].id, start: records[12].start.addingTimeInterval(-1000), end: records[12].end.addingTimeInterval(900))
        index.replace(id: edited.id, with: edited); expected[12] = edited
        index.replace(id: records[50].id, with: nil); expected.removeAll { $0.id == records[50].id }
        var day = calendar.dayStart(for: first)
        for _ in 0..<90 {
            #expect(index.intervals(on: day) == calendar.intervals(on: day, from: expected))
            #expect(abs(index.total(on: day) - calendar.intervals(on: day, from: expected).reduce(0) { $0 + $1.duration }) < 0.00001)
            day = calendar.nextDay(day)
        }
    }
    @Test func liveCheckpointIsCountedOnceAndOnlyInItsDay() {
        let start = date("2026-11-10T03:59:00+08:00")
        let saved = StudyInterval(start: start, end: start.addingTimeInterval(30))
        let live = StudyInterval(id: saved.id, start: start, end: start.addingTimeInterval(180))
        let index = StatisticsIndex(records: [saved], calendar: calendar)
        #expect(index.total(on: start, live: live) == 60)
        #expect(index.total(on: live.end, live: live) == 120)
        #expect(index.intervals(on: start, live: live).count == 1)
    }
    @Test func indexPreservesDSTAndCanRebuildForAnotherZone() {
        let record = StudyInterval(start: date("2026-10-31T12:00:00-04:00"), end: date("2026-11-02T12:00:00-05:00"))
        for zone in ["America/New_York", "Asia/Shanghai"] {
            let cal = StudyCalendar(timeZone: TimeZone(identifier: zone)!)
            let index = StatisticsIndex(records: [record], calendar: cal)
            #expect(cal.split(record).reduce(0) { $0 + index.total(on: $1.day) } == record.duration)
        }
    }
    @Test func twentyStepHistoryAdvancesOnlyAfterCommitAndClearsRedo() {
        var history = RecordHistory()
        for i in 0..<25 {
            let item = StudyInterval(start: Date(timeIntervalSince1970: Double(i) * 10), end: Date(timeIntervalSince1970: Double(i) * 10 + 5))
            history.record(RecordChange(before: nil, after: item))
        }
        #expect(history.undoCount == 20)
        let pending = history.undo
        // 失败路径不调用 didUndo，因此保留原操作。
        #expect(history.undo == pending)
        history.didUndo(); #expect(history.undoCount == 19 && history.redoCount == 1)
        history.didRedo(); #expect(history.undoCount == 20 && history.redoCount == 0)
        history.didUndo(); history.record(RecordChange(before: pending!.after, after: nil))
        #expect(history.redo == nil)
        let count = history.undoCount
        history.record(RecordChange(before: pending!.after, after: pending!.after))
        #expect(history.undoCount == count)
        history.clear(); #expect(history.undo == nil && history.redo == nil)
    }
    @Test func databaseMutationAvoidsFullReadsAndRejectsStaleUndo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(directory: folder)
        let item = StudyInterval(start: .now.addingTimeInterval(-100), end: .now.addingTimeInterval(-80))
        let add = RecordChange(before: nil, after: item)
        try store.apply(add)
        let initialReads = store.fullReadCount
        var changed = item; changed.end.addTimeInterval(5)
        try store.apply(RecordChange(before: item, after: changed))
        #expect(throws: (any Error).self) { try store.apply(add.reversed) }
        #expect(abs(try store.interval(id: item.id)!.duration - changed.duration) < 0.000001)
        var overlap = item; overlap.id = UUID()
        #expect(throws: (any Error).self) { try store.upsert(overlap) }
        #expect(store.fullReadCount == initialReads)
    }
    @Test func tenThousandSyntheticRecordsKeepCheckpointsAndQueriesIncremental() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(directory: folder)
        let origin = Date().addingTimeInterval(-20_000 * 3600)
        let records = (0..<10_000).map { i in
            StudyInterval(start: origin.addingTimeInterval(Double(i) * 3600), end: origin.addingTimeInterval(Double(i) * 3600 + 900))
        }
        try store.restore(Backup(intervals: records, timer: TimerState(), preferences: Preferences()))
        let index = StatisticsIndex(records: try store.intervals(), calendar: calendar)
        let reads = store.fullReadCount
        let live = StudyInterval(start: .now.addingTimeInterval(-60), end: .now)
        for i in 1...60 {
            var current = live; current.end = live.start.addingTimeInterval(Double(i))
            try store.save(TimerUpdate(state: TimerState(), interval: current))
            let days = calendar.recentSevenDays(endingAt: current.end)
            #expect(index.totals(on: days, live: current).reduce(0) { $0 + $1.seconds } >= Double(i))
        }
        #expect(store.fullReadCount == reads)
    }
    @Test func labelCollisionResolutionKeepsAllThirtyOneValues() {
        let input = (0..<31).map { ChartLabel(id: $0, x: Double($0) * 18, y: 100 - Double($0 % 4) * 5, width: 25) }
        let labels = ChartLabel.arranged(input)
        #expect(labels.count == 31)
        for i in labels.indices {
            for j in labels.indices where j > i { #expect(!labels[i].rect.intersects(labels[j].rect)) }
        }
    }
    @Test func automaticBackupsDefaultOnForLegacyPreferences() throws {
        let value = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(value.automaticBackups)
        var off = value; off.automaticBackups = false
        #expect(try Backup.decode(Backup(intervals: [], timer: TimerState(), preferences: off).encoded()).preferences.automaticBackups == false)
    }
    @Test func backupRotationIsVerifiedAndPreservesUnrelatedFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = BackupService(directory: folder)
        let root = folder.appendingPathComponent("自动备份")
        let start = Date().addingTimeInterval(-20 * 86400)
        for i in 0..<9 {
            let backup = Backup(intervals: [], timer: TimerState(), preferences: Preferences(), createdAt: start.addingTimeInterval(Double(i) * 86400))
            try await service.daily(backup, calendar: calendar)
        }
        let daily = root.appendingPathComponent("每日")
        let manual = daily.appendingPathComponent("manual.json"); try Data("keep".utf8).write(to: manual)
        for i in 0..<12 {
            try await service.beforeChange(Backup(intervals: [], timer: TimerState(), preferences: Preferences(), createdAt: start.addingTimeInterval(Double(i))))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: daily.path).filter { $0.hasPrefix("daily-") }.count == 7)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("操作前"), includingPropertiesForKeys: nil)
        #expect(files.count == 10)
        for file in files { _ = try Backup.decode(Data(contentsOf: file)) }
        #expect(FileManager.default.fileExists(atPath: manual.path))
    }
    @Test func failedBackupDoesNotPruneExistingCopies() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = BackupService(directory: folder)
        let backup = Backup(intervals: [], timer: TimerState(), preferences: Preferences())
        try await service.beforeChange(backup)
        let pre = folder.appendingPathComponent("自动备份/操作前")
        let initial = try FileManager.default.contentsOfDirectory(atPath: pre.path)
        var invalid = backup; invalid.version = 99
        await #expect(throws: (any Error).self) { try await service.beforeChange(invalid) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: pre.path) == initial)
    }
}
