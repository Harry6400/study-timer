import Foundation
import CoreGraphics
import Testing
@testable import StudyTimerCore

private final class BadgeTime: TimeSource {
    var date = Date(timeIntervalSince1970: 1_790_000_000)
    var continuousSeconds: Double = 0
    func advance(_ seconds: Double) { date.addTimeInterval(seconds); continuousSeconds += seconds }
}

struct BadgeCalendarTests {
    private let cal = StudyCalendar(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func transientClockResetsAndUsesContinuousTime() {
        let time = BadgeTime(), clock = TransientPauseTimer(time: BadgeTime())
        #expect(clock.elapsed == nil)
        let pause = TransientPauseTimer(time: time)
        pause.start(); #expect(pause.elapsed == 0)
        time.advance(2.5); time.date.addTimeInterval(-20_000)
        #expect(pause.elapsed == 2.5)
        time.advance(3600); #expect(pause.elapsed == 3602.5)
        pause.clear(); #expect(!pause.isActive && pause.elapsed == nil)
        pause.start(); #expect(pause.elapsed == 0)
        time.advance(4); #expect(pause.elapsed == 4)
        #expect(TransientPauseTimer(time: time).elapsed == nil)
    }

    @Test func pauseDurationDoesNotBecomeStudyTimeOrBackupState() throws {
        let time = BadgeTime(), engine = TimerEngine(time: BadgeTime())
        #expect(engine.state.status == .paused)
        let timer = TimerEngine(time: time), pause = TransientPauseTimer(time: time)
        timer.start(target: nil); time.advance(12)
        let record = timer.pause().interval!
        pause.start(); time.advance(100)
        #expect(timer.elapsed == 12 && pause.elapsed == 100)
        #expect(timer.liveInterval == nil && record.duration == 12)
        let backup = Backup(intervals: [record], timer: timer.state, preferences: Preferences())
        let restored = try Backup.decode(backup.encoded(), now: time.date)
        #expect(restored.intervals.count == 1 && restored.intervals[0].duration == 12)
        #expect(restored.timer.elapsed == 12)
        timer.resume(); pause.clear(); time.advance(5)
        #expect(timer.pause().interval?.duration == 5 && pause.elapsed == nil)
    }

    @Test func todayBadgePreferenceDefaultsAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(!legacy.showTodayTotalOnFloatingWindow)
        var prefs = legacy; prefs.showTodayTotalOnFloatingWindow = true
        let backup = Backup(intervals: [], timer: TimerState(), preferences: prefs)
        #expect(try Backup.decode(backup.encoded()).preferences.showTodayTotalOnFloatingWindow)
    }

    @Test func floatingGroupHasReadableSingleAndPairedBadges() {
        let body = CGRect(x: 20, y: 12, width: 150, height: 58)
        #expect(FloatingBadgeLayout.frames(above: body, count: 0).isEmpty)
        let single = FloatingBadgeLayout.frames(above: body, count: 1)
        #expect(single[0].midX == body.midX && single[0].minY == body.maxY - 1)
        let pair = FloatingBadgeLayout.frames(above: body, count: 2)
        #expect(pair[0].maxX < pair[1].minX)
        #expect((pair[0].midX + pair[1].midX) / 2 == body.midX)
        #expect(pair[0].width >= 84)
    }

    @Test func screenConstraintsIncludeBadgesAtAllEdges() {
        let space = CGRect(x: 0, y: 0, width: 1440, height: 850)
        for origin in [CGPoint(x: 0, y: 0), CGPoint(x: 1400, y: 810), CGPoint(x: 0, y: 820)] {
            let body = CGRect(origin: origin, size: CGSize(width: 100, height: 38))
            let clamped = FloatingBadgeLayout.clampedBody(body, count: 2, workspace: space)
            let group = FloatingBadgeLayout.groupBounds(body: clamped, count: 2)
            #expect(space.insetBy(dx: 6, dy: 6).contains(group))
            #expect(clamped.size == body.size)
        }
    }

    @Test func tallBodyLeavesRoomForBadgesOnSmallScreens() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 420)
        let body = CGRect(x: 0, y: 0, width: 150, height: 400)
        let fitted = FloatingBadgeLayout.clampedBody(body, count: 2, workspace: screen)
        #expect(fitted.height >= 38 && fitted.height < body.height)
        #expect(screen.insetBy(dx: 6, dy: 6).contains(FloatingBadgeLayout.groupBounds(body: fitted, count: 2)))
    }

    @Test func monthGridUsesFourFiveOrSixMondayFirstRows() {
        for (text, rows, count) in [("2021-02-10", 4, 28), ("2024-02-10", 5, 29), ("2026-11-10", 6, 30)] {
            let month = date(text + "T12:00:00+08:00")
            let grid = cal.monthGrid(containing: month)
            #expect(grid.count == rows * 7)
            #expect(cal.calendar.component(.weekday, from: grid[0]) == 2)
            #expect(grid.filter { cal.calendar.isDate($0, equalTo: month, toGranularity: .month) }.count == count)
            #expect(Set(grid).count == grid.count)
            #expect(grid.allSatisfy { cal.calendar.component(.hour, from: $0) == 4 })
        }
        let january = cal.monthGrid(containing: date("2026-01-15T12:00:00+08:00"))
        #expect(january.first == date("2025-12-29T04:00:00+08:00"))
    }

    @Test func pauseContinuesAcrossFourAMWhileTodayChanges() {
        let time = BadgeTime()
        time.date = date("2026-11-12T03:59:00+08:00")
        let pause = TransientPauseTimer(time: time)
        let record = StudyInterval(start: date("2026-11-11T10:00:00+08:00"), end: date("2026-11-11T11:00:00+08:00"))
        pause.start()
        #expect(cal.intervals(on: time.date, from: [record]).reduce(0) { $0 + $1.duration } == 3600)
        time.advance(120)
        #expect(pause.elapsed == 120)
        #expect(cal.intervals(on: time.date, from: [record]).isEmpty)
    }
}
