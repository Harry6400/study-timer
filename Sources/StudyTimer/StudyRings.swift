import AppKit
import SwiftUI
import StudyTimerCore

struct DayStudyRings: View {
    let date: Date
    let intervals: [StudyInterval]
    let calendar: StudyCalendar
    let today: Date
    let clockReadout: LiveReadout
    var compact = false
    var diameter: CGFloat = 190
    var activeID: UUID?
    var liveReadout: LiveReadout?
    var highlightedID: UUID?
    var selection: Binding<StudyInterval>?
    var locksDuration = false
    var onSelect: ((StudyInterval) -> Void)?
    var onVacantTime: ((Date) -> Void)?
    var onDragEnded: ((Date) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = compact ? 8 : 28
            let size = min(diameter, (geometry.size.width - gap) / 2)
            let clock = StudyClock(day: date, calendar: calendar)
            HStack(spacing: gap) {
                ForEach(0..<2) { ring in
                    StudyRing(clock: clock, ring: ring, intervals: intervals,
                              compact: compact, activeID: activeID, liveReadout: liveReadout,
                              clockReadout: clock.day == today ? clockReadout : nil, selection: selection,
                              highlightedID: highlightedID, locksDuration: locksDuration,
                              onSelect: onSelect, onVacantTime: onVacantTime, onDragEnded: onDragEnded)
                        .frame(width: size, height: size)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(height: diameter)
    }
}

private struct ClockArc: Shape {
    let range: ClosedRange<Double>
    let inset: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: max(1, rect.width / 2 - inset),
                    startAngle: .radians(StudyClock.angle(for: range.lowerBound)),
                    endAngle: .radians(StudyClock.angle(for: range.upperBound)), clockwise: false)
        return path
    }
}

private struct StudyArcStroke: View {
    let range: ClosedRange<Double>
    let radius: CGFloat
    let inset: CGFloat
    let lineWidth: CGFloat
    let paint: AngularGradient
    var selected = false

    var body: some View {
        let outerWidth = lineWidth + (selected ? 2 : 1.5)
        let secondsPerPoint = StudyClock.halfDay / (2 * Double.pi * radius)
        let padding = outerWidth / 2 * secondsPerPoint
        let rounded = range.upperBound - range.lowerBound > 2 * padding
        let path = ClockArc(range: rounded ? (range.lowerBound + padding)...(range.upperBound - padding) : range,
                            inset: inset)
        let cap: CGLineCap = rounded ? .round : .butt
        return ZStack {
            path.stroke(Color.primary.opacity(selected ? 0.7 : 0.3), style: StrokeStyle(lineWidth: outerWidth, lineCap: cap))
            path.stroke(paint, style: StrokeStyle(lineWidth: lineWidth, lineCap: cap))
        }
    }
}

private struct LiveRingArc: View {
    @ObservedObject var readout: LiveReadout
    let clock: StudyClock
    let ring: Int
    let inset: CGFloat
    let lineWidth: CGFloat
    let radius: CGFloat
    let gradient: AngularGradient
    let highlightedID: UUID?
    var body: some View {
        if let live = readout.interval, let range = clock.clippedOffsets(live, ring: ring) {
            StudyArcStroke(range: range, radius: radius, inset: inset, lineWidth: lineWidth,
                           paint: gradient, selected: highlightedID == live.id)
                .opacity(highlightedID != nil && highlightedID != live.id ? 0.5 : 1)
                .allowsHitTesting(false).accessibilityLabel("计时中的学习记录")
        }
    }
}

private struct RingDragState {
    var original: StudyInterval
    var fine: Bool
    let target: StudyClock.DragTarget
    var tracker: ClockDrag
}

