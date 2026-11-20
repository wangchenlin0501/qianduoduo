import CoreData
import Foundation
import Testing
@testable import 钱多多

/// Imports run while other screens may hold unsaved edits in the view context.
/// Uses a real SQLite file so the import context and the view context share an on-disk store.
@MainActor
struct BackupImportIsolationTests {
    @Test func aRejectedBackupKeepsUnsavedEditsElsewhere() throws {
        let stack = try Stack()
        defer { stack.close() }
        let context = stack.persistence.container.viewContext
        let record = AdRecord(context: context)
        record.id = UUID()
        record.brandName = "已保存品牌"
        try context.save()
        record.brandName = "正在编辑的品牌"

        let invalid = try Self.backup(recordID: "not-a-uuid")
        #expect(throws: BackupImportError.invalidRecordID) {
            try importRecords(data: invalid, context: context, persistence: stack.persistence)
        }
        #expect(context.hasChanges)
        #expect(record.brandName == "正在编辑的品牌")
    }

    @Test func aSuccessfulImportNeitherCommitsNorDropsUnsavedEditsAndUsesTheExistingSpace() throws {
        let stack = try Stack()
        defer { stack.close() }
        let context = stack.persistence.container.viewContext
        let space = try stack.persistence.activeSyncSpace(in: context)
        let record = AdRecord(context: context)
        record.id = UUID()
        record.brandName = "已保存品牌"
        record.syncSpace = space
        try context.save()
        record.brandName = "正在编辑的品牌"

        let importedID = UUID()
        let summary = try importRecords(data: try Self.backup(recordID: importedID.uuidString),
                                        context: context, persistence: stack.persistence)

        #expect(summary.importedCount == 1)
        #expect(context.hasChanges)
        #expect(record.brandName == "正在编辑的品牌")
        let verifier = stack.freshContext()
        let stored = try #require(try verifier.existingObject(with: record.objectID) as? AdRecord)
        #expect(stored.brandName == "已保存品牌")
        #expect(try verifier.fetch(SyncSpace.fetchRequest()).count == 1)

        let request = AdRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", importedID as CVarArg)
        let imported = try #require(try context.fetch(request).first)
        #expect(imported.syncSpace == space)
    }

    @Test func anUnsavedNewDataSpaceBlocksTheImportInsteadOfCreatingASecondSpace() throws {
        let stack = try Stack()
        defer { stack.close() }
        let context = stack.persistence.container.viewContext
        let pendingSpace = try stack.persistence.activeSyncSpace(in: context)
        #expect(pendingSpace.objectID.isTemporaryID)

        let data = try Self.backup(recordID: UUID().uuidString)
        #expect(throws: BackupImportError.unsavedDataSpace) {
            try importRecords(data: data, context: context, persistence: stack.persistence)
        }
        let verifier = stack.freshContext()
        #expect(try verifier.fetch(SyncSpace.fetchRequest()).isEmpty)
        #expect(try verifier.fetch(AdRecord.fetchRequest()).isEmpty)
        #expect(context.insertedObjects.contains(pendingSpace))
    }

    private static func backup(recordID: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "records": [["id": recordID, "brandName": "备份品牌", "adFee": 100.0, "lookNumber": 1, "paidAmount": 0]],
            "followerSnapshots": []
        ] as [String: Any])
    }

    @MainActor
    private final class Stack {
        let persistence: PersistenceController
        private let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BackupImportIsolation-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            persistence = PersistenceController(location: .localFile(directory.appendingPathComponent("QianDuoDuo.sqlite")))
            try #require(persistence.loadState.isReady)
        }

        func freshContext() -> NSManagedObjectContext {
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = persistence.container.persistentStoreCoordinator
            return context
        }

        func close() {
            persistence.container.viewContext.rollback()
            persistence.container.viewContext.reset()
            let coordinator = persistence.container.persistentStoreCoordinator
            for store in coordinator.persistentStores { try? coordinator.remove(store) }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
