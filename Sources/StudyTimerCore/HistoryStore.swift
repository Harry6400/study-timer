import Foundation
import SQLite3

public struct Backup: Codable, Sendable {
    public var version = 1
    public var createdAt: Date
    public var intervals: [StudyInterval]
    public var timer: TimerState
    public var preferences: Preferences
    public init(intervals: [StudyInterval], timer: TimerState, preferences: Preferences, createdAt: Date = Date()) {
        self.intervals = intervals; self.timer = timer; self.preferences = preferences; self.createdAt = createdAt
    }

    public func validated(now: Date = Date()) throws -> Backup {
        guard version == 1, createdAt.timeIntervalSince1970.isFinite,
              timer.elapsed.isFinite, timer.elapsed >= 0, timer.checkpointElapsed.isFinite,
              timer.checkpointElapsed >= 0,
              timer.target.map({ $0.isFinite && $0 > 0 && $0 <= 31_536_000 && timer.elapsed <= $0 && timer.checkpointElapsed <= $0 }) ?? true,
              preferences.glassOpacity.isFinite, (0...1).contains(preferences.glassOpacity),
              (100...800).contains(preferences.windowWidth), (38...400).contains(preferences.windowHeight),
              preferences.windowX.map(\.isFinite) ?? true, preferences.windowY.map(\.isFinite) ?? true,
              Set(intervals.map(\.id)).count == intervals.count else { throw StudyError.invalidBackup }
        let sorted = intervals.sorted { $0.start < $1.start }
        for (index, interval) in sorted.enumerated() {
            guard interval.start.timeIntervalSince1970.isFinite, interval.end.timeIntervalSince1970.isFinite,
                  interval.end > interval.start, interval.end <= now.addingTimeInterval(1),
                  ["timer", "manual"].contains(interval.source) else { throw StudyError.invalidBackup }
            if index > 0 && sorted[index - 1].end > interval.start { throw StudyError.invalidBackup }
        }
        if timer.status == .running {
            guard timer.activeStart != nil, timer.activeID != nil, timer.checkpoint != nil,
                  timer.checkpointElapsed >= timer.elapsed else { throw StudyError.invalidBackup }
        } else if timer.activeStart != nil || timer.activeID != nil { throw StudyError.invalidBackup }
        if let checkpoint = timer.checkpoint {
            guard checkpoint.timeIntervalSince1970.isFinite, checkpoint <= now.addingTimeInterval(1) else { throw StudyError.invalidBackup }
        }
        if let day = timer.studyDayStart {
            guard day.timeIntervalSince1970.isFinite else { throw StudyError.invalidBackup }
        }
        if let start = timer.activeStart {
            guard start.timeIntervalSince1970.isFinite, let checkpoint = timer.checkpoint, start <= checkpoint else { throw StudyError.invalidBackup }
        }
        if timer.status == .completed {
            guard let target = timer.target, timer.elapsed == target else { throw StudyError.invalidBackup }
        }
        return self
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }
    public static func decode(_ data: Data, now: Date = Date()) throws -> Backup {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        do { return try decoder.decode(Backup.self, from: data).validated(now: now) }
        catch { throw StudyError.invalidBackup }
    }
}

