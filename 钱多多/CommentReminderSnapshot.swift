import CryptoKit
import Foundation

/// Only reminder metadata crosses from the database queue to the UI actor.
nonisolated struct CommentReminderRecordSnapshot: Sendable {
    let reminderID: String?
    let spaceID: UUID?
    let videoName: String?
    let videoDate: Date?
    let publishedAt: Date?
    let updatedAt: Date?
    let completedAt: Date?
}

nonisolated enum CommentReminderSnapshot {
    static func events(from snapshots: [CommentReminderRecordSnapshot], calendar: Calendar) -> [CommentReminderEvent] {
        var groups: [String: [CommentReminderRecordSnapshot]] = [:]
        for snapshot in snapshots {
            guard let publishedAt = snapshot.publishedAt else { continue }
            let title = snapshot.videoName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty || snapshot.videoDate != nil else { continue }
            let id: String
            if let reminderID = snapshot.reminderID, !reminderID.isEmpty {
                id = reminderID
            } else {
                let scope = snapshot.spaceID?.uuidString ?? "legacy"
                let dateKey = snapshot.videoDate.map {
                    String(calendar.startOfDay(for: $0).timeIntervalSinceReferenceDate)
                } ?? "pending"
                let name = title.isEmpty ? "未命名视频" : title
                let source = "\(scope)|\(name)|\(dateKey)|\(publishedAt.timeIntervalSinceReferenceDate)"
                id = "legacy-" + SHA256.hash(data: Data(source.utf8))
                    .map { String(format: "%02x", $0) }.joined()
            }
            groups[id, default: []].append(snapshot)
        }
        return groups.compactMap { id, records in
            guard let latest = records.sorted(by: {
                ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }).first, let publishedAt = latest.publishedAt else { return nil }
            let title = latest.videoName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CommentReminderEvent(
                id: id, videoName: title.isEmpty ? "未命名视频" : title,
                videoDate: latest.videoDate.map { calendar.startOfDay(for: $0) },
                publishedAt: publishedAt, completedAt: records.compactMap(\.completedAt).max()
            )
        }.sorted { $0.fireDate < $1.fireDate }
    }
}
