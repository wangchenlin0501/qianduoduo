import Foundation

struct VideoCalendarSlot {
    let id: String
    let date: Date?
    var isPublished: Bool = false
}

struct VideoCalendarMovePlan {
    struct Change: Equatable {
        let id: String
        let date: Date
    }

    enum MoveError: Error {
        case unknownVideo
        case multipleVideosOnDay
        case noAvailableDay
        case publishedVideo
    }

    let changes: [Change]
    let destinationDate: Date

    init(sourceID: String, destination: Date, slots: [VideoCalendarSlot], calendar: Calendar) throws {
        guard let source = slots.first(where: { $0.id == sourceID }) else {
            throw MoveError.unknownVideo
        }
        guard !source.isPublished else { throw MoveError.publishedVideo }
        let destinationDay = calendar.startOfDay(for: destination)
        guard let sourceDate = source.date else {
            guard let availableDay = Self.nearestAvailableDay(to: destinationDay, slots: slots, calendar: calendar) else {
                throw MoveError.noAvailableDay
            }
            destinationDate = availableDay
            changes = [Change(id: sourceID, date: availableDay)]
            return
        }
        let sourceDay = calendar.startOfDay(for: sourceDate)
        guard sourceDay != destinationDay else {
            destinationDate = destinationDay
            changes = []
            return
        }

        let sourceOccupants = slots.filter { $0.date.map { calendar.isDate($0, inSameDayAs: sourceDay) } ?? false }
        let destinationOccupants = slots.filter { $0.date.map { calendar.isDate($0, inSameDayAs: destinationDay) } ?? false }
        guard sourceOccupants.count == 1, destinationOccupants.count <= 1 else {
            throw MoveError.multipleVideosOnDay
        }

        // Published videos are fixed, including when another video is dropped on them.
        if destinationOccupants.first?.isPublished == true {
            guard let availableDay = Self.nearestAvailableDay(to: destinationDay, slots: slots, calendar: calendar) else {
                throw MoveError.noAvailableDay
            }
            destinationDate = availableDay
            changes = [Change(id: sourceID, date: availableDay)]
            return
        }
        destinationDate = destinationDay

        var moves = [Change(id: sourceID, date: destinationDay)]
        if let occupant = destinationOccupants.first {
            moves.append(Change(id: occupant.id, date: sourceDay))
        }
        changes = moves
    }

    private static func nearestAvailableDay(to day: Date, slots: [VideoCalendarSlot], calendar: Calendar) -> Date? {
        let occupied = Set(slots.compactMap(\.date).map { calendar.startOfDay(for: $0) })
        let daysInMonth = calendar.range(of: .day, in: .month, for: day)?.count ?? 31
        for distance in 0..<daysInMonth {
            // Equal distances favor the later day. Keep placement inside the visible month.
            for offset in distance == 0 ? [0] : [distance, -distance] {
                guard let candidate = calendar.date(byAdding: .day, value: offset, to: day),
                      calendar.isDate(candidate, equalTo: day, toGranularity: .month),
                      !occupied.contains(candidate) else { continue }
                return candidate
            }
        }
        return nil
    }
}
