import SwiftUI
import StudyTimerCore

private struct RecordRowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct StudyRecordList: View {
    let entries: [StudyInterval]
    let date: Date
    let calendar: StudyCalendar
    let activeID: UUID?
    let readout: LiveReadout
    let editsDisabled: Bool
    @Binding var selectedID: UUID?
    @Binding var hoveredID: UUID?
    let edit: (StudyInterval) -> Void
    let delete: (StudyInterval) -> Void
    @State private var liveScale: TimeInterval = 0
    @State private var pointer: CGPoint?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @Namespace private var viewport

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label("这一天还没有学习记录", systemImage: "clock")
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let longest = entries.lazy.filter { $0.id != activeID }.map(\.duration).max() ?? 0
            let scale = max(3600, Self.scaleBucket(longest), activeID == nil ? 0 : liveScale)
            let clock = StudyClock(day: date, calendar: calendar)
            let parts = StudyDayParts(clock: clock)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(entries) { entry in
                        if entry.id == activeID {
                            ReadoutContent(readout: readout) { _, live in
                                let current = live.flatMap { calendar.intervals(on: date, from: [$0]).first } ?? entry
                                row(current, scale: scale, isLive: true, clock: clock, parts: parts)
                                    .onChange(of: Self.scaleBucket(current.duration), initial: true) { _, value in
                                        liveScale = value
                                    }
                            }
                        } else {
                            row(entry, scale: scale, isLive: false, clock: clock, parts: parts)
                        }
                    }
                }.padding(.vertical, 2)
            }
            .coordinateSpace(name: viewport)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): pointer = location
                case .ended: pointer = nil
                }
                updateHover()
            }
            .onPreferenceChange(RecordRowFrames.self) { frames in
                rowFrames = frames
                updateHover()
            }
            .onChange(of: date) { _, _ in clearHover() }
            .onDisappear { clearHover() }
        }
    }

    private func updateHover() {
        let id = pointer.flatMap { location in rowFrames.first { $0.value.contains(location) }?.key }
        if hoveredID != id { hoveredID = id }
    }

    private func clearHover() {
        pointer = nil
        updateHover()
    }

    private static func scaleBucket(_ duration: TimeInterval) -> TimeInterval {
        ceil(duration / 1800) * 1800
    }

    private func row(_ entry: StudyInterval, scale: TimeInterval, isLive: Bool,
                     clock: StudyClock, parts: StudyDayParts) -> some View {
        let selected = selectedID == entry.id
        let range = "\(clockText(entry.start))–\(isLive ? "计时中" : clockText(entry.end))"
        let duration = Self.durationLabel(entry.duration, isLive: isLive)
        let dayParts = parts.names(overlapping: entry).joined(separator: " · ")
        let hour = 4 + clock.offset(for: entry.start) / 3600
        let (r, g, b) = StudyDayPalette.rgb(at: hour)
        let tint = Color(red: r, green: g, blue: b)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Button {
                    selectedID = selected ? nil : entry.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 8)
                        Text(range).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                            .layoutPriority(1)
                        GeometryReader { geometry in
                            let width = geometry.size.width
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                if entry.duration > 0 {
                                    Capsule().fill(tint)
                                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.75))
                                        .frame(width: min(width, max(3, width * entry.duration / scale)))
                                }
                            }
                        }.frame(minWidth: 24, maxWidth: 118, minHeight: 6, maxHeight: 6)
                            .accessibilityHidden(true)
                        Text(duration).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                            .minimumScaleFactor(0.75).frame(minWidth: 66, alignment: .trailing)
                        Text(dayParts).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minWidth: 80, idealWidth: 88, maxWidth: 100, alignment: .leading)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(range)，\(duration)，\(dayParts)")
                    .accessibilityValue(selected ? "已展开" : "已折叠")
                if !isLive {
                    Button { edit(entry) } label: { Image(systemName: "pencil") }
                        .help("修改记录").accessibilityLabel("修改记录").disabled(editsDisabled)
                    Button { delete(entry) } label: { Image(systemName: "trash") }
                        .help("删除记录").accessibilityLabel("删除记录").disabled(editsDisabled)
                }
            }.buttonStyle(.borderless)
            if selected {
                Text("\(clockText(entry.start, seconds: true)) – \(clockText(entry.end, seconds: true)) · \(exactDuration(entry.duration))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().textSelection(.enabled)
                    .padding(.leading, 16).padding(.bottom, 6)
            }
        }.font(.callout).padding(.horizontal, 8)
            .background(selected ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: RecordRowFrames.self,
                                           value: entry.duration > 0 ? [entry.id: geometry.frame(in: .named(viewport))] : [:])
                }.allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) { Divider().opacity(0.5).allowsHitTesting(false) }
    }

    private func clockText(_ time: Date, seconds: Bool = false) -> String {
        let parts = calendar.calendar.dateComponents([.hour, .minute, .second], from: time)
        let prefix = calendar.calendar.isDate(time, inSameDayAs: date) ? "" : "次日 "
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        return prefix + (seconds ? String(format: "%02d:%02d:%02d", hour, minute, parts.second ?? 0)
                                 : String(format: "%02d:%02d", hour, minute))
    }

    private func exactDuration(_ duration: TimeInterval) -> String {
        duration > 0 && duration < 1 ? "不足 1 秒" : TimeInput.format(duration)
    }

    private static func durationLabel(_ duration: TimeInterval, isLive: Bool) -> String {
        if duration < 60 { return isLive ? TimeInput.format(duration) : "不足 1 分钟" }
        let minutes = Int(duration / 60)
        let hours = minutes / 60
        if hours == 0 { return "\(minutes) 分钟" }
        return minutes % 60 == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes % 60) 分"
    }
}
