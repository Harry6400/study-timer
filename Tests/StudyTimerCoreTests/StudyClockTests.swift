import Foundation
import Testing
@testable import StudyTimerCore

struct StudyClockTests {
    private let calendar = StudyCalendar(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func clockPositionsAndHalfDayClipping() {
        let start = date("2026-11-10T04:00:00+08:00")
        let clock = StudyClock(day: start, calendar: calendar)
        let full = StudyInterval(start: start, end: calendar.nextDay(start))
        #expect(clock.clippedOffsets(full, ring: 0) == 0...43_200)
        #expect(clock.clippedOffsets(full, ring: 1) == 43_200...86_400)
        #expect(abs(StudyClock.angle(for: 0) - .pi / 6) < 0.000001)
        #expect(abs(StudyClock.angle(for: 28_800) - 1.5 * .pi) < 0.000001)
        let crossing = StudyInterval(start: date("2026-11-10T15:50:00+08:00"), end: date("2026-11-10T16:10:00+08:00"))
        #expect(clock.clippedOffsets(crossing, ring: 0) == 42_600...43_200)
        #expect(clock.clippedOffsets(crossing, ring: 1) == 43_200...43_800)
    }

    @Test func midnightAndFourAMBelongToSameContinuousScale() {
        let clock = StudyClock(day: date("2026-11-10T04:00:00+08:00"), calendar: calendar)
        #expect(clock.offset(for: date("2026-11-11T00:00:00+08:00")) == 72_000)
        #expect(clock.offset(for: date("2026-11-11T04:00:00+08:00")) == 86_400)
        let crossing = StudyInterval(start: date("2026-11-11T03:50:00+08:00"), end: date("2026-11-11T04:10:00+08:00"))
        #expect(clock.clippedOffsets(crossing, ring: 1) == 85_800...86_400)
        let next = StudyClock(day: crossing.end, calendar: calendar)
        #expect(next.clippedOffsets(crossing, ring: 0) == 0...600)
        #expect(calendar.split(crossing).reduce(0) { $0 + $1.interval.duration } == crossing.duration)
    }

    @Test func dragUnwrapsClockAndSeamInBothDirections() {
        var drag = ClockDrag(angle: 179 * .pi / 180)
        drag.update(angle: -179 * .pi / 180, fine: false)
        #expect(abs(drag.seconds - 240) < 0.000001)
        drag.update(angle: 179 * .pi / 180, fine: false)
        #expect(abs(drag.seconds) < 0.000001)
        var turn = ClockDrag(angle: StudyClock.seamAngle)
        for i in 1...24 { turn.update(angle: StudyClock.seamAngle + Double(i) * .pi / 6, fine: false) }
        #expect(abs(turn.seconds - 86_400) < 0.000001)
        var fine = ClockDrag(angle: 0)
        fine.update(angle: .pi / 6, fine: true)
        #expect(abs(fine.seconds - 60) < 0.000001)
    }

    @Test func endpointSnappingAndWholeRecordMovement() {
        let entry = StudyInterval(start: date("2026-11-10T23:59:33+08:00"), end: date("2026-11-11T04:00:27+08:00"))
        #expect(StudyClock.adjusted(entry, target: .start, seconds: 0, fine: false) == entry)
        let start = StudyClock.adjusted(entry, target: .start, seconds: 55, fine: false)
        #expect(start.start == date("2026-11-11T00:00:00+08:00"))
        #expect(start.end == entry.end)
        let fine = StudyClock.adjusted(entry, target: .end, seconds: 1.7, fine: true)
        #expect(fine.end == date("2026-11-11T04:00:29+08:00"))
        #expect(fine.start == entry.start)
        let move = StudyClock.adjusted(entry, target: .move, seconds: 91, fine: false)
        #expect(move.duration == entry.duration)
        #expect(move.start.timeIntervalSince(entry.start) == 120)
        #expect(move.end.timeIntervalSince(entry.end) == 120)
        #expect(move.id == entry.id && move.source == entry.source)
        #expect(StudyClock.adjusted(entry, target: .start, seconds: 100_000, fine: false).duration == 1)
    }

    @Test func paletteUsesAbsoluteStudyTimeAndKeepsSeamColors() {
        let black = StudyDayPalette.rgb(at: 4), end = StudyDayPalette.rgb(at: 28)
        #expect(black.0 == 0 && black.1 == 0 && black.2 == 0)
        #expect(end.0 == 0 && end.1 == 0 && end.2 == 0)
        let teal = StudyDayPalette.rgb(at: 7.5)
        #expect(abs(teal.0 - 46.0 / 255) < 0.000001)
        let before = StudyDayPalette.rgb(at: 16 - 0.00001), after = StudyDayPalette.rgb(at: 16 + 0.00001)
        #expect(abs(before.0 - after.0) < 0.0001 && abs(before.2 - after.2) < 0.0001)
        #expect(StudyDayPalette.rgb(at: 16).0 > 0.9)
    }
}
