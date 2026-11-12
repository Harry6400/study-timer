import SwiftUI
import StudyTimerCore

private enum CalendarPage: Equatable { case days, months, years }

struct StudyCalendarView: View {
    @Binding var selection: Date
    var compact: Bool
    var now: Date
    var onChoose: (() -> Void)?
    @State private var month: Date
    @State private var page = CalendarPage.days
    @State private var yearPage: Int
    @State private var focusedDay: Date
    @State private var hoveredDay: Date?
    @State private var focusedChoice = 1
    @FocusState private var keyboardFocus: Bool
    private var calendar: StudyCalendar { StudyCalendar() }
    private var today: Date { calendar.dayStart(for: now) }
    private var year: Int { calendar.calendar.component(.year, from: month) }
    private var monthNumber: Int { calendar.calendar.component(.month, from: month) }
    private var cell: CGFloat { compact ? 28 : 36 }
    private var gap: CGFloat { compact ? 2 : 4 }
    private var contentWidth: CGFloat { cell * 7 + gap * 6 }

    init(selection: Binding<Date>, compact: Bool = false, now: Date = Date(), onChoose: (() -> Void)? = nil) {
        _selection = selection; self.compact = compact; self.now = now; self.onChoose = onChoose
        let calendar = StudyCalendar()
        let selected = min(calendar.dateAtFour(on: selection.wrappedValue), calendar.dayStart(for: now))
        _month = State(initialValue: calendar.monthStart(containing: selected))
        _focusedDay = State(initialValue: selected)
        let year = calendar.calendar.component(.year, from: selected)
        _yearPage = State(initialValue: max(1, year - year % 12))
    }

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            header
            switch page {
            case .days:
                HStack(spacing: gap) {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { name in
                        Text(name).font(.system(size: compact ? 10 : 11, weight: .medium))
                            .foregroundStyle(.tertiary).frame(width: cell)
                    }
                }.accessibilityHidden(true)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: gap), count: 7), spacing: gap) {
                    ForEach(calendar.monthGrid(containing: month), id: \.self) { day in dayButton(day) }
                }
            case .months:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: 3), spacing: compact ? 4 : 8) {
                    ForEach(1...12, id: \.self) { number in
                        choice("\(number)月", value: number, selected: number == monthNumber,
                               disabled: makeMonth(year: year, month: number) > calendar.monthStart(containing: today)) {
                            showMonth(makeMonth(year: year, month: number))
                        }
                    }
                }
            case .years:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: 3), spacing: compact ? 4 : 8) {
                    ForEach(yearPage..<(yearPage + 12), id: \.self) { value in
                        choice("\(value)", value: value, selected: value == year,
                               disabled: value > calendar.calendar.component(.year, from: today)) {
                            showMonth(min(makeMonth(year: value, month: monthNumber), calendar.monthStart(containing: today)))
                        }
                    }
                }
            }
        }
        .frame(width: contentWidth)
        .padding(compact ? 0 : 14)
        .fixedSize(horizontal: true, vertical: true)
        .focusable().focused($keyboardFocus).focusEffectDisabled()
        .onKeyPress(.leftArrow) { moveFocus(-1); return .handled }
        .onKeyPress(.rightArrow) { moveFocus(1); return .handled }
        .onKeyPress(.upArrow) { moveFocus(-7); return .handled }
        .onKeyPress(.downArrow) { moveFocus(7); return .handled }
        .onKeyPress(.return) { confirmFocus(); return .handled }
        .onKeyPress(.space) { confirmFocus(); return .handled }
        .onKeyPress(.escape) {
            if let onChoose { onChoose() } else { page = .days; keyboardFocus = false }
            return .handled
        }
        .onAppear { if !compact { keyboardFocus = true } }
        .onChange(of: page) { _, value in
            focusedChoice = value == .years ? year : monthNumber
        }
        .onChange(of: selection) { _, value in
            focusedDay = min(calendar.dateAtFour(on: value), today)
            month = calendar.monthStart(containing: focusedDay); page = .days
        }
    }

    private var header: some View {
        HStack(spacing: compact ? 2 : 6) {
            Button { movePage(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .frame(width: compact ? 24 : 32, height: compact ? 28 : 34)
            }.help(page == .years ? "前12年" : page == .months ? "前一年" : "前一月")
            Spacer(minLength: 0)
            if page == .years {
                Text(String(yearPage) + "–" + String(yearPage + 11)).font(.system(size: compact ? 12 : 14, weight: .semibold)).monospacedDigit()
            } else {
                Button {
                    yearPage = max(1, year - year % 12); page = .years
                } label: {
                    HStack(spacing: 3) { Text(String(year) + "年"); Image(systemName: "chevron.down").font(.system(size: 8)) }
                }.accessibilityLabel("选择年份")
                Button { page = page == .months ? .days : .months } label: {
                    HStack(spacing: 3) { Text("\(monthNumber)月"); Image(systemName: "chevron.down").font(.system(size: 8)) }
                }.accessibilityLabel("选择月份")
            }
            Spacer(minLength: 0)
            Button { movePage(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .frame(width: compact ? 24 : 32, height: compact ? 28 : 34)
            }.disabled(!canMoveForward)
                .help(page == .years ? "后12年" : page == .months ? "后一年" : "后一月")
        }.font(.system(size: compact ? 12 : 15, weight: .semibold))
            .buttonStyle(.borderless).frame(height: compact ? 28 : 36)
    }

    private func dayButton(_ day: Date) -> some View {
        let selected = calendar.calendar.isDate(day, inSameDayAs: selection)
        let current = calendar.calendar.isDate(day, inSameDayAs: today)
        let inMonth = calendar.calendar.isDate(day, equalTo: month, toGranularity: .month)
        let disabled = day > today
        let focused = keyboardFocus && calendar.calendar.isDate(day, inSameDayAs: focusedDay)
        return Button { choose(day) } label: {
            Text("\(calendar.calendar.component(.day, from: day))")
                .font(.system(size: compact ? 12 : 14, weight: selected || current ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(disabled ? 0.2 : inMonth ? 0.9 : 0.38))
                .frame(width: cell, height: cell)
                .background {
                    RoundedRectangle(cornerRadius: compact ? 6 : 8)
                        .fill(selected ? Color.accentColor : Color.primary.opacity(hoveredDay == day && !disabled ? 0.08 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 6 : 8)
                        .strokeBorder(current || focused ? Color.accentColor.opacity(selected ? 0.65 : 0.85) : .clear,
                                      lineWidth: focused ? 2 : 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).disabled(disabled)
            .onHover { hoveredDay = $0 && !disabled ? day : nil }
            .accessibilityLabel(day.formatted(.dateTime.year().month().day().weekday()))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choice(_ name: String, value: Int, selected: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name).font(.system(size: compact ? 12 : 14, weight: selected ? .semibold : .regular)).monospacedDigit()
                .frame(maxWidth: .infinity).frame(height: compact ? 32 : 44)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(keyboardFocus && focusedChoice == value ? Color.accentColor : .clear, lineWidth: 1))
        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.25 : 1)
    }

    private func makeMonth(year: Int, month: Int) -> Date {
        calendar.calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 4))!
    }
    private var canMoveForward: Bool {
        switch page {
        case .days: return calendar.calendar.date(byAdding: .month, value: 1, to: month)! <= calendar.monthStart(containing: today)
        case .months: return year < calendar.calendar.component(.year, from: today)
        case .years: return yearPage + 12 <= calendar.calendar.component(.year, from: today)
        }
    }
    private func movePage(_ direction: Int) {
        switch page {
        case .days:
            let dayNumber = calendar.calendar.component(.day, from: focusedDay)
            month = calendar.calendar.date(byAdding: .month, value: direction, to: month)!
            let last = calendar.calendar.range(of: .day, in: .month, for: month)!.count
            focusedDay = min(calendar.calendar.date(byAdding: .day, value: min(dayNumber, last) - 1, to: month)!, today)
        case .months:
            month = min(calendar.calendar.date(byAdding: .year, value: direction, to: month)!, calendar.monthStart(containing: today))
            focusedChoice = monthNumber
        case .years:
            let offset = min(11, max(0, focusedChoice - yearPage))
            yearPage = max(1, yearPage + direction * 12)
            focusedChoice = min(yearPage + offset, calendar.calendar.component(.year, from: today))
        }
    }
    private func choose(_ day: Date) {
        guard day <= today else { return }
        selection = calendar.dateAtFour(on: day); focusedDay = selection
        month = calendar.monthStart(containing: selection); page = .days
        keyboardFocus = compact
        onChoose?()
    }
    private func showMonth(_ value: Date) {
        month = value
        focusedDay = calendar.calendar.isDate(selection, equalTo: month, toGranularity: .month) ? selection : month
        page = .days
    }
    private func moveFocus(_ days: Int) {
        switch page {
        case .days:
            focusedDay = min(calendar.calendar.date(byAdding: .day, value: days, to: focusedDay)!, today)
            month = calendar.monthStart(containing: focusedDay)
        case .months:
            let delta = abs(days) == 7 ? (days < 0 ? -3 : 3) : days
            let maxMonth = year == calendar.calendar.component(.year, from: today) ? calendar.calendar.component(.month, from: today) : 12
            focusedChoice = min(maxMonth, max(1, focusedChoice + delta))
        case .years:
            let delta = abs(days) == 7 ? (days < 0 ? -3 : 3) : days
            focusedChoice = min(min(yearPage + 11, calendar.calendar.component(.year, from: today)), max(yearPage, focusedChoice + delta))
        }
    }
    private func confirmFocus() {
        switch page {
        case .days: choose(focusedDay)
        case .months: showMonth(makeMonth(year: year, month: focusedChoice))
        case .years: showMonth(min(makeMonth(year: focusedChoice, month: monthNumber), calendar.monthStart(containing: today)))
        }
    }
}
