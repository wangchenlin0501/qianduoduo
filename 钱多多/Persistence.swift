//
//  Persistence.swift
//  钱多多
//
//

import CloudKit
import CoreData

final class PersistenceController {
    static let cloudKitContainerIdentifier = Bundle.main.object(forInfoDictionaryKey: "QDDCloudKitContainerIdentifier") as? String ?? "iCloud.com.example.qianduoduo"
    static let shared = PersistenceController()
    private let maxShareRetryAttempts = 5
    private var scheduledShareRetryKeys: Set<String> = []
    private var isShareRepairScheduled = false
    private var cloudKitEventObserver: NSObjectProtocol?

    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext
        let syncSpace = SyncSpace(context: viewContext)
        syncSpace.id = UUID()
        syncSpace.name = "钱多多共享数据"
        syncSpace.createdAt = Date()
        syncSpace.updatedAt = Date()

        let samples: [(String, String, AdCategory, Int16, Double, PaymentStatus, Bool, Int?, Int?, Int?, PaymentMethod, String)] = [
            ("示例品牌 A", "demo_contact_a", .clothing, 1, 3200, .paid, true, -18, -16, -3, .weChat, "五月第一期"),
            ("示例品牌 B", "demo_contact_b", .skirt, 2, 2600, .unpaid, true, -8, -7, nil, .bankCard, "五月第二期"),
            ("示例品牌 C", "demo_contact_c", .pants, 1, 4500, .unpaid, false, nil, nil, nil, .alipay, ""),
            ("示例品牌 D", "demo_contact_d", .accessory, 3, 1800, .paid, true, 4, 5, 7, .alipay, "六月第一期")
        ]

        for sample in samples {
            let record = AdRecord(context: viewContext)
            record.id = UUID()
            record.createdAt = Date()
            record.updatedAt = Date()
            record.brandName = sample.0
            record.contactWeChat = sample.1
            record.platform = sample.2.rawValue
            record.lookNumber = sample.3
            record.adFee = sample.4
            record.paidAmount = sample.5 == .paid ? sample.4 : 0
            record.paymentStatus = sample.5.rawValue
            if sample.6 {
                record.arrivalDate = qddCalendar.date(byAdding: .day, value: -5, to: Date())
            }
            if let paidOffset = sample.7 {
                record.publishDate = qddCalendar.date(byAdding: .day, value: paidOffset, to: Date())
            }
            if let publishedOffset = sample.8 {
                record.dueDate = qddCalendar.date(byAdding: .day, value: publishedOffset, to: Date())
            }
            if let paidOffset = sample.9 {
                record.paidDate = qddCalendar.date(byAdding: .day, value: paidOffset, to: Date())
            }
            record.paymentAccount = sample.5 == .paid ? sample.10.rawValue : nil
            record.videoTitle = sample.11
            record.paymentNote = sample.5 == .unpaid ? "等对接人确认打款时间" : ""
            record.syncSpace = syncSpace
        }

        for (monthOffset, count) in [(-5, 18_200), (-4, 19_100), (-3, 20_400), (-2, 21_050), (-1, 22_300), (0, 23_180)] {
            let snapshot = FollowerSnapshot(context: viewContext)
            snapshot.id = UUID()
            snapshot.date = qddCalendar.date(byAdding: .month, value: monthOffset, to: Date())
            snapshot.followerCount = Int64(count)
            snapshot.createdAt = Date()
            snapshot.updatedAt = Date()
            snapshot.syncSpace = syncSpace
        }

