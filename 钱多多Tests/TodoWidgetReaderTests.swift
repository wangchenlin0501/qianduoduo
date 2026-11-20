import CoreData
import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import TodoNative
#else
@testable import 钱多多
#endif

@MainActor
struct TodoWidgetReaderTests {
    private let appearance = TodoWidgetReader.Appearance(
        themeHex: "8B5E3C", lightAccentHex: "8B5E3C", darkAccentHex: "C9A47F"
    )

    @Test func readingAnEmptyDatabaseDoesNotCreateASpaceOrRecords() async throws {
        let fixture = try Fixture()
        let snapshot = try await read(fixture)
        #expect(snapshot.status == .ready)
        #expect(snapshot.pendingCount == 0)
        #expect(snapshot.items.isEmpty)
        #expect(snapshot.spaceName == nil)
        #expect(snapshot.spaceURI == nil)
        #expect(try fixture.context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "SyncSpace")) == 0)
        #expect(try fixture.context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "TodoItem")) == 0)
        #expect(!fixture.context.hasChanges)
    }

    @Test func sharedSpaceWinsAndOnlyItsSavedPendingItemsArePublished() async throws {
        let fixture = try Fixture(twoStores: true)
        let sharedStore = try #require(fixture.sharedStore)
        let duplicatedSpaceID = UUID()
        let duplicatedItemID = UUID()
        let privateSpace = fixture.space(in: fixture.privateStore, name: "个人空间", id: duplicatedSpaceID, createdOffset: 0)
        let privateItem = fixture.item(in: privateSpace, title: "不能混入的个人记录", id: duplicatedItemID)
        let sharedSpace = fixture.space(in: sharedStore, name: "共享拍摄空间", id: duplicatedSpaceID, createdOffset: 600)
        let sharedItem = fixture.item(in: sharedSpace, title: "已保存的共享记录", id: duplicatedItemID)
        sharedItem.setValue("第一行备注\n第二行", forKey: "notes")
        let savedDueDate = Fixture.epoch.addingTimeInterval(3_600.5)
        sharedItem.setValue(savedDueDate, forKey: "dueDate")
        // Commit the first row in each store before adding more rows, so p1 collisions are deterministic.
        try fixture.context.save()
        let completedItem = fixture.item(in: sharedSpace, title: "已完成不显示")
        completedItem.setValue(Fixture.epoch, forKey: "completedAt")
        try fixture.context.save()

        // Both SQLite files have p1 rows and duplicate UUIDs. Scope must use the store and relationship.
        #expect(privateSpace.objectID.uriRepresentation().lastPathComponent == sharedSpace.objectID.uriRepresentation().lastPathComponent)
        #expect(privateItem.objectID.uriRepresentation().lastPathComponent == sharedItem.objectID.uriRepresentation().lastPathComponent)
        let savedSharedURI = sharedItem.objectID.uriRepresentation().absoluteString
        sharedItem.setValue("尚未保存的改名", forKey: "title")
        _ = fixture.item(in: sharedSpace, title: "尚未提交的输入")

        let snapshot = try await read(fixture)
        #expect(snapshot.spaceName == "共享拍摄空间")
        #expect(snapshot.spaceURI == sharedSpace.objectID.uriRepresentation().absoluteString)
        #expect(snapshot.pendingCount == 1)
        #expect(snapshot.items.map(\.title) == ["已保存的共享记录"])
        #expect(snapshot.items.first?.notes == "")
        #expect(snapshot.items.first?.linkedContentTitle == nil)
        #expect(snapshot.items.first?.dueDate == savedDueDate)
        #expect(snapshot.items.first?.recordURI == savedSharedURI)
        #expect(snapshot.items.first?.canComplete == true)
        #expect(fixture.context.hasChanges)

        // With no shared store selected, the same reader falls back to the private space.
        let privateSnapshot = try await TodoWidgetReader.read(
            coordinator: fixture.coordinator, privateStore: fixture.privateStore, sharedStore: nil,
            sort: "手动", appearance: appearance, canUpdate: { _ in true }
        )
        #expect(privateSnapshot.items.map(\.title) == ["不能混入的个人记录"])
        #expect(privateSnapshot.spaceURI == privateSpace.objectID.uriRepresentation().absoluteString)
    }

