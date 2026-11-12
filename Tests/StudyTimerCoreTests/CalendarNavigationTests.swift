import Foundation
import Testing
@testable import StudyTimerCore

struct CalendarNavigationTests {
    private let cal = StudyCalendar(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var distantNow: Date { date("2030-12-31T12:00:00+08:00") }

    @Test func calendarSelectionUsesSelectedCivilDateAtFour() {
        let midnight = date("2026-11-12T00:00:00+08:00")
        #expect(cal.dateAtFour(on: midnight) == date("2026-11-12T04:00:00+08:00"))
        #expect(cal.dayStart(for: midnight) == date("2026-11-11T04:00:00+08:00"))
    }

    @Test func monthAndYearNavigationClampInvalidDays() {
        let january = date("2026-01-31T04:00:00+08:00")
        #expect(cal.movedDay(january, component: .month, value: 1, now: distantNow) == date("2026-02-28T04:00:00+08:00"))
        let leap = date("2024-02-29T04:00:00+08:00")
        #expect(cal.movedDay(leap, component: .year, value: 1, now: distantNow) == date("2025-02-28T04:00:00+08:00"))
        #expect(cal.movedDay(january, component: .month, value: -1, now: distantNow) == date("2025-12-31T04:00:00+08:00"))
    }

    @Test func navigationCannotPassCurrentStudyDay() {
        let now = date("2026-11-12T03:30:00+08:00")
        let today = date("2026-11-11T04:00:00+08:00")
        #expect(cal.movedDay(today, component: .day, value: 1, now: now) == today)
        #expect(cal.movedDay(date("2026-10-31T04:00:00+08:00"), component: .month, value: 1, now: now) == today)
        #expect(cal.movedDay(today, component: .year, value: 1, now: now) == today)
    }

    @Test func recentDaysAndCurrentWeekUseFourAMBoundary() {
        let now = date("2026-11-12T03:30:00+08:00")
        let recent = cal.recentSevenDays(endingAt: now)
        #expect(recent.count == 7)
        #expect(recent.first == date("2026-11-05T04:00:00+08:00"))
        #expect(recent.last == date("2026-11-11T04:00:00+08:00"))
        #expect(cal.recentSevenDays(endingAt: date("2026-11-12T04:00:00+08:00")).last == date("2026-11-12T04:00:00+08:00"))
        let week = cal.days(containing: now, period: .weekOfYear)
        #expect(week.first == date("2026-11-09T04:00:00+08:00"))
        #expect(week.last == date("2026-11-15T04:00:00+08:00"))
    }

    @Test func yearBoundaryAndAllMonthLengths() {
        let recent = cal.recentSevenDays(endingAt: date("2026-01-02T12:00:00+08:00"))
        #expect(recent.first == date("2025-12-27T04:00:00+08:00"))
        let week = cal.days(containing: date("2026-01-02T12:00:00+08:00"), period: .weekOfYear)
        #expect(week.first == date("2025-12-29T04:00:00+08:00"))
        #expect(week.last == date("2026-01-04T04:00:00+08:00"))
        for (month, count) in [("2025-02-10", 28), ("2024-02-10", 29), ("2026-04-10", 30), ("2026-01-10", 31)] {
            #expect(cal.days(containing: date(month + "T12:00:00+08:00"), period: .month).count == count)
        }
    }

    @Test func hoursLabelsAndDailyTotalsPreserveExactDuration() {
        let day = date("2026-11-11T04:00:00+08:00")
        for (seconds, text) in [(0.0, "0.0"), (1800.0, "0.5"), (24_300.0, "6.8"), (86_399.0, "24.0")] {
            #expect(DayTotal(date: day, seconds: seconds).hoursLabel == text)
        }
        let record = StudyInterval(start: date("2026-11-11T03:30:00+08:00"), end: date("2026-11-11T04:30:00+08:00"))
        let days = cal.recentSevenDays(endingAt: date("2026-11-11T12:00:00+08:00"))
        let totals = cal.totals(on: days, records: [record])
        #expect(totals.reduce(0) { $0 + $1.seconds } == 3600)
        #expect(totals.suffix(2).allSatisfy { $0.hoursLabel == "0.5" })
    }
}
