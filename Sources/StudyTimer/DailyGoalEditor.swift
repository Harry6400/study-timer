import SwiftUI
import StudyTimerCore

struct DailyGoalDraft {
    private(set) var totalMinutes: Int

    init(minutes: Int) {
        totalMinutes = minutes.clamped(to: Preferences.dailyGoalMinutesRange)
    }

    var hours: Int {
        get { totalMinutes / 60 }
        set {
            let hour = newValue.clamped(to: 0...24)
            totalMinutes = hour * 60 + minutes.clamped(to: Self.minuteRange(for: hour))
        }
    }

    var minutes: Int {
        get { totalMinutes % 60 }
        set { totalMinutes = hours * 60 + newValue.clamped(to: minuteRange) }
    }

    var minuteRange: ClosedRange<Int> { Self.minuteRange(for: hours) }

    private static func minuteRange(for hours: Int) -> ClosedRange<Int> {
        switch hours {
        case 0: 1...59
        case 24: 0...0
        default: 0...59
        }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

struct DailyGoalEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DailyGoalDraft
    let onSave: (Int) -> Void

    init(minutes: Int, onSave: @escaping (Int) -> Void) {
        _draft = State(initialValue: DailyGoalDraft(minutes: minutes))
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("每日学习目标").font(.headline)
            amountRow("小时", value: $draft.hours, range: 0...24)
            amountRow("分钟", value: $draft.minutes, range: draft.minuteRange)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(draft.totalMinutes)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 280)
    }

    private func amountRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        let fixed = range.lowerBound == range.upperBound
        let sliderValue = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) })
        let sliderRange = Double(range.lowerBound)...Double(fixed ? range.upperBound + 1 : range.upperBound)
        return HStack(spacing: 10) {
            Text(title).frame(width: 30, alignment: .leading)
            Slider(value: sliderValue, in: sliderRange, step: 1) { Text(title) }
                .labelsHidden()
                .accessibilityValue(String(value.wrappedValue))
            Text(value.wrappedValue.formatted(.number.precision(.integerLength(2))))
                .monospacedDigit().frame(width: 22, alignment: .trailing)
            Stepper(title, value: value, in: range)
                .labelsHidden()
                .accessibilityValue(String(value.wrappedValue))
        }.disabled(fixed)
    }
}
