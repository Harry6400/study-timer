import SwiftUI
import Charts
import AppKit
import StudyTimerCore

private enum TrendPeriod: Int { case week, month }
private enum WeekWindow: Int { case recent, current }

private struct IntervalDraft: Identifiable {
    let entry: StudyInterval
    var pending: PendingStudyInterval?
    var id: UUID { entry.id }
}

struct StatisticsView: View {
    @ObservedObject var model: AppModel
    @State private var selection = StatisticsSelection(today: StudyCalendar().dayStart(for: Date()))
    @State private var trendPeriod = CommandLine.arguments.contains("--verification-month") ? TrendPeriod.month : TrendPeriod.week
    @State private var weekWindow = WeekWindow.recent
    @State private var hoveredDate: Date?
    @State private var editor: IntervalDraft?
    @State private var selectedRecord: UUID?
    @State private var hoveredRecord: UUID?
    @State private var showsPending = false
    @State private var deleting: StudyInterval?
    @State private var error: String?
    @State private var showsDailyGoal = false
    private let teal = Color(red: 0.18, green: 0.65, blue: 0.57)
    private var studyCalendar: StudyCalendar { model.studyCalendar }
    private var date: Date { selection.date }
    private var detailDate: Date { isTimeline ? date : selection.detailDate }
    private var dateBinding: Binding<Date> {
        Binding(get: { selection.date }, set: { selection.navigate(to: $0) })
    }
    private var layoutBinding: Binding<StatisticsLayout> {
        Binding(get: { model.preferences.statisticsLayout }, set: { layout in
            if layout == .timeline { model.synchronizeTime(); showToday() }
            model.preferences.statisticsLayout = layout
        })
    }
    private var entries: [StudyInterval] {
        var values = model.entries(on: detailDate, live: model.engine.liveInterval)
        if let id = model.activeID, let start = model.engine.state.activeStart,
           studyCalendar.dayStart(for: start) == detailDate, !values.contains(where: { $0.id == id }) {
            values.append(StudyInterval(id: id, start: start, end: start))
        }
        return values
    }
    private var isTimeline: Bool { model.preferences.statisticsLayout == .timeline }

