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
        didSet { if statisticsVisible { statisticsReadout.update(now: now, interval: engine.liveInterval) } }
    }
    @Published private(set) var records: [StudyInterval] = []
    @Published private(set) var studyDay = StudyCalendar().dayStart(for: Date())
    @Published private(set) var isMutating = false
    @Published private(set) var settlementPending = false
    @Published private(set) var statisticsPresentation = 0
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
    private let time: any TimeSource
    private let calendarOverride: StudyCalendar?
    var now: Date { time.date }
    var studyCalendar: StudyCalendar { calendarOverride ?? StudyCalendar() }
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

    init(directoryOverride: URL? = nil, time: any TimeSource = SystemTimeSource(), calendar: StudyCalendar? = nil) throws {
        self.time = time; calendarOverride = calendar
        let currentCalendar = calendar ?? StudyCalendar()
        studyDay = currentCalendar.dayStart(for: time.date)
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
        engine = TimerEngine(state: try store.timerState(), time: time, calendar: currentCalendar)
        let loaded = try store.intervals()
        index = StatisticsIndex(records: loaded, calendar: currentCalendar)
        records = loaded
        backups = BackupService(directory: directory)
        notifications = directoryOverride == nil ? NotificationService() : nil
        lastBackup = defaults.object(forKey: "lastAutomaticBackup") as? Date
        if let recovered = engine.recoveredAt {
            let formatter = DateFormatter(); formatter.dateFormat = "M月d日 HH:mm:ss"
            message = "上次未正常退出，已恢复到 \(formatter.string(from: recovered)) 并暂停。"
        }
        if let update = engine.initialUpdate {
            settlementPending = engine.settledOnLoad
            if settlementPending { notifications?.cancel() }
            persist(update)
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
        let now = engine.liveInterval?.end ?? self.now
        let calendar = studyCalendar
        return days.contains { $0 <= now && calendar.nextDay($0) > start }
    }
    var todayTotal: TimeInterval { index.total(on: now, live: engine.liveInterval) }
    var pauseElapsed: TimeInterval? { pauseTimer.elapsed }
    var isRunning: Bool { engine.state.status == .running }
    var activeID: UUID? { engine.state.activeID }
    var shortcutEnabled: Bool { modalDepth == 0 && !isMutating && !settlementPending }
    var backupDirectory: URL { directory.appendingPathComponent("自动备份", isDirectory: true) }
    var statusText: String {
        if settlementPending { return "日结算待保存" }
        return switch engine.state.status { case .running: "计时中"; case .paused: "已暂停"; case .completed: "已完成" }
    }
    func start(text: String) throws {
        reconcileDay()
        guard !settlementPending else { throw StudyError.storage("凌晨4点结算尚未保存，请稍后重试") }
        let target = try TimeInput.parse(text)
        pauseTimer.clear(); persist(engine.start(target: target))
        scheduleReminder(); transition()
    }
    func toggle() {
        reconcileDay()
        guard !settlementPending else { return }
        if isRunning {
            let update = engine.pause()
            if engine.state.status == .paused && !update.isDaySettlement { pauseTimer.start() } else { pauseTimer.clear() }
            persist(update)
            if engine.state.status == .completed { notifications?.finished(preferences: preferences) }
            else { notifications?.cancel() }
        } else { pauseTimer.clear(); persist(engine.resume()); scheduleReminder() }
        transition(); queueDailyBackup()
    }
    func resumeAfterUpdate() {
        guard !engine.settledOnLoad && !settlementPending && engine.state.status == .paused else { return }
        pauseTimer.clear()
        let update = engine.resume(allowNewDay: false)
        persist(update)
        if !update.isDaySettlement { scheduleReminder() }
        reconcileDay(); transition(); queueDailyBackup()
    }
    func reset() {
        reconcileDay()
        guard !settlementPending else { return }
        pauseTimer.clear(); persist(engine.reset()); notifications?.cancel(); transition(); queueDailyBackup()
    }
    private func transition() {
        objectWillChange.send(); configureTicker(); publishReadings(); onUpdate?()
    }
    private func scheduleReminder() {
        if let remaining = countdownReminderDelay {
            notifications?.schedule(after: remaining, preferences: preferences)
        } else { notifications?.cancel() }
    }
    var countdownReminderDelay: TimeInterval? {
        guard isRunning, let target = engine.state.target else { return nil }
        let remaining = max(0, target - engine.elapsed)
        return remaining > 0 && remaining < engine.nextStudyDayBoundary.timeIntervalSince(now) ? remaining : nil
    }
    func reminderPreferencesChanged() { scheduleReminder() }
    private func configureTicker() {
        ticker?.invalidate(); ticker = nil
        guard isRunning || pauseTimer.isActive || !pendingWrites.isEmpty else { return }
        let value = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronizeTime() }
        }
        value.tolerance = 0.06; RunLoop.main.add(value, forMode: .common); ticker = value
    }
    private func publishReadings() {
        let now = self.now, live = engine.liveInterval
        controlsReadout.update(now: now, interval: live)
        if statisticsVisible { statisticsReadout.update(now: now, interval: live) }
    }
    func synchronizeTime() {
        reconcileDay()
        if isRunning {
            if let finished = engine.tick() {
                pauseTimer.clear(); persist(finished)
                if finished.isDaySettlement { notifications?.cancel() }
                else { notifications?.finished(preferences: preferences) }
                transition(); queueDailyBackup()
            } else if lastCheckpoint.duration(to: .now) >= .seconds(15) { checkpoint() }
            if lastDaily.duration(to: .now) >= .seconds(1800) { queueDailyBackup() }
        }
        publishReadings(); onUpdate?()
    }
    func checkpoint() {
        reconcileDay()
        guard !settlementPending else { return }
        let wasRunning = isRunning
        let update = engine.checkpoint()
        persist(update)
        if wasRunning && !isRunning {
            pauseTimer.clear()
            if update.isDaySettlement { notifications?.cancel() }
            else { notifications?.finished(preferences: preferences) }
            transition(); queueDailyBackup()
        }
    }
    @discardableResult private func persist(_ update: TimerUpdate? = nil) -> Bool {
        if let update {
            if update.isDaySettlement { settlementPending = true; pauseTimer.clear(); notifications?.cancel() }
            pendingWrites.append(update)
        }
        do {
            while let next = pendingWrites.first {
                try store.save(next)
                if let interval = next.interval, interval.id != activeID {
                    index.replace(id: interval.id, with: interval); records = index.records
                }
                pendingWrites.removeFirst()
            }
            let wasBlocked = settlementPending || storageFailed
            lastCheckpoint = .now; storageFailed = false; settlementPending = false
            if wasBlocked {
                if message?.hasPrefix("凌晨4点结算尚未保存：") == true { message = nil }
                configureTicker(); queueDailyBackup()
            }
            return true
        } catch {
            let detail = settlementPending ? "凌晨4点结算尚未保存：" + error.localizedDescription : error.localizedDescription
            if !storageFailed || message != detail { message = detail }
            storageFailed = true; configureTicker(); return false
        }
    }
    private func scheduleBoundary() {
        boundaryTimer?.invalidate()
        let next = studyCalendar.nextDay(studyCalendar.dayStart(for: now))
        let timer = Timer(timeInterval: max(0.01, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronizeTime(); self?.scheduleBoundary() }
        }
        RunLoop.main.add(timer, forMode: .common); boundaryTimer = timer
    }
    private func reconcileDay() {
        if let update = engine.settleDayIfNeeded(calendar: studyCalendar) {
            settlementPending = true
            pauseTimer.clear(); notifications?.cancel()
            persist(update); transition(); queueDailyBackup()
        } else if !pendingWrites.isEmpty { persist() }
        let day = studyCalendar.dayStart(for: now)
        if studyDay != day { studyDay = day; queueDailyBackup() }
    }
    @objc private func calendarChanged() {
        reconcileDay()
        index = StatisticsIndex(records: records, calendar: studyCalendar); objectWillChange.send()
        scheduleBoundary(); publishReadings(); onUpdate?()
    }
    @objc private func willSleep() { checkpoint() }
    @objc private func didWake() { calendarChanged(); synchronizeTime() }
    func openedStatistics() {
        synchronizeTime(); statisticsPresentation &+= 1
    }
    @discardableResult func quit() async -> Bool {
        reconcileDay()
        guard !settlementPending else { return false }
        pauseTimer.clear(); notifications?.cancel()
        guard persist(engine.pause()) else { return false }
        ticker?.invalidate(); boundaryTimer?.invalidate()
        queueDailyBackup(); await dailyTask?.value
        return true
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
        reconcileDay()
        guard !settlementPending else { throw StudyError.storage("凌晨4点结算尚未保存，请稍后重试") }
        guard !isMutating else { throw StudyError.storage("正在处理上一项操作") }
        guard change.before != change.after else { return }
        guard change.id != activeID else { throw StudyError.storage("请先暂停，再修改当前时段") }
        isMutating = true; defer { isMutating = false }
        if let after = change.after { try HistoryStore.validate(after, against: liveRecords, now: now) }
        guard pendingWrites.isEmpty else { throw StudyError.storage("计时检查点尚未保存，请稍后重试") }
        if preferences.automaticBackups { try await beforeChangeBackup() }
        reconcileDay()
        guard !settlementPending && pendingWrites.isEmpty else { throw StudyError.storage("计时记录尚未保存，请稍后重试") }
        if let after = change.after { try HistoryStore.validate(after, against: liveRecords, now: now) }
        try store.apply(change, now: now)
        index.replace(id: change.id, with: change.after); records = index.records
        if mode == -1 { history.didUndo() } else if mode == 1 { history.didRedo() } else { history.record(change) }
        canUndo = history.undo != nil; canRedo = history.redo != nil
        publishReadings(); onUpdate?(); queueDailyBackup()
    }
    func snapshot() -> Backup {
        reconcileDay()
        let value = engine.snapshot()
        var saved = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for update in pendingWrites { if let interval = update.interval { saved[interval.id] = interval } }
        if let live = value.interval { saved[live.id] = live }
        return Backup(intervals: saved.values.sorted { $0.start < $1.start }, timer: value.state, preferences: preferences, createdAt: now)
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
        reconcileDay()
        guard !settlementPending else { throw StudyError.storage("凌晨4点结算尚未保存，请稍后重试") }
        guard !isMutating else { throw StudyError.storage("正在处理上一项操作") }
        let replacement = try Backup.decode(Data(contentsOf: url), now: now)
        isMutating = true; defer { isMutating = false }
        // 完整恢复无论自动备份开关如何，始终先保留原始数据。
        try await beforeChangeBackup()
        reconcileDay()
        guard !settlementPending else { throw StudyError.storage("凌晨4点结算尚未保存，请稍后重试") }
        try store.restore(replacement, now: now)
        notifications?.cancel(); pauseTimer.clear(); pendingWrites.removeAll()
        engine = TimerEngine(state: try store.timerState(), time: time, calendar: studyCalendar)
        let loaded = try store.intervals(); index = StatisticsIndex(records: loaded, calendar: studyCalendar); records = loaded
        if let update = engine.initialUpdate {
            settlementPending = engine.settledOnLoad
            persist(update)
        }
        history.clear(); canUndo = false; canRedo = false
        preferences = replacement.preferences
        reconcileDay(); transition(); queueDailyBackup()
    }
}
