// Runs on macOS with VideoCalendarMonth.swift and VideoCalendarMovePlan.swift.
import Foundation

@main
struct VerifyVideoCalendar {
    static func main() {
        var checks = 0
        for zone in ["Asia/Shanghai", "Europe/Paris", "America/New_York"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!

            for year in 2020...2032 {
                for month in 1...12 {
                    let date = calendar.date(from: DateComponents(year: year, month: month, day: 15))!
                    let slots = VideoCalendarMonth(containing: date, calendar: calendar).days
                    let dates = slots.compactMap { $0 }
                    let expectedCount = calendar.range(of: .day, in: .month, for: date)!.count
                    precondition(dates.count == expectedCount, "Every day must appear exactly once")
                    precondition(slots.count % 7 == 0 && (28...42).contains(slots.count))
                    precondition(Set(dates).count == dates.count)

                    for (index, day) in slots.enumerated() {
                        guard let day else { continue }
                        precondition((calendar.component(.weekday, from: day) + 5) % 7 == index % 7, "Weekday columns must stay Monday-first")
                        precondition(calendar.component(.month, from: day) == month)
                        precondition(calendar.component(.year, from: day) == year)
                        precondition(calendar.component(.hour, from: day) == 0, "DST must preserve local day boundaries")
                    }
                    precondition(dates.enumerated().allSatisfy { calendar.component(.day, from: $0.element) == $0.offset + 1 })
                    checks += 1
                }
            }

            let leapFebruary = calendar.date(from: DateComponents(year: 2024, month: 2, day: 1))!
            precondition(VideoCalendarMonth(containing: leapFebruary, calendar: calendar).days.compactMap { $0 }.count == 29)
            let fourWeekMonth = calendar.date(from: DateComponents(year: 2021, month: 2, day: 1))!
            precondition(VideoCalendarMonth(containing: fourWeekMonth, calendar: calendar).days.count == 28)
            let sixWeekMonth = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
            precondition(VideoCalendarMonth(containing: sixWeekMonth, calendar: calendar).days.count == 42)
        }
        verifyMoves()
        verifyPendingPlacement()
        verifyPublishedProtection()
        print("PASS: \(checks) month grids, dated-video moves, pending-video placement, nearest free days, forward tie-breaks, month boundaries, full months, and published-video protection.")
    }

