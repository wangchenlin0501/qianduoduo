import CoreData
import Foundation
import Testing
@testable import 钱多多

@MainActor
struct CelebrationSoundModelMigrationTests {
    @Test func existingV2DatabaseMigratesToV3WithoutLosingBusinessData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("migration.sqlite")
        let recordID = UUID()
        let spaceID = UUID()
        let picture = Data((0..<20_003).map { UInt8($0 % 241) })
        let date = Date(timeIntervalSince1970: 1_792_500_000)
        let old = try Stack(model: model(named: "QianDuoDuoV2"), url: url)
        let space = old.insert("SyncSpace")
        space.setValuesForKeys(["id": spaceID, "name": "迁移前共享空间", "createdAt": date, "updatedAt": date])
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

        let migrated = try Stack(model: model(named: "QianDuoDuoV3"), url: url)
        let restoredSpace = try #require(migrated.fetch("SyncSpace").first)
        let restoredRecord = try #require(migrated.fetch("AdRecord").first)
        #expect(restoredSpace.value(forKey: "id") as? UUID == spaceID)
        #expect(restoredSpace.value(forKey: "name") as? String == "迁移前共享空间")
        #expect(restoredSpace.value(forKey: "celebrationSoundData") == nil)
        #expect(restoredRecord.value(forKey: "id") as? UUID == recordID)
        #expect(restoredRecord.value(forKey: "brandName") as? String == "保留合作记录")
        #expect(restoredRecord.value(forKey: "adFee") as? Double == 1234.56)
        #expect(restoredRecord.value(forKey: "photoData") as? Data == picture)
        #expect(restoredRecord.value(forKey: "syncSpace") as? NSManagedObject === restoredSpace)
        #expect(try migrated.fetch("FollowerSnapshot").first?.value(forKey: "followerCount") as? Int64 == 123)
        #expect(try migrated.fetch("VideoLikeSnapshot").first?.value(forKey: "likeCount") as? Int64 == 456)

        let repository = PublishCelebrationSoundSync(
            context: migrated.context, activeSpace: { restoredSpace }, existingSpace: { restoredSpace },
            canUpdate: { _ in true }, legacyStorage: nil
        )
        let audio = Data([30, 40, 50, 60])
        try repository.saveRecording(data: audio)
        #expect(try repository.selectedRecordingData() == audio)
        #expect(restoredRecord.value(forKey: "photoData") as? Data == picture)
        #expect((restoredSpace.entity.attributesByName["celebrationSoundData"])?.allowsExternalBinaryDataStorage == true)
        try migrated.close()
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
