import CloudKit
import CoreData
import Foundation

nonisolated struct CloudSharingPresentation: Identifiable {
    let id = UUID()
    let syncSpaceID: NSManagedObjectID
    let share: CKShare
    let container: CKContainer
}

/// Coalesce retries while Core Data is still preparing the same share.
@MainActor
final class CloudSharingPreparationService {
    static let shared = CloudSharingPreparationService()
    typealias Completion = @MainActor (Result<CloudSharingPresentation, Error>) -> Void

    private var callbacks: [UUID: Completion] = [:]
    private var isRunning = false

    func prepare(requestID: UUID, completion: @escaping Completion) {
        callbacks[requestID] = completion
        guard !isRunning else { return }
        isRunning = true

        let persistence = PersistenceController.shared
        let container = persistence.container
        let containerIdentifier = PersistenceController.cloudKitContainerIdentifier
        AppLogger.shared.log("开始在后台准备共享")
        container.performBackgroundTask { @Sendable context in
            CloudSharingWorker.prepare(
                in: context, container: container, containerIdentifier: containerIdentifier
            ) { result in
                Task { @MainActor in
                    self.finish(result)
                }
            }
        }
    }

    func stopWaiting(requestID: UUID) {
        callbacks.removeValue(forKey: requestID)
    }

    private func finish(_ result: Result<CloudSharingPresentation, Error>) {
        isRunning = false
        let completions = Array(callbacks.values)
        callbacks.removeAll()
        switch result {
        case .success:
            AppLogger.shared.log("共享准备完成")
            PersistenceController.shared.repairOwnedShareMembership()
        case .failure(let error):
            AppLogger.shared.log("准备共享失败：\(PersistenceController.describe(error))")
        }
        completions.forEach { $0(result) }
    }
}

private nonisolated enum CloudSharingWorker {
    enum PreparationError: LocalizedError {
        case storeUnavailable
        case sharedMetadataUnavailable
        case missingShare

        var errorDescription: String? {
            switch self {
            case .storeUnavailable: "本机数据库尚未准备好，请稍后重试。"
            case .sharedMetadataUnavailable: "共享信息尚未同步完成，请稍后重试。"
            case .missingShare: "iCloud 没有返回共享信息，请确认网络和 iCloud 登录状态后重试。"
            }
        }
    }

    static func prepare(
        in context: NSManagedObjectContext,
        container: NSPersistentCloudKitContainer,
        containerIdentifier: String,
        completion: @escaping @Sendable (Result<CloudSharingPresentation, Error>) -> Void
    ) {
        // This method runs only on this private context's queue. Managed objects never leave it.
        context.name = "CloudSharingPreparation"
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.undoManager = nil
        do {
            let stores = container.persistentStoreCoordinator.persistentStores
            let sharedStore = stores.first { $0.url?.lastPathComponent == "QianDuoDuo-shared.sqlite" }
            let privateStore = stores.first { $0.url?.lastPathComponent == "QianDuoDuo.sqlite" }
                ?? stores.first { $0 != sharedStore }
            let request = NSFetchRequest<NSManagedObject>(entityName: "SyncSpace")
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            let spaces = try context.fetch(request)
            let sharedSpace = sharedStore.flatMap { store in spaces.first { $0.objectID.persistentStore == store } }
            let privateSpace = privateStore.flatMap { store in spaces.first { $0.objectID.persistentStore == store } }
            let syncSpace: NSManagedObject
            if let existing = sharedSpace ?? privateSpace ?? spaces.first {
                syncSpace = existing
            } else {
                guard let privateStore else { throw PreparationError.storeUnavailable }
                syncSpace = NSEntityDescription.insertNewObject(forEntityName: "SyncSpace", into: context)
                context.assign(syncSpace, to: privateStore)
                syncSpace.setValue(UUID(), forKey: "id")
                syncSpace.setValue("钱多多共享数据", forKey: "name")
                syncSpace.setValue(Date(), forKey: "createdAt")
                syncSpace.setValue(Date(), forKey: "updatedAt")
            }

            if !syncSpace.objectID.isTemporaryID {
                // Opening management does not resubmit an already shared object graph.
                if let share = try container.fetchShares(matching: [syncSpace.objectID])[syncSpace.objectID] {
                    completion(.success(CloudSharingPresentation(
                        syncSpaceID: syncSpace.objectID, share: share,
                        container: CKContainer(identifier: containerIdentifier)
                    )))
                    return
                }
                if let sharedStore, syncSpace.objectID.persistentStore == sharedStore {
                    throw PreparationError.sharedMetadataUnavailable
                }
            }

            guard let privateStore else { throw PreparationError.storeUnavailable }
            for entityName in ["AdRecord", "FollowerSnapshot", "VideoLikeSnapshot"] {
                let orphanRequest = NSFetchRequest<NSManagedObject>(entityName: entityName)
                orphanRequest.predicate = NSPredicate(format: "syncSpace == nil")
                orphanRequest.affectedStores = [privateStore]
                orphanRequest.fetchBatchSize = 100
                for object in try context.fetch(orphanRequest) {
                    object.setValue(syncSpace, forKey: "syncSpace")
                }
            }
            if context.hasChanges {
                syncSpace.setValue(Date(), forKey: "updatedAt")
                try context.save()
            }
            let syncSpaceID = syncSpace.objectID
            // Core Data traverses the root's relationships itself; do not fault every child here.
            container.share([syncSpace], to: nil) { [context] _, share, cloudContainer, error in
                _ = context // Keep the private context alive until its share operation finishes.
                if let error {
                    completion(.failure(error))
                } else if let share, let cloudContainer {
                    share[CKShare.SystemFieldKey.title] = "钱多多共享数据" as NSString
                    completion(.success(CloudSharingPresentation(syncSpaceID: syncSpaceID, share: share, container: cloudContainer)))
                } else {
                    completion(.failure(PreparationError.missingShare))
                }
            }
        } catch {
            context.rollback()
            completion(.failure(error))
        }
    }
}