        do {
            try viewContext.save()
        } catch {
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }
        return result
    }()

    let container: NSPersistentCloudKitContainer

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "QianDuoDuo")

        guard let privateDescription = container.persistentStoreDescriptions.first else {
            fatalError("Missing persistent store description")
        }

        if inMemory {
            privateDescription.url = URL(fileURLWithPath: "/dev/null")
            privateDescription.cloudKitContainerOptions = nil
        } else {
            configure(
                privateDescription,
                databaseScope: .private,
                containerIdentifier: Self.cloudKitContainerIdentifier
            )

            let privateStoreURL = privateDescription.url ?? Self.defaultStoreURL(named: "QianDuoDuo.sqlite")
            privateDescription.url = privateStoreURL

            let sharedDescription = NSPersistentStoreDescription(
                url: privateStoreURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("QianDuoDuo-shared.sqlite")
            )
            configure(
                sharedDescription,
                databaseScope: .shared,
                containerIdentifier: Self.cloudKitContainerIdentifier
            )

            container.persistentStoreDescriptions = [privateDescription, sharedDescription]
        }

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        observeCloudKitEvents()
    }

    var privatePersistentStore: NSPersistentStore? {
        persistentStore(matching: "QianDuoDuo.sqlite") ??
        container.persistentStoreCoordinator.persistentStores.first { store in
            store.url?.lastPathComponent != "QianDuoDuo-shared.sqlite"
        }
    }

    var sharedPersistentStore: NSPersistentStore? {
        persistentStore(matching: "QianDuoDuo-shared.sqlite")
    }

    func activeSyncSpace(in context: NSManagedObjectContext) throws -> SyncSpace {
        let request: NSFetchRequest<SyncSpace> = SyncSpace.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \SyncSpace.createdAt, ascending: true)]
        let spaces = try context.fetch(request)

        if let sharedPersistentStore,
           let sharedSpace = spaces.first(where: { $0.objectID.persistentStore == sharedPersistentStore }) {
            return sharedSpace
        }

        if let privatePersistentStore {
            let privateSpaces = spaces.filter { $0.objectID.persistentStore == privatePersistentStore }
            if let privateSpace = privateSpaces.first {
                return privateSpace
            }
        }

        if let existingSpace = spaces.first {
            return existingSpace
        }

        return makeSyncSpace(in: context, store: privatePersistentStore)
    }

    @discardableResult
    func prepareSharingSpace(in context: NSManagedObjectContext) throws -> SyncSpace {
        let syncSpace = try activeSyncSpace(in: context)
        try attachPrivateOrphanRecords(to: syncSpace, in: context)
        if syncSpace.objectID.isTemporaryID {
            try context.obtainPermanentIDs(for: [syncSpace])
        }
        if context.hasChanges {
            try context.save()
        }
        context.processPendingChanges()
        return syncSpace
    }

    func prepareNewRecord(_ record: AdRecord, in context: NSManagedObjectContext) {
        do {
            let syncSpace = try activeSyncSpace(in: context)
            if record.objectID.isTemporaryID, let store = syncSpace.objectID.persistentStore {
                context.assign(record, to: store)
            }
            record.syncSpace = syncSpace
            syncSpace.updatedAt = Date()
        } catch {
            AppLogger.shared.log("准备同步空间失败: \(error.localizedDescription)")
        }
    }

    func prepareNewFollowerSnapshot(_ snapshot: FollowerSnapshot, in context: NSManagedObjectContext) {
        do {
            let syncSpace = try activeSyncSpace(in: context)
            if snapshot.objectID.isTemporaryID, let store = syncSpace.objectID.persistentStore {
                context.assign(snapshot, to: store)
            }
            snapshot.syncSpace = syncSpace
            syncSpace.updatedAt = Date()
        } catch {
            AppLogger.shared.log("准备粉丝数据同步空间失败: \(error.localizedDescription)")
        }
    }

    func prepareNewVideoLikeSnapshot(_ snapshot: VideoLikeSnapshot, in context: NSManagedObjectContext) {
        do {
            let syncSpace = try activeSyncSpace(in: context)
            if snapshot.objectID.isTemporaryID, let store = syncSpace.objectID.persistentStore {
                context.assign(snapshot, to: store)
            }
            snapshot.syncSpace = syncSpace
            syncSpace.updatedAt = Date()
        } catch {
            AppLogger.shared.log("准备点赞数据同步空间失败: \(error.localizedDescription)")
        }
    }

    func existingShare(for syncSpace: SyncSpace, logsFailures: Bool = true) -> CKShare? {
        do {
            return try container.fetchShares(matching: [syncSpace.objectID])[syncSpace.objectID]
        } catch {
            if logsFailures {
                AppLogger.shared.log("读取共享信息失败: \(Self.describe(error))")
            }
            return nil
        }
    }

    func share(
        syncSpace: SyncSpace,
        completion: @escaping (CKShare?, CKContainer?, Error?) -> Void
    ) {
        container.share(objectsToShare(with: syncSpace), to: nil) { _, share, cloudKitContainer, error in
            if let share {
                share[CKShare.SystemFieldKey.title] = "钱多多共享数据" as NSString
            }
            completion(share, cloudKitContainer, error)
        }
    }

    func shareExistingRecordsIfNeeded(for syncSpace: SyncSpace, share: CKShare) {
        let objects = objectsToShare(with: syncSpace)
        guard objects.count > 1 else { return }

        container.share(objects, to: share) { _, _, _, error in
            if let error {
                AppLogger.shared.log("补充共享记录失败: \(Self.describe(error))")
            } else {
                AppLogger.shared.log("已检查并补充共享记录 \(objects.count - 1) 条")
            }
        }
    }

    func shareOwnedRecordIfNeeded(_ record: AdRecord) {
        shareOwnedRecordsIfNeeded([record])
    }

    func shareOwnedFollowerSnapshotIfNeeded(_ snapshot: FollowerSnapshot) {
        shareOwnedFollowerSnapshotsIfNeeded([snapshot])
    }

    func shareOwnedVideoLikeSnapshotIfNeeded(_ snapshot: VideoLikeSnapshot) {
        shareOwnedVideoLikeSnapshotsIfNeeded([snapshot])
    }

    func shareOwnedFollowerSnapshotsIfNeeded(_ snapshots: [FollowerSnapshot]) {
        let objectIDs = snapshots
            .map(\.objectID)
            .filter { !$0.isTemporaryID }
        scheduleOwnedShareRetry(for: objectIDs, attempt: 1, delayOverride: 0.8)
    }

    func shareOwnedVideoLikeSnapshotsIfNeeded(_ snapshots: [VideoLikeSnapshot]) {
        let objectIDs = snapshots
            .map(\.objectID)
            .filter { !$0.isTemporaryID }
        scheduleOwnedShareRetry(for: objectIDs, attempt: 1, delayOverride: 0.8)
    }

    func shareOwnedRecordsIfNeeded(_ records: [AdRecord]) {
        let objectIDs = records
            .map(\.objectID)
            .filter { !$0.isTemporaryID }
        scheduleOwnedShareRetry(for: objectIDs, attempt: 1, delayOverride: 0.8)
    }

    func repairOwnedShareMembership(in context: NSManagedObjectContext? = nil) {
        scheduleOwnedShareRepair()
    }

    private func scheduleOwnedShareRepair() {
        DispatchQueue.main.async {
            guard !self.isShareRepairScheduled else { return }
            self.isShareRepairScheduled = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.isShareRepairScheduled = false
                self.processOwnedShareRepair()
            }
        }
    }

    private func processOwnedShareRepair() {
        container.performBackgroundTask { context in
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            guard let privatePersistentStore = self.privatePersistentStore else { return }

            let request: NSFetchRequest<SyncSpace> = SyncSpace.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \SyncSpace.createdAt, ascending: true)]

            do {
                let spaces = try context.fetch(request).filter {
                    $0.objectID.persistentStore == privatePersistentStore
                }

                let childObjectIDs = spaces.flatMap { syncSpace -> [NSManagedObjectID] in
                    guard
                        self.existingShare(for: syncSpace, logsFailures: false) != nil
                    else {
                        return []
                    }

                    let records = syncSpace.records?.allObjects as? [AdRecord] ?? []
                    let followerSnapshots = syncSpace.followerSnapshots?.allObjects as? [FollowerSnapshot] ?? []
                    let videoLikeSnapshots = syncSpace.videoLikeSnapshots?.allObjects as? [VideoLikeSnapshot] ?? []
                    return (
                        records.map { $0 as NSManagedObject } +
                        followerSnapshots.map { $0 as NSManagedObject } +
                        videoLikeSnapshots.map { $0 as NSManagedObject }
                    )
                        .filter {
                            !$0.objectID.isTemporaryID &&
                            $0.objectID.persistentStore == privatePersistentStore
                        }
                        .map(\.objectID)
                }

                guard !childObjectIDs.isEmpty else { return }
                self.scheduleOwnedShareRetry(for: childObjectIDs, attempt: 1, delayOverride: 0.2)
            } catch {
                AppLogger.shared.log("检查共享补同步失败: \(Self.describe(error))")
            }
        }
    }

    private func processOwnedShareRetry(for objectIDs: [NSManagedObjectID], attempt: Int) {
        guard let privatePersistentStore else { return }

        container.performBackgroundTask { context in
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

            var groupedObjects: [NSManagedObjectID: [NSManagedObject]] = [:]
            for objectID in objectIDs {
                guard
                    !objectID.isTemporaryID,
                    let object = try? context.existingObject(with: objectID),
                    object.objectID.persistentStore == privatePersistentStore,
                    let syncSpace = self.syncSpace(for: object)
                else {
                    continue
                }

                groupedObjects[syncSpace.objectID, default: []].append(object)
            }

            for (syncSpaceID, objects) in groupedObjects {
                let objectsNeedingShare = self.objectsNeedingShare(objects)
                guard !objectsNeedingShare.isEmpty else { continue }

                do {
                    guard let share = try self.container.fetchShares(matching: [syncSpaceID])[syncSpaceID] else {
                        continue
                    }

                    let retryObjectIDs = objectsNeedingShare.map(\.objectID)
                    self.container.share(objectsNeedingShare, to: share) { _, _, _, error in
                        if let error {
                            AppLogger.shared.log("新增记录加入共享失败: \(Self.describe(error))")
                            self.scheduleOwnedShareRetry(for: retryObjectIDs, attempt: attempt + 1)
                        } else {
                            AppLogger.shared.log("新增记录已加入共享 \(retryObjectIDs.count) 条")
                        }
                    }
                } catch {
                    AppLogger.shared.log("读取共享信息失败: \(Self.describe(error))")
                    self.scheduleOwnedShareRetry(for: objects.map(\.objectID), attempt: attempt + 1)
                }
            }
        }
    }

    private func syncSpace(for object: NSManagedObject) -> SyncSpace? {
        switch object {
        case let record as AdRecord:
            record.syncSpace
        case let snapshot as FollowerSnapshot:
            snapshot.syncSpace
        case let snapshot as VideoLikeSnapshot:
            snapshot.syncSpace
        default:
            nil
        }
    }

    private func objectsNeedingShare(_ objects: [NSManagedObject]) -> [NSManagedObject] {
        let objectIDs = objects.map(\.objectID)
        guard !objectIDs.isEmpty else { return [] }

        do {
            let existingShares = try container.fetchShares(matching: objectIDs)
            return objects.filter { existingShares[$0.objectID] == nil }
        } catch {
            AppLogger.shared.log("检查记录共享状态失败，将重试补共享: \(Self.describe(error))")
            return objects
        }
    }

    private func scheduleOwnedShareRetry(
        for objectIDs: [NSManagedObjectID],
        attempt: Int,
        delayOverride: TimeInterval? = nil
    ) {
        let stableObjectIDs = objectIDs.filter { !$0.isTemporaryID }
        guard !stableObjectIDs.isEmpty else { return }
        guard attempt <= maxShareRetryAttempts else {
            AppLogger.shared.log("新增记录加入共享已多次失败，请稍后打开隐藏设置页重新点一次创建/管理共享")
            return
        }

        let retryKey = stableObjectIDs
            .map { $0.uriRepresentation().absoluteString }
            .sorted()
            .joined(separator: "|")
        let delay: TimeInterval = delayOverride ?? [6, 18, 45, 120, 240][min(attempt - 1, 4)]

        DispatchQueue.main.async {
            guard !self.scheduledShareRetryKeys.contains(retryKey) else { return }
            self.scheduledShareRetryKeys.insert(retryKey)
            AppLogger.shared.log("将在 \(Int(delay)) 秒后重试补共享 \(stableObjectIDs.count) 条记录")

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.scheduledShareRetryKeys.remove(retryKey)
                self.processOwnedShareRetry(for: stableObjectIDs, attempt: attempt)
            }
        }
    }

    func persistUpdatedShare(
        _ share: CKShare,
        for syncSpace: SyncSpace,
        completion: ((Error?) -> Void)? = nil
    ) {
        guard let store = syncSpace.objectID.persistentStore else {
            completion?(nil)
            return
        }
        container.persistUpdatedShare(share, in: store) { _, error in
            if let error {
                AppLogger.shared.log("保存共享设置失败: \(Self.describe(error))")
            } else {
                AppLogger.shared.log("共享设置已更新")
            }
            completion?(error)
        }
    }

    func acceptShare(_ metadata: CKShare.Metadata) {
        guard let sharedPersistentStore else {
            AppLogger.shared.log("接受共享失败: 缺少 shared CloudKit store")
            return
        }

        container.acceptShareInvitations(from: [metadata], into: sharedPersistentStore) { accepted, error in
            if let error {
                AppLogger.shared.log("接受共享失败: \(Self.describe(error))")
            } else {
                AppLogger.shared.log("已接受共享邀请，数量 \(accepted?.count ?? 0)")
                DispatchQueue.main.async {
                    self.container.viewContext.refreshAllObjects()
                    NotificationCenter.default.post(name: .adRecordsDidChange, object: nil)
                }
            }
        }
    }

    func cloudAccountStatus(completion: @escaping (CKAccountStatus, Error?) -> Void) {
        CKContainer(identifier: Self.cloudKitContainerIdentifier).accountStatus(completionHandler: completion)
    }

    private func observeCloudKitEvents() {
        cloudKitEventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main
        ) { notification in
            guard
                let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                let error = event.error
            else {
                return
            }

            AppLogger.shared.log("CloudKit \(String(describing: event.type)) 失败: \(Self.describe(error))")
        }
    }

    private func configure(
        _ description: NSPersistentStoreDescription,
        databaseScope: CKDatabase.Scope,
        containerIdentifier: String
    ) {
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)

        let options = NSPersistentCloudKitContainerOptions(containerIdentifier: containerIdentifier)
        options.databaseScope = databaseScope
        description.cloudKitContainerOptions = options
    }

    private static func defaultStoreURL(named fileName: String) -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier ?? "QianDuoDuo", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    private func persistentStore(matching fileName: String) -> NSPersistentStore? {
        container.persistentStoreCoordinator.persistentStores.first { store in
            store.url?.lastPathComponent == fileName
        }
    }

    private func makeSyncSpace(in context: NSManagedObjectContext, store: NSPersistentStore?) -> SyncSpace {
        let syncSpace = SyncSpace(context: context)
        if let store {
            context.assign(syncSpace, to: store)
        }
        syncSpace.id = UUID()
        syncSpace.name = "钱多多共享数据"
        syncSpace.createdAt = Date()
        syncSpace.updatedAt = Date()
        return syncSpace
    }

    private func attachPrivateOrphanRecords(to syncSpace: SyncSpace, in context: NSManagedObjectContext) throws {
        guard let syncSpaceStore = syncSpace.objectID.persistentStore else { return }

        let request: NSFetchRequest<AdRecord> = AdRecord.fetchRequest()
        request.predicate = NSPredicate(format: "syncSpace == nil")
        let records = try context.fetch(request)

        for record in records {
            if record.objectID.isTemporaryID {
                context.assign(record, to: syncSpaceStore)
                record.syncSpace = syncSpace
            } else if record.objectID.persistentStore == syncSpaceStore {
                record.syncSpace = syncSpace
            }
        }

        let followerRequest: NSFetchRequest<FollowerSnapshot> = FollowerSnapshot.fetchRequest()
        followerRequest.predicate = NSPredicate(format: "syncSpace == nil")
        let followerSnapshots = try context.fetch(followerRequest)

        for snapshot in followerSnapshots {
            if snapshot.objectID.isTemporaryID {
                context.assign(snapshot, to: syncSpaceStore)
                snapshot.syncSpace = syncSpace
            } else if snapshot.objectID.persistentStore == syncSpaceStore {
                snapshot.syncSpace = syncSpace
            }
        }

        let videoLikeRequest: NSFetchRequest<VideoLikeSnapshot> = VideoLikeSnapshot.fetchRequest()
        videoLikeRequest.predicate = NSPredicate(format: "syncSpace == nil")
        let videoLikeSnapshots = try context.fetch(videoLikeRequest)

        for snapshot in videoLikeSnapshots {
            if snapshot.objectID.isTemporaryID {
                context.assign(snapshot, to: syncSpaceStore)
                snapshot.syncSpace = syncSpace
            } else if snapshot.objectID.persistentStore == syncSpaceStore {
                snapshot.syncSpace = syncSpace
            }
        }

        if !records.isEmpty || !followerSnapshots.isEmpty || !videoLikeSnapshots.isEmpty {
            syncSpace.updatedAt = Date()
        }
    }

    private func objectsToShare(with syncSpace: SyncSpace) -> [NSManagedObject] {
        var objects: [NSManagedObject] = [syncSpace]
        if let records = syncSpace.records?.allObjects as? [AdRecord] {
            objects.append(contentsOf: records)
        }
        if let followerSnapshots = syncSpace.followerSnapshots?.allObjects as? [FollowerSnapshot] {
            objects.append(contentsOf: followerSnapshots)
        }
        if let videoLikeSnapshots = syncSpace.videoLikeSnapshots?.allObjects as? [VideoLikeSnapshot] {
            objects.append(contentsOf: videoLikeSnapshots)
        }
        return objects
    }

    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var pieces = [
            "\(nsError.domain) code \(nsError.code)",
            nsError.localizedDescription
        ]

        if let ckError = error as? CKError {
            pieces.append("CKError \(ckError.code.rawValue) \(ckError.code)")
            if let serverDescription = ckError.userInfo["ServerDescription"] as? String {
                pieces.append("server: \(serverDescription)")
            }
            if let retryAfter = ckError.userInfo[CKErrorRetryAfterKey] {
                pieces.append("retryAfter: \(retryAfter)")
            }
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            pieces.append("underlying: \(describe(underlyingError))")
        }

        if let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
           !partialErrors.isEmpty {
            let details = partialErrors.map { key, value in
                "\(key): \(describe(value))"
            }
            pieces.append("partial: \(details.joined(separator: " | "))")
        }

        return pieces.joined(separator: "；")
    }
}
