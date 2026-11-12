import AppKit
import SwiftUI
import StudyTimerCore

struct DayStudyRings: View {
    let date: Date
    let intervals: [StudyInterval]
    var compact = false
    var diameter: CGFloat = 190
    var activeID: UUID?
    var liveReadout: LiveReadout?
    var selection: Binding<StudyInterval>?
    var onSelect: ((StudyInterval) -> Void)?
    var onDragEnded: ((Date) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = compact ? 8 : 28
            let size = min(diameter, (geometry.size.width - gap) / 2)
            HStack(spacing: gap) {
                ForEach(0..<2) { ring in
                    StudyRing(clock: StudyClock(day: date), ring: ring, intervals: intervals,
                              compact: compact, activeID: activeID, liveReadout: liveReadout, selection: selection,
                              onSelect: onSelect, onDragEnded: onDragEnded)
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

private struct LiveRingArc: View {
    @ObservedObject var readout: LiveReadout
    let clock: StudyClock
    let ring: Int
    let inset: CGFloat
    let lineWidth: CGFloat
    let gradient: AngularGradient
    var body: some View {
        if let live = readout.interval, let range = clock.clippedOffsets(live, ring: ring) {
            let arc = ClockArc(range: range, inset: inset)
            ZStack {
                arc.stroke(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: lineWidth + 1.5, lineCap: .butt))
                arc.stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }.allowsHitTesting(false).accessibilityLabel("计时中的学习记录")
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
    let selection: Binding<StudyInterval>?
    let onSelect: ((StudyInterval) -> Void)?
    let onDragEnded: ((Date) -> Void)?
    @State private var dragState: RingDragState?

    private var lower: Double { Double(ring) * StudyClock.halfDay }
    private var upper: Double { lower + StudyClock.halfDay }
    private var inset: CGFloat { compact ? 19 : 32 }
    private var lineWidth: CGFloat { compact ? 9 : selection == nil ? 12 : 15 }
    private var space: String { "study-clock-\(ring)" }
    private var markers: [Double] { ring == 0 ? [4, 7.5, 12 + 10.0 / 60, 14] : [16, 17 + 40.0 / 60, 18.5, 22.75] }
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
                ForEach(intervals.filter { $0.id != selection?.wrappedValue.id }) { entry in
                    if let range = clock.clippedOffsets(entry, ring: ring) {
                        recordArc(entry, range: range).opacity(selection == nil ? 1 : 0.22)
                    }
                }
                if let liveReadout {
                    LiveRingArc(readout: liveReadout, clock: clock, ring: ring, inset: inset,
                                lineWidth: lineWidth, gradient: gradient)
                }
                if let selection, let range = clock.clippedOffsets(selection.wrappedValue, ring: ring)
                    ?? dragState.flatMap({ clock.clippedOffsets($0.original, ring: ring) }) {
                    arcLayers(range, selected: true)
                        .opacity(clock.clippedOffsets(selection.wrappedValue, ring: ring) == nil ? 0.3 : 1)
                        .contentShape(ClockArc(range: range, inset: inset).stroke(style: StrokeStyle(lineWidth: 28, lineCap: .round)))
                        .gesture(dragGesture(target: .move, size: size))
                        .help("学习记录")
                }
                clockMarks(size: size, radius: radius)
                centerLabel
                    .allowsHitTesting(false)
                if let selection {
                    endpoint(.start, date: selection.wrappedValue.start, size: size, radius: radius + 15)
                    endpoint(.end, date: selection.wrappedValue.end, size: size, radius: radius - 15)
                }
            }.coordinateSpace(name: space)
        }
    }

    private func arcLayers(_ range: ClosedRange<Double>, selected: Bool = false) -> some View {
        let arc = ClockArc(range: range, inset: inset)
        return ZStack {
            arc.stroke(Color.primary.opacity(selected ? 0.65 : 0.28), style: StrokeStyle(lineWidth: lineWidth + 1.5, lineCap: .butt))
            arc.stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
        }
    }

    private func recordArc(_ entry: StudyInterval, range: ClosedRange<Double>) -> some View {
        arcLayers(range)
            .contentShape(ClockArc(range: range, inset: inset).stroke(style: StrokeStyle(lineWidth: 24, lineCap: .round)))
            .onTapGesture { if entry.id != activeID { onSelect?(entry) } }
            .help("\(entry.start.formatted(date: .omitted, time: .standard))–\(entry.end.formatted(date: .omitted, time: .standard))\(entry.id == activeID ? " · 计时中" : "")")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("学习记录")
            .accessibilityValue("\(entry.start.formatted()) 至 \(entry.end.formatted())")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if entry.id != activeID { onSelect?(entry) } }
    }

    private var centerLabel: some View {
        VStack(spacing: compact ? 2 : 4) {
            Text(ring == 0 ? "04:00" : "16:00").fontWeight(.medium)
            Text("—").foregroundStyle(.tertiary)
            Text(ring == 0 ? "16:00" : "次日04:00")
        }.font(.system(size: compact ? 9 : 12)).monospacedDigit().foregroundStyle(.secondary)
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
            ForEach(markers, id: \.self) { hour in
                let offset = (hour - 4) * 3600
                let a = point(offset: offset, radius: radius + lineWidth / 2 + 3, size: size)
                let b = point(offset: offset, radius: radius + lineWidth / 2 + (compact ? 8 : 11), size: size)
                Path { p in p.move(to: a); p.addLine(to: b) }
                    .stroke(Color.primary.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }.allowsHitTesting(false)
        .overlay {
            // Separate hit areas let a marker reveal its time without covering the arcs.
            ForEach(markers, id: \.self) { hour in
                let p = point(offset: (hour - 4) * 3600, radius: radius + lineWidth / 2 + 8, size: size)
                Color.clear.frame(width: 14, height: 14).contentShape(Circle())
                    .position(p).help(String(format: "%02d:%02d", Int(hour) % 24, Int((hour * 60).rounded()) % 60))
            }
        }
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
            Text(isStart ? "起" : "止")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isStart ? Color(nsColor: .textBackgroundColor) : .white)
                .frame(width: 24, height: 24)
                .background(isStart ? Color.primary : Color(red: 0.15, green: 0.55, blue: 0.49), in: Circle())
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                .contentShape(Circle().size(width: 30, height: 30).offset(x: -3, y: -3))
                .gesture(dragGesture(target: target, size: size))
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
    @State private var precise = false
    @State private var error: String?

    init(interval: StudyInterval, model: AppModel) {
        self.model = model
        _interval = State(initialValue: interval)
        _day = State(initialValue: StudyCalendar().dayStart(for: interval.start))
    }
    private var validationError: String? {
        do { try HistoryStore.validate(interval, against: model.liveRecords); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(model.records.contains(where: { $0.id == interval.id }) ? "修改学习记录" : "补记学习记录").font(.title2.weight(.semibold))
                Spacer()
                Text(TimeInput.format(interval.duration)).font(.title3.weight(.semibold)).monospacedDigit()
            }
            StudyDateNavigator(date: $day)
            DayStudyRings(date: day, intervals: model.liveRecords, diameter: 270,
                          selection: $interval, onDragEnded: { focus in
                let calendar = StudyCalendar()
                if focus < day || focus >= calendar.nextDay(day) { day = calendar.dayStart(for: focus) }
            })
            HStack(spacing: 12) {
                timeCard("开始", date: interval.start)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                timeCard("结束", date: interval.end)
            }
            DisclosureGroup("精确输入", isExpanded: $precise) {
                VStack(spacing: 10) {
                    DatePicker("开始时间", selection: $interval.start, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("结束时间", selection: $interval.end, displayedComponents: [.date, .hourAndMinute])
                }.padding(.top, 10)
            }.font(.callout)
            HStack {
                if let message = validationError ?? error {
                    Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isMutating)
                Button("保存") {
                    Task {
                        do { try await model.saveInterval(interval); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(validationError != nil || model.isMutating)
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
