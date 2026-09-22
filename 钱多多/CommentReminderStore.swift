import CoreData
import CryptoKit
import Foundation

@MainActor
enum CommentReminderStore {
    static func eventID(for record: AdRecord) -> String? {
        guard let publishedAt = record.publishedDate, record.isAssignedToVideo else { return nil }
        if let id = record.commentReminderID, !id.isEmpty { return id }
        // Object URIs differ between shared stores. Legacy IDs use shared values.
        let scope = record.syncSpace?.id?.uuidString ?? "legacy"
        let dateKey = record.publishDate.map { String(dayOnly($0).timeIntervalSinceReferenceDate) } ?? "pending"
        let source = "\(scope)|\(record.videoTitle.nonEmptyOr("未命名视频"))|\(dateKey)|\(publishedAt.timeIntervalSinceReferenceDate)"
        return "legacy-" + SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func events(from records: [AdRecord]) -> [CommentReminderEvent] {
        let grouped = Dictionary(grouping: records.filter { eventID(for: $0) != nil }) { eventID(for: $0)! }
        return grouped.compactMap { id, records in
            guard let record = records.sorted(by: { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }).first,
                  let publishedAt = record.publishedDate else { return nil }
            return CommentReminderEvent(
                id: id, videoName: record.videoTitle.nonEmptyOr("未命名视频"),
                videoDate: record.publishDate.map(dayOnly), publishedAt: publishedAt,
                completedAt: records.compactMap(\.brandCommentedAt).max()
            )
        }.sorted { $0.fireDate < $1.fireDate }
    }

    static func records(in context: NSManagedObjectContext) throws -> [AdRecord] {
        let request = AdRecord.fetchRequest()
        request.predicate = NSPredicate(format: "dueDate != nil")
        return try context.fetch(request)
    }
}