    var body: some View {
        page(now: model.now)
        .frame(minWidth: 780, minHeight: 540)
        .onAppear { showToday() }
        .onChange(of: model.statisticsPresentation) { _, _ in showToday() }
        .onChange(of: model.preferences.statisticsLayout) { _, layout in
            hoveredDate = nil
            hoveredRecord = nil
            if layout == .trend && trendPeriod == .week { showToday() }
        }
        .onChange(of: trendPeriod) { _, period in
            hoveredDate = nil
            hoveredRecord = nil
            if period == .week { showToday() }
            else { selection.navigate(to: date) }
        }
        .onChange(of: weekWindow) { _, _ in
            hoveredDate = nil
            hoveredRecord = nil
            showToday()
        }
        .onChange(of: deleting != nil) { _, presented in model.modalDepth = max(0, model.modalDepth + (presented ? 1 : -1)) }
        .onChange(of: error != nil) { _, presented in model.modalDepth = max(0, model.modalDepth + (presented ? 1 : -1)) }
        .onChange(of: detailDate) { _, _ in
            selectedRecord = nil
            hoveredRecord = nil
        }
        .sheet(item: $editor) { draft in IntervalEditor(interval: draft.entry, model: model, pending: draft.pending) }
        .alert("删除这段学习记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let deleting {
                    Task {
                        do { try await model.deleteInterval(id: deleting.id) }
                        catch { self.error = error.localizedDescription }
                    }
                }
                deleting = nil
            }
        }
        .alert("无法修改记录", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func page(now: Date) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if isTimeline {
                    StudyDateNavigator(date: dateBinding, now: now)
                } else {
                    Picker("统计范围", selection: $trendPeriod) {
                        Text("周").tag(TrendPeriod.week)
                        Text("月").tag(TrendPeriod.month)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 88)
                    if trendPeriod == .month {
                        StudyDateNavigator(date: dateBinding, showsDays: false, now: now)
                    } else {
                        Text(weekRangeTitle(now: now)).font(.headline).monospacedDigit()
                    }
                }
                Spacer(minLength: 8)
                Picker("展示方式", selection: layoutBinding) {
                    Text("时间段").tag(StatisticsLayout.timeline)
                    Text("趋势").tag(StatisticsLayout.trend)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 166)
                HStack(spacing: 10) {
                    Button { runHistory(undo: true) } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("撤销记录更改").accessibilityLabel("撤销记录更改").disabled(!model.canUndo || model.isMutating || model.timerWriteBlocked)
                    Button { runHistory(undo: false) } label: { Image(systemName: "arrow.uturn.forward") }
                        .help("重做记录更改").accessibilityLabel("重做记录更改").disabled(!model.canRedo || model.isMutating || model.timerWriteBlocked)
                    Button { addRecord() } label: { Label("补记", systemImage: "plus") }
                        .disabled(model.isMutating || model.timerWriteBlocked || detailDate > model.studyDay)
                }
            }.buttonStyle(.borderless).padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            if isTimeline { timelineLayout(now: now) } else { trendLayout(now: now) }
            Divider()
            HStack {
                if model.isVerification { Text("隔离验证记录") }
                if !model.pendingIntervals.isEmpty { pendingButton }
                Spacer()
                Text("\(entries.count) 段学习记录")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 9)
        }
        .onChange(of: model.studyDay) { old, today in
            hoveredDate = nil
            selection.dayChanged(from: old, to: today)
        }
    }

    private func trendDays(now: Date) -> [Date] {
        if trendPeriod == .month { return studyCalendar.days(containing: date, period: .month) }
        return weekWindow == .recent ? studyCalendar.recentSevenDays(endingAt: now)
            : studyCalendar.days(containing: now, period: .weekOfYear)
    }
    private func weekRangeTitle(now: Date) -> String {
        let days = trendDays(now: now)
        guard let a = days.first, let b = days.last else { return "" }
        return "\(a.formatted(.dateTime.month().day())) – \(b.formatted(.dateTime.month().day()))"
    }
    private var totalTitle: String {
        trendPeriod == .month ? "\(date.formatted(.dateTime.month()))累计" : weekWindow == .recent ? "近7天累计" : "本周累计"
    }

    private func timelineLayout(now: Date) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Text("当日学习").foregroundStyle(.secondary)
                liveContent(days: [date]) { _, live in
                    Text(TimeInput.format(model.total(on: date, live: live)))
                        .font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.7).lineLimit(1)
                }
                Divider()
                StudyCalendarView(selection: dateBinding, compact: true, now: now)
                Spacer()
            }.padding(16).frame(width: 240).background(.quaternary.opacity(0.25))
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("学习时间轴").font(.title3.weight(.semibold))
                    Spacer()
                    Text(date.formatted(.dateTime.month().day().weekday())).foregroundStyle(.secondary)
                }
                DayStudyRings(date: date, intervals: model.entries(on: date), calendar: studyCalendar,
                              today: model.studyDay, clockReadout: model.statisticsReadout, activeID: model.activeID,
                              liveReadout: model.liveAffects([date]) ? model.statisticsReadout : nil,
                              highlightedID: highlightedRecord, onSelect: editRecord, onVacantTime: addRecord(at:))
                recordTable
            }.padding(.horizontal, 24).padding(.vertical, 18)
        }
    }

    private func trendLayout(now: Date) -> some View {
        let days = trendDays(now: now)
        return GeometryReader { geometry in
            let contentHeight = max(0, geometry.size.height - 48)
            let chartHeight = min(220, max(120, contentHeight * 0.32))
            let detailHeight = max(0, contentHeight - 64 - chartHeight - 37)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(totalTitle).foregroundStyle(.secondary)
                        liveContent(days: days) { _, live in
                            Text(TimeInput.format(model.totals(on: days, live: live).reduce(0) { $0 + $1.seconds }))
                                .font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                    }
                    Spacer()
                    dailyGoalButton
                    if trendPeriod == .week {
                        Picker("周趋势范围", selection: $weekWindow) {
                            Text("近7天").tag(WeekWindow.recent)
                            Text("当周").tag(WeekWindow.current)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 154)
                    }
                }.frame(height: 64)
                liveContent(days: days) { current, live in
                    chart(data: model.totals(on: days, live: live), now: current)
                }.frame(height: chartHeight)
                Divider()
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(detailDate.formatted(.dateTime.month().day())) 的时间轴").font(.headline)
                            liveContent(days: [detailDate]) { _, live in
                                let seconds = model.total(on: detailDate, live: live)
                                if detailDate > model.studyDay {
                                    Text("未到").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("\(TimeInput.format(seconds)) · \(goalStatus(seconds: seconds))")
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                        DayStudyRings(date: detailDate, intervals: model.entries(on: detailDate), calendar: studyCalendar,
                                      today: model.studyDay, clockReadout: model.statisticsReadout, compact: true,
                                      diameter: min(130, max(96, detailHeight - 66)),
                                      activeID: model.activeID,
                                      liveReadout: model.liveAffects([detailDate]) ? model.statisticsReadout : nil,
                                      highlightedID: highlightedRecord, onSelect: editRecord, onVacantTime: addRecord(at:))
                        Spacer(minLength: 0)
                    }.frame(width: 265)
                    recordTable.frame(maxHeight: .infinity)
                }.frame(height: detailHeight, alignment: .top)
            }.padding(24).frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var dailyGoalButton: some View {
        let minutes = model.preferences.dailyGoalMinutes
        let hours = minutes / 60, remainder = minutes % 60
        let duration = hours == 0 ? "\(remainder) 分钟" :
            remainder == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainder) 分"
        return Button { showsDailyGoal.toggle() } label: {
            Label("每日目标 \(duration)", systemImage: "target")
                .monospacedDigit()
        }
        .help("设置每日学习目标")
        .popover(isPresented: $showsDailyGoal, arrowEdge: .bottom) {
            DailyGoalEditor(minutes: minutes) { model.preferences.dailyGoalMinutes = $0 }
        }
    }

    private func chart(data: [DayTotal], now: Date) -> some View {
        let maxHours = max(1, (data.map(\.seconds).max() ?? 0) / 3600)
        let first = studyCalendar.calendar.startOfDay(for: data.first!.date)
        let end = studyCalendar.calendar.date(byAdding: .day, value: 1,
                                             to: studyCalendar.calendar.startOfDay(for: data.last!.date))!
        return Chart(data) { day in
            let future = day.date > model.studyDay
            let reached = model.preferences.hasReachedDailyGoal(seconds: day.seconds)
            BarMark(x: .value("日期", day.date, unit: .day), y: .value("学习小时", day.seconds / 3600), width: .ratio(0.65))
                .foregroundStyle((reached ? Color.red : teal).gradient).cornerRadius(3)
                .opacity(day.date == detailDate ? 1 : 0.72)
                .accessibilityLabel(day.date.formatted(.dateTime.month().day()))
                .accessibilityValue(future ? "未到" : "\(TimeInput.format(day.seconds))，\(goalStatus(seconds: day.seconds))")
        }
        .chartXScale(domain: first...end, range: .plotDimension(padding: 0))
        .chartYScale(domain: 0...(maxHours + max(0.7, maxHours * 0.35)))
        .chartYAxisLabel("小时", position: .leading)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { value in
                AxisValueLabel(centered: true) {
                    if let day = value.as(Date.self) {
                        if data.count > 7 {
                            Text("\(studyCalendar.calendar.component(.day, from: day))").font(.system(size: 9))
                        } else {
                            Text(day, format: .dateTime.day().weekday(.abbreviated)).font(.system(size: 10))
                        }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .frame(width: frame.width, height: frame.height)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                hoveredDate = chartDay(at: point.x, proxy: proxy, data: data)?.date
                                if let hoveredDate, hoveredDate != detailDate { selection.preview(hoveredDate) }
                            case .ended: hoveredDate = nil
                            }
                        }
                        .onTapGesture { point in
                            if let selected = chartDay(at: point.x, proxy: proxy, data: data), selected.date <= studyCalendar.dayStart(for: now) {
                                selection.navigate(to: selected.date)
                                hoveredDate = nil
                                model.preferences.statisticsLayout = .timeline
                            }
                        }
                        .focusable()
                        .onKeyPress(keys: [.leftArrow, .rightArrow]) { key in
                            guard let index = data.firstIndex(where: { $0.date == detailDate }) else { return .ignored }
                            let next = index + (key.key == .rightArrow ? 1 : -1)
                            if data.indices.contains(next) { selection.preview(data[next].date) }
                            return .handled
                        }
                        .onKeyPress(.return) {
                            guard detailDate <= model.studyDay else { return .ignored }
                            selection.navigate(to: detailDate)
                            hoveredDate = nil
                            model.preferences.statisticsLayout = .timeline
                            return .handled
                        }
                        .accessibilityLabel("趋势日期")
                        .accessibilityValue(detailDate.formatted(.dateTime.month().day()))
                        .help(hoverDescription(data: data))
                        .position(x: frame.midX, y: frame.midY)
                    ForEach(chartLabels(data: data, proxy: proxy, frame: frame)) { label in
                        Text(data[label.id].date > model.studyDay ? "–" : data[label.id].hoursLabel)
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.secondary).fixedSize()
                            .position(x: frame.minX + label.x, y: frame.minY + label.y)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            }
        }
    }
    private func chartDay(at x: CGFloat, proxy: ChartProxy, data: [DayTotal]) -> DayTotal? {
        guard let value: Date = proxy.value(atX: x) else { return nil }
        let day = studyCalendar.dateAtFour(on: value)
        return data.first { $0.date == day }
    }
    private func goalStatus(seconds: TimeInterval) -> String {
        if model.preferences.hasReachedDailyGoal(seconds: seconds) { return "已达标" }
        let remaining = Double(model.preferences.dailyGoalMinutes) * 60 - seconds
        return "距目标 \(TimeInput.format(remaining, roundUp: true))"
    }

    private func hoverDescription(data: [DayTotal]) -> String {
        guard let day = data.first(where: { $0.date == hoveredDate }) else { return "" }
        let status = day.date > model.studyDay ? "未到" : "\(TimeInput.format(day.seconds)) · \(goalStatus(seconds: day.seconds))"
        return "\(day.date.formatted(.dateTime.month().day())) · \(status)"
    }

    private var highlightedRecord: UUID? {
        guard let id = hoveredRecord ?? selectedRecord, entries.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private var recordTable: some View {
        StudyRecordList(entries: entries, date: detailDate, calendar: studyCalendar, activeID: model.activeID,
                        readout: model.statisticsReadout, editsDisabled: model.isMutating || model.timerWriteBlocked,
                        selectedID: $selectedRecord, hoveredID: $hoveredRecord,
                        edit: editRecord, delete: { deleting = $0 })
    }

    private var pendingButton: some View {
        Button { showsPending.toggle() } label: {
            Label("待校对 \(model.pendingIntervals.count) 段", systemImage: "clock.badge.exclamationmark")
        }.buttonStyle(.borderless)
            .disabled(model.timerWriteBlocked || model.isMutating)
            .popover(isPresented: $showsPending, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("待校对").font(.headline)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(model.pendingIntervals) { pending in
                                Button { openPending(pending) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(pending.original.start, format: .dateTime.month().day().hour().minute().second())
                                            Text(pending.original.end, format: .dateTime.month().day().hour().minute().second())
                                            Text(TimeInput.format(pending.duration)).foregroundStyle(.secondary).monospacedDigit()
                                        }
                                        Spacer()
                                        Text("校对")
                                    }.padding(5)
                                }.buttonStyle(.borderless)
                            }
                        }
                    }.frame(maxHeight: min(240, CGFloat(model.pendingIntervals.count) * 64))
                }.padding(14).frame(width: 270)
            }
    }

    @ViewBuilder private func liveContent<Content: View>(days: [Date], @ViewBuilder content: @escaping (Date, StudyInterval?) -> Content) -> some View {
        if model.liveAffects(days) { ReadoutContent(readout: model.statisticsReadout, content: content) }
        else { content(model.now, nil) }
    }
    private func runHistory(undo: Bool) {
        Task {
            do { if undo { try await model.undoRecord() } else { try await model.redoRecord() } }
            catch { self.error = error.localizedDescription }
        }
    }
    private func chartLabels(data: [DayTotal], proxy: ChartProxy, frame: CGRect) -> [ChartLabel] {
        let candidates = data.enumerated().map { index, day in
            let midnight = studyCalendar.calendar.startOfDay(for: day.date)
            let next = studyCalendar.calendar.date(byAdding: .day, value: 1, to: midnight)!
            let center = midnight.addingTimeInterval(next.timeIntervalSince(midnight) / 2)
            let width = (day.hoursLabel as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]).width + 3
            return ChartLabel(id: index, x: proxy.position(forX: center) ?? 0,
                              y: (proxy.position(forY: day.seconds / 3600) ?? frame.height) - 10, width: width)
        }
        return ChartLabel.arranged(candidates)
    }
    private func editRecord(_ entry: StudyInterval) {
        guard entry.id != model.activeID, !model.isMutating, !model.timerWriteBlocked else { return }
        editor = IntervalDraft(entry: model.index.record(id: entry.id) ?? entry)
    }

    private func addRecord(at point: Date? = nil) {
        guard !model.isMutating, !model.timerWriteBlocked, detailDate <= model.studyDay else { return }
        guard let draft = studyCalendar.draft(on: detailDate, at: point, occupied: entries, now: model.now) else {
            if point == nil { error = "所选学习日没有可补记的空档。" }
            return
        }
        editor = IntervalDraft(entry: draft)
    }

    private func openPending(_ pending: PendingStudyInterval) {
        let original = pending.original
        let date = min(original.start, model.now)
        let occupied = model.entries(on: date, live: model.engine.liveInterval)
        let hint = studyCalendar.draft(on: date, occupied: occupied, now: model.now,
                                       duration: pending.duration, locked: true)
        let start = hint?.start ?? min(original.start, model.now.addingTimeInterval(-pending.duration))
        let entry = StudyInterval(id: pending.id, start: start, end: start.addingTimeInterval(pending.duration),
                                  source: original.source)
        showsPending = false
        editor = IntervalDraft(entry: entry, pending: pending)
    }
    private func showToday() {
        hoveredDate = nil
        selection.showToday(studyCalendar.dayStart(for: model.now))
    }
}

struct ReadoutContent<Content: View>: View {
    @ObservedObject var readout: LiveReadout
    @ViewBuilder let content: (Date, StudyInterval?) -> Content
    var body: some View { content(readout.now, readout.interval) }
}
