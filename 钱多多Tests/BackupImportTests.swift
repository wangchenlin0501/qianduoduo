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
