import Foundation

struct MonthChartTotal: Identifiable {
    let month: Date
    let amount: Double

    var id: Date { month }
}

/// The average uses the same whole months as the visible bars, including zero months.
struct MonthlyAmountWindow {
    let months: [MonthChartTotal]

    init(totals: [MonthChartTotal], scrollPosition: Double, visibleCount: Int) {
        let count = min(max(visibleCount, 1), totals.count)
        let maxStart = max(totals.count - count, 0)
        let position = scrollPosition.isFinite ? scrollPosition.rounded() : Double(maxStart)
        let start = Int(min(max(position, 0), Double(maxStart)))
        months = Array(totals.dropFirst(start).prefix(count))
    }

    var average: Double? {
        guard !months.isEmpty else { return nil }
        return months.reduce(0) { $0 + $1.amount } / Double(months.count)
    }
}
