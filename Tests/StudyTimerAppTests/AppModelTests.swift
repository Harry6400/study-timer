import Foundation
import Testing
import SQLite3
import StudyTimerCore
@testable import StudyTimer

@MainActor struct AppModelTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("study-app-test-" + UUID().uuidString) }
    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: "local.harry64.studytimer.verify." + directory.lastPathComponent)
    }
    private func execute(_ sql: String, at folder: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(folder.appendingPathComponent("history.sqlite3").path, &db) == SQLITE_OK else { throw StudyError.storage("test open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StudyError.storage("test SQL") }
    }
    @Test func failedPreoperationBackupPreservesRecordsAndUndoHistory() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let model = try AppModel(directoryOverride: dir)
        let item = StudyInterval(start: .now.addingTimeInterval(-100), end: .now.addingTimeInterval(-50), source: "manual")
        try await model.saveInterval(item)
        #expect(model.records == [item] && model.canUndo)
        let root = model.backupDirectory
        // 等待启动/修改后的每日备份，然后将备份目录替换为普通文件，模拟不可写位置。
        await model.quit()
        try FileManager.default.removeItem(at: root); try Data("blocked".utf8).write(to: root)
        await #expect(throws: (any Error).self) { try await model.deleteInterval(id: item.id) }
        #expect(model.records == [item] && model.canUndo && !model.canRedo)
        #expect(try model.store.interval(id: item.id) != nil)
        #expect(model.backupError != nil && !model.isMutating)
    }
    @Test func failedCommitDoesNotMoveCachesOrUndoStack() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let model = try AppModel(directoryOverride: dir)
        let item = StudyInterval(start: .now.addingTimeInterval(-100), end: .now.addingTimeInterval(-50), source: "manual")
        try await model.saveInterval(item)
        try execute("CREATE TRIGGER reject_delete BEFORE DELETE ON intervals BEGIN SELECT RAISE(ABORT,'simulated failure'); END;", at: dir)
        await #expect(throws: (any Error).self) { try await model.undoRecord() }
        #expect(model.canUndo && !model.canRedo && model.records == [item])
        try execute("DROP TRIGGER reject_delete", at: dir)
        try await model.undoRecord(); #expect(model.records.isEmpty && model.canRedo)
        try await model.redoRecord(); #expect(model.records == [item] && model.canUndo)
        await model.quit()
    }
    @Test func checkpointsDoNotReadHistoryAndSnapshotDoesNotPauseLiveTimer() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let model = try AppModel(directoryOverride: dir)
        try model.start(text: "0")
        let reads = model.store.fullReadCount
        for _ in 0..<30 { model.checkpoint() }
        let backup = model.snapshot()
        #expect(model.isRunning && backup.timer.status == .paused)
        #expect(backup.timer.activeID == nil && backup.timer.activeStart == nil)
        #expect(model.store.fullReadCount == reads && !model.canUndo)
        #expect(backup.intervals.count == 1)
        _ = try backup.validated()
        model.toggle()
        #expect(model.records.count == 1 && model.pauseElapsed != nil)
        let pausedBackup = model.snapshot()
        #expect(pausedBackup.intervals.count == 1)
        await model.quit()
    }
    @Test func successfulRestoreRebuildsIndexAndClearsBothHistoryStacks() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let model = try AppModel(directoryOverride: dir)
        let item = StudyInterval(start: .now.addingTimeInterval(-1000), end: .now.addingTimeInterval(-500), source: "manual")
        try await model.saveInterval(item)
        let backupURL = dir.appendingPathComponent("manual.json")
        try await model.exportBackup(to: backupURL)
        try await model.deleteInterval(id: item.id)
        #expect(model.canUndo && model.records.isEmpty)
        try await model.restore(from: backupURL)
        #expect(model.records.count == 1 && !model.canUndo && !model.canRedo && !model.isRunning)
        #expect(abs(model.total(on: item.start) - item.duration) < 0.000001)
        #expect(try model.store.intervals().count == 1)
        await model.quit()
    }
    @Test func failedRestoreBackupKeepsOriginalDataAndHistory() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let model = try AppModel(directoryOverride: dir)
        let item = StudyInterval(start: .now.addingTimeInterval(-1000), end: .now.addingTimeInterval(-500), source: "manual")
        try await model.saveInterval(item)
        let replacement = dir.appendingPathComponent("empty.json")
        try Backup(intervals: [], timer: TimerState(), preferences: Preferences()).encoded().write(to: replacement)
        await model.quit()
        try FileManager.default.removeItem(at: model.backupDirectory)
        try Data("blocked".utf8).write(to: model.backupDirectory)
        await #expect(throws: (any Error).self) { try await model.restore(from: replacement) }
        #expect(model.records == [item] && model.canUndo && !model.canRedo)
        #expect(try model.store.interval(id: item.id) != nil)
    }

    @Test func editingLoadedRecordUsesOriginalCompleteInterval() async throws {
        let dir = folder(); defer { cleanup(dir) }
        let start = StudyCalendar().dayStart(for: .now).addingTimeInterval(-30 * 86400 - 1800)
        let item = StudyInterval(start: start, end: start.addingTimeInterval(8 * 3600), source: "manual")
        do { let store = try HistoryStore(directory: dir); try store.upsert(item) }
        let model = try AppModel(directoryOverride: dir)
        var edited = model.records[0]; edited.end.addTimeInterval(-1800)
        try await model.saveInterval(edited)
        #expect(model.records.count == 1 && model.canUndo)
        #expect(abs(try model.store.interval(id: item.id)!.duration - 7.5 * 3600) < 0.000001)
        try await model.undoRecord()
        #expect(abs(model.records[0].duration - item.duration) < 0.000001)
        await model.quit()
    }

}
