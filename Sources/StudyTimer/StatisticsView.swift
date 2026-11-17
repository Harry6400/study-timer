import SwiftUI
import Charts
import AppKit
import StudyTimerCore

private enum TrendPeriod: Int { case week, month }
private enum WeekWindow: Int { case recent, current }

struct StatisticsView: View {
    @ObservedObject var model: AppModel
    @State private var selection = StatisticsSelection(today: StudyCalendar().dayStart(for: Date()))
    @State private var trendPeriod = CommandLine.arguments.contains("--verification-month") ? TrendPeriod.month : TrendPeriod.week
    @State private var weekWindow = WeekWindow.recent
    @State private var hoveredDate: Date?
    @State private var editor: StudyInterval?
    @State private var deleting: StudyInterval?
    @State private var error: String?
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
            if layout == .trend && trendPeriod == .week { showToday() }
        }
        .onChange(of: trendPeriod) { _, period in
            hoveredDate = nil
            if period == .week { showToday() }
            else { selection.navigate(to: date) }
        }
        .onChange(of: weekWindow) { _, _ in
            hoveredDate = nil
            showToday()
        }
        .onChange(of: deleting != nil) { _, presented in model.modalDepth = max(0, model.modalDepth + (presented ? 1 : -1)) }
        .onChange(of: error != nil) { _, presented in model.modalDepth = max(0, model.modalDepth + (presented ? 1 : -1)) }
        .sheet(item: $editor) { entry in IntervalEditor(interval: entry, model: model) }
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
                        .help("撤销记录更改").accessibilityLabel("撤销记录更改").disabled(!model.canUndo || model.isMutating || model.settlementPending)
                    Button { runHistory(undo: false) } label: { Image(systemName: "arrow.uturn.forward") }
                        .help("重做记录更改").accessibilityLabel("重做记录更改").disabled(!model.canRedo || model.isMutating || model.settlementPending)
                    Button { addRecord() } label: { Label("补记", systemImage: "plus") }
                        .disabled(model.isMutating || model.settlementPending || detailDate > model.studyDay)
                }
            }.buttonStyle(.borderless).padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            if isTimeline { timelineLayout(now: now) } else { trendLayout(now: now) }
            Divider()
            HStack {
                if model.isVerification { Text("隔离验证记录") }
                Spacer()
                Text("\(entries.count) 段学习记录")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 10)
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
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("学习时间轴").font(.title3.weight(.semibold))
                    Spacer()
                    Text(date.formatted(.dateTime.month().day().weekday())).foregroundStyle(.secondary)
                }
                DayStudyRings(date: date, intervals: model.entries(on: date), activeID: model.activeID,
                              liveReadout: model.liveAffects([date]) ? model.statisticsReadout : nil, onSelect: editRecord)
                recordTable
            }.padding(26)
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
                        Text("\(detailDate.formatted(.dateTime.month().day())) 的时间轴").font(.headline)
                        DayStudyRings(date: detailDate, intervals: model.entries(on: detailDate), compact: true,
                                      diameter: min(130, max(96, detailHeight - 66)),
                                      activeID: model.activeID,
                                      liveReadout: model.liveAffects([detailDate]) ? model.statisticsReadout : nil,
                                      onSelect: editRecord)
                        liveContent(days: [detailDate]) { _, live in
                            Text("\(entries.count) 段 · \(TimeInput.format(model.total(on: detailDate, live: live)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.frame(width: 265)
                    recordTable.frame(maxHeight: .infinity)
                }.frame(height: detailHeight, alignment: .top)
            }.padding(24).frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func chart(data: [DayTotal], now: Date) -> some View {
        let maxHours = max(1, (data.map(\.seconds).max() ?? 0) / 3600)
        let first = studyCalendar.calendar.startOfDay(for: data.first!.date)
        let end = studyCalendar.calendar.date(byAdding: .day, value: 1,
                                             to: studyCalendar.calendar.startOfDay(for: data.last!.date))!
        return Chart(data) { day in
            BarMark(x: .value("日期", day.date, unit: .day), y: .value("学习小时", day.seconds / 3600), width: .ratio(0.65))
                .foregroundStyle(teal.gradient).cornerRadius(3)
                .opacity(day.date == detailDate ? 1 : 0.72)
                .accessibilityLabel(day.date.formatted(.dateTime.month().day()))
                .accessibilityValue(TimeInput.format(day.seconds))
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
                                if let hoveredDate { selection.preview(hoveredDate) }
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
                        .help(hoverDescription(data: data))
                        .position(x: frame.midX, y: frame.midY)
                    ForEach(chartLabels(data: data, proxy: proxy, frame: frame)) { label in
                        Text(data[label.id].hoursLabel).font(.system(size: 11, weight: .medium)).monospacedDigit()
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
    private func hoverDescription(data: [DayTotal]) -> String {
        guard let day = data.first(where: { $0.date == hoveredDate }) else { return "" }
        return "\(day.date.formatted(.dateTime.month().day())) · \(TimeInput.format(day.seconds))"
    }
    @ViewBuilder private var recordTable: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label("这一天还没有学习记录", systemImage: "clock")
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                // 原生表格还会为单元格边距、inset 和纵向滚动条预留空间。
                let columnWidth = max(76, floor((geometry.size.width - 58 - 128) / 3))
                Table(entries) {
                TableColumn("开始") { entry in Text(entry.start, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(columnWidth)
                TableColumn("结束") { entry in
                    if entry.id == model.activeID { Text("计时中").foregroundStyle(teal) }
                    else { Text(entry.end, format: .dateTime.hour().minute().second()).monospacedDigit() }
                }.width(columnWidth)
                TableColumn("时长") { entry in
                    if entry.id == model.activeID {
                        ReadoutContent(readout: model.statisticsReadout) { _, live in
                            Text(TimeInput.format(live.flatMap { studyCalendar.intervals(on: detailDate, from: [$0]).first }?.duration ?? entry.duration)).monospacedDigit()
                        }
                    } else { Text(TimeInput.format(entry.duration)).monospacedDigit() }
                }.width(columnWidth)
                TableColumn("") { entry in
                    HStack(spacing: 12) {
                        Button {
                            editRecord(entry)
                        } label: { Image(systemName: "pencil") }.help("修改记录").accessibilityLabel("修改记录")
                        Button { deleting = entry } label: { Image(systemName: "trash") }.help("删除记录").accessibilityLabel("删除记录")
                    }.buttonStyle(.borderless).disabled(entry.id == model.activeID || model.isMutating || model.settlementPending)
                }.width(58)
            }.tableStyle(.inset(alternatesRowBackgrounds: true))
                    .id(columnWidth)
            }
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
        guard entry.id != model.activeID else { return }
        editor = model.records.first { $0.id == entry.id } ?? entry
    }
    private func addRecord() {
        guard detailDate <= model.studyDay else { return }
        let end = min(model.now, studyCalendar.nextDay(studyCalendar.dayStart(for: detailDate)))
        editor = StudyInterval(start: end.addingTimeInterval(-1800), end: end, source: "manual")
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
