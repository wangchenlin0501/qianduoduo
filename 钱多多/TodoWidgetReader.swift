import CoreData
import Foundation

/// Reads saved metadata on its own queue. No managed objects leave this reader.
nonisolated enum TodoWidgetReader {
    struct Appearance: Sendable {
        let themeHex: String
        let lightAccentHex: String
        let darkAccentHex: String
    }

    static func read(
        coordinator: NSPersistentStoreCoordinator,
        privateStore: NSPersistentStore?, sharedStore: NSPersistentStore?,
        sort: String, appearance: Appearance,
        canUpdate: @escaping @Sendable (NSManagedObjectID) -> Bool
    ) async throws -> TodoWidgetSnapshot {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.name = "TodoWidgetMetadataRead"
        context.undoManager = nil
        context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        let privateStoreID = privateStore.map(ObjectIdentifier.init)
        let sharedStoreID = sharedStore.map(ObjectIdentifier.init)
        return try await context.perform {
            let spacesRequest = NSFetchRequest<NSManagedObject>(entityName: "SyncSpace")
            spacesRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            spacesRequest.includesPendingChanges = false
            let spaces = try context.fetch(spacesRequest)
            // Match PersistenceController's current-space policy without creating a space.
            let space = spaces.first {
                sharedStoreID != nil && $0.objectID.persistentStore.map(ObjectIdentifier.init) == sharedStoreID
            } ?? spaces.first {
                privateStoreID != nil && $0.objectID.persistentStore.map(ObjectIdentifier.init) == privateStoreID
            }
                ?? spaces.first
            guard let space else {
                return TodoWidgetSnapshot(status: .ready, generatedAt: Date(), spaceName: nil,
                                          pendingCount: 0, items: [], themeHex: appearance.themeHex,
                                          lightAccentHex: appearance.lightAccentHex,
                                          darkAccentHex: appearance.darkAccentHex)
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: "TodoItem")
            request.predicate = NSPredicate(format: "syncSpace == %@ AND completedAt == nil", space)
            request.affectedStores = space.objectID.persistentStore.map { [$0] }
            request.includesPendingChanges = false
            request.propertiesToFetch = ["id", "title", "createdAt", "dueDate", "sortOrder", "linkedContent"]
            request.returnsObjectsAsFaults = false
            let rows = try context.fetch(request).sorted { first, second in
                func date(_ object: NSManagedObject, _ key: String, fallback: Date) -> Date {
                    object.value(forKey: key) as? Date ?? fallback
                }
                switch sort {
                case "日期":
                    let a = date(first, "dueDate", fallback: .distantFuture)
                    let b = date(second, "dueDate", fallback: .distantFuture)
                    if a != b { return a < b }
                case "创建日期": break
                case "标题":
                    let a = first.value(forKey: "title") as? String ?? ""
                    let b = second.value(forKey: "title") as? String ?? ""
                    let comparison = a.localizedStandardCompare(b)
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                default:
                    let a = (first.value(forKey: "sortOrder") as? Double) ?? 0
                    let b = (second.value(forKey: "sortOrder") as? Double) ?? 0
                    if a != b { return a < b }
                }
                let a = date(first, "createdAt", fallback: .distantPast)
                let b = date(second, "createdAt", fallback: .distantPast)
                if a != b { return a < b }
                return ((first.value(forKey: "id") as? UUID)?.uuidString ?? "")
                    < ((second.value(forKey: "id") as? UUID)?.uuidString ?? "")
            }
            let spaceURI = space.objectID.uriRepresentation().absoluteString
            let spaceCanUpdate = canUpdate(space.objectID)
            let visibleRows = Array(rows.prefix(20))
            let links = visibleRows.map { TodoContentLink.decode($0.value(forKey: "linkedContent") as? String) }
            let linkedRecords = try linkedMetadata(for: links.compactMap { $0 }, space: space, context: context)
            let items = try zip(visibleRows, links).map { object, link -> TodoWidgetSnapshot.Item in
                guard let id = object.value(forKey: "id") as? UUID,
                      let title = object.value(forKey: "title") as? String,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
                var item = TodoWidgetSnapshot.Item(
                    id: id, title: String(title.prefix(400)),
                    notes: "",
                    dueDate: object.value(forKey: "dueDate") as? Date
                )
                item.recordURI = object.objectID.uriRepresentation().absoluteString
                item.canComplete = spaceCanUpdate && canUpdate(object.objectID)
                item.linkedContentTitle = link.map { linkedTitle($0, records: linkedRecords) }
                return item
            }
            var snapshot = TodoWidgetSnapshot(
                status: .ready, generatedAt: Date(), spaceName: space.value(forKey: "name") as? String,
                pendingCount: rows.count, items: items, themeHex: appearance.themeHex,
                lightAccentHex: appearance.lightAccentHex, darkAccentHex: appearance.darkAccentHex
            )
            snapshot.spaceURI = spaceURI
            return snapshot
        }
    }

    private struct LinkedRecord {
        let videoTitle: String
        let brandName: String
        let hasVideoDate: Bool

        var isAssignedToVideo: Bool { !videoTitle.isEmpty || hasVideoDate }
    }

    /// Dictionary projections deliberately exclude notes and image blobs. UUIDs alone are not a
    /// boundary: the relationship and affected store must both match the selected data space.
    private static func linkedMetadata(
        for links: [TodoContentLink], space: NSManagedObject, context: NSManagedObjectContext
    ) throws -> [UUID: LinkedRecord] {
        let ids = Set(links.flatMap(\.recordIDs))
        guard !ids.isEmpty else { return [:] }
        let request = NSFetchRequest<NSDictionary>(entityName: "AdRecord")
        request.resultType = .dictionaryResultType
        request.predicate = NSPredicate(format: "syncSpace == %@ AND id IN %@", space, Array(ids))
        request.affectedStores = space.objectID.persistentStore.map { [$0] }
        request.includesPendingChanges = false
        request.propertiesToFetch = ["id", "videoTitle", "publishDate", "brandName"]
        var result: [UUID: LinkedRecord] = [:]
        for row in try context.fetch(request) {
            guard let id = row["id"] as? UUID, result[id] == nil else { continue }
            result[id] = LinkedRecord(
                videoTitle: (row["videoTitle"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                brandName: (row["brandName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                hasVideoDate: row["publishDate"] is Date
            )
        }
        return result
    }

    private static func linkedTitle(_ link: TodoContentLink, records: [UUID: LinkedRecord]) -> String {
        let prefix = link.kind == .video ? "视频 · " : "池子 · "
        let anchors = link.recordIDs.compactMap { records[$0] }
        let title: String
        switch link.kind {
        case .video:
            if let anchor = anchors.first(where: \.isAssignedToVideo) {
                title = anchor.videoTitle.isEmpty ? "未命名视频" : anchor.videoTitle
            } else {
                title = "\(link.fallbackTitle)（已不可用）"
            }
        case .pool:
            if let anchor = anchors.first {
                title = anchor.brandName.isEmpty ? "未填写品牌" : anchor.brandName
            } else {
                title = "\(link.fallbackTitle)（已不可用）"
            }
        }
        return String((prefix + title).prefix(800))
    }
}
