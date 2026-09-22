import Foundation

nonisolated struct CommentReminderEvent: Identifiable, Equatable, Sendable {
    let id: String
    let videoName: String
    let videoDate: Date?
    let publishedAt: Date
    let completedAt: Date?
    var fireDate: Date { publishedAt.addingTimeInterval(CommentReminderPlan.delay) }
}

/// Publication data is shared; accepted/delivered notification state is device-local.
nonisolated enum CommentReminderPlan: Equatable {
    static let delay: TimeInterval = 175 * 60
    static let catchUpWindow: TimeInterval = 24 * 60 * 60
    case schedule(Date), keepPending, alreadyHandled, completed, tooOld

    static func decide(event: CommentReminderEvent, now: Date, hasPending: Bool,
                       hasDelivered: Bool, lastScheduledDate: Date?) -> Self {
        if event.completedAt != nil { return .completed }
        if hasDelivered { return .alreadyHandled }
        if hasPending { return .keepPending }
        if event.fireDate > now { return .schedule(event.fireDate) }
        // A past accepted request may have been dismissed or silenced by iOS.
        // Its absence from Notification Center is not permission to notify again.
        if let lastScheduledDate, lastScheduledDate <= now { return .alreadyHandled }
        if now.timeIntervalSince(event.fireDate) <= catchUpWindow {
            return .schedule(now.addingTimeInterval(3))
        }
        return .tooOld
    }
}
