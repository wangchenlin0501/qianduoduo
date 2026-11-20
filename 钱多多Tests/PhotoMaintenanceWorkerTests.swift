import CoreData
import Foundation
import Testing
@testable import 钱多多

enum PhotoEncoderOutcome: CaseIterable, Sendable {
    case failure, empty, larger
}

@MainActor
struct PhotoMaintenanceWorkerTests {
    private let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
    /// Back-filled and imported records carry an old month as their creation date.
    private var yearsAgo: Date { startedAt.addingTimeInterval(-3 * 365 * 86_400) }

    @Test func screenshotsOfOldMonthsAreCompressedButNeverCleared() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let oldLarge = fixture.insert(photo: Data(repeating: 1, count: 20), createdAt: yearsAgo)
        let oldSmall = fixture.insert(photo: Data([3, 3]), createdAt: yearsAgo)
        let currentLarge = fixture.insert(photo: Data(repeating: 2, count: 20), createdAt: startedAt)
        try fixture.reader.save()
        let summary = try await PhotoMaintenanceWorker.run(
            coordinator: fixture.coordinator, startedAt: startedAt,
            targetByteCount: 4, batchSize: 1
        ) { data in
            #expect(!Thread.isMainThread)
            let marker = data.first ?? 0
            return Data([marker, marker])
        }
        fixture.reader.refreshAllObjects()
        #expect(Set(summary.compressedObjectIDs) == [oldLarge.objectID, currentLarge.objectID])
        #expect(oldLarge.value(forKey: "photoData") as? Data == Data([1, 1]))
        #expect(oldSmall.value(forKey: "photoData") as? Data == Data([3, 3]))
        #expect(currentLarge.value(forKey: "photoData") as? Data == Data([2, 2]))
        for record in [oldLarge, oldSmall, currentLarge] {
            #expect(record.value(forKey: "brandName") as? String == "原品牌")
        }
    }

    @Test(arguments: PhotoEncoderOutcome.allCases)
    func anUnusableEncodingKeepsTheOriginalScreenshot(_ outcome: PhotoEncoderOutcome) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let photo = Data(repeating: 6, count: 20)
        let record = fixture.insert(photo: photo, createdAt: yearsAgo)
        try fixture.reader.save()
        let summary = try await PhotoMaintenanceWorker.run(
            coordinator: fixture.coordinator, startedAt: startedAt, targetByteCount: 4
        ) { original in
            switch outcome {
            case .failure: return nil
            case .empty: return Data() // Smaller than the original, yet it would erase the image.
            case .larger: return original + Data([0])
            }
        }
        fixture.reader.refreshAllObjects()
        #expect(summary.compressedObjectIDs.isEmpty)
        #expect(record.value(forKey: "photoData") as? Data == photo)
    }

    @Test func skipsEditsMadeAfterSchedulingAndLeavesUnsavedUIChangesAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let photo = Data(repeating: 7, count: 20)
        let recent = fixture.insert(photo: photo, createdAt: yearsAgo)
        recent.setValue(startedAt.addingTimeInterval(1), forKey: "updatedAt")
        let unsaved = fixture.insert(photo: photo, createdAt: yearsAgo)
        try fixture.reader.save()
        unsaved.setValue("正在编辑", forKey: "brandName")
        let summary = try await PhotoMaintenanceWorker.run(
            coordinator: fixture.coordinator, startedAt: startedAt,
            targetByteCount: 4, excluding: [unsaved.objectID]
        ) { _ in
            Issue.record("Newly edited photos must not reach the encoder")
            return nil
        }
        #expect(summary.compressedObjectIDs.isEmpty)
        #expect(fixture.reader.hasChanges)
        #expect(unsaved.value(forKey: "brandName") as? String == "正在编辑")
        let stored = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        stored.persistentStoreCoordinator = fixture.coordinator
        let ids = [recent.objectID, unsaved.objectID]
        try await stored.perform {
            for id in ids {
                let object = try stored.existingObject(with: id)
                #expect(object.value(forKey: "photoData") as? Data == photo)
            }
        }
    }

    @Test func aConcurrentSaveWinsOverStaleMaintenanceData() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let record = fixture.insert(photo: Data(repeating: 1, count: 20), createdAt: startedAt)
        try fixture.reader.save()
        let id = record.objectID
        let writer = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        writer.persistentStoreCoordinator = fixture.coordinator
        let userPhoto = Data(repeating: 9, count: 30)
        let editDate = startedAt.addingTimeInterval(1)
        let summary = try await PhotoMaintenanceWorker.run(
            coordinator: fixture.coordinator, startedAt: startedAt,
            targetByteCount: 4
        ) { _ in
            writer.performAndWait {
                do {
                    let edited = try writer.existingObject(with: id)
                    edited.setValue(userPhoto, forKey: "photoData")
                    edited.setValue(editDate, forKey: "updatedAt")
                    edited.setValue("刚修改的品牌", forKey: "brandName")
                    try writer.save()
                } catch { Issue.record(error) }
            }
            return Data([1, 1])
        }
        fixture.reader.refreshAllObjects()
        #expect(summary.compressedObjectIDs.isEmpty)
        #expect(summary.conflictedCount == 1)
        #expect(record.value(forKey: "photoData") as? Data == userPhoto)
        #expect(record.value(forKey: "brandName") as? String == "刚修改的品牌")
    }

    @Test func processesSeveralPrivateBatchesWithoutChangingOtherFields() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let records = (0..<19).map { _ in
            fixture.insert(photo: Data(repeating: 4, count: 20), createdAt: startedAt)
        }
        try fixture.reader.save()
        let summary = try await PhotoMaintenanceWorker.run(
            coordinator: fixture.coordinator, startedAt: startedAt,
            targetByteCount: 4, batchSize: 2
        ) { _ in
            #expect(!Thread.isMainThread)
            return Data([4, 4])
        }
        fixture.reader.refreshAllObjects()
        #expect(summary.compressedObjectIDs.count == 19)
        for record in records {
            #expect(record.value(forKey: "photoData") as? Data == Data([4, 4]))
            #expect(record.value(forKey: "brandName") as? String == "原品牌")
        }
    }

    private final class Fixture {
        let coordinator: NSPersistentStoreCoordinator
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        private let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoMaintenance-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let entity = NSEntityDescription()
            entity.name = "AdRecord"
            entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
            entity.properties = [
                Self.attribute("photoData", type: .binaryDataAttributeType),
                Self.attribute("createdAt", type: .dateAttributeType),
                Self.attribute("updatedAt", type: .dateAttributeType),
                Self.attribute("brandName", type: .stringAttributeType)
            ]
            let model = NSManagedObjectModel()
            model.entities = [entity]
            coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                               at: directory.appendingPathComponent("photos.sqlite"))
            reader.persistentStoreCoordinator = coordinator
        }

        func insert(photo: Data, createdAt: Date) -> NSManagedObject {
            let record = NSEntityDescription.insertNewObject(forEntityName: "AdRecord", into: reader)
            record.setValue(photo, forKey: "photoData")
            record.setValue(createdAt, forKey: "createdAt")
            record.setValue("原品牌", forKey: "brandName")
            return record
        }

        func close() {
            reader.rollback()
            reader.reset()
            for store in coordinator.persistentStores { try? coordinator.remove(store) }
            try? FileManager.default.removeItem(at: directory)
        }

        private static func attribute(_ name: String, type: NSAttributeType) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = true
            return attribute
        }
    }
}