private struct StudyRing: View {
    let clock: StudyClock
    let ring: Int
    let intervals: [StudyInterval]
    let compact: Bool
    let activeID: UUID?
    let liveReadout: LiveReadout?
    let clockReadout: LiveReadout?
    let selection: Binding<StudyInterval>?
    let highlightedID: UUID?
    let locksDuration: Bool
    let onSelect: ((StudyInterval) -> Void)?
    let onVacantTime: ((Date) -> Void)?
    let onDragEnded: ((Date) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @State private var dragState: RingDragState?

    private var lower: Double { Double(ring) * StudyClock.halfDay }
    private var upper: Double { lower + StudyClock.halfDay }
    private var inset: CGFloat { compact ? 19 : 32 }
    private var lineWidth: CGFloat { compact ? 9 : selection == nil ? 12 : 15 }
    private var space: String { "study-clock-\(ring)" }
    private var markers: [Int] { StudyDayPart.markerMinutes(onRing: ring) }
    private var gradient: AngularGradient {
        // Each half keeps its own endpoint colors at the four-o'clock seam.
        let first = 4 + lower / 3600, last = first + 12
        let hours = [first] + StudyDayPalette.stops.map(\.hour).filter { $0 > first && $0 < last } + [last]
        let stops = hours.map { hour -> Gradient.Stop in
            let (r, g, b) = StudyDayPalette.rgb(at: hour)
            return .init(color: Color(red: r, green: g, blue: b), location: (hour - first) / 12)
        }
        return AngularGradient(gradient: Gradient(stops: stops), center: .center,
                               startAngle: .degrees(30), endAngle: .degrees(390))
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            let radius = max(1, size / 2 - inset)
            ZStack {
                Circle().stroke(.quaternary, lineWidth: lineWidth)
                    .padding(inset)
                if let onVacantTime {
                    Circle().stroke(.clear, lineWidth: lineWidth).padding(inset)
                        .contentShape(Circle().inset(by: inset).stroke(style: StrokeStyle(lineWidth: lineWidth + 14)))
                        .onTapGesture { point in
                            let angle = atan2(point.y - size / 2, point.x - size / 2)
                            if let date = clock.date(atAngle: angle, ring: ring) { onVacantTime(date) }
                        }
                        .accessibilityHidden(true)
                }
                ForEach(intervals.filter { $0.id != selection?.wrappedValue.id }) { entry in
                    if let range = clock.clippedOffsets(entry, ring: ring) {
                        recordArc(entry, range: range, radius: radius)
                            .opacity(selection != nil ? 0.22 : highlightedID != nil && highlightedID != entry.id ? 0.5 : 1)
                    }
                }
                if let liveReadout {
                    LiveRingArc(readout: liveReadout, clock: clock, ring: ring, inset: inset,
                                lineWidth: lineWidth, radius: radius, gradient: gradient, highlightedID: highlightedID)
                }
                if let selection, let range = clock.clippedOffsets(selection.wrappedValue, ring: ring)
                    ?? dragState.flatMap({ clock.clippedOffsets($0.original, ring: ring) }) {
                    arcLayers(range, radius: radius, selected: true)
                        .opacity(clock.clippedOffsets(selection.wrappedValue, ring: ring) == nil ? 0.3 : 1)
                        .contentShape(ClockArc(range: range, inset: inset).stroke(style: StrokeStyle(lineWidth: 28, lineCap: .round)))
                        .gesture(dragGesture(target: .move, size: size))
                        .focusable(locksDuration)
                        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) {
                            locksDuration ? adjustByKey($0, target: .move) : .ignored
                        }
                        .help("学习记录")
                }
                clockMarks(size: size, radius: radius)
                if let clockReadout {
                    ReadoutContent(readout: clockReadout) { now, _ in
                        clockFace(now: now, size: size, radius: radius)
                    }
                } else {
                    clockFace(now: nil, size: size, radius: radius)
                }
                if let selection, !locksDuration {
                    endpoint(.start, date: selection.wrappedValue.start, size: size, radius: radius + 15)
                    endpoint(.end, date: selection.wrappedValue.end, size: size, radius: radius - 15)
                }
            }.coordinateSpace(name: space)
        }
    }

    private func arcLayers(_ range: ClosedRange<Double>, radius: CGFloat, selected: Bool = false) -> some View {
        StudyArcStroke(range: range, radius: radius, inset: inset, lineWidth: lineWidth, paint: gradient, selected: selected)
    }

    private func recordArc(_ entry: StudyInterval, range: ClosedRange<Double>, radius: CGFloat) -> some View {
        arcLayers(range, radius: radius, selected: highlightedID == entry.id)
            .contentShape(ClockArc(range: range, inset: inset).stroke(style: StrokeStyle(lineWidth: lineWidth + 10)))
            .onTapGesture { if entry.id != activeID { onSelect?(entry) } }
            .help("\(entry.start.formatted(date: .omitted, time: .standard))–\(entry.end.formatted(date: .omitted, time: .standard))\(entry.id == activeID ? " · 计时中" : "")")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("学习记录")
            .accessibilityValue("\(entry.start.formatted()) 至 \(entry.end.formatted())")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if entry.id != activeID { onSelect?(entry) } }
    }

    @ViewBuilder private func clockFace(now: Date?, size: CGFloat, radius: CGFloat) -> some View {
        if let now, let offset = clock.currentOffset(at: now, ring: ring) {
            let components = clock.calendar.calendar.dateComponents([.hour, .minute], from: now)
            let time = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
            currentTimeMarker(offset: offset, size: size, radius: radius)
            centerLabel(currentTime: time)
        } else {
            centerLabel(currentTime: nil)
        }
    }

    private func currentTimeMarker(offset: Double, size: CGFloat, radius: CGFloat) -> some View {
        let halfBand = lineWidth / 2
        let inner = point(offset: offset, radius: radius - halfBand - (compact ? 3 : 5), size: size)
        let outer = point(offset: offset, radius: radius + halfBand + (compact ? 3 : 8), size: size)
        let marker = Path { path in
            path.move(to: inner)
            path.addLine(to: outer)
        }
        let sizeOfTip: CGFloat = compact ? 2 : 3.5
        let tangent = StudyClock.angle(for: offset) + .pi / 2
        let vector = CGPoint(x: cos(tangent) * sizeOfTip, y: sin(tangent) * sizeOfTip)
        let tip = Path { path in
            path.move(to: CGPoint(x: outer.x - vector.x, y: outer.y - vector.y))
            path.addLine(to: CGPoint(x: outer.x + vector.x, y: outer.y + vector.y))
            path.addLine(to: point(offset: offset, radius: radius + halfBand + (compact ? 6 : 12), size: size))
            path.closeSubpath()
        }
        let width: CGFloat = compact ? 2 : 2.5
        let dark = colorScheme == .dark
        let highlight = dark ? Color(red: 0.67, green: 0.89, blue: 1) : Color(red: 0.09, green: 0.39, blue: 0.68)
        let outline = dark ? Color.black.opacity(0.88) : Color.white.opacity(0.96)
        return ZStack {
            marker.stroke(outline, style: StrokeStyle(lineWidth: width + 2, lineCap: .round))
            marker.stroke(highlight, style: StrokeStyle(lineWidth: width, lineCap: .round))
            tip.fill(highlight)
            tip.stroke(outline, lineWidth: 0.75)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func centerLabel(currentTime: String?) -> some View {
        VStack(spacing: compact ? 3 : 6) {
            Text(ring == 0 ? "04:00–16:00" : "16:00–次日04:00").fontWeight(.medium)
                .lineLimit(1).minimumScaleFactor(0.75)
            if let currentTime {
                Text(compact ? currentTime : "当前 \(currentTime)")
                    .font(.system(size: compact ? 10 : 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("当前时间")
                    .accessibilityValue(currentTime)
            }
        }.font(.system(size: compact ? 9 : 12)).monospacedDigit().foregroundStyle(.secondary)
            .accessibilityElement(children: .contain)
            .allowsHitTesting(false)
    }

    private func point(offset: Double, radius: CGFloat, size: CGFloat) -> CGPoint {
        let angle = StudyClock.angle(for: offset)
        return CGPoint(x: size / 2 + cos(angle) * radius, y: size / 2 + sin(angle) * radius)
    }

    private func clockMarks(size: CGFloat, radius: CGFloat) -> some View {
        ZStack {
            ForEach([12, 3, 6, 9], id: \.self) { hour in
                let angle = Double(hour) / 12 * 2 * Double.pi - .pi / 2
                Text("\(hour)")
                    .font(.system(size: compact ? 8 : 10)).foregroundStyle(.tertiary)
                    .position(x: size / 2 + cos(angle) * (radius + (compact ? 15 : 26)),
                              y: size / 2 + sin(angle) * (radius + (compact ? 15 : 26)))
            }
            ForEach(markers, id: \.self) { minute in
                let offset = markerOffset(minute)
                let a = point(offset: offset, radius: radius + lineWidth / 2 + 3, size: size)
                let b = point(offset: offset, radius: radius + lineWidth / 2 + (compact ? 8 : 11), size: size)
                Path { p in p.move(to: a); p.addLine(to: b) }
                    .stroke(Color.primary.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }.allowsHitTesting(false)
        .overlay {
            // Separate hit areas let a marker reveal its time without covering the arcs.
            ForEach(markers, id: \.self) { minute in
                let p = point(offset: markerOffset(minute), radius: radius + lineWidth / 2 + 8, size: size)
                Color.clear.frame(width: 14, height: 14).contentShape(Circle())
                    .position(p).help(String(format: "%02d:%02d", minute / 60, minute % 60))
            }
        }
    }

    private func markerOffset(_ minute: Int) -> Double {
        Double(minute - StudyDayPart.earlyMorning.rawValue) * 60
    }

    @ViewBuilder private func endpoint(_ target: StudyClock.DragTarget, date: Date, size: CGFloat, radius: CGFloat) -> some View {
        let offset = clock.offset(for: date)
        let isStart = target == .start
        let visible = isStart ? offset >= lower && offset < upper : offset > lower && offset <= upper
        if visible || dragState?.target == target {
            let p = point(offset: offset, radius: radius, size: size)
            let track = point(offset: offset, radius: size / 2 - inset, size: size)
            Path { path in path.move(to: track); path.addLine(to: p) }
                .stroke(Color.primary.opacity(0.6), lineWidth: 1)
                .allowsHitTesting(false)
            Image(systemName: isStart ? "play.fill" : "stop.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isStart ? Color.primary : .white)
                .frame(width: 25, height: 25)
                .background(isStart ? Color(nsColor: .windowBackgroundColor) : Color(red: 0.07, green: 0.44, blue: 0.39), in: Circle())
                .overlay(Circle().strokeBorder(isStart ? Color.primary : Color.white.opacity(0.5), lineWidth: 1.25))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .gesture(dragGesture(target: target, size: size))
                .focusable()
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { adjustByKey($0, target: target) }
                .help(isStart ? "开始时间" : "结束时间")
                .accessibilityLabel(isStart ? "开始时间" : "结束时间")
                .accessibilityValue(date.formatted())
                .accessibilityAdjustableAction { direction in
                    guard let selection else { return }
                    let delta: Double = direction == .increment ? 60 : -60
                    selection.wrappedValue = StudyClock.adjusted(selection.wrappedValue, target: target, seconds: delta, fine: false)
                }
                .opacity(visible ? 1 : 0.45)
                .position(p)
        }
    }

    private func adjustByKey(_ key: KeyPress, target: StudyClock.DragTarget) -> KeyPress.Result {
        guard let selection else { return .ignored }
        let fine = key.modifiers.contains(.option)
        let forward = key.key == .rightArrow || key.key == .upArrow
        selection.wrappedValue = StudyClock.adjusted(selection.wrappedValue, target: target,
                                                     seconds: (forward ? 1 : -1) * (fine ? 1 : 60), fine: fine)
        let date = target == .end ? selection.wrappedValue.end.addingTimeInterval(-0.001) : selection.wrappedValue.start
        onDragEnded?(date)
        return .handled
    }

    private func dragGesture(target: StudyClock.DragTarget, size: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
            .onChanged { value in
                guard let selection else { return }
                func angle(_ p: CGPoint) -> Double { atan2(p.y - size / 2, p.x - size / 2) }
                let fine = NSEvent.modifierFlags.contains(.option)
                var state = dragState ?? RingDragState(original: selection.wrappedValue, fine: fine, target: target,
                                                       tracker: ClockDrag(angle: angle(value.startLocation)))
                if state.fine != fine {
                    state.original = selection.wrappedValue
                    state.tracker = ClockDrag(angle: angle(value.location))
                    state.fine = fine
                }
                // The original ring remains the gesture's coordinate origin when the endpoint changes rings.
                state.tracker.update(angle: angle(value.location), fine: fine)
                selection.wrappedValue = StudyClock.adjusted(state.original, target: state.target,
                                                              seconds: state.tracker.seconds, fine: fine)
                dragState = state
            }
            .onEnded { _ in
                guard let selection else { return }
                let focus = target == .end ? selection.wrappedValue.end.addingTimeInterval(-0.001) : selection.wrappedValue.start
                dragState = nil
                onDragEnded?(focus)
            }
    }
}

struct IntervalEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var interval: StudyInterval
    @State private var day: Date
    let pending: PendingStudyInterval?
    @State private var error: String?

    init(interval: StudyInterval, model: AppModel, pending: PendingStudyInterval? = nil) {
        self.model = model
        self.pending = pending
        _interval = State(initialValue: interval)
        _day = State(initialValue: model.studyCalendar.dayStart(for: interval.start))
    }
    private var validationError: String? {
        do { try HistoryStore.validate(interval, against: model.liveRecords, now: model.now); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(pending != nil ? "校对学习记录" : model.records.contains(where: { $0.id == interval.id }) ? "修改学习记录" : "补记学习记录")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(TimeInput.format(interval.duration)).font(.title3.weight(.semibold)).monospacedDigit()
            }
            StudyDateNavigator(date: $day, now: model.now)
            DayStudyRings(date: day, intervals: model.liveRecords, calendar: model.studyCalendar,
                          today: model.studyDay, clockReadout: model.statisticsReadout, diameter: 270,
                          selection: $interval, locksDuration: pending != nil, onDragEnded: { focus in
                let calendar = model.studyCalendar
                if focus < day || focus >= calendar.nextDay(day) { day = calendar.dayStart(for: focus) }
            })
            HStack(spacing: 12) {
                timeCard("开始", date: interval.start)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                timeCard("结束", date: interval.end)
            }
            HStack {
                if let message = validationError ?? error {
                    Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isMutating)
                Button("保存") {
                    Task {
                        do {
                            if let pending { try await model.archive(pending, as: interval) }
                            else { try await model.saveInterval(interval) }
                            dismiss()
                        }
                        catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(validationError != nil || model.isMutating || model.timerWriteBlocked)
            }
        }.padding(28).frame(width: 680)
            .interactiveDismissDisabled(model.isMutating)
            .onAppear { model.modalDepth += 1 }
            .onDisappear { model.modalDepth = max(0, model.modalDepth - 1) }
    }

    private func timeCard(_ title: String, date: Date) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(date, format: .dateTime.month().day().hour().minute().second())
                .monospacedDigit().fontWeight(.medium)
        }.font(.callout).padding(12).frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
    }
}
