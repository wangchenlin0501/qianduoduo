import Foundation

/// A complete Monday-first month grid, using calendar arithmetic across time changes.
struct VideoCalendarMonth {
    let days: [Date?]

    init(containing date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let start = calendar.date(from: components),
              let dayRange = calendar.range(of: .day, in: .month, for: start) else {
            days = []
            return
        }

        let leadingEmptyDays = (calendar.component(.weekday, from: start) + 5) % 7
        var slots = Array<Date?>(repeating: nil, count: leadingEmptyDays)
        for offset in 0..<dayRange.count {
            slots.append(calendar.date(byAdding: .day, value: offset, to: start))
        }
        let trailingEmptyDays = (7 - slots.count % 7) % 7
        slots.append(contentsOf: Array<Date?>(repeating: nil, count: trailingEmptyDays))
        days = slots
    }
}