    @Test func readOnlyContentRemainsVisibleAndBothSpaceAndItemPermissionsGateCompletion() async throws {
        let fixture = try Fixture()
        let space = fixture.space(in: fixture.privateStore, name: "只读合作空间")
        let item = fixture.item(in: space, title: "可查看但不可勾选")
        try fixture.context.save()
        let spaceID = space.objectID
        let itemID = item.objectID

        let readOnly = try await read(fixture, canUpdate: { _ in false })
        #expect(readOnly.items.map(\.title) == ["可查看但不可勾选"])
        #expect(readOnly.pendingCount == 1)
        #expect(readOnly.items.first?.canComplete == false)
        #expect(readOnly.items.first?.recordURI == itemID.uriRepresentation().absoluteString)

        let deniedSpace = try await read(fixture, canUpdate: { $0 != spaceID })
        #expect(deniedSpace.items.first?.canComplete == false)
        let deniedItem = try await read(fixture, canUpdate: { $0 != itemID })
        #expect(deniedItem.items.first?.canComplete == false)
        #expect(!fixture.context.hasChanges)
    }

    @Test func orderingShowsTwentyItemsButRetainsTotalCountAndPermanentRoutes() async throws {
        let fixture = try Fixture()
        let space = fixture.space(in: fixture.privateStore, name: "排序验收")
        let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliet", "Kilo", "Lima", "Mike", "November", "Oscar", "Papa", "Quebec", "Romeo", "Sierra", "Tango", "Uniform", "Victor", "Whiskey", "Xray", "Yankee"]
        let deadlines: [Int: TimeInterval] = [0: 3_600, 2: 0, 3: 1_200, 5: 2_400]
        var recordsByTitle: [String: NSManagedObject] = [:]
        for (index, name) in names.enumerated() {
            let item = fixture.item(in: space, title: name, sortOrder: Double(names.count - 1 - index), createdOffset: Double(index))
            item.setValue(deadlines[index].map { Fixture.epoch.addingTimeInterval($0) }, forKey: "dueDate")
            recordsByTitle[name] = item
        }
        try fixture.context.save()

        let manual = try await read(fixture, sort: "手动")
        #expect(manual.items.map(\.title) == ["Yankee", "Xray", "Whiskey", "Victor", "Uniform", "Tango", "Sierra", "Romeo", "Quebec", "Papa", "Oscar", "November", "Mike", "Lima", "Kilo", "Juliet", "India", "Hotel", "Golf", "Foxtrot"])
        let due = try await read(fixture, sort: "日期")
        #expect(due.items.map(\.title) == ["Charlie", "Delta", "Foxtrot", "Alpha", "Bravo", "Echo", "Golf", "Hotel", "India", "Juliet", "Kilo", "Lima", "Mike", "November", "Oscar", "Papa", "Quebec", "Romeo", "Sierra", "Tango"])
        #expect(due.items.prefix(4).allSatisfy { $0.dueDate != nil })
        #expect(due.items.dropFirst(4).allSatisfy { $0.dueDate == nil })
        let title = try await read(fixture, sort: "标题")
        #expect(title.items.map(\.title) == Array(names.prefix(20)))

        for snapshot in [manual, due, title] {
            #expect(snapshot.pendingCount == 25)
            #expect(snapshot.items.count == 20)
            #expect(snapshot.spaceURI == space.objectID.uriRepresentation().absoluteString)
            for item in snapshot.items {
                let uri = try #require(item.recordURI.flatMap(URL.init(string:)))
                let resolvedID = try #require(fixture.coordinator.managedObjectID(forURIRepresentation: uri))
                let expectedID = try #require(recordsByTitle[item.title]?.objectID)
                #expect(resolvedID == expectedID)
                #expect(!resolvedID.isTemporaryID)
                #expect(resolvedID.persistentStore == fixture.privateStore)
            }
        }
    }

