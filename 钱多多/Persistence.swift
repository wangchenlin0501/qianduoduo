//
//  Persistence.swift
//  钱多多
//
//  Created by Mashiro on 2026/5/7.
//

import CloudKit
import Combine
import CoreData

/// Whether the on-disk stores are usable. The app renders its data screens only for `.ready`.
nonisolated enum PersistentStoreLoadState {
    case loading
    case ready
    /// A store could not be opened. Nothing is retried, recreated or deleted; the files stay as they were.
    case failed(NSError)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Collects the `loadPersistentStores` callbacks, one per store description.
///
/// `PersistenceController.init` forces `shouldAddStoreAsynchronously = false`, so every callback runs
/// on the calling thread before `loadPersistentStores` returns. The lock and the deferred hand-off only
/// matter if that contract is ever broken: the app then stays on the loading screen until the last store
/// reports, instead of rendering against a coordinator that has no stores yet.
private nonisolated final class StoreLoadTracker: @unchecked Sendable {
    nonisolated enum Outcome {
        case pending
        case finished(NSError?)
    }

    private let lock = NSLock()
    private var remaining: Int
    private var firstError: NSError?
    private var onFinish: (@Sendable (NSError?) -> Void)?

    init(expectedStores: Int) {
        remaining = expectedStores
    }

    func record(_ error: Error?) {
        lock.lock()
        if let error, firstError == nil { firstError = error as NSError }
        remaining -= 1
        let finish = remaining == 0 ? onFinish : nil
        if finish != nil { onFinish = nil }
        let result = firstError
        lock.unlock()
        finish?(result)
    }

    /// Returns the result if every store has reported; otherwise `onFinish` runs after the last callback.
    func outcome(orWhenFinished onFinish: @escaping @Sendable (NSError?) -> Void) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return .finished(firstError) }
        self.onFinish = onFinish
        return .pending
    }
}

final class PersistenceController: ObservableObject {
    /// Where the stores live. Production uses CloudKit; tests use memory or a plain local SQLite file.
    enum StoreLocation {
        case cloudKit
        case inMemory
        case localFile(URL)
    }

    static let cloudKitContainerIdentifier = Bundle.main.object(forInfoDictionaryKey: "QDDCloudKitContainerIdentifier") as? String ?? "iCloud.com.example.qianduoduo"
    static let shared = PersistenceController()
    /// A failed store is never retried, replaced by an empty store, or deleted. The app shows a recovery
    /// screen instead of crashing on every launch, which would also block exporting diagnostics.
    @Published private(set) var loadState: PersistentStoreLoadState = .loading
    private let maxShareRetryAttempts = 5
    private var scheduledShareRetryKeys: Set<String> = []
    private var shareRepairGate = CloudShareRepairGate()
    private var cloudKitEventObserver: NSObjectProtocol?
    private(set) var sharingConfigurationError: CloudSyncConfigurationError?

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
            ("Luna Studio", "wx_lunastudio", .clothing, 1, 3200, .paid, true, -18, -16, -3, .weChat, "五月第一期"),
            ("Faye Select", "wx_fayeselect", .skirt, 2, 2600, .unpaid, true, -8, -7, nil, .bankCard, "五月第二期"),
            ("NOVA", "wx_nova", .pants, 1, 4500, .unpaid, false, nil, nil, nil, .alipay, ""),
            ("森系衣橱", "wx_senxi", .accessory, 3, 1800, .paid, true, 4, 5, 7, .alipay, "六月第一期")
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

    convenience init(inMemory: Bool = false) {
        self.init(location: inMemory ? .inMemory : .cloudKit)
    }

