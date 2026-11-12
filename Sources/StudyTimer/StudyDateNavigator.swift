import SwiftUI
import StudyTimerCore

struct StudyDateNavigator: View {
    @Binding var date: Date
    var showsDays = true
    var now = Date()
    @State private var calendarShown = false
    private var calendar: StudyCalendar { StudyCalendar() }

    var body: some View {
        HStack(spacing: 4) {
            jump(.year, -1)
            jump(.month, -1)
            if showsDays { jump(.day, -1) }
            Button { calendarShown.toggle() } label: {
                Text(date, format: showsDays ? .dateTime.year().month().day() : .dateTime.year().month())
                    .font(.headline).monospacedDigit().frame(minWidth: showsDays ? 122 : 90, minHeight: 28)
            }
            .help("选择日期").accessibilityLabel("选择日期")
            .popover(isPresented: $calendarShown, arrowEdge: .bottom) {
                StudyCalendarView(selection: $date, now: now) { calendarShown = false }
            }
            if showsDays { jump(.day, 1) }
            jump(.month, 1)
            jump(.year, 1)
        }.buttonStyle(.borderless).fixedSize()
    }

    private func jump(_ component: Calendar.Component, _ direction: Int) -> some View {
        let name = component == .year ? "年" : component == .month ? "月" : "天"
        let title = "\(direction < 0 ? "前" : "后")一\(name)"
        let target = calendar.movedDay(date, component: component, value: direction, now: now)
        return Button { date = target } label: {
            HStack(spacing: 1) {
                if component == .year && direction > 0 { Text("年").font(.system(size: 11)) }
                Image(systemName: component == .month
                      ? (direction < 0 ? "chevron.left.2" : "chevron.right.2")
                      : (direction < 0 ? "chevron.left" : "chevron.right"))
                    .font(.system(size: component == .month ? 16 : 11, weight: .medium))
                if component == .year && direction < 0 { Text("年").font(.system(size: 11)) }
            }.frame(width: component == .year ? 32 : component == .month ? 28 : 22, height: 28)
        }.disabled(target == date).help(title).accessibilityLabel(title)
    }
}
