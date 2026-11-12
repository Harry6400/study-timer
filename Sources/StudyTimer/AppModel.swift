import AppKit
import Combine
import StudyTimerCore
import Darwin

private final class InstanceLock {
    private let descriptor: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = Darwin.open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StudyError.storage("无法创建应用实例锁") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw StudyError.storage("这个数据目录已在另一个学习计时器中使用，请先退出已有实例")
        }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

@MainActor final class LiveReadout: ObservableObject {
    @Published private(set) var now = Date()
    private(set) var interval: StudyInterval?
    func update(now: Date, interval: StudyInterval?) {
        self.interval = interval
        self.now = now
    }
}

@MainActor final class AppModel: ObservableObject {
    let directory: URL
    let store: HistoryStore
    private(set) var engine: TimerEngine
    private(set) var index: StatisticsIndex
    let statisticsReadout = LiveReadout()
    let controlsReadout = LiveReadout()
    var statisticsVisible = false {
        didSet { if statisticsVisible { statisticsReadout.update(now: Date(), interval: engine.liveInterval) } }
    }
    @Published private(set) var records: [StudyInterval] = []
    @Published private(set) var studyDay = StudyCalendar().dayStart(for: Date())
    @Published private(set) var isMutating = false
    @Published var modalDepth = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var lastBackup: Date?
    @Published private(set) var backupError: String?
    @Published var message: String?
    @Published var preferences: Preferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "preferences") }
            if oldValue.showTodayTotalOnFloatingWindow != preferences.showTodayTotalOnFloatingWindow { configureTicker() }
            if !oldValue.automaticBackups && preferences.automaticBackups { queueDailyBackup() }
            onUpdate?()
        }
    }
    let isVerification = CommandLine.arguments.contains("--data-directory") || Bundle.main.object(forInfoDictionaryKey: "StudyTimerVerificationDirectory") != nil
    var onUpdate: (() -> Void)?
    private let defaults: UserDefaults
    private let instanceLock: InstanceLock
    private let backups: BackupService
    private let notifications: NotificationService?
    private let pauseTimer = TransientPauseTimer()
    private var history = RecordHistory()
    private var ticker: Timer?
    private var boundaryTimer: Timer?
    private var lastCheckpoint = ContinuousClock.now
    private var lastDaily = ContinuousClock.now
    private var storageFailed = false
    private var pendingWrites: [TimerUpdate] = []
    private var dailyRequested = false
    private var dailyTask: Task<Void, Never>?

    init(directoryOverride: URL? = nil) throws {
        let fallback = Bundle.main.object(forInfoDictionaryKey: "StudyTimerVerificationDirectory") as? String
        let args = CommandLine.arguments + (fallback.map { ["--data-directory", $0] } ?? [])
        if let directoryOverride {
            directory = directoryOverride
            defaults = UserDefaults(suiteName: "local.harry64.studytimer.verify." + directory.lastPathComponent)!
        } else if let position = args.firstIndex(of: "--data-directory"), args.indices.contains(position + 1) {
            directory = URL(fileURLWithPath: args[position + 1], isDirectory: true)
            defaults = UserDefaults(suiteName: "local.harry64.studytimer.verify." + directory.lastPathComponent)!
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StudyTimer", isDirectory: true)
            defaults = .standard
        }
        preferences = defaults.data(forKey: "preferences").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        instanceLock = try InstanceLock(directory: directory)
        store = try HistoryStore(directory: directory)
        engine = TimerEngine(state: try store.timerState())
        let loaded = try store.intervals()
        index = StatisticsIndex(records: loaded)
        records = loaded
        backups = BackupService(directory: directory)
        notifications = directoryOverride == nil ? NotificationService() : nil
        lastBackup = defaults.object(forKey: "lastAutomaticBackup") as? Date
        if let recovered = engine.recoveredAt {
            let formatter = DateFormatter(); formatter.dateFormat = "M月d日 HH:mm:ss"
            message = "上次未正常退出，已恢复到 \(formatter.string(from: recovered)) 并暂停。"
            try store.save(TimerUpdate(state: engine.state, interval: nil))
        }
        configureTicker(); scheduleBoundary(); publishReadings(); queueDailyBackup()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(calendarChanged), name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(calendarChanged), name: NSNotification.Name.NSSystemClockDidChange, object: nil)
    }
    var liveRecords: [StudyInterval] {
        guard let live = engine.liveInterval else { return records }
        return records + [live]
    }
    func entries(on date: Date, live: StudyInterval? = nil) -> [StudyInterval] { index.intervals(on: date, live: live) }
    func total(on date: Date, live: StudyInterval? = nil) -> TimeInterval { index.total(on: date, live: live) }
    func totals(on days: [Date], live: StudyInterval? = nil) -> [DayTotal] { index.totals(on: days, live: live) }
    func liveAffects(_ days: [Date]) -> Bool {
        guard let start = engine.state.activeStart else { return false }
        let now = engine.liveInterval?.end ?? Date()
        let calendar = StudyCalendar()
        return days.contains { $0 <= now && calendar.nextDay($0) > start }
    }
    var todayTotal: TimeInterval { index.total(on: Date(), live: engine.liveInterval) }
    var pauseElapsed: TimeInterval? { pauseTimer.elapsed }
    var isRunning: Bool { engine.state.status == .running }
    var activeID: UUID? { engine.state.activeID }
    var shortcutEnabled: Bool { modalDepth == 0 && !isMutating }
    var backupDirectory: URL { directory.appendingPathComponent("自动备份", isDirectory: true) }
    var statusText: String {
        switch engine.state.status { case .running: "计时中"; case .paused: "已暂停"; case .completed: "已完成" }
    }
    func start(text: String) throws {
        let target = try TimeInput.parse(text)
        pauseTimer.clear(); persist(engine.start(target: target))
        scheduleReminder(); transition()
    }
    func toggle() {
        if isRunning {
            let update = engine.pause()
            if engine.state.status == .paused { pauseTimer.start() } else { pauseTimer.clear() }
            persist(update)
            if engine.state.status == .completed { notifications?.finished(preferences: preferences) }
            else { notifications?.cancel() }
        } else { pauseTimer.clear(); persist(engine.resume()); scheduleReminder() }
        transition(); queueDailyBackup()
    }
    func reset() {
        pauseTimer.clear(); persist(engine.reset()); notifications?.cancel(); transition(); queueDailyBackup()
    }
    private func transition() {
        objectWillChange.send(); configureTicker(); publishReadings(); onUpdate?()
    }
    private func scheduleReminder() {
        if isRunning, let target = engine.state.target {
            notifications?.schedule(after: max(0, target - engine.elapsed), preferences: preferences)
        } else { notifications?.cancel() }
    }
    func reminderPreferencesChanged() { scheduleReminder() }
    private func configureTicker() {
        ticker?.invalidate(); ticker = nil
        guard isRunning || pauseTimer.isActive else { return }
        let value = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        value.tolerance = 0.06; RunLoop.main.add(value, forMode: .common); ticker = value
    }
    private func publishReadings() {
        let now = Date(), live = engine.liveInterval
        controlsReadout.update(now: now, interval: live)
        if statisticsVisible { statisticsReadout.update(now: now, interval: live) }
    }
    private func tick() {
        if isRunning {
            if let finished = engine.tick() {
                pauseTimer.clear(); persist(finished); notifications?.finished(preferences: preferences)
                transition(); queueDailyBackup()
            } else if lastCheckpoint.duration(to: .now) >= .seconds(15) { checkpoint() }
            if lastDaily.duration(to: .now) >= .seconds(1800) { queueDailyBackup() }
        }
        refreshDay(); publishReadings(); onUpdate?()
    }
    func checkpoint() {
        let wasRunning = isRunning
        persist(engine.checkpoint())
        if wasRunning && !isRunning {
            pauseTimer.clear(); notifications?.finished(preferences: preferences); transition(); queueDailyBackup()
        }
    }
    @discardableResult private func persist(_ update: TimerUpdate) -> Bool {
        pendingWrites.append(update)
        do {
            while let next = pendingWrites.first {
                try store.save(next)
                if let interval = next.interval, interval.id != activeID {
                    index.replace(id: interval.id, with: interval); records = index.records
                }
                pendingWrites.removeFirst()
            }
            lastCheckpoint = .now; storageFailed = false; return true
        } catch {
            if !storageFailed { message = error.localizedDescription }
            storageFailed = true; return false
        }
    }
    private func scheduleBoundary() {
        boundaryTimer?.invalidate()
        let next = StudyCalendar().nextDay(StudyCalendar().dayStart(for: Date()))
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDay(); self?.publishReadings(); self?.onUpdate?(); self?.scheduleBoundary() }
        }
        RunLoop.main.add(timer, forMode: .common); boundaryTimer = timer
    }
    private func refreshDay() {
        let day = StudyCalendar().dayStart(for: Date())
        if studyDay != day { studyDay = day; queueDailyBackup() }
    }
    @objc private func calendarChanged() {
        index = StatisticsIndex(records: records); objectWillChange.send()
        refreshDay(); scheduleBoundary(); publishReadings(); onUpdate?()
    }
    @objc private func willSleep() { checkpoint() }
    @objc private func didWake() { calendarChanged(); tick() }
    func quit() async {
        pauseTimer.clear(); persist(engine.pause()); notifications?.cancel(); ticker?.invalidate(); boundaryTimer?.invalidate()
        queueDailyBackup(); await dailyTask?.value
    }

    func saveInterval(_ interval: StudyInterval) async throws {
        try await perform(RecordChange(before: index.record(id: interval.id), after: interval), mode: 0)
    }
    func deleteInterval(id: UUID) async throws {
        guard let old = index.record(id: id) else { return }
        try await perform(RecordChange(before: old, after: nil), mode: 0)
    }
    func undoRecord() async throws { if let change = history.undo { try await perform(change.reversed, mode: -1) } }
    func redoRecord() async throws { if let change = history.redo { try await perform(change, mode: 1) } }
    private func perform(_ change: RecordChange, mode: Int) async throws {
        guard !isMutating else { throw StudyError.storage("正在处理上一项操作") }
        guard change.before != change.after else { return }
        guard change.id != activeID else { throw StudyError.storage("请先暂停，再修改当前时段") }
        isMutating = true; defer { isMutating = false }
        if let after = change.after { try HistoryStore.validate(after, against: liveRecords) }
        guard pendingWrites.isEmpty else { throw StudyError.storage("计时检查点尚未保存，请稍后重试") }
        if preferences.automaticBackups { try await beforeChangeBackup() }
        if let after = change.after { try HistoryStore.validate(after, against: liveRecords) }
        try store.apply(change)
        index.replace(id: change.id, with: change.after); records = index.records
        if mode == -1 { history.didUndo() } else if mode == 1 { history.didRedo() } else { history.record(change) }
        canUndo = history.undo != nil; canRedo = history.redo != nil
        publishReadings(); onUpdate?(); queueDailyBackup()
    }
    func snapshot() -> Backup {
        let value = engine.snapshot()
        var saved = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for update in pendingWrites { if let interval = update.interval { saved[interval.id] = interval } }
        if let live = value.interval { saved[live.id] = live }
        return Backup(intervals: saved.values.sorted { $0.start < $1.start }, timer: value.state, preferences: preferences)
    }
    private func backupSucceeded(_ date: Date) {
        lastBackup = date; backupError = nil; defaults.set(date, forKey: "lastAutomaticBackup")
        if message?.hasPrefix("自动备份失败：") == true { message = nil }
    }
    private func beforeChangeBackup() async throws {
        do { backupSucceeded(try await backups.beforeChange(snapshot())) }
        catch { backupError = error.localizedDescription; throw StudyError.storage("操作前备份失败，记录未更改。\(error.localizedDescription)") }
    }
    private func queueDailyBackup() {
        guard preferences.automaticBackups else { return }
        dailyRequested = true; lastDaily = .now
        guard dailyTask == nil else { return }
        dailyTask = Task { [weak self] in
            guard let self else { return }
            while self.dailyRequested {
                self.dailyRequested = false
                guard self.preferences.automaticBackups else { break }
                let backup = self.snapshot()
                do { self.backupSucceeded(try await self.backups.daily(backup)) }
                catch {
                    let detail = error.localizedDescription
                    if self.backupError != detail { self.message = "自动备份失败：" + detail }
                    self.backupError = detail
                }
            }
            self.dailyTask = nil
        }
    }
    func exportBackup(to url: URL) async throws { try await backups.export(snapshot(), to: url) }
    func exportCSV(to url: URL) throws { try Data(StudyCalendar().csv(liveRecords).utf8).write(to: url, options: .atomic) }
    func restore(from url: URL) async throws {
        guard !isMutating else { throw StudyError.storage("正在处理上一项操作") }
        let replacement = try Backup.decode(Data(contentsOf: url))
        isMutating = true; defer { isMutating = false }
        // 完整恢复无论自动备份开关如何，始终先保留原始数据。
        try await beforeChangeBackup()
        try store.restore(replacement)
        notifications?.cancel(); pauseTimer.clear(); pendingWrites.removeAll()
        engine = TimerEngine(state: try store.timerState())
        let loaded = try store.intervals(); index = StatisticsIndex(records: loaded); records = loaded
        history.clear(); canUndo = false; canRedo = false
        preferences = replacement.preferences
        refreshDay(); transition(); queueDailyBackup()
    }
}
