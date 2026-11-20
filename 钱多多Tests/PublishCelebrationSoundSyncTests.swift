import CoreData
import Foundation
import Testing
@testable import 钱多多

@MainActor
struct PublishCelebrationSoundSyncTests {
    @Test func savingRecordingChangesOnlyTheSelectedSpace() throws {
        let fixture = try Fixture()
        let own = fixture.makeSpace(name: "own")
        let shared = fixture.makeSpace(name: "shared")
        try fixture.context.save()
        let ownSound = fixture.repository(space: own)
        let sharedSound = fixture.repository(space: shared)
        let first = Data([1, 2, 3, 4])
        let second = Data([5, 6, 7])

        try ownSound.saveRecording(data: first)
        try sharedSound.saveRecording(data: second)

        #expect(try ownSound.selectedRecordingData() == first)
        #expect(try sharedSound.selectedRecordingData() == second)
        #expect(own.value(forKey: "updatedAt") as? Date != nil)
        #expect(shared.value(forKey: "updatedAt") as? Date != nil)
        try sharedSound.restoreDefault()
        #expect(try sharedSound.selectedRecordingData() == nil)
        #expect(try ownSound.selectedRecordingData() == first)
    }

    @Test func reopeningSQLitePreservesRecordingBytesAndDefaultSelection() throws {
        try withTemporaryDirectory { directory in
            let storeURL = directory.appendingPathComponent("sound.sqlite")
            let bytes = Data((0..<65_537).map { UInt8($0 % 251) })
            var identifier: NSManagedObjectID!
            do {
                let first = try Fixture(storeURL: storeURL)
                let space = first.makeSpace(name: "persisted")
                try first.context.save()
                identifier = space.objectID
                try first.repository(space: space).saveRecording(data: bytes)
                try first.closeStore()
            }

            let second = try Fixture(storeURL: storeURL)
            let restored = try second.context.existingObject(with: identifier)
            #expect(try second.repository(space: restored).selectedRecordingData() == bytes)
            try second.repository(space: restored).restoreDefault()
            try second.closeStore()

            let third = try Fixture(storeURL: storeURL)
            let reset = try third.context.existingObject(with: identifier)
            #expect(try third.repository(space: reset).selectedRecordingData() == nil)
            #expect(reset.value(forKey: "updatedAt") as? Date != nil)
            try third.closeStore()
        }
    }

    @Test func oldLocalRecordingIsUploadedOnlyWhenRequested() throws {
        try withLegacyStorage { legacy, directory in
            let bytes = Data([10, 20, 30])
            let source = directory.appendingPathComponent("source.m4a")
            try bytes.write(to: source)
            try legacy.saveRecording(from: source)
            let fixture = try Fixture()
            let space = fixture.makeSpace(name: "existing")
            try fixture.context.save()
            let repository = fixture.repository(space: space, legacy: legacy)

            #expect(repository.hasUnsyncedLocalRecording)
            #expect(try repository.selectedRecordingData() == bytes)
            #expect(space.value(forKey: "celebrationSoundData") == nil)
            #expect(space.value(forKey: "updatedAt") == nil)
            #expect(!fixture.context.hasChanges)

            try repository.syncExistingRecording()
            #expect(!repository.hasUnsyncedLocalRecording)
            #expect(space.value(forKey: "celebrationSoundData") as? Data != nil)
            #expect(try repository.selectedRecordingData() == bytes)
            #expect(try Data(contentsOf: source) == bytes)
        }
    }

    @Test func syncedRecordingTakesPrecedenceOverAnOlderLocalCopy() throws {
        try withLegacyStorage { legacy, directory in
            let source = directory.appendingPathComponent("old.m4a")
            try Data([8, 8, 8]).write(to: source)
            try legacy.saveRecording(from: source)
            let fixture = try Fixture()
            let space = fixture.makeSpace(name: "shared")
            let synced = Data([9, 9, 9, 9])
            try fixture.repository(space: space).saveRecording(data: synced)

            let repository = fixture.repository(space: space, legacy: legacy)
            #expect(try repository.selectedRecordingData() == synced)
            #expect(!repository.hasUnsyncedLocalRecording)
        }
    }

    @Test func restoredDefaultDoesNotResurrectAnotherDevicesOldLocalRecording() throws {
        try withLegacyStorage { legacy, directory in
            let fixture = try Fixture()
            let space = fixture.makeSpace(name: "shared")
            try fixture.context.save()
            let repository = fixture.repository(space: space, legacy: legacy)
            try repository.saveRecording(data: Data([1, 2, 3]))
            try repository.restoreDefault()

            // Simulate a second device that still has the pre-sync local file.
            let stale = directory.appendingPathComponent("stale.m4a")
            try Data([4, 5, 6]).write(to: stale)
            try legacy.saveRecording(from: stale)
            let otherDevice = fixture.repository(space: space, legacy: legacy)
            #expect(try otherDevice.selectedRecordingData() == nil)
            #expect(!otherDevice.hasUnsyncedLocalRecording)
            #expect(space.value(forKey: "celebrationSoundData") as? Data != nil)
            #expect(space.value(forKey: "updatedAt") as? Date != nil)
        }
    }

