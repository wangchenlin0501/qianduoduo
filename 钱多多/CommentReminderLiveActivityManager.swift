import ActivityKit
import Foundation
import UIKit

nonisolated struct CommentReminderActivityInfo: Sendable {
    let id: String
    let videoName: String
    let publishedAt: Date
    let fireDate: Date
}

@MainActor
final class CommentReminderLiveActivityManager {
    static let shared = CommentReminderLiveActivityManager()

    private(set) var lastError: String?
    private var reconciliationGeneration = 0

    private init() {}

    func reconcile(reminders: [CommentReminderActivityInfo]) async {
        reconciliationGeneration += 1
        let generation = reconciliationGeneration
        let enabled = UserDefaults.standard.object(forKey: "commentReminderLiveActivitiesEnabled") as? Bool ?? true
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endAll()
            return
        }

        lastError = nil
        let remindersByID = Dictionary(reminders.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        var existingIDs = Set<String>()

        for activity in Activity<CommentReminderAttributes>.activities {
            guard generation == reconciliationGeneration else { return }
            let id = activity.attributes.videoID
            guard let reminder = remindersByID[id], !existingIDs.contains(id) else {
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            guard activity.activityState == .active || activity.activityState == .stale else { continue }
            existingIDs.insert(id)
            let state = contentState(for: reminder)
            if activity.content.state != state || activity.content.staleDate != reminder.fireDate {
                await activity.update(ActivityContent(state: state, staleDate: reminder.fireDate))
            }
        }

        guard generation == reconciliationGeneration,
              UIApplication.shared.applicationState == .active else { return }

        // Background sync can update/end existing activities. iOS only permits
        // this app to start a new local Live Activity while it is foregrounded.
        for reminder in reminders.sorted(by: { $0.fireDate < $1.fireDate })
        where reminder.fireDate > Date() && !existingIDs.contains(reminder.id) {
            do {
                let attributes = CommentReminderAttributes(videoID: reminder.id)
                let content = ActivityContent(state: contentState(for: reminder), staleDate: reminder.fireDate)
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
                existingIDs.insert(reminder.id)
            } catch {
                lastError = "实时活动未能开启：\(error.localizedDescription)"
            }
        }
    }

    func endAll() async {
        reconciliationGeneration += 1
        let generation = reconciliationGeneration
        lastError = nil
        for activity in Activity<CommentReminderAttributes>.activities {
            guard generation == reconciliationGeneration else { return }
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func contentState(for reminder: CommentReminderActivityInfo) -> CommentReminderAttributes.ContentState {
        CommentReminderAttributes.ContentState(
            videoName: reminder.videoName,
            publishedAt: reminder.publishedAt,
            fireDate: reminder.fireDate
        )
    }
}
