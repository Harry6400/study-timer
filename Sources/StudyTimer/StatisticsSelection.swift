import Foundation

/// 图表范围与详情分别选择，悬停结束后仍可操作刚查看的记录。
struct StatisticsSelection {
    private(set) var date: Date
    private(set) var detailDate: Date

    init(today: Date) { date = today; detailDate = today }
    mutating func showToday(_ today: Date) { navigate(to: today) }
    mutating func navigate(to day: Date) { date = day; detailDate = day }
    mutating func preview(_ day: Date) { detailDate = day }
    mutating func dayChanged(from old: Date, to today: Date) {
        if date == old { date = today }
        if detailDate == old { detailDate = today }
    }
}
