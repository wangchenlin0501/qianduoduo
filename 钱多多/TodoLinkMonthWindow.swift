import Foundation

/// Only new selections are limited to these three calendar months. Existing links stay valid.
nonisolated struct TodoLinkMonthWindow: Equatable, Sendable {
    let start: Date
    let endExclusive: Date

    init(containing date: Date, calendar: Calendar) {
        let monthStart = calendar.dateInterval(of: .month, for: date)?.start
            ?? calendar.startOfDay(for: date)
        start = calendar.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
        endExclusive = calendar.date(byAdding: .month, value: 2, to: monthStart) ?? monthStart
    }

    func contains(_ date: Date) -> Bool {
        date >= start && date < endExclusive
    }
}