    @Test func linkedLabelsUseOnlyTheSelectedSpaceAndStoreWithoutPublishingNotesOrPhotos() async throws {
        let fixture = try Fixture(twoStores: true)
        let sharedStore = try #require(fixture.sharedStore)
        let duplicatedSpaceID = UUID()
        let poolID = UUID()
        let videoID = UUID()
        let privateSpace = fixture.space(in: fixture.privateStore, name: "个人空间", id: duplicatedSpaceID)
        let privateRecord = fixture.record(in: privateSpace, id: poolID, brand: "错误的个人品牌")
        let sharedSpace = fixture.space(in: sharedStore, name: "共享空间", id: duplicatedSpaceID)
        let pool = fixture.record(in: sharedSpace, id: poolID, brand: "共享品牌截图")
        // A real external image blob exists, but the widget only requests metadata columns.
        pool.setValue(Data(repeating: 0xAB, count: 1_100_000), forKey: "photoData")
        // Save each store's first AdRecord before adding videos; SQLite allocates inserted rows
        // in an unspecified order when several records are committed in the same transaction.
        try fixture.context.save()
        #expect(privateRecord.objectID.uriRepresentation().lastPathComponent == pool.objectID.uriRepresentation().lastPathComponent)
        _ = fixture.record(in: privateSpace, id: videoID, brand: "错误的个人视频品牌", video: "错误的个人视频")
        _ = fixture.record(in: sharedSpace, id: videoID, brand: "共享视频品牌", video: "十月购物分享")
        let otherSpace = fixture.space(in: sharedStore, name: "同存储的其他空间", createdOffset: 600)
        _ = fixture.record(in: otherSpace, id: poolID, brand: "错误的同存储品牌")
        _ = fixture.record(in: otherSpace, id: videoID, brand: "错误的同存储视频品牌", video: "错误的同存储视频")
        let poolTodo = fixture.item(in: sharedSpace, title: "确认池子内容", sortOrder: 0)
        poolTodo.setValue(TodoContentLink(kind: .pool, recordIDs: [poolID], fallbackTitle: "旧池子名").encodedValue, forKey: "linkedContent")
        poolTodo.setValue("备注不应进入小组件", forKey: "notes")
        let videoTodo = fixture.item(in: sharedSpace, title: "准备视频", sortOrder: 1)
        videoTodo.setValue(TodoContentLink(kind: .video, recordIDs: [videoID], fallbackTitle: "旧视频名").encodedValue, forKey: "linkedContent")
        try fixture.context.save()

        let snapshot = try await read(fixture)
        #expect(snapshot.items.map(\.linkedContentTitle) == ["池子 · 共享品牌截图", "视频 · 十月购物分享"])
        #expect(snapshot.items.allSatisfy { $0.notes.isEmpty })
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(encoded.count < 8_000)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("备注不应进入小组件"))

