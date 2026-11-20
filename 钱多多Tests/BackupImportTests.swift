import CoreData
import Foundation
import ImageIO
import Testing
@testable import 钱多多

@MainActor
struct BackupImportTests {
    @Test func repeatedImportPreservesExistingData() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let recordID = UUID()
        let followerID = UUID()
        let likeID = UUID()
        let data = try backup(recordIDs: [recordID], followerIDs: [followerID], likeIDs: [likeID])
        let first = try importRecords(data: data, context: context, persistence: persistence)
        #expect(first.importedCount == 3)
        #expect(first.skippedCount == 0)

        let record = try #require(context.fetch(AdRecord.fetchRequest()).first)
        let follower = try #require(context.fetch(FollowerSnapshot.fetchRequest()).first)
        let like = try #require(context.fetch(VideoLikeSnapshot.fetchRequest()).first)
        record.brandName = "导入后修改的品牌"
        record.adFee = 789.12
        record.photoData = Data([1, 2, 3])
        follower.followerCount = 2_000
        like.likeCount = 300
        try context.save()

        // UUID text casing must not make a repeated backup look new.
        var repeatedJSON = String(decoding: data, as: UTF8.self)
        for id in [recordID, followerID, likeID] {
            repeatedJSON = repeatedJSON.replacingOccurrences(of: id.uuidString, with: id.uuidString.lowercased())
        }
        let repeatedData = Data(repeatedJSON.utf8)
        let repeated = try importRecords(data: repeatedData, context: context, persistence: persistence)
        #expect(repeated.importedCount == 0)
        #expect(repeated.skippedCount == 3)
        #expect(repeated.message.contains("均已存在"))
        #expect(try context.fetch(AdRecord.fetchRequest()).count == 1)
        #expect(try context.fetch(FollowerSnapshot.fetchRequest()).count == 1)
        #expect(try context.fetch(VideoLikeSnapshot.fetchRequest()).count == 1)
        #expect(record.brandName == "导入后修改的品牌")
        #expect(record.adFee == 789.12)
        #expect(record.photoData == Data([1, 2, 3]))
        #expect(follower.followerCount == 2_000)
        #expect(like.likeCount == 300)
    }

    @Test func duplicatesWithinOneBackupAreSkippedPerEntity() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let id = UUID()
        let data = try backup(recordIDs: [id, id], followerIDs: [id, id], likeIDs: [id, id])
        let summary = try importRecords(data: data, context: context, persistence: persistence)
        #expect(summary.importedCount == 3)
        #expect(summary.skippedCount == 3)
        #expect(try context.fetch(AdRecord.fetchRequest()).count == 1)
        #expect(try context.fetch(FollowerSnapshot.fetchRequest()).count == 1)
        #expect(try context.fetch(VideoLikeSnapshot.fetchRequest()).count == 1)
    }

    @Test func mixedBackupImportsOnlyNewIDs() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let oldID = UUID()
        let newID = UUID()
        _ = try importRecords(
            data: backup(recordIDs: [oldID], followerIDs: [oldID], likeIDs: [oldID]),
            context: context, persistence: persistence
        )
        let summary = try importRecords(
            data: backup(recordIDs: [oldID, newID], followerIDs: [oldID, newID], likeIDs: [oldID, newID]),
            context: context, persistence: persistence
        )
        #expect(summary.importedCount == 3)
        #expect(summary.skippedCount == 3)
        // Different IDs remain separate even when every other field is identical.
        #expect(try context.fetch(AdRecord.fetchRequest()).count == 2)
        #expect(try context.fetch(FollowerSnapshot.fetchRequest()).count == 2)
        #expect(try context.fetch(VideoLikeSnapshot.fetchRequest()).count == 2)
    }

    @Test func legacyRecordArrayStillImportsAndDeduplicates() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [record(id), record(id)])
        let first = try importRecords(data: data, context: context, persistence: persistence)
        let second = try importRecords(data: data, context: context, persistence: persistence)
        #expect(first.importedCount == 1)
        #expect(first.skippedCount == 1)
        #expect(second.importedCount == 0)
        #expect(second.skippedCount == 2)
        #expect(try context.fetch(AdRecord.fetchRequest()).count == 1)
    }

    @Test func invalidIDRejectsTheWholeBackup() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let data = try JSONSerialization.data(withJSONObject: [
            "records": [record(UUID())],
            "followerSnapshots": [],
            "videoLikeSnapshots": [["id": "invalid-id", "likeCount": 10]]
        ] as [String: Any])
        do {
            _ = try importRecords(data: data, context: context, persistence: persistence)
            Issue.record("Invalid IDs must not be replaced by random UUIDs")
        } catch {
            #expect(try context.fetch(AdRecord.fetchRequest()).isEmpty)
            #expect(try context.fetch(FollowerSnapshot.fetchRequest()).isEmpty)
            #expect(try context.fetch(VideoLikeSnapshot.fetchRequest()).isEmpty)
        }
    }

    @Test func emptyBackupIsSuccessfulWithoutCreatingASyncSpace() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let summary = try importRecords(
            data: backup(recordIDs: []), context: context, persistence: persistence
        )
        #expect(summary.importedCount == 0)
        #expect(summary.skippedCount == 0)
        #expect(summary.message == "备份中没有可导入的记录。")
        #expect(try context.fetch(SyncSpace.fetchRequest()).isEmpty)
    }

    @Test func exportedFileRestoresEveryFieldAndScreenshotExactly() throws {
        let source = PersistenceController(inMemory: true)
        let sourceContext = source.container.viewContext
        let instant = Date(timeIntervalSinceReferenceDate: 810_123_456.123456)
        let imageData = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
        ))
        let record = AdRecord(context: sourceContext)
        record.setValuesForKeys([
            "id": UUID(), "brandName": "完整备份测试", "contactWeChat": "test-contact",
            "platform": "衣服", "productCode": "寄拍", "clothingName": "历史衣服名称",
            "adFee": 12_345.67, "lookNumber": Int16(3), "videoTitle": "测试视频",
            "paymentStatus": "已打款", "paymentAccount": "微信", "paymentNote": "测试备注",
            "paidAmount": 12_345.67, "poolOrder": 101.25, "videoOrder": 202.75,
            "createdAt": instant, "updatedAt": instant.addingTimeInterval(0.125),
            "publishDate": instant.addingTimeInterval(1), "dueDate": instant.addingTimeInterval(2),
            "paidDate": instant.addingTimeInterval(3), "arrivalDate": instant.addingTimeInterval(4),
            "commentReminderID": "test-publication", "brandCommentedAt": instant.addingTimeInterval(5),
            "photoData": imageData
        ])
        let follower = FollowerSnapshot(context: sourceContext)
        follower.setValuesForKeys([
            "id": UUID(), "date": instant, "followerCount": Int64(9_876),
            "createdAt": instant.addingTimeInterval(0.25), "updatedAt": instant.addingTimeInterval(0.5)
        ])
        let like = VideoLikeSnapshot(context: sourceContext)
        like.setValuesForKeys([
            "id": UUID(), "videoName": "测试视频", "videoDate": instant.addingTimeInterval(1),
            "publishedDate": instant.addingTimeInterval(2), "recordedAt": instant.addingTimeInterval(60),
            "likeCount": Int64(654), "createdAt": instant.addingTimeInterval(0.75),
            "updatedAt": instant.addingTimeInterval(0.875)
        ])
        try sourceContext.save()
        let exported = try #require(exportRecords(context: sourceContext))
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("qdd-roundtrip-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try exported.write(to: fileURL)

        let destination = PersistenceController(inMemory: true)
        let destinationContext = destination.container.viewContext
        let summary = try importRecords(
            data: Data(contentsOf: fileURL), context: destinationContext, persistence: destination
        )
        #expect(summary.importedCount == 3)
        let restoredRecord = try #require(destinationContext.fetch(AdRecord.fetchRequest()).first)
        let restoredFollower = try #require(destinationContext.fetch(FollowerSnapshot.fetchRequest()).first)
        let restoredLike = try #require(destinationContext.fetch(VideoLikeSnapshot.fetchRequest()).first)
        for (original, restored) in [(record as NSManagedObject, restoredRecord as NSManagedObject),
                                     (follower as NSManagedObject, restoredFollower as NSManagedObject),
                                     (like as NSManagedObject, restoredLike as NSManagedObject)] {
            for key in original.entity.attributesByName.keys {
                let expected = original.value(forKey: key) as? NSObject
                let actual = restored.value(forKey: key) as? NSObject
                #expect(actual == expected, "Restored attribute differs: \(key)")
            }
        }
        let restoredImage = try #require(restoredRecord.photoData)
        #expect(restoredImage == imageData)
        let imageSource = try #require(CGImageSourceCreateWithData(restoredImage as CFData, nil))
        #expect(CGImageSourceGetCount(imageSource) == 1)
        #expect(CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil)
        #expect(exportRecords(context: destinationContext) == exported)

        let repeated = try importRecords(data: exported, context: destinationContext, persistence: destination)
        #expect(repeated.importedCount == 0)
        #expect(repeated.skippedCount == 3)
        #expect(restoredRecord.photoData == imageData)
    }

    @Test func oldBundleWithoutScreenshotsStillRestoresDates() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        var oldRecord = record(UUID())
        oldRecord["createdAt"] = "2026-10-17T08:30:00Z"
        let data = try JSONSerialization.data(withJSONObject: [
            "records": [oldRecord], "followerSnapshots": []
        ] as [String: Any])
        let summary = try importRecords(data: data, context: context, persistence: persistence)
        let restored = try #require(context.fetch(AdRecord.fetchRequest()).first)
        #expect(summary.importedCount == 1)
        #expect(restored.createdAt == ISO8601DateFormatter().date(from: "2026-10-17T08:30:00Z"))
        #expect(restored.photoData == nil)
    }

    @Test func unsupportedBackupVersionDoesNotImportAnything() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let data = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 999, "records": [record(UUID())], "followerSnapshots": []
        ] as [String: Any])
        do {
            _ = try importRecords(data: data, context: context, persistence: persistence)
            Issue.record("Unknown backup versions must be rejected")
        } catch {
            #expect(try context.fetch(AdRecord.fetchRequest()).isEmpty)
        }
    }

    @Test func todoBackupRoundTripPreservesContentDatesCompletionAndOrder() throws {
        let source = PersistenceController(inMemory: true)
        let context = source.container.viewContext
        let instant = Date(timeIntervalSinceReferenceDate: 810_456_789.123456)
        let completed = TodoItem(context: context)
        completed.id = UUID()
        completed.title = "开票\n核对金额"
        completed.notes = "保留空格  和备注\n下一行"
        completed.createdAt = instant
        completed.updatedAt = instant.addingTimeInterval(0.125)
        completed.completedAt = instant.addingTimeInterval(0.25)
        completed.dueDate = instant.addingTimeInterval(0.5)
        completed.sortOrder = 42.75
        let pending = TodoItem(context: context)
        pending.id = UUID()
        pending.title = "待处理事项"
        pending.sortOrder = -3.5
        try context.save()

        let exported = try #require(exportRecords(context: context))
        let decoder = JSONDecoder()
        let bundle = try decoder.decode(ExportDataBundle.self, from: exported)
        #expect(bundle.formatVersion == 4)
        #expect(bundle.todoItems?.count == 2)
        #expect(bundle.todoItems?.first?.id == pending.id?.uuidString)

        let destination = PersistenceController(inMemory: true)
        let destinationContext = destination.container.viewContext
        let summary = try importRecords(data: exported, context: destinationContext, persistence: destination)
        #expect(summary.importedCount == 2)
        #expect(summary.skippedCount == 0)
        let restored = try destinationContext.fetch(TodoItem.fetchRequest())
        for original in [completed, pending] {
            let copy = try #require(restored.first { $0.id == original.id })
            for key in original.entity.attributesByName.keys {
                #expect(copy.value(forKey: key) as? NSObject == original.value(forKey: key) as? NSObject,
                        "Restored todo attribute differs: \(key)")
            }
            #expect(copy.syncSpace != nil)
            #expect(copy.objectID.persistentStore == copy.syncSpace?.objectID.persistentStore)
        }
        #expect(exportRecords(context: destinationContext) == exported)
    }

    @Test func duplicateTodoIDsDoNotOverwriteLocalEditsOrCompletion() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let id = UUID()
        let newID = UUID()
        let firstData = try todoBackup(items: [todo(id)])
        _ = try importRecords(data: firstData, context: context, persistence: persistence)
        let item = try #require(context.fetch(TodoItem.fetchRequest()).first)
        let completedAt = Date(timeIntervalSinceReferenceDate: 810_000_000.125)
        item.title = "本机修改后的标题"
        item.notes = "本机备注"
        item.completedAt = completedAt
        item.sortOrder = 19.25
        try context.save()
        var duplicate = todo(id)
        duplicate["id"] = id.uuidString.lowercased()
        let data = try todoBackup(items: [duplicate, todo(newID), todo(newID)])
        let summary = try importRecords(data: data, context: context, persistence: persistence)
        #expect(summary.importedCount == 1)
        #expect(summary.skippedCount == 2)
        #expect(try context.fetch(TodoItem.fetchRequest()).count == 2)
        #expect(item.title == "本机修改后的标题")
        #expect(item.notes == "本机备注")
        #expect(item.completedAt == completedAt)
        #expect(item.sortOrder == 19.25)

        let repeated = try importRecords(data: data, context: context, persistence: persistence)
        #expect(repeated.importedCount == 0)
        #expect(repeated.skippedCount == 3)
    }

    @Test func invalidTodoIDRejectsMixedBackupBeforeInsertingAnything() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        var invalid = todo(UUID())
        invalid["id"] = "invalid-todo-id"
        let data = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 3,
            "records": [record(UUID())],
            "followerSnapshots": [],
            "todoItems": [todo(UUID()), invalid]
        ] as [String: Any])
        do {
            _ = try importRecords(data: data, context: context, persistence: persistence)
            Issue.record("An invalid todo ID must reject the complete backup")
        } catch {
            #expect(try context.fetch(AdRecord.fetchRequest()).isEmpty)
            #expect(try context.fetch(TodoItem.fetchRequest()).isEmpty)
            #expect(try context.fetch(SyncSpace.fetchRequest()).isEmpty)
        }
    }

    @Test func versionTwoBackupWithoutTodosStillImportsWithoutTouchingTodos() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let todo = TodoItem(context: context)
        todo.id = UUID()
        todo.title = "保留已有待办"
        try context.save()
        var legacyRecord = record(UUID())
        legacyRecord["createdAt"] = 810_000_000.125
        let data = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 2, "records": [legacyRecord], "followerSnapshots": []
        ] as [String: Any])
        let summary = try importRecords(data: data, context: context, persistence: persistence)
        #expect(summary.importedCount == 1)
        #expect(try context.fetch(TodoItem.fetchRequest()).count == 1)
        #expect(todo.title == "保留已有待办")
        let restored = try #require(context.fetch(AdRecord.fetchRequest()).first)
        #expect(restored.createdAt == Date(timeIntervalSinceReferenceDate: 810_000_000.125))
    }

    @Test func contentAssociationSurvivesBackupAndOlderTodoBackupsRemainCompatible() throws {
        let source = PersistenceController(inMemory: true)
        let context = source.container.viewContext
        let space = try source.activeSyncSpace(in: context)
        let record = AdRecord(context: context)
        record.id = UUID()
        record.brandName = "关联品牌"
        record.syncSpace = space
        let todo = TodoItem(context: context)
        todo.id = UUID()
        todo.title = "跟进寄样"
        todo.syncSpace = space
        let link = TodoContentLink(kind: .pool, recordIDs: [try #require(record.id)], fallbackTitle: "关联品牌")
        todo.linkedContent = link.encodedValue
        try context.save()
        let exported = try #require(exportRecords(context: context))
        let destination = PersistenceController(inMemory: true)
        let restoredContext = destination.container.viewContext
        let summary = try importRecords(data: exported, context: restoredContext, persistence: destination)
        #expect(summary.importedCount == 2)
        let restoredTodo = try #require(restoredContext.fetch(TodoItem.fetchRequest()).first)
        let restoredRecords = try restoredContext.fetch(AdRecord.fetchRequest())
        #expect(restoredTodo.contentLink == link)
        #expect(link.resolvedRecords(in: restoredRecords).first?.id == record.id)
        #expect(restoredRecords.first?.syncSpace == restoredTodo.syncSpace)
        let oldSummary = try importRecords(data: todoBackup(items: [self.todo(UUID())]),
                                           context: restoredContext, persistence: destination)
        #expect(oldSummary.importedCount == 1)
        #expect(try restoredContext.fetch(TodoItem.fetchRequest()).filter { $0.linkedContent == nil }.count == 1)
    }

    private func todo(_ id: UUID) -> [String: Any] {
        ["id": id.uuidString, "title": "测试待办", "notes": "测试备注", "sortOrder": 1.25]
    }

    private func todoBackup(items: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "formatVersion": 3, "records": [], "followerSnapshots": [], "todoItems": items
        ] as [String: Any])
    }

    private func record(_ id: UUID) -> [String: Any] {
        ["id": id.uuidString, "brandName": "测试品牌", "adFee": 123.45,
         "lookNumber": 1, "paidAmount": 0]
    }

    private func backup(
        recordIDs: [UUID], followerIDs: [UUID] = [], likeIDs: [UUID] = []
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "records": recordIDs.map { record($0) },
            "followerSnapshots": followerIDs.map { ["id": $0.uuidString, "followerCount": 1_000] },
            "videoLikeSnapshots": likeIDs.map { ["id": $0.uuidString, "likeCount": 100] }
        ] as [String: Any])
    }
}