    init(location: StoreLocation) {
        container = NSPersistentCloudKitContainer(name: "QianDuoDuo")

        switch location {
        case .inMemory:
            guard let description = container.persistentStoreDescriptions.first else {
                finishLoading(Self.configurationError("缺少数据库配置"))
                return
            }
            description.url = URL(fileURLWithPath: "/dev/null")
            description.cloudKitContainerOptions = nil
        case .localFile(let url):
            container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
        case .cloudKit:
            // Establish the session boundary before CloudKit can commit its first import.
            _ = AppLogger.shared
            guard let privateDescription = container.persistentStoreDescriptions.first else {
                finishLoading(Self.configurationError("缺少数据库配置"))
                return
            }
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

        observeCloudKitEvents()

        // Everything that touches `shared` (app delegate, scene delegate, tests) expects attached stores
        // once `init` returns, so loading stays synchronous on purpose. Each description is loaded once;
        // a failed store is reported, never retried, recreated or deleted.
        let descriptions = container.persistentStoreDescriptions
        guard !descriptions.isEmpty else {
            finishLoading(Self.configurationError("缺少数据库配置"))
            return
        }
        descriptions.forEach { $0.shouldAddStoreAsynchronously = false }
        let tracker = StoreLoadTracker(expectedStores: descriptions.count)
        container.loadPersistentStores { _, error in
            tracker.record(error)
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        switch tracker.outcome(orWhenFinished: { error in
            DispatchQueue.main.async { [weak self] in self?.finishLoading(error) }
        }) {
        case .finished(let error):
            finishLoading(error)
        case .pending:
            AppLogger.shared.log("数据库仍在打开，完成前不显示数据页面")
        }
    }

    private func finishLoading(_ error: NSError?) {
        guard case .loading = loadState else { return }
        if let error {
            loadState = .failed(error)
            AppLogger.shared.log("数据库打开失败，已进入恢复页面；未重试、未新建或删除数据库文件: \(Self.describe(error))")
        } else {
            loadState = .ready
        }
    }

    private static func configurationError(_ message: String) -> NSError {
        NSError(domain: "QianDuoDuo.Persistence", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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
        try existingActiveSyncSpace(in: context) ?? makeSyncSpace(in: context, store: privatePersistentStore)
    }

    func existingActiveSyncSpace(in context: NSManagedObjectContext) throws -> SyncSpace? {
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

        return nil
    }

    @MainActor
    func makeCelebrationSoundSync() -> PublishCelebrationSoundSync {
        let context = container.viewContext
        return PublishCelebrationSoundSync(
            context: context,
            activeSpace: { try self.activeSyncSpace(in: context) },
            existingSpace: { try self.existingActiveSyncSpace(in: context) },
            canUpdate: { space in
                space.objectID.isTemporaryID || space.objectID.persistentStore != self.sharedPersistentStore ||
                    self.container.canUpdateRecord(forManagedObjectWith: space.objectID)
            },
            legacyStorage: try? PublishCelebrationSoundStorage.applicationStorage()
        )
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

    /// Todo writes propagate errors so a failed assignment never saves into the wrong data space.
    func prepareNewTodoItem(_ item: TodoItem, in context: NSManagedObjectContext) throws {
        let syncSpace = try activeSyncSpace(in: context)
        guard syncSpace.objectID.isTemporaryID || syncSpace.objectID.persistentStore != sharedPersistentStore ||
                container.canUpdateRecord(forManagedObjectWith: syncSpace.objectID) else {
            throw TodoStore.StoreError.readOnly
        }
        if item.objectID.isTemporaryID, let store = syncSpace.objectID.persistentStore {
            context.assign(item, to: store)
        }
        item.syncSpace = syncSpace
        syncSpace.updatedAt = Date()
    }

    func shareOwnedTodoItemsIfNeeded(_ items: [TodoItem]) {
        scheduleOwnedShareRetry(for: items.map(\.objectID).filter { !$0.isTemporaryID }, attempt: 1, delayOverride: 0.8)
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

    func repairOwnedShareMembership(force: Bool = false) {
        scheduleOwnedShareRepair(force: force)
    }

    private func scheduleOwnedShareRepair(force: Bool) {
        DispatchQueue.main.async {
            guard self.sharingConfigurationError == nil else { return }
            guard self.shareRepairGate.begin(at: Date(), force: force) else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard self.sharingConfigurationError == nil else {
                    self.shareRepairGate.finish(at: Date(), succeeded: false)
                    return
                }
                self.processOwnedShareRepair()
            }
        }
    }

    private func processOwnedShareRepair() {
        container.performBackgroundTask { context in
            var succeeded = false
            defer {
                let completedSuccessfully = succeeded
                DispatchQueue.main.async {
                    self.shareRepairGate.finish(at: Date(), succeeded: completedSuccessfully)
                }
            }
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            guard let privatePersistentStore = self.privatePersistentStore else { return }

            let request: NSFetchRequest<SyncSpace> = SyncSpace.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \SyncSpace.createdAt, ascending: true)]
            request.affectedStores = [privatePersistentStore]

            do {
                let spaces = try context.fetch(request)

                var childObjectIDs: [NSManagedObjectID] = []
                for syncSpace in spaces {
                    guard
                        try self.container.fetchShares(matching: [syncSpace.objectID])[syncSpace.objectID] != nil
                    else {
                        continue
                    }
                    for entity in ["AdRecord", "FollowerSnapshot", "VideoLikeSnapshot", "TodoItem"] {
                        let childRequest = NSFetchRequest<NSManagedObjectID>(entityName: entity)
                        childRequest.resultType = .managedObjectIDResultType
                        childRequest.predicate = NSPredicate(format: "syncSpace == %@", syncSpace)
                        childRequest.affectedStores = [privatePersistentStore]
                        childRequest.includesPropertyValues = false
                        childObjectIDs.append(contentsOf: try context.fetch(childRequest))
                    }
                }
                guard !childObjectIDs.isEmpty else { succeeded = true; return }
                let needingShare = try self.objectIDsNeedingShare(childObjectIDs)
                succeeded = true
                AppLogger.shared.log("共享关联检查：检查 \(childObjectIDs.count) 条，本机已关联 \(childObjectIDs.count - needingShare.count) 条，待加入 \(needingShare.count) 条；关联状态不代表已上传")
                guard !needingShare.isEmpty else { return }
                self.scheduleOwnedShareRetry(for: needingShare, attempt: 1, delayOverride: 0.2)
            } catch {
                AppLogger.shared.log("检查共享补同步失败: \(Self.describe(error))")
                self.pauseSharingIfConfigurationError(error)
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
                do {
                    let objectsNeedingShare = try self.objectsNeedingShare(objects)
                    guard !objectsNeedingShare.isEmpty else { continue }
                    guard let share = try self.container.fetchShares(matching: [syncSpaceID])[syncSpaceID] else {
                        continue
                    }

                    let retryObjectIDs = objectsNeedingShare.map(\.objectID)
                    self.container.share(objectsNeedingShare, to: share) { _, _, _, error in
                        if let error {
                            AppLogger.shared.log("新增记录加入共享失败: \(Self.describe(error))")
                            if !self.pauseSharingIfConfigurationError(error) {
                                self.scheduleOwnedShareRetry(for: retryObjectIDs, attempt: attempt + 1)
                            }
                        } else {
                            AppLogger.shared.log("新增记录已加入共享 \(retryObjectIDs.count) 条")
                        }
                    }
                } catch {
                    AppLogger.shared.log("读取共享信息失败: \(Self.describe(error))")
                    if !self.pauseSharingIfConfigurationError(error) {
                        self.scheduleOwnedShareRetry(for: objects.map(\.objectID), attempt: attempt + 1)
                    }
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
        case let item as TodoItem:
            item.syncSpace
        default:
            nil
        }
    }

    private func objectsNeedingShare(_ objects: [NSManagedObject]) throws -> [NSManagedObject] {
        let missingIDs = Set(try objectIDsNeedingShare(objects.map(\.objectID)))
        return objects.filter { missingIDs.contains($0.objectID) }
    }

    private func objectIDsNeedingShare(_ objectIDs: [NSManagedObjectID]) throws -> [NSManagedObjectID] {
        guard !objectIDs.isEmpty else { return [] }
        var missing: [NSManagedObjectID] = []
        // Read local sharing metadata in small batches; do not fault records or screenshot blobs.
        for start in stride(from: 0, to: objectIDs.count, by: 200) {
            let batch = Array(objectIDs[start..<min(start + 200, objectIDs.count)])
            let existingShares = try container.fetchShares(matching: batch)
            missing.append(contentsOf: batch.filter { existingShares[$0] == nil })
        }
        return missing
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
            guard self.sharingConfigurationError == nil else { return }
            guard !self.scheduledShareRetryKeys.contains(retryKey) else { return }
            self.scheduledShareRetryKeys.insert(retryKey)
            let delayText = String(format: "%.1f", delay)
            AppLogger.shared.log("将在 \(delayText) 秒后检查补共享 \(stableObjectIDs.count) 条记录")

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.scheduledShareRetryKeys.remove(retryKey)
                guard self.sharingConfigurationError == nil else { return }
                self.processOwnedShareRetry(for: stableObjectIDs, attempt: attempt)
            }
        }
    }

    func persistUpdatedShare(
        _ share: CKShare,
        for syncSpaceID: NSManagedObjectID,
        completion: ((Error?) -> Void)? = nil
    ) {
        guard let store = syncSpaceID.persistentStore else {
            completion?(nil)
            return
        }
        container.persistUpdatedShare(share, in: store) { _, error in
            if let error {
                AppLogger.shared.log("保存共享设置失败: \(Self.describe(error))")
                self.pauseSharingIfConfigurationError(error)
            } else {
                AppLogger.shared.log("共享设置已更新")
            }
            completion?(error)
        }
    }

    func acceptShare(_ metadata: CKShare.Metadata) {
        guard loadState.isReady else {
            AppLogger.shared.log("接受共享失败: 数据库未就绪，请在数据恢复后重新打开邀请链接")
            return
        }
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

    func logSyncStoreSummary() {
        container.performBackgroundTask { context in
            do {
                for store in self.container.persistentStoreCoordinator.persistentStores {
                    let label = store == self.sharedPersistentStore ? "共享库" : "私有库"
                    var counts: [String] = []
                    for entity in ["SyncSpace", "AdRecord", "FollowerSnapshot", "VideoLikeSnapshot", "TodoItem"] {
                        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
                        request.affectedStores = [store]
                        counts.append("\(entity)=\(try context.count(for: request))")
                    }
                    AppLogger.shared.log("同步诊断 \(label)：\(counts.joined(separator: ", "))")
                }
                let request: NSFetchRequest<SyncSpace> = SyncSpace.fetchRequest()
                for space in try context.fetch(request) {
                    let spaceID = space.id.map { String($0.uuidString.prefix(8)) } ?? "未知"
                    if let share = try self.container.fetchShares(matching: [space.objectID])[space.objectID] {
                        let accepted = share.participants.filter { $0.acceptanceStatus == .accepted }.count
                        let role = share.currentUserParticipant.map { String(describing: $0.role) } ?? "未知"
                        AppLogger.shared.log("同步空间 \(spaceID)：已有共享，本人角色 \(role)，已接受成员 \(accepted)；未读取成员联系方式")
                    } else {
                        AppLogger.shared.log("同步空间 \(spaceID)：本机未找到共享关联")
                    }
                }
            } catch {
                AppLogger.shared.log("读取同步诊断失败：\(Self.describe(error))")
            }
        }
    }

    private func observeCloudKitEvents() {
        // NotificationCenter waits for an observer's OperationQueue to finish. Never
        // make a Core Data / CloudKit posting queue wait for the UI queue, which may
        // itself be fetching from that store (including during store loading).
        cloudKitEventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: nil
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            Task { @MainActor [weak self] in
                self?.recordCloudKitEvent(event)
            }
        }

    }

    private func recordCloudKitEvent(_ event: NSPersistentCloudKitContainer.Event) {
        let stage: String
        switch event.type {
        case .setup: stage = "初始化"
        case .import: stage = "下载"
        case .export: stage = "上传"
        @unknown default: stage = "未知阶段"
        }
        let store = container.persistentStoreCoordinator.persistentStores.first { $0.identifier == event.storeIdentifier }
        let storeLabel = store.map { $0 == sharedPersistentStore ? "共享库" : "私有库" }
            ?? "库 \(event.storeIdentifier.prefix(8))"
        if let error = event.error {
            AppLogger.shared.log("CloudKit \(stage)（\(storeLabel)）失败：\(Self.describe(error))")
            pauseSharingIfConfigurationError(error)
        } else if event.endDate == nil {
            AppLogger.shared.log("CloudKit \(stage)（\(storeLabel)）开始")
        } else {
            AppLogger.shared.log("CloudKit \(stage)（\(storeLabel)）\(event.succeeded ? "完成" : "未完成")")
        }
        CloudSyncRefreshService.shared.record(event)
    }

    /// Configuration failures cannot recover by retrying. A new app launch after an update resets this state.
    @discardableResult
    func pauseSharingIfConfigurationError(_ error: Error) -> Bool {
        guard let configurationError = CloudSyncErrorPolicy.configurationError(in: error) else { return false }
        DispatchQueue.main.async {
            guard self.sharingConfigurationError == nil else { return }
            self.sharingConfigurationError = configurationError
            AppLogger.shared.log(configurationError.localizedDescription)
        }
        return true
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
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? NSPersistentContainer.defaultDirectoryURL()
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

    static func describe(_ error: Error) -> String {
        CloudSyncDiagnostics.describe(error)
    }
}
