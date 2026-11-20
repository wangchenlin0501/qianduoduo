import Foundation
import Testing
@testable import 钱多多

struct TodoLinkMonthWindowTests {
    @Test func includesOnlyPreviousCurrentAndNextCalendarMonth() {
        let window = TodoLinkMonthWindow(containing: date(2026, 10, 23), calendar: calendar)
        #expect(window.start == date(2026, 9, 1))
        #expect(window.endExclusive == date(2026, 12, 1))
        #expect(!window.contains(date(2026, 8, 31)))
        #expect(window.contains(date(2026, 9, 1)))
        #expect(window.contains(date(2026, 10, 31)))
        #expect(window.contains(date(2026, 11, 30)))
        #expect(!window.contains(date(2026, 12, 1)))
    }

    @Test func handlesYearBoundaryInBothDirections() {
        let january = TodoLinkMonthWindow(containing: date(2027, 1, 31), calendar: calendar)
        #expect(january.start == date(2026, 12, 1))
        #expect(january.endExclusive == date(2027, 3, 1))
        let december = TodoLinkMonthWindow(containing: date(2026, 12, 15), calendar: calendar)
        #expect(december.start == date(2026, 11, 1))
        #expect(december.endExclusive == date(2027, 2, 1))
    }

    @Test func includesLeapDayAndUsesExclusiveEnd() {
        let window = TodoLinkMonthWindow(containing: date(2028, 1, 31), calendar: calendar)
        #expect(window.contains(date(2028, 2, 29)))
        #expect(window.contains(date(2028, 3, 1).addingTimeInterval(-0.001)))
        #expect(!window.contains(date(2028, 3, 1)))
        #expect(!window.contains(window.start.addingTimeInterval(-0.001)))
    }

    @Test func followsShanghaiMidnightRatherThanDeviceTimeZone() throws {
        let parser = ISO8601DateFormatter()
        let now = try #require(parser.date(from: "2026-09-30T16:01:00Z"))
        let window = TodoLinkMonthWindow(containing: now, calendar: calendar)
        #expect(window.start == date(2026, 9, 1))
        #expect(window.endExclusive == date(2026, 12, 1))
        #expect(!window.contains(Date.distantPast))
        #expect(!window.contains(Date.distantFuture))
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