    static func verifyMoves() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day))!
        }
        let source = VideoCalendarSlot(id: "first", date: date(17))
        let neighbor = VideoCalendarSlot(id: "second", date: date(16))
        let emptyMove = try! VideoCalendarMovePlan(sourceID: source.id, destination: date(18), slots: [source, neighbor], calendar: calendar)
        precondition(emptyMove.changes == [.init(id: source.id, date: date(18))])

        let swap = try! VideoCalendarMovePlan(sourceID: source.id, destination: date(16), slots: [source, neighbor], calendar: calendar)
        precondition(swap.changes == [.init(id: source.id, date: date(16)), .init(id: neighbor.id, date: date(17))])
        let movedDates = [source, neighbor].map { slot in
            swap.changes.first { $0.id == slot.id }?.date ?? slot.date
        }
        precondition(Set(movedDates).count == movedDates.count, "Swapping must keep one video per day")

        let sameDay = try! VideoCalendarMovePlan(sourceID: source.id, destination: date(17).addingTimeInterval(3600), slots: [source], calendar: calendar)
        precondition(sameDay.changes.isEmpty, "Dropping onto the same day must not rewrite records")

        do {
            _ = try VideoCalendarMovePlan(sourceID: "unknown", destination: date(18), slots: [source], calendar: calendar)
            preconditionFailure("Unknown drag identities must be rejected")
        } catch VideoCalendarMovePlan.MoveError.unknownVideo { }
        catch { preconditionFailure("Unexpected error: \(error)") }

        do {
            let duplicate = VideoCalendarSlot(id: "third", date: date(16))
            _ = try VideoCalendarMovePlan(sourceID: source.id, destination: date(16), slots: [source, neighbor, duplicate], calendar: calendar)
            preconditionFailure("Legacy duplicate slots must not silently overwrite a video")
        } catch VideoCalendarMovePlan.MoveError.multipleVideosOnDay { }
        catch { preconditionFailure("Unexpected error: \(error)") }

        let december = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        let january = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        let yearBoundary = try! VideoCalendarMovePlan(sourceID: "year-end", destination: january, slots: [.init(id: "year-end", date: december)], calendar: calendar)
        precondition(yearBoundary.changes.first?.date == january)
    }

    static func verifyPublishedProtection() {
        for zone in ["Asia/Shanghai", "Europe/Paris", "America/New_York"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            func date(_ day: Int) -> Date {
                calendar.date(from: DateComponents(year: 2026, month: 10, day: day))!
            }
            let published = VideoCalendarSlot(id: "published", date: date(16), isPublished: true)
            let scheduled = VideoCalendarSlot(id: "scheduled", date: date(19))
            let pending = VideoCalendarSlot(id: "pending", date: nil)
            for destination in [date(16), date(17), date(19)] {
                do {
                    _ = try VideoCalendarMovePlan(sourceID: published.id, destination: destination, slots: [published, scheduled], calendar: calendar)
                    preconditionFailure("Published videos must reject all drag moves, including swaps")
                } catch VideoCalendarMovePlan.MoveError.publishedVideo { }
                catch { preconditionFailure("Unexpected error: \(error)") }
            }
            for source in [scheduled, pending] {
                let plan = try! VideoCalendarMovePlan(sourceID: source.id, destination: date(16), slots: [published, source], calendar: calendar)
                precondition(plan.destinationDate == date(17))
                precondition(plan.changes == [.init(id: source.id, date: date(17))], "Dropping on a published video must never change its date")
            }
            let fullMonth = (1...31).map { VideoCalendarSlot(id: "published-\($0)", date: date($0), isPublished: true) }
            do {
                _ = try VideoCalendarMovePlan(sourceID: pending.id, destination: date(16), slots: fullMonth + [pending], calendar: calendar)
                preconditionFailure("A full published calendar must not accept another video")
            } catch VideoCalendarMovePlan.MoveError.noAvailableDay { }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }
    }

    static func verifyPendingPlacement() {
        for zone in ["Asia/Shanghai", "Europe/Paris", "America/New_York"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            func date(_ day: Int) -> Date {
                calendar.date(from: DateComponents(year: 2026, month: 10, day: day))!
            }
            let pending = VideoCalendarSlot(id: "pending", date: nil)
            func occupied(_ days: [Int]) -> [VideoCalendarSlot] {
                days.map { VideoCalendarSlot(id: "scheduled-\($0)", date: date($0)) }
            }
            func plan(day: Int, occupiedDays: [Int]) -> VideoCalendarMovePlan {
                try! VideoCalendarMovePlan(sourceID: pending.id, destination: date(day), slots: [pending] + occupied(occupiedDays), calendar: calendar)
            }

            let empty = plan(day: 17, occupiedDays: [])
            precondition(empty.destinationDate == date(17))
            precondition(empty.changes == [.init(id: pending.id, date: date(17))])

            let tie = plan(day: 17, occupiedDays: [17])
            precondition(tie.destinationDate == date(18), "Equally close free days must favor the future")
            precondition(tie.changes.count == 1 && tie.changes.first?.id == pending.id, "Existing videos must never be swapped or overwritten by a pending video")

            let earlier = plan(day: 17, occupiedDays: [17, 18])
            precondition(earlier.destinationDate == date(16), "An earlier day wins when it is closer")
            precondition(plan(day: 17, occupiedDays: [16, 17, 18]).destinationDate == date(19))
            precondition(plan(day: 1, occupiedDays: [1, 2]).destinationDate == date(3))
            precondition(plan(day: 31, occupiedDays: [31]).destinationDate == date(30))

            do {
                _ = try VideoCalendarMovePlan(sourceID: pending.id, destination: date(17), slots: [pending] + occupied(Array(1...31)), calendar: calendar)
                preconditionFailure("A full month must not overwrite a scheduled video or silently spill into another month")
            } catch VideoCalendarMovePlan.MoveError.noAvailableDay { }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }
    }
}