    @Test func readOnlySharingCannotReplaceOrResetTheSharedRecording() throws {
        let fixture = try Fixture()
        let space = fixture.makeSpace(name: "read-only")
        let original = Data([11, 12])
        try fixture.repository(space: space).saveRecording(data: original)
        let repository = fixture.repository(space: space, canUpdate: false)

        #expect(!repository.canChangeSound)
        #expect(throws: (any Error).self) { try repository.saveRecording(data: Data([13, 14])) }
        #expect(throws: (any Error).self) { try repository.restoreDefault() }
        #expect(try repository.selectedRecordingData() == original)
        #expect(!fixture.context.hasChanges)
    }

    @Test func emptyRecordingDoesNotReplaceExistingSound() throws {
        let fixture = try Fixture()
        let space = fixture.makeSpace(name: "selected")
        try fixture.context.save()
        let repository = fixture.repository(space: space)
        let original = Data([42, 43, 44])
        try repository.saveRecording(data: original)

        #expect(throws: (any Error).self) { try repository.saveRecording(data: Data()) }
        #expect(try repository.selectedRecordingData() == original)
        #expect(!fixture.context.hasChanges)
    }

    @Test func corruptOrFutureSelectionKeepsResetAvailableAndCanRestoreDefault() throws {
        let fixture = try Fixture()
        let space = fixture.makeSpace(name: "downloaded")
        try fixture.context.save()
        let repository = fixture.repository(space: space)
        #expect(!repository.hasCustomRecording)
        try repository.saveRecording(data: Data([21, 22, 23]))
        #expect(repository.hasCustomRecording)
        let future = try PropertyListSerialization.data(
            fromPropertyList: ["version": 2, "audio": Data([24, 25])],
            format: .binary, options: 0
        )

        for payload in [Data([0xff, 0, 0x01]), future] {
            space.setValue(payload, forKey: "celebrationSoundData")
            try fixture.context.save()
            #expect(repository.hasCustomRecording, "Recovery must stay available for an unreadable selection")
            #expect(throws: (any Error).self) { try repository.selectedRecordingData() }
            #expect(space.value(forKey: "celebrationSoundData") as? Data == payload)

            try repository.restoreDefault()
            #expect(!repository.hasCustomRecording)
            #expect(try repository.selectedRecordingData() == nil)
            #expect(space.value(forKey: "celebrationSoundData") as? Data != nil)
        }
    }

    @Test func failedSavePreservesPreviousSelectionAndUnrelatedPendingEdits() throws {
        let fixture = try Fixture()
        let space = fixture.makeSpace(name: "selected")
        try fixture.context.save()
        let repository = fixture.repository(space: space)
        let original = Data([71, 72, 73])
        try repository.saveRecording(data: original)
        let originalDate = space.value(forKey: "updatedAt") as? Date
        let unrelated = NSEntityDescription.insertNewObject(forEntityName: "Draft", into: fixture.context)
        // Missing a mandatory field makes a real Core Data save fail.
        #expect(throws: (any Error).self) { try repository.saveRecording(data: Data([74, 75])) }

        #expect(try repository.selectedRecordingData() == original)
        #expect(space.value(forKey: "updatedAt") as? Date == originalDate)
        #expect(unrelated.isInserted)
        #expect(fixture.context.insertedObjects.contains(unrelated))
        #expect(!unrelated.isDeleted)
    }

    @MainActor
    private final class Fixture {
        let coordinator: NSPersistentStoreCoordinator
        let context: NSManagedObjectContext

        init(storeURL: URL? = nil) throws {
            let model = NSManagedObjectModel()
            let space = NSEntityDescription()
            space.name = "SyncSpace"
            space.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
            space.properties = [
                Self.attribute("name", .stringAttributeType),
                Self.attribute("updatedAt", .dateAttributeType),
                Self.attribute("celebrationSoundData", .binaryDataAttributeType)
            ]
            (space.propertiesByName["celebrationSoundData"] as? NSAttributeDescription)?.allowsExternalBinaryDataStorage = true
            let draft = NSEntityDescription()
            draft.name = "Draft"
            draft.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
            let required = Self.attribute("requiredValue", .stringAttributeType)
            required.isOptional = false
            draft.properties = [required]
            model.entities = [space, draft]
            coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            try coordinator.addPersistentStore(
                ofType: storeURL == nil ? NSInMemoryStoreType : NSSQLiteStoreType,
                configurationName: nil, at: storeURL,
                options: [NSMigratePersistentStoresAutomaticallyOption: true,
                          NSInferMappingModelAutomaticallyOption: true]
            )
            context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
        }

        func makeSpace(name: String) -> NSManagedObject {
            let space = NSEntityDescription.insertNewObject(forEntityName: "SyncSpace", into: context)
            space.setValue(name, forKey: "name")
            return space
        }

        func repository(space: NSManagedObject, legacy: PublishCelebrationSoundStorage? = nil,
                        canUpdate: Bool = true) -> PublishCelebrationSoundSync {
            PublishCelebrationSoundSync(
                context: context,
                activeSpace: { space }, existingSpace: { space },
                canUpdate: { _ in canUpdate }, legacyStorage: legacy
            )
        }

        func closeStore() throws {
            context.reset()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }

        private static func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = true
            return attribute
        }
    }

    private func withTemporaryDirectory(_ action: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try action(directory)
    }

    private func withLegacyStorage(_ action: (PublishCelebrationSoundStorage, URL) throws -> Void) throws {
        try withTemporaryDirectory { directory in
            try action(PublishCelebrationSoundStorage(directory: directory.appendingPathComponent("legacy")), directory)
        }
    }
}
