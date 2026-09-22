import Foundation

// Run without a simulator:
// swiftc 钱多多/CommentReminderPlan.swift scripts/verify-comment-reminders.swift -o /tmp/qdd-reminder-check
@main
struct VerifyCommentReminders {
    static func main() {
        let publication = Date(timeIntervalSince1970: 1_788_666_000)
        let event = CommentReminderEvent(id: "publication-1", videoName: "鞋靴分享", videoDate: nil,
                                         publishedAt: publication, completedAt: nil)
        let due = publication.addingTimeInterval(10_500)
        func plan(_ now: Date, pending: Bool = false, delivered: Bool = false, scheduled: Date? = nil) -> CommentReminderPlan {
            CommentReminderPlan.decide(event: event, now: now, hasPending: pending,
                                       hasDelivered: delivered, lastScheduledDate: scheduled)
        }
        precondition(event.fireDate == due, "2h55 must mean 10,500 elapsed seconds")
        precondition(plan(publication) == .schedule(due))
        precondition(plan(publication.addingTimeInterval(60), pending: true, scheduled: due) == .keepPending,
                     "Repeated sync must not move the timer")
        precondition(plan(publication.addingTimeInterval(60)) == .schedule(due),
                     "Another device independently schedules the same publication deadline")
        precondition(plan(due.addingTimeInterval(60)) == .schedule(due.addingTimeInterval(63)),
                     "Late first sync should catch up once")
        precondition(plan(due.addingTimeInterval(60), scheduled: due) == .alreadyHandled,
                     "A dismissed/silenced reminder must not be redelivered")
        precondition(plan(due.addingTimeInterval(60), delivered: true) == .alreadyHandled)
        precondition(plan(due.addingTimeInterval(86_401)) == .tooOld,
                     "Installing the update must not send all historical video reminders")
        precondition(plan(due.addingTimeInterval(86_400)) == .schedule(due.addingTimeInterval(86_403)))
        precondition(plan(publication.addingTimeInterval(60), scheduled: due) == .schedule(due),
                     "A missing future request must be repaired")
        precondition(plan(due) == .schedule(due.addingTimeInterval(3)))
        let done = CommentReminderEvent(id: event.id, videoName: event.videoName, videoDate: nil,
                                        publishedAt: publication, completedAt: due)
        precondition(CommentReminderPlan.decide(event: done, now: due, hasPending: true,
                                               hasDelivered: true, lastScheduledDate: due) == .completed,
                     "Shared completion must cancel even an existing pending request")
        let renamed = CommentReminderEvent(id: event.id, videoName: "新的名字", videoDate: publication,
                                           publishedAt: publication, completedAt: nil)
        precondition(renamed.id == event.id && renamed.fireDate == event.fireDate)
        let republished = CommentReminderEvent(id: "publication-2", videoName: event.videoName, videoDate: nil,
                                               publishedAt: due, completedAt: nil)
        precondition(CommentReminderPlan.decide(event: republished, now: due, hasPending: false,
                                               hasDelivered: false, lastScheduledDate: nil) == .schedule(due.addingTimeInterval(10_500)))
        let utc = ISO8601DateFormatter()
        let china = utc.date(from: "2026-09-06T15:00:00+08:00")!
        let losAngeles = utc.date(from: "2026-09-06T00:00:00-07:00")!
        precondition(china == losAngeles && china.addingTimeInterval(CommentReminderPlan.delay) == losAngeles.addingTimeInterval(10_500))
        print("Passed 15 checks: independent devices, sync, catch-up, deduplication, completion, republishing, and time zones.")
    }
}
