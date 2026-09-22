// Compile with 钱多多/MonthlyAmountTrend.swift; runs on macOS without a simulator.
import Foundation

@main
struct VerifyMonthlyAmount {
    static func main() {
        let start = Date(timeIntervalSince1970: 0)
        func months(_ values: [Double]) -> [MonthChartTotal] {
            values.enumerated().map { MonthChartTotal(month: start.addingTimeInterval(Double($0.offset) * 86400), amount: $0.element) }
        }
        let sample = months([14_495, 7_010, 5_480, 6_070, 1_970])
        let displayed = MonthlyAmountWindow(totals: sample, scrollPosition: 0, visibleCount: 5)
        precondition(displayed.average == 7_005, "Screenshot example must average monthly totals to ¥7,005")

        let history = months([100_000, 14_495, 7_010, 5_480, 6_070, 1_970])
        let latest = MonthlyAmountWindow(totals: history, scrollPosition: 1, visibleCount: 5)
        precondition(latest.average == 7_005, "Off-screen older months must not change the average")
        let older = MonthlyAmountWindow(totals: history, scrollPosition: 0, visibleCount: 2)
        precondition(older.average == 57_247.5, "Scrolling must update the displayed average")

        let withZero = MonthlyAmountWindow(totals: months([0, 6_000]), scrollPosition: 0, visibleCount: 2)
        precondition(withZero.average == 3_000, "Zero-amount months count in a monthly average")
        let single = MonthlyAmountWindow(totals: months([1_970]), scrollPosition: 200, visibleCount: 5)
        precondition(single.average == 1_970, "A single available month must not divide by five")
        let empty = MonthlyAmountWindow(totals: [], scrollPosition: 0, visibleCount: 5)
        precondition(empty.average == nil, "An empty period has no average")
        let beforeStart = MonthlyAmountWindow(totals: sample, scrollPosition: -4, visibleCount: 2)
        precondition(beforeStart.average == 10_752.5, "Scroll bounce must clamp to the first available month")
        print("PASS: screenshot average ¥7,005; scrolling, zero months, single month, empty period and boundary clamping.")
    }
}
