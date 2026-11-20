import Foundation

/// A value snapshot keeps the calendar's UIKit cells out of the todo context.
struct VideoCalendarTodo: Identifiable, Equatable {
    let id: String
    let title: String
    let date: Date
    let canEdit: Bool
}

enum VideoCalendarContentLayout {
    static let collapsedTodoLimit = 2
    static let contentTop: CGFloat = 29
    static let videoSlotHeight: CGFloat = 50
    static let gap: CGFloat = 4

    static func todoTop(hasVideo: Bool) -> CGFloat {
        contentTop + (hasVideo ? videoSlotHeight : 0)
    }

    static func weekHeights(days: [Date?], videoDays: Set<Date>, todoCounts: [Date: Int],
                            expandedDays: Set<Date>, minimumHeight: CGFloat,
                            todoHeight: CGFloat) -> [CGFloat] {
        stride(from: 0, to: days.count, by: 7).map { start in
            days[start..<min(start + 7, days.count)].reduce(minimumHeight) { height, day in
                guard let day, let count = todoCounts[day], count > 0 else { return height }
                let visible = expandedDays.contains(day) ? count : min(count, collapsedTodoLimit)
                let controlCount = visible + (count > collapsedTodoLimit ? 1 : 0)
                let needed = todoTop(hasVideo: videoDays.contains(day))
                    + CGFloat(controlCount) * todoHeight + CGFloat(controlCount - 1) * gap + 6
                return max(height, needed)
            }
        }
    }
}
