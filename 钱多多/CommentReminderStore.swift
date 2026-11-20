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

    /// Reconciliation is a read-only snapshot of saved data. User edits stay in their own context.
    static func savedEvents(in container: NSPersistentCloudKitContainer) async throws -> [CommentReminderEvent] {
        let calendar = qddCalendar
        let context = container.newBackgroundContext()
        return try await context.perform {
            context.name = "CommentReminderMetadataRead"
            context.undoManager = nil
            return try projectedEvents(in: context, calendar: calendar)
        }
    }

    nonisolated static func projectedEvents(
        in context: NSManagedObjectContext, calendar: Calendar
    ) throws -> [CommentReminderEvent] {
        let spaceID = NSExpressionDescription()
        spaceID.name = "spaceID"
        spaceID.expression = NSExpression(forKeyPath: "syncSpace.id")
        spaceID.expressionResultType = .UUIDAttributeType
        let request = NSFetchRequest<NSDictionary>(entityName: "AdRecord")
        request.resultType = .dictionaryResultType
        request.predicate = NSPredicate(format: "dueDate != nil")
        request.propertiesToFetch = [
            "commentReminderID", "videoTitle", "publishDate", "dueDate",
            "updatedAt", "brandCommentedAt", spaceID
        ]
        request.includesPendingChanges = false
        // Dictionary projections return metadata values, not batched managed-object faults.
        // fetchBatchSize requires self/objectID and is ignored for this field-only projection.
        let snapshots = try context.fetch(request).map { row in
            CommentReminderRecordSnapshot(
                reminderID: row["commentReminderID"] as? String,
                spaceID: row["spaceID"] as? UUID,
                videoName: row["videoTitle"] as? String,
                videoDate: row["publishDate"] as? Date,
                publishedAt: row["dueDate"] as? Date,
                updatedAt: row["updatedAt"] as? Date,
                completedAt: row["brandCommentedAt"] as? Date
            )
        }
        return CommentReminderSnapshot.events(from: snapshots, calendar: calendar)
    }
}