        // Turning off the shared-store selection cannot reuse labels cached for the shared space.
        let privateTodo = fixture.item(in: privateSpace, title: "个人待办")
        privateTodo.setValue(TodoContentLink(kind: .pool, recordIDs: [poolID], fallbackTitle: "旧名").encodedValue, forKey: "linkedContent")
        try fixture.context.save()
        let personal = try await TodoWidgetReader.read(
            coordinator: fixture.coordinator, privateStore: fixture.privateStore, sharedStore: nil,
            sort: "手动", appearance: appearance, canUpdate: { _ in true }
        )
        #expect(personal.items.map(\.linkedContentTitle) == ["池子 · 错误的个人品牌"])
    }

    @Test func linkedLabelsTrackSavedRenamesAndBecomeUnavailableAfterTheExactAnchorIsDeleted() async throws {
        let fixture = try Fixture()
        let space = fixture.space(in: fixture.privateStore, name: "关联更新")
        let poolID = UUID()
        let firstVideoID = UUID()
        let secondVideoID = UUID()
        let pool = fixture.record(in: space, id: poolID, brand: "原品牌")
        let video = fixture.record(in: space, id: firstVideoID, brand: "合作甲", video: "原视频")
        let otherAnchor = fixture.record(in: space, id: secondVideoID, brand: "合作乙", video: "原视频")
        let poolTodo = fixture.item(in: space, title: "跟进品牌", sortOrder: 0)
        poolTodo.setValue(TodoContentLink(kind: .pool, recordIDs: [poolID], fallbackTitle: "原品牌").encodedValue, forKey: "linkedContent")
        let videoTodo = fixture.item(in: space, title: "准备合作", sortOrder: 1)
        videoTodo.setValue(TodoContentLink(kind: .video, recordIDs: [firstVideoID, secondVideoID], fallbackTitle: "原视频").encodedValue, forKey: "linkedContent")
        try fixture.context.save()
        pool.setValue("已保存品牌", forKey: "brandName")
        video.setValue("已保存视频", forKey: "videoTitle")
        otherAnchor.setValue("已保存视频", forKey: "videoTitle")
        try fixture.context.save()
        pool.setValue("未保存品牌", forKey: "brandName")
        video.setValue("未保存视频", forKey: "videoTitle")
        let renamed = try await read(fixture)
        #expect(renamed.items.map(\.linkedContentTitle) == ["池子 · 已保存品牌", "视频 · 已保存视频"])
        fixture.context.rollback()

        fixture.context.delete(pool)
        fixture.context.delete(video)
        try fixture.context.save()
        let partiallyDeleted = try await read(fixture)
        #expect(partiallyDeleted.items.map(\.linkedContentTitle) == ["池子 · 原品牌（已不可用）", "视频 · 已保存视频"])
        fixture.context.delete(otherAnchor)
        // Same-name replacements must never silently become an old association's target.
        _ = fixture.record(in: space, id: UUID(), brand: "原品牌", video: "原视频")
        try fixture.context.save()
        let deleted = try await read(fixture)
        #expect(deleted.items.map(\.linkedContentTitle) == ["池子 · 原品牌（已不可用）", "视频 · 原视频（已不可用）"])
    }

    @Test func malformedOrRemovedAssociationsCannotLeakHistoricalNotesIntoTheWidget() async throws {
        let fixture = try Fixture()
        let space = fixture.space(in: fixture.privateStore, name: "无关联")
        let item = fixture.item(in: space, title: "独立待办")
        item.setValue("旧备注只留在原始数据里", forKey: "notes")
        item.setValue("{malformed", forKey: "linkedContent")
        try fixture.context.save()
        let malformed = try await read(fixture)
        #expect(malformed.items.first?.linkedContentTitle == nil)
        #expect(malformed.items.first?.notes == "")
        item.setValue(nil, forKey: "linkedContent")
        try fixture.context.save()
        let removed = try await read(fixture)
        #expect(removed.items.first?.linkedContentTitle == nil)
        #expect(removed.items.first?.notes == "")
        #expect(item.value(forKey: "notes") as? String == "旧备注只留在原始数据里")
    }

    private func read(
        _ fixture: Fixture, sort: String = "手动",
        canUpdate: @escaping @Sendable (NSManagedObjectID) -> Bool = { _ in true }
    ) async throws -> TodoWidgetSnapshot {
        try await TodoWidgetReader.read(
            coordinator: fixture.coordinator, privateStore: fixture.privateStore, sharedStore: fixture.sharedStore,
            sort: sort, appearance: appearance, canUpdate: canUpdate
        )
    }

    private final class Fixture {
        static let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        private static let model: NSManagedObjectModel = {
            #if SWIFT_PACKAGE
            PersistenceController(inMemory: true).container.managedObjectModel
            #else
            PersistenceController.shared.container.managedObjectModel
            #endif
        }()

        let directory: URL
        let coordinator: NSPersistentStoreCoordinator
        let context: NSManagedObjectContext
        private var storesBySpace: [ObjectIdentifier: NSPersistentStore] = [:]
        var privateStore: NSPersistentStore { coordinator.persistentStores[0] }
        var sharedStore: NSPersistentStore? { coordinator.persistentStores.dropFirst().first }

        init(twoStores: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("todo-widget-reader-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            coordinator = NSPersistentStoreCoordinator(managedObjectModel: Self.model)
            for index in 0..<(twoStores ? 2 : 1) {
                try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                    at: directory.appendingPathComponent("store-\(index).sqlite"), options: nil)
            }
            context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
        }

        deinit {
            context.reset()
            for store in coordinator.persistentStores { try? coordinator.remove(store) }
            try? FileManager.default.removeItem(at: directory)
        }

        func space(in store: NSPersistentStore, name: String, id: UUID = UUID(), createdOffset: TimeInterval = 0) -> NSManagedObject {
            let object = NSManagedObject(entity: Self.model.entitiesByName["SyncSpace"]!, insertInto: context)
            context.assign(object, to: store)
            storesBySpace[ObjectIdentifier(object)] = store
            object.setValue(id, forKey: "id")
            object.setValue(name, forKey: "name")
            object.setValue(Self.epoch.addingTimeInterval(createdOffset), forKey: "createdAt")
            return object
        }

        func item(in space: NSManagedObject, title: String, id: UUID = UUID(), sortOrder: Double = 0, createdOffset: TimeInterval = 0) -> NSManagedObject {
            let object = NSManagedObject(entity: Self.model.entitiesByName["TodoItem"]!, insertInto: context)
            context.assign(object, to: storesBySpace[ObjectIdentifier(space)]!)
            object.setValue(id, forKey: "id")
            object.setValue(title, forKey: "title")
            object.setValue("", forKey: "notes")
            object.setValue(Self.epoch.addingTimeInterval(createdOffset), forKey: "createdAt")
            object.setValue(sortOrder, forKey: "sortOrder")
            object.setValue(space, forKey: "syncSpace")
            return object
        }

        func record(in space: NSManagedObject, id: UUID, brand: String, video: String? = nil) -> NSManagedObject {
            let object = NSManagedObject(entity: Self.model.entitiesByName["AdRecord"]!, insertInto: context)
            context.assign(object, to: storesBySpace[ObjectIdentifier(space)]!)
            object.setValue(id, forKey: "id")
            object.setValue(brand, forKey: "brandName")
            object.setValue(video, forKey: "videoTitle")
            object.setValue(space, forKey: "syncSpace")
            return object
        }
    }
}
