import CoreData
import Foundation

nonisolated struct PhotoMaintenanceSummary: Sendable {
    var compressedObjectIDs: [NSManagedObjectID] = []
    var conflictedCount = 0
}

/// Shrinks oversized screenshots. It only ever replaces a photo with a smaller encoding of itself:
/// there is intentionally no code path that clears `photoData`, whatever the record's age.
/// Owns a disposable private context. It never reads or saves the UI context.
nonisolated enum PhotoMaintenanceWorker {
    static func run(
        coordinator: NSPersistentStoreCoordinator,
        startedAt: Date,
        targetByteCount: Int,
        excluding excludedIDs: Set<NSManagedObjectID> = [],
        batchSize: Int = 8,
        compress: @escaping @Sendable (Data) -> Data?
    ) async throws -> PhotoMaintenanceSummary {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.name = "BackgroundPhotoMaintenance"
        context.undoManager = nil
        // A stale image must never win over an edit saved by another context.
        context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)

        return try await context.perform {
            var summary = PhotoMaintenanceSummary()
            let predicate = candidatePredicate(startedAt: startedAt)
            let request = NSFetchRequest<NSManagedObjectID>(entityName: "AdRecord")
            request.resultType = .managedObjectIDResultType
            request.predicate = predicate
            request.includesPropertyValues = false
            request.includesPendingChanges = false
            let objectIDs = try context.fetch(request).filter { !excludedIDs.contains($0) }
            let limit = max(1, min(batchSize, 32))

            for offset in stride(from: 0, to: objectIDs.count, by: limit) {
                try autoreleasepool {
                    defer { context.reset() }
                    let end = min(offset + limit, objectIDs.count)
                    let batchRequest = NSFetchRequest<NSManagedObject>(entityName: "AdRecord")
                    batchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                        predicate, NSPredicate(format: "SELF IN %@", Array(objectIDs[offset..<end]))
                    ])
                    batchRequest.fetchLimit = limit
                    let objects = try context.fetch(batchRequest)
                    var changedIDs: [NSManagedObjectID] = []

                    for object in objects {
                        autoreleasepool {
                            guard let original = object.value(forKey: "photoData") as? Data,
                                  original.count > targetByteCount,
                                  let compressed = compress(original),
                                  !compressed.isEmpty,
                                  compressed.count < original.count else { return }
                            object.setValue(compressed, forKey: "photoData")
                            object.setValue(Date(), forKey: "updatedAt")
                            changedIDs.append(object.objectID)
                        }
                    }

                    guard !changedIDs.isEmpty else { return }
                    do {
                        try context.save()
                        summary.compressedObjectIDs.append(contentsOf: changedIDs)
                    } catch {
                        context.rollback()
                        let error = error as NSError
                        guard error.domain == NSCocoaErrorDomain,
                              error.code == NSManagedObjectMergeError ||
                                error.code == NSPersistentStoreSaveConflictsError else { throw error }
                        // Skip the entire conflicted batch rather than retry stale writes.
                        summary.conflictedCount += changedIDs.count
                    }
                }
            }
            return summary
        }
    }

    /// Records edited after scheduling are left for the next launch; age is never a criterion.
    private static func candidatePredicate(startedAt: Date) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "photoData != nil"),
            NSPredicate(format: "updatedAt == nil OR updatedAt <= %@", startedAt as NSDate)
        ])
    }
}