public final class HistoryStore {
    private var db: OpaquePointer?
    public private(set) var fullReadCount = 0
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open_v2(directory.appendingPathComponent("history.sqlite3").path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StudyError.storage("无法打开数据库")
        }
        sqlite3_busy_timeout(db, 3000)
        let version = try statement("PRAGMA user_version")
        let result = sqlite3_step(version)
        let schema = sqlite3_column_int(version, 0)
        sqlite3_finalize(version)
        guard result == SQLITE_ROW, schema <= 1 else { throw StudyError.storage("数据库版本较新，请使用更新版本的应用") }
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS intervals (id TEXT PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL, source TEXT NOT NULL); CREATE INDEX IF NOT EXISTS intervals_start ON intervals(start); CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL); PRAGMA user_version=1;")
    }
    deinit { sqlite3_close(db) }

    private func error() -> StudyError { .storage(String(cString: sqlite3_errmsg(db))) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw error() }
        return value
    }
    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }
    private func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try operation(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func write(_ interval: StudyInterval) throws {
        let s = try statement("INSERT INTO intervals(id,start,end,source) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET start=excluded.start,end=excluded.end,source=excluded.source")
        defer { sqlite3_finalize(s) }
        bind(interval.id.uuidString, at: 1, to: s)
        sqlite3_bind_double(s, 2, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(s, 3, interval.end.timeIntervalSince1970)
        bind(interval.source, at: 4, to: s)
        guard sqlite3_step(s) == SQLITE_DONE else { throw error() }
    }
    private func write(_ state: TimerState) throws {
        let text = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        let s = try statement("INSERT INTO metadata(key,value) VALUES('timer',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        defer { sqlite3_finalize(s) }; bind(text, at: 1, to: s)
        guard sqlite3_step(s) == SQLITE_DONE else { throw error() }
    }
    public func save(_ update: TimerUpdate) throws {
        try transaction {
            if let interval = update.interval, interval.duration > 0 { try write(interval) }
            try write(update.state)
        }
    }
    public func timerState() throws -> TimerState {
        let s = try statement("SELECT value FROM metadata WHERE key='timer'")
        defer { sqlite3_finalize(s) }
        let status = sqlite3_step(s)
        if status == SQLITE_DONE { return TimerState() }
        guard status == SQLITE_ROW, let data = sqlite3_column_text(s, 0) else { throw error() }
        return try JSONDecoder().decode(TimerState.self, from: Data(String(cString: data).utf8))
    }
    public func intervals() throws -> [StudyInterval] {
        fullReadCount += 1
        let s = try statement("SELECT id,start,end,source FROM intervals ORDER BY start")
        defer { sqlite3_finalize(s) }; var result: [StudyInterval] = []
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let idText = sqlite3_column_text(s, 0),
                  let id = UUID(uuidString: String(cString: idText)), let source = sqlite3_column_text(s, 3) else { throw error() }
            result.append(StudyInterval(id: id, start: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                                        end: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)), source: String(cString: source)))
        }
    }
    public static func validate(_ interval: StudyInterval, against records: [StudyInterval], now: Date = Date()) throws {
        guard interval.end > interval.start, interval.start.timeIntervalSince1970.isFinite,
              interval.end.timeIntervalSince1970.isFinite else { throw StudyError.invalidInterval }
        guard interval.end <= now else { throw StudyError.futureInterval }
        guard !records.contains(where: { $0.id != interval.id && $0.start < interval.end && interval.start < $0.end }) else {
            throw StudyError.overlapping
        }
    }
    public func upsert(_ interval: StudyInterval, now: Date = Date()) throws {
        try transaction {
            try validateInDatabase(interval, now: now)
            try write(interval)
        }
    }
    private func validateInDatabase(_ interval: StudyInterval, now: Date) throws {
        try Self.validate(interval, against: [], now: now)
        let s = try statement("SELECT 1 FROM intervals WHERE id<>? AND start<? AND end>? LIMIT 1")
        defer { sqlite3_finalize(s) }
        bind(interval.id.uuidString, at: 1, to: s)
        sqlite3_bind_double(s, 2, interval.end.timeIntervalSince1970)
        sqlite3_bind_double(s, 3, interval.start.timeIntervalSince1970)
        let status = sqlite3_step(s)
        if status == SQLITE_ROW { throw StudyError.overlapping }
        guard status == SQLITE_DONE else { throw error() }
    }
    public func interval(id: UUID) throws -> StudyInterval? {
        let s = try statement("SELECT start,end,source FROM intervals WHERE id=?")
        defer { sqlite3_finalize(s) }; bind(id.uuidString, at: 1, to: s)
        let status = sqlite3_step(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let source = sqlite3_column_text(s, 2) else { throw error() }
        return StudyInterval(id: id, start: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)),
                             end: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)), source: String(cString: source))
    }
    public func apply(_ change: RecordChange, now: Date = Date()) throws {
        guard change.before != nil || change.after != nil,
              change.before == nil || change.after == nil || change.before?.id == change.after?.id else {
            throw StudyError.invalidInterval
        }
        try transaction {
            let current = try interval(id: change.id)
            let matches: Bool
            if let current, let before = change.before {
                matches = current.id == before.id && current.source == before.source &&
                    abs(current.start.timeIntervalSince(before.start)) < 0.000001 &&
                    abs(current.end.timeIntervalSince(before.end)) < 0.000001
            } else { matches = current == nil && change.before == nil }
            guard matches else { throw StudyError.storage("记录已经变化，请重新打开后再试") }
            if let after = change.after { try validateInDatabase(after, now: now); try write(after) }
            else { try delete(id: change.id) }
        }
    }
    public func delete(id: UUID) throws {
        let s = try statement("DELETE FROM intervals WHERE id=?")
        defer { sqlite3_finalize(s) }; bind(id.uuidString, at: 1, to: s)
        guard sqlite3_step(s) == SQLITE_DONE else { throw error() }
    }
    public func restore(_ backup: Backup, now: Date = Date()) throws {
        let backup = try backup.validated(now: now)
        var state = backup.timer
        if state.status == .running { state.elapsed = state.checkpointElapsed; state.status = .paused }
        if state.target.map({ state.elapsed >= $0 }) == true { state.status = .completed }
        state.activeStart = nil; state.activeID = nil
        try transaction {
            try execute("DELETE FROM intervals")
            for interval in backup.intervals { try write(interval) }
            try write(state)
        }
    }
}
