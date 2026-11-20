import Combine
import CoreData
import Foundation

/// A separate context keeps quick todo edits from committing unfinished business forms.
@MainActor
final class TodoStore: NSObject, ObservableObject, @preconcurrency NSFetchedResultsControllerDelegate {
    @Published private(set) var items: [TodoItem] = []
    @Published var errorMessage: String?

    let context: NSManagedObjectContext
    private let existingSpace: (NSManagedObjectContext) throws -> SyncSpace?
    private let activeSpace: (NSManagedObjectContext) throws -> SyncSpace
    private let canUpdateObject: (NSManagedObject) -> Bool
    private let canDeleteObject: (NSManagedObject) -> Bool
    private let didCreate: ([TodoItem]) -> Void
    private let results: NSFetchedResultsController<TodoItem>
    private var scopeID: NSManagedObjectID?
    private var activeScope: SyncSpace?
    private var scopeFetchFailed = false
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?

    convenience init(persistence: PersistenceController? = nil) {
        let persistence = persistence ?? .shared
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = persistence.container.persistentStoreCoordinator
        self.init(
            context: context,
            existingSpace: { try persistence.existingActiveSyncSpace(in: $0) },
            activeSpace: { try persistence.activeSyncSpace(in: $0) },
            canUpdate: { object in
                object.objectID.isTemporaryID ||
                    object.objectID.persistentStore != persistence.sharedPersistentStore ||
                    persistence.container.canUpdateRecord(forManagedObjectWith: object.objectID)
            },
            canDelete: { object in
                object.objectID.isTemporaryID ||
                    object.objectID.persistentStore != persistence.sharedPersistentStore ||
                    persistence.container.canDeleteRecord(forManagedObjectWith: object.objectID)
            },
            didCreate: { persistence.shareOwnedTodoItemsIfNeeded($0) }
        )
        // The context's automatic merging handles local edits and CloudKit saves. Import
        // completion also refreshes its small registered graph after a data-space switch.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: persistence.container, queue: nil
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .import, event.endDate != nil, event.succeeded else { return }
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        })
    }

    /// Also used by native SQLite tests without signing in to or contacting iCloud.
    init(
        context: NSManagedObjectContext,
        existingSpace: @escaping (NSManagedObjectContext) throws -> SyncSpace?,
        activeSpace: @escaping (NSManagedObjectContext) throws -> SyncSpace,
        canUpdate: @escaping (NSManagedObject) -> Bool,
        canDelete: @escaping (NSManagedObject) -> Bool,
        didCreate: @escaping ([TodoItem]) -> Void = { _ in }
    ) {
        self.context = context
        self.existingSpace = existingSpace
        self.activeSpace = activeSpace
        canUpdateObject = canUpdate
        canDeleteObject = canDelete
        self.didCreate = didCreate
        context.name = "TodoStore"
        context.undoManager = nil
        // Never recreate a remotely deleted item to resolve a save conflict.
        context.mergePolicy = NSErrorMergePolicy
        context.automaticallyMergesChangesFromParent = true
        let request: NSFetchRequest<TodoItem> = TodoItem.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \TodoItem.sortOrder, ascending: true),
            NSSortDescriptor(keyPath: \TodoItem.createdAt, ascending: true),
            NSSortDescriptor(keyPath: \TodoItem.id, ascending: true)
        ]
        request.fetchBatchSize = 100
        request.shouldRefreshRefetchedObjects = true
        request.predicate = NSPredicate(value: false)
        results = NSFetchedResultsController(fetchRequest: request, managedObjectContext: context,
                                             sectionNameKeyPath: nil, cacheName: nil)
        super.init()
        results.delegate = self
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange, object: context, queue: nil
        ) { [weak self] note in
            // Todo row changes are handled by the FRC. Re-evaluate the scope only
            // when spaces change, avoiding a whole-app fetch for every checkbox.
            let changedSpaces = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey,
                                 NSRefreshedObjectsKey, NSInvalidatedObjectsKey].contains { key in
                (note.userInfo?[key] as? Set<NSManagedObject>)?.contains { $0 is SyncSpace } == true
            }
            guard changedSpaces || note.userInfo?[NSInvalidatedAllObjectsKey] != nil else { return }
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        })
        do { try refresh() } catch { errorMessage = error.localizedDescription }
    }

    deinit {
        refreshTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        results.delegate = nil
        // Release fetched object IDs before the coordinator can be torn down.
        results.fetchRequest.predicate = NSPredicate(value: false)
        try? results.performFetch()
    }

    var canCreate: Bool {
        guard !scopeFetchFailed else { return false }
        guard let activeScope, !activeScope.isDeleted else { return true }
        return canUpdateObject(activeScope)
    }

    func canEdit(_ item: TodoItem) -> Bool {
        guard !item.isDeleted, item.managedObjectContext != nil,
              let space = item.syncSpace else { return false }
        return canCreate && space.objectID == scopeID && canUpdateObject(item)
    }

    /// Viewing an empty list never creates or saves a SyncSpace.
    func refresh() throws {
        let space: SyncSpace?
        do {
            space = try existingSpace(context)
            scopeFetchFailed = false
        } catch {
            scopeFetchFailed = true
            throw error
        }
        activeScope = space
        scopeID = space?.objectID
        if let space {
            results.fetchRequest.predicate = NSPredicate(format: "syncSpace == %@", space)
            results.fetchRequest.affectedStores = space.objectID.persistentStore.map { [$0] }
        } else {
            results.fetchRequest.predicate = NSPredicate(value: false)
            results.fetchRequest.affectedStores = nil
        }
        try results.performFetch()
        items = results.fetchedObjects ?? []
    }

    @discardableResult
    func create(title: String, notes: String = "", dueDate: Date? = nil, link: TodoContentLink? = nil) throws -> TodoItem? {
        guard let title = TodoRules.normalizedTitle(title) else { return nil }
        return try mutate {
            try refresh()
            let space = try activeSpace(context)
            guard canUpdateObject(space) else { throw StoreError.readOnly }
            let linkedContent = try validatedLink(link, in: space)
            let item = TodoItem(entity: results.fetchRequest.entity ??
                NSEntityDescription.entity(forEntityName: "TodoItem", in: context)!, insertInto: context)
            if let store = space.objectID.persistentStore { context.assign(item, to: store) }
            let now = Date()
            item.id = UUID()
            item.title = title
            item.notes = notes
            item.linkedContent = linkedContent
            item.dueDate = dueDate
            item.createdAt = now
            item.updatedAt = now
            item.sortOrder = (items.map(\.sortOrder).filter(\.isFinite).max() ?? -1) + 1
            item.syncSpace = space
            try context.save()
            try refresh()
            didCreate([item])
            return item
        }
    }

    /// Existing callers editing a title/date keep the association unchanged.
    func update(_ item: TodoItem, title: String, notes: String, dueDate: Date?) throws {
        try update(item, title: title, notes: notes, dueDate: dueDate, linkChange: nil)
    }

    /// Passing nil explicitly removes the association.
    func update(_ item: TodoItem, title: String, notes: String, dueDate: Date?, link: TodoContentLink?) throws {
        try update(item, title: title, notes: notes, dueDate: dueDate, linkChange: .some(link))
    }

    private func update(_ item: TodoItem, title: String, notes: String, dueDate: Date?,
                        linkChange: TodoContentLink??) throws {
        guard let title = TodoRules.normalizedTitle(title) else { throw StoreError.emptyTitle }
        try mutate {
            let current = try requireEditable(item)
            if let link = linkChange {
                if link != current.contentLink {
                    guard let space = current.syncSpace else { throw StoreError.unavailable }
                    current.linkedContent = try validatedLink(link, in: space)
                } else if link == nil {
                    // A malformed old payload can still be explicitly removed.
                    current.linkedContent = nil
                }
            }
            current.title = title
            current.notes = notes
            current.dueDate = dueDate
            current.updatedAt = Date()
            try context.save()
        }
    }

    /// Calendar drags change only the date of an existing, unfinished todo.
    @discardableResult
    func reschedule(_ item: TodoItem, to date: Date) throws -> Date {
        let destination = dayOnly(date)
        return try mutate {
            // Resolve into this store's context and read the latest saved state
            // before accepting a drag that began before a remote edit.
            let current = try requireEditable(item, refreshing: true)
            guard current.completedAt == nil, let previousDate = current.dueDate else {
                throw StoreError.calendarUnavailable
            }
            guard !qddCalendar.isDate(previousDate, inSameDayAs: destination) else { return destination }
            current.dueDate = destination
            current.updatedAt = Date()
            try context.save()
            return destination
        }
    }

    /// The picker and resolver must never search another private/shared store.
    func contentRecords() throws -> [AdRecord] {
        guard let space = try existingSpace(context) else { return [] }
        return try contentRecords(in: space)
    }

    private func contentRecords(in space: SyncSpace) throws -> [AdRecord] {
        let request: NSFetchRequest<AdRecord> = AdRecord.fetchRequest()
        request.predicate = NSPredicate(format: "syncSpace == %@", space)
        request.affectedStores = space.objectID.persistentStore.map { [$0] }
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \AdRecord.createdAt, ascending: false),
            NSSortDescriptor(keyPath: \AdRecord.id, ascending: true)
        ]
        request.shouldRefreshRefetchedObjects = true
        request.includesPendingChanges = false
        return try context.fetch(request)
    }

    private func validatedLink(_ link: TodoContentLink?, in space: SyncSpace) throws -> String? {
        guard let link else { return nil }
        guard let encoded = link.encodedValue else { throw StoreError.contentUnavailable }
        let resolved = link.resolvedRecords(in: try contentRecords(in: space))
        let ids = Set(resolved.compactMap(\.id))
        guard Set(link.recordIDs).isSubset(of: ids) else { throw StoreError.contentUnavailable }
        return encoded
    }

    func rename(_ item: TodoItem, title: String) throws {
        guard let title = TodoRules.normalizedTitle(title) else { throw StoreError.emptyTitle }
        try mutate {
            let current = try requireEditable(item)
            current.title = title
            current.updatedAt = Date()
            try context.save()
        }
    }

    func toggleCompletion(_ item: TodoItem) throws {
        try mutate {
            let current = try requireEditable(item)
            let now = Date()
            current.completedAt = current.completedAt == nil ? now : nil
            current.updatedAt = now
            try context.save()
        }
    }

    /// Repeated widget actions must not undo completion or reset its original date.
    func setCompletion(_ item: TodoItem, completed: Bool) throws {
        try mutate {
            let current = try requireEditable(item, refreshing: true)
            guard (current.completedAt != nil) != completed else { return }
            let now = Date()
            current.completedAt = completed ? now : nil
            current.updatedAt = now
            try context.save()
        }
    }

    func delete(_ item: TodoItem) throws {
        try mutate {
            let current = try requireEditable(item, deleting: true)
            context.delete(current)
            try context.save()
        }
    }

    func deleteCompleted() throws {
        try mutate {
            try refresh()
            let completed = try items.filter { $0.completedAt != nil }.map { try requireEditable($0, deleting: true) }
            completed.forEach(context.delete)
            if context.hasChanges { try context.save() }
        }
    }

    /// The supplied rows come first; omitted rows retain their relative order.
    func move(ids: [NSManagedObjectID]) throws {
        try mutate {
            try refresh()
            guard Set(ids).count == ids.count else { throw StoreError.unavailable }
            let selected = try ids.map { id -> TodoItem in
                guard let item = items.first(where: { $0.objectID == id }) else { throw StoreError.unavailable }
                return try requireEditable(item)
            }
            let selectedIDs = Set(ids)
            let ordered = selected + items.filter { !selectedIDs.contains($0.objectID) }
            let now = Date()
            for (index, item) in ordered.enumerated() where item.sortOrder != Double(index) {
                let current = try requireEditable(item)
                current.sortOrder = Double(index)
                current.updatedAt = now
            }
            if context.hasChanges { try context.save() }
        }
    }

    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        items = results.fetchedObjects ?? []
    }

    private func requireEditable(_ item: TodoItem, deleting: Bool = false, refreshing: Bool = false) throws -> TodoItem {
        guard !item.isDeleted, item.managedObjectContext != nil, !item.objectID.isTemporaryID else {
            throw StoreError.unavailable
        }
        let request: NSFetchRequest<TodoItem> = TodoItem.fetchRequest()
        request.predicate = NSPredicate(format: "SELF == %@", item.objectID)
        request.affectedStores = item.objectID.persistentStore.map { [$0] }
        request.fetchLimit = 1
        request.shouldRefreshRefetchedObjects = true
        guard let current = try context.fetch(request).first, !current.isDeleted else {
            throw StoreError.unavailable
        }
        // An explicit desired state must use the latest saved value even before
        // this context receives another context's asynchronous automatic merge.
        if refreshing { context.refresh(current, mergeChanges: false) }
        guard let space = try existingSpace(context), current.syncSpace?.objectID == space.objectID else {
            throw StoreError.unavailable
        }
        guard canUpdateObject(space), deleting ? canDeleteObject(current) : canUpdateObject(current) else {
            throw StoreError.readOnly
        }
        return current
    }

    private func mutate<T>(_ action: () throws -> T) throws -> T {
        do {
            let value = try action()
            errorMessage = nil
            return value
        } catch {
            // This context contains only the current short todo operation.
            context.rollback()
            try? refresh()
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            do { try self.refresh() } catch { self.errorMessage = error.localizedDescription }
        }
    }

    enum StoreError: LocalizedError {
        case readOnly, emptyTitle, unavailable, contentUnavailable, calendarUnavailable

        var errorDescription: String? {
            switch self {
            case .readOnly: "当前共享只允许查看，无法修改待办。"
            case .emptyTitle: "请输入待办事项。"
            case .unavailable: "这条待办已被删除或不在当前数据空间，请刷新后重试。"
            case .contentUnavailable: "关联内容已被删除、移动或不在当前数据空间，请重新选择。"
            case .calendarUnavailable: "这条待办已完成或已清除日期，请刷新后重试。"
            }
        }
    }
}
