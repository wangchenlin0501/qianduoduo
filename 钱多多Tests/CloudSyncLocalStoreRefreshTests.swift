import CoreData
import Foundation
import Testing
@testable import 钱多多

@MainActor
struct CloudSyncLocalStoreRefreshTests {
    @Test func mergesAnotherContextsInsertUpdateAndDeleteIntoFetchedResults() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let refresh = CloudSyncLocalStoreRefresh()
        let fetchedResults = try fixture.fetchedResults()
        #expect(fetchedResults.fetchedObjects?.isEmpty == true)

        let object = fixture.insert(title: "first", in: fixture.writer)
        try fixture.writer.save()
        let objectID = object.objectID
        #expect(try refresh.refresh(fixture.reader) == 1)
        #expect(fetchedResults.fetchedObjects?.count == 1)
        let displayed = try #require(fetchedResults.fetchedObjects?.first)
        #expect(displayed.objectID == objectID)
        #expect(displayed.value(forKey: "title") as? String == "first")

        object.setValue("updated", forKey: "title")
        try fixture.writer.save()
        #expect(displayed.value(forKey: "title") as? String == "first")
        #expect(try refresh.refresh(fixture.reader) == 1)
        #expect(displayed.value(forKey: "title") as? String == "updated")

        fixture.writer.delete(object)
        try fixture.writer.save()
        #expect(try refresh.refresh(fixture.reader) == 1)
        #expect(fetchedResults.fetchedObjects?.isEmpty == true)
        #expect(try refresh.refresh(fixture.reader) == 0)
    }

    @Test func savesPendingEditsBeforeRefreshingWithoutLosingTheObject() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let object = fixture.insert(title: "unsaved edit", in: fixture.reader)
        #expect(fixture.reader.hasChanges)

        _ = try CloudSyncLocalStoreRefresh().refresh(fixture.reader)

        #expect(!fixture.reader.hasChanges)
        #expect(!object.objectID.isTemporaryID)
        #expect(object.managedObjectContext === fixture.reader)
        #expect(object.value(forKey: "title") as? String == "unsaved edit")
        let persisted = try fixture.writer.existingObject(with: object.objectID)
        #expect(persisted.value(forKey: "title") as? String == "unsaved edit")
    }

    @Test func saveValidationFailureLeavesEditsAndHistoryAvailableForRetry() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let remote = fixture.insert(title: "other context", in: fixture.writer)
        try fixture.writer.save()
        let pending = fixture.insert(title: "valid before editing", in: fixture.reader)
        pending.setValue(nil, forKey: "title")
        let refresh = CloudSyncLocalStoreRefresh()

        #expect(throws: (any Error).self) { try refresh.refresh(fixture.reader) }
        #expect(fixture.reader.hasChanges)
        #expect(pending.managedObjectContext === fixture.reader)
        #expect(pending.value(forKey: "title") == nil)

        pending.setValue("recovered local edit", forKey: "title")
        #expect(try refresh.refresh(fixture.reader) == 2)
        #expect(!fixture.reader.hasChanges)
        let merged = try fixture.reader.existingObject(with: remote.objectID)
        #expect(merged.value(forKey: "title") as? String == "other context")
        #expect(pending.value(forKey: "title") as? String == "recovered local edit")
        #expect(try refresh.refresh(fixture.reader) == 0)
    }

    @Test func consumesHistoryInBoundedBatchesWithoutRepeatingTransactions() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for index in 0..<5 {
            _ = fixture.insert(title: "item \(index)", in: fixture.writer)
            try fixture.writer.save()
        }
        let refresh = CloudSyncLocalStoreRefresh(maximumTransactions: 2)

        let counts = try (0..<4).map { _ in try refresh.refresh(fixture.reader) }
        #expect(counts == [2, 2, 1, 0])
    }

    @Test func inMemoryPreviewStoresSaveAndRefreshWithoutHistory() throws {
        let fixture = try Fixture(inMemory: true)
        defer { fixture.close() }
        let pending = fixture.insert(title: "preview", in: fixture.reader)

        #expect(try CloudSyncLocalStoreRefresh().refresh(fixture.reader) == 0)
        #expect(!fixture.reader.hasChanges)
        #expect(pending.value(forKey: "title") as? String == "preview")
    }

    @Test func sessionDateSkipsOldHistoryAndMergesLaterInsertUpdateAndDelete() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let old = fixture.insert(title: "before session", in: fixture.writer)
        try fixture.writer.save()
        let fetchedResults = try fixture.fetchedResults()
        let displayed = try #require(fetchedResults.fetchedObjects?.first)
        let refresh = CloudSyncLocalStoreRefresh(since: Date())
        #expect(try refresh.refresh(fixture.reader) == 0)

        old.setValue("edited after session", forKey: "title")
        let added = fixture.insert(title: "new after session", in: fixture.writer)
        try fixture.writer.save()
        #expect(try refresh.refresh(fixture.reader) == 1)
        #expect(fetchedResults.fetchedObjects?.count == 2)
        #expect(displayed.value(forKey: "title") as? String == "edited after session")

        fixture.writer.delete(added)
        try fixture.writer.save()
        #expect(try refresh.refresh(fixture.reader) == 1)
        #expect(fetchedResults.fetchedObjects?.count == 1)
        #expect(fetchedResults.fetchedObjects?.first?.objectID == old.objectID)
        #expect(try refresh.refresh(fixture.reader) == 0)
    }

    @Test func automaticCoordinatorMergesPrivateWriterInsertUpdateAndDeleteIntoFetchedResults() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.reader.automaticallyMergesChangesFromParent = true
        let fetchedResults = try fixture.fetchedResults()
        let background = fixture.backgroundWriter()
        let id = try await background.perform {
            #expect(!Thread.isMainThread)
            let object = NSEntityDescription.insertNewObject(forEntityName: "RefreshItem", into: background)
            object.setValue("first", forKey: "title")
            try background.save()
            return object.objectID
        }
        try await waitUntil { fetchedResults.fetchedObjects?.count == 1 }
        let displayed = try #require(fetchedResults.fetchedObjects?.first)
        #expect(displayed.value(forKey: "title") as? String == "first")

        try await background.perform {
            let object = try background.existingObject(with: id)
            object.setValue("updated", forKey: "title")
            try background.save()
        }
        try await waitUntil { displayed.value(forKey: "title") as? String == "updated" }
        #expect(displayed.value(forKey: "title") as? String == "updated")

        try await background.perform {
            background.delete(try background.existingObject(with: id))
            try background.save()
        }
        try await waitUntil { fetchedResults.fetchedObjects?.isEmpty == true }
        #expect(fetchedResults.fetchedObjects?.isEmpty == true)

        // Later transactions still merge after a remote deletion, with no explicit refresh.
        try await background.perform {
            for index in 0..<5 {
                let object = NSEntityDescription.insertNewObject(forEntityName: "RefreshItem", into: background)
                object.setValue("later \(index)", forKey: "title")
                try background.save()
            }
        }
        try await waitUntil { fetchedResults.fetchedObjects?.count == 5 }
        #expect(fetchedResults.fetchedObjects?.count == 5)
        await background.perform { background.reset() }
    }

    @Test func automaticUnrelatedUpdateDoesNotRefaultLoadedObjects() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let unchanged = fixture.insert(title: "unchanged", in: fixture.writer)
        let changed = fixture.insert(title: "before", in: fixture.writer)
        try fixture.writer.save()
        let unchangedID = unchanged.objectID
        let changedID = changed.objectID
        fixture.reader.automaticallyMergesChangesFromParent = true
        let fetchedResults = try fixture.fetchedResults()
        let displayed = try #require(fetchedResults.fetchedObjects?.first { $0.objectID == unchangedID })
        let updated = try #require(fetchedResults.fetchedObjects?.first { $0.objectID == changedID })
        #expect(displayed.value(forKey: "title") as? String == "unchanged")
        #expect(updated.value(forKey: "title") as? String == "before")
        let background = fixture.backgroundWriter()
        try await background.perform {
            let object = try background.existingObject(with: changedID)
            object.setValue("after", forKey: "title")
            try background.save()
        }
        try await waitUntil { updated.value(forKey: "title") as? String == "after" }
        #expect(updated.value(forKey: "title") as? String == "after")
        #expect(!displayed.isFault)
        #expect(displayed.value(forKey: "title") as? String == "unchanged")
        await background.perform { background.reset() }
    }

    @Test func automaticMergeDoesNotSavePendingEditorValuesOrNewObjects() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let saved = fixture.insert(title: "saved", in: fixture.writer)
        let changed = fixture.insert(title: "before", in: fixture.writer)
        try fixture.writer.save()
        let savedID = saved.objectID
        let changedID = changed.objectID
        fixture.reader.automaticallyMergesChangesFromParent = true
        let fetchedResults = try fixture.fetchedResults()
        let editing = try #require(fetchedResults.fetchedObjects?.first { $0.objectID == savedID })
        let updated = try #require(fetchedResults.fetchedObjects?.first { $0.objectID == changedID })
        editing.setValue("unfinished edit", forKey: "title")
        let newEdit = fixture.insert(title: "unsaved insert", in: fixture.reader)
        let background = fixture.backgroundWriter()
        try await background.perform {
            let object = try background.existingObject(with: changedID)
            object.setValue("after", forKey: "title")
            try background.save()
        }
        try await waitUntil { updated.value(forKey: "title") as? String == "after" }
        #expect(updated.value(forKey: "title") as? String == "after")
        #expect(fixture.reader.hasChanges)
        #expect(editing.value(forKey: "title") as? String == "unfinished edit")
        #expect(newEdit.objectID.isTemporaryID)
        try await background.perform {
            let values = try background.fetch(NSFetchRequest<NSManagedObject>(entityName: "RefreshItem"))
                .compactMap { $0.value(forKey: "title") as? String }
            #expect(Set(values) == ["saved", "after"])
            background.reset()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private final class Fixture {
        let coordinator: NSPersistentStoreCoordinator
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        let writer = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        private let directory: URL
        private let observer = FetchedResultsObserver()

        init(inMemory: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CloudSyncLocalRefresh-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let entity = NSEntityDescription()
            entity.name = "RefreshItem"
            entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
            let title = NSAttributeDescription()
            title.name = "title"
            title.attributeType = .stringAttributeType
            title.isOptional = false
            entity.properties = [title]
            let model = NSManagedObjectModel()
            model.entities = [entity]
            coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            try coordinator.addPersistentStore(
                ofType: inMemory ? NSInMemoryStoreType : NSSQLiteStoreType,
                configurationName: nil,
                at: inMemory ? nil : directory.appendingPathComponent("refresh.sqlite"),
                options: inMemory ? nil : [NSPersistentHistoryTrackingKey: true]
            )
            reader.persistentStoreCoordinator = coordinator
            writer.persistentStoreCoordinator = coordinator
            reader.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
            writer.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        }

        func insert(title: String, in context: NSManagedObjectContext) -> NSManagedObject {
            let object = NSEntityDescription.insertNewObject(forEntityName: "RefreshItem", into: context)
            object.setValue(title, forKey: "title")
            return object
        }

        func backgroundWriter() -> NSManagedObjectContext {
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            return context
        }

        func fetchedResults() throws -> NSFetchedResultsController<NSManagedObject> {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RefreshItem")
            request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
            let controller = NSFetchedResultsController(
                fetchRequest: request, managedObjectContext: reader,
                sectionNameKeyPath: nil, cacheName: nil
            )
            controller.delegate = observer
            try controller.performFetch()
            return controller
        }

        func close() {
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private final class FetchedResultsObserver: NSObject, NSFetchedResultsControllerDelegate {
        func controllerDidChangeContent(_ controller: NSFetchedResultsController<any NSFetchRequestResult>) {}
    }
}
