import CoreData
import Foundation
import Testing
@testable import 钱多多

@MainActor
struct TodoModelMigrationTests {
    @Test func existingV3DatabaseMigratesToV4WithoutLosingBusinessDataOrAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("migration.sqlite")
        let recordID = UUID()
        let spaceID = UUID()
        let picture = Data((0..<20_003).map { UInt8($0 % 241) })
        let date = Date(timeIntervalSince1970: 1_792_500_000)
        let audio = Data((0..<30_007).map { UInt8($0 % 239) })
        let old = try Stack(model: model(named: "QianDuoDuoV3"), url: url)
        let space = old.insert("SyncSpace")
        space.setValuesForKeys(["id": spaceID, "name": "迁移前共享空间", "createdAt": date, "updatedAt": date, "celebrationSoundData": audio])
        let record = old.insert("AdRecord")
        record.setValuesForKeys([
            "id": recordID, "brandName": "保留合作记录", "adFee": 1234.56,
            "photoData": picture, "createdAt": date, "syncSpace": space
        ])
        let follower = old.insert("FollowerSnapshot")
        follower.setValuesForKeys(["id": UUID(), "followerCount": Int64(123), "date": date, "syncSpace": space])
        let like = old.insert("VideoLikeSnapshot")
        like.setValuesForKeys(["id": UUID(), "likeCount": Int64(456), "videoName": "保留视频", "syncSpace": space])
        try old.context.save()
        try old.close()

        let migrated = try Stack(model: model(named: "QianDuoDuoV4"), url: url)
        let restoredSpace = try #require(migrated.fetch("SyncSpace").first)
        let restoredRecord = try #require(migrated.fetch("AdRecord").first)
        #expect(restoredSpace.value(forKey: "id") as? UUID == spaceID)
        #expect(restoredSpace.value(forKey: "name") as? String == "迁移前共享空间")
        #expect(restoredSpace.value(forKey: "celebrationSoundData") as? Data == audio)
        #expect(try migrated.fetch("TodoItem").isEmpty)
        #expect(restoredRecord.value(forKey: "id") as? UUID == recordID)
        #expect(restoredRecord.value(forKey: "brandName") as? String == "保留合作记录")
        #expect(restoredRecord.value(forKey: "adFee") as? Double == 1234.56)
        #expect(restoredRecord.value(forKey: "photoData") as? Data == picture)
        #expect(restoredRecord.value(forKey: "syncSpace") as? NSManagedObject === restoredSpace)
        #expect(try migrated.fetch("FollowerSnapshot").first?.value(forKey: "followerCount") as? Int64 == 123)
        #expect(try migrated.fetch("VideoLikeSnapshot").first?.value(forKey: "likeCount") as? Int64 == 456)

        let todo = migrated.insert("TodoItem")
        let todoID = UUID()
        todo.setValuesForKeys(["id": todoID, "title": "迁移后新建", "sortOrder": 1.0,
                               "createdAt": date, "syncSpace": restoredSpace])
        try migrated.context.save()
        #expect(try migrated.fetch("TodoItem").first?.value(forKey: "id") as? UUID == todoID)
        #expect(restoredSpace.value(forKey: "celebrationSoundData") as? Data == audio)
        #expect((restoredSpace.entity.attributesByName["celebrationSoundData"])?.allowsExternalBinaryDataStorage == true)
        #expect((restoredSpace.value(forKey: "todoItems") as? Set<NSManagedObject>)?.contains(todo) == true)
        try migrated.close()
    }

    @Test func existingV4DatabaseMigratesToV5PreservingTodosAndBusinessData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("v4-v5.sqlite")
        let date = Date(timeIntervalSinceReferenceDate: 810_000_000.123456)
        let id = UUID()
        let old = try Stack(model: model(named: "QianDuoDuoV4"), url: url)
        let space = old.insert("SyncSpace")
        let audio = Data([1, 3, 5, 7])
        space.setValuesForKeys(["id": UUID(), "name": "已有共享空间", "createdAt": date, "celebrationSoundData": audio])
        let record = old.insert("AdRecord")
        let recordID = UUID()
        record.setValuesForKeys(["id": recordID, "brandName": "原有合作", "syncSpace": space])
        let todo = old.insert("TodoItem")
        todo.setValuesForKeys(["id": id, "title": "原有待办", "notes": "保留备注", "createdAt": date,
                               "updatedAt": date, "dueDate": date, "completedAt": date, "sortOrder": 3.75,
                               "syncSpace": space])
        try old.context.save()
        try old.close()
        let migrated = try Stack(model: model(named: "QianDuoDuoV5"), url: url)
        let restored = try #require(migrated.fetch("TodoItem").first)
        #expect(restored.value(forKey: "id") as? UUID == id)
        #expect(restored.value(forKey: "title") as? String == "原有待办")
        #expect(restored.value(forKey: "notes") as? String == "保留备注")
        #expect(restored.value(forKey: "dueDate") as? Date == date)
        #expect(restored.value(forKey: "completedAt") as? Date == date)
        #expect(restored.value(forKey: "sortOrder") as? Double == 3.75)
        #expect(restored.value(forKey: "linkedContent") == nil)
        let restoredSpace = try #require(migrated.fetch("SyncSpace").first)
        #expect(restored.value(forKey: "syncSpace") as? NSManagedObject === restoredSpace)
        #expect(restoredSpace.value(forKey: "celebrationSoundData") as? Data == audio)
        let restoredRecord = try #require(migrated.fetch("AdRecord").first)
        #expect(restoredRecord.value(forKey: "id") as? UUID == recordID)
        let link = TodoContentLink(kind: .pool, recordIDs: [recordID], fallbackTitle: "原有合作")
        restored.setValue(link.encodedValue, forKey: "linkedContent")
        try migrated.context.save()
        try migrated.close()
        let reloaded = try Stack(model: model(named: "QianDuoDuoV5"), url: url)
        #expect(TodoContentLink.decode(try reloaded.fetch("TodoItem").first?.value(forKey: "linkedContent") as? String) == link)
        try reloaded.close()
    }

    private func model(named name: String) throws -> NSManagedObjectModel {
        #if SWIFT_PACKAGE
        let url = Bundle.module.resourceURL?.appendingPathComponent("Resources/\(name).mom")
        #else
        let url = Bundle.main.url(forResource: "QianDuoDuo", withExtension: "momd")?
            .appendingPathComponent("\(name).mom")
        #endif
        let model = try #require(url.flatMap(NSManagedObjectModel.init(contentsOf:)))
        // Use generic objects so the old schema can be exercised alongside the current one.
        for entity in model.entities { entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self) }
        return model
    }

    private final class Stack {
        let coordinator: NSPersistentStoreCoordinator
        let context: NSManagedObjectContext

        init(model: NSManagedObjectModel, url: URL) throws {
            coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType, configurationName: nil, at: url,
                options: [NSMigratePersistentStoresAutomaticallyOption: true,
                          NSInferMappingModelAutomaticallyOption: true]
            )
            context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
        }

        func insert(_ name: String) -> NSManagedObject {
            NSEntityDescription.insertNewObject(forEntityName: name, into: context)
        }

        func fetch(_ name: String) throws -> [NSManagedObject] {
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: name))
        }

        func close() throws {
            context.reset()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
    }
}
