import Foundation

public actor BackupService {
    public let directory: URL
    public init(directory: URL) { self.directory = directory.appendingPathComponent("自动备份", isDirectory: true) }
    @discardableResult public func daily(_ backup: Backup, calendar: StudyCalendar = StudyCalendar()) throws -> Date {
        let formatter = DateFormatter(); formatter.calendar = calendar.calendar
        formatter.timeZone = calendar.calendar.timeZone; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "daily-" + formatter.string(from: calendar.dayStart(for: backup.createdAt)) + ".json"
        let folder = directory.appendingPathComponent("每日", isDirectory: true)
        try write(backup, to: folder.appendingPathComponent(name))
        try prune(folder, prefix: "daily-", keep: 7)
        return backup.createdAt
    }
    @discardableResult public func beforeChange(_ backup: Backup) throws -> Date {
        let name = "before-\(String(format: "%016.0f", backup.createdAt.timeIntervalSince1970 * 1000))-\(UUID().uuidString).json"
        let folder = directory.appendingPathComponent("操作前", isDirectory: true)
        try write(backup, to: folder.appendingPathComponent(name))
        try prune(folder, prefix: "before-", keep: 10)
        return backup.createdAt
    }
    public func export(_ backup: Backup, to url: URL) throws { try write(backup, to: url) }
    private func write(_ backup: Backup, to url: URL) throws {
        let data = try backup.encoded()
        _ = try Backup.decode(data, now: max(Date(), backup.createdAt))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        _ = try Backup.decode(Data(contentsOf: url), now: max(Date(), backup.createdAt))
    }
    private func prune(_ folder: URL, prefix: String, keep: Int) throws {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in files.dropFirst(keep) { try FileManager.default.removeItem(at: file) }
    }
}
