import CoreData
import Foundation
import Testing
@testable import 钱多多

@MainActor
struct TodoStoreTests {
    @Test func viewingOrDiscardingBlankDraftDoesNotCreateSpace() throws {
        let stack = try Stack()
        let store = stack.makeStore()
        #expect(store.items.isEmpty)
        #expect(store.canCreate)
        #expect(try store.create(title: " \n\t ") == nil)
        #expect(try stack.context.count(for: SyncSpace.fetchRequest()) == 0)
        #expect(try stack.context.count(for: TodoItem.fetchRequest()) == 0)
        #expect(!store.context.hasChanges)
    }

    @Test func editsCompletionAndOrderingSurviveSQLiteReload() throws {
        let stack = try Stack()
        let store = stack.makeStore()
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try #require(try store.create(title: "  开票  ", notes: "抬头", dueDate: due))
        let b = try #require(try store.create(title: "采购"))
        let c = try #require(try store.create(title: "寄样"))
        #expect(a.title == "开票")
        #expect(a.syncSpace?.objectID.persistentStore == a.objectID.persistentStore)
        #expect(stack.sharedCreatedIDs == [a.objectID, b.objectID, c.objectID])
        try store.update(a, title: "开票确认", notes: "完整备注", dueDate: due)
        try store.toggleCompletion(a)
        #expect(a.completedAt != nil)
        try store.move(ids: [c.objectID, b.objectID])
        try store.rename(b, title: "采购衣服")
        let reloaded = stack.makeStore()
        #expect(reloaded.items.map(\.title) == ["寄样", "采购衣服", "开票确认"])
        let restored = try #require(reloaded.items.last)
        #expect(restored.notes == "完整备注")
        #expect(restored.dueDate == due)
        #expect(restored.completedAt != nil)
        try reloaded.toggleCompletion(restored)
        #expect(restored.completedAt == nil)
        try reloaded.toggleCompletion(restored)
        try reloaded.deleteCompleted()
        #expect(reloaded.items.map(\.title) == ["寄样", "采购衣服"])
        try reloaded.delete(try #require(reloaded.items.first))
        #expect(stack.makeStore().items.map(\.title) == ["采购衣服"])
    }

    @Test func completingAndRestoringTheMiddleRowKeepsItsManualPositionAcrossSQLiteReload() throws {
        let stack = try Stack()
        let store = stack.makeStore()
        let first = try #require(try store.create(title: "确认报价"))
        let middle = try #require(try store.create(title: "安排拍摄"))
        let last = try #require(try store.create(title: "发布视频"))
        let expectedIDs = [last, middle, first].map(\.objectID)
        try store.move(ids: expectedIDs)
        let expectedSortOrder = store.items.map(\.sortOrder)
        #expect(store.items.map(\.objectID) == expectedIDs)
        #expect(expectedSortOrder == [0, 1, 2])

        try store.toggleCompletion(middle)
        let completedAt = try #require(middle.completedAt)
        #expect(store.items.map(\.objectID) == expectedIDs)
        #expect(store.items.map(\.sortOrder) == expectedSortOrder)
        try store.refresh()
        #expect(store.items.map(\.objectID) == expectedIDs)
        #expect(store.items.map(\.sortOrder) == expectedSortOrder)
        let completedReader = stack.makeStore()
        #expect(completedReader.items.map(\.objectID) == expectedIDs)
        #expect(completedReader.items.map(\.sortOrder) == expectedSortOrder)
        #expect(completedReader.items[1].completedAt == completedAt)
        #expect(completedReader.items[0].completedAt == nil)
        #expect(completedReader.items[2].completedAt == nil)

        try store.toggleCompletion(middle)
        #expect(middle.completedAt == nil)
        #expect(store.items.map(\.objectID) == expectedIDs)
        try store.refresh()
        #expect(store.items.map(\.objectID) == expectedIDs)
        #expect(store.items.map(\.sortOrder) == expectedSortOrder)
        let restoredReader = stack.makeStore()
        #expect(restoredReader.items.map(\.objectID) == expectedIDs)
        #expect(restoredReader.items.map(\.sortOrder) == expectedSortOrder)
        #expect(restoredReader.items.allSatisfy { $0.completedAt == nil })
        #expect(!restoredReader.context.hasChanges)
    }

    @Test func movingCompletedRowsPreservesPendingOrderAndCompletionAcrossSQLiteReload() throws {
        let stack = try Stack()
        let store = stack.makeStore()
        let pendingA = try #require(try store.create(title: "确认报价"))
        let completedA = try #require(try store.create(title: "开票"))
        let pendingB = try #require(try store.create(title: "安排拍摄"))
        let completedB = try #require(try store.create(title: "寄样"))
        let completedC = try #require(try store.create(title: "收款"))
        let pendingC = try #require(try store.create(title: "发布视频"))
        for item in [completedA, completedB, completedC] {
            try store.toggleCompletion(item)
        }

        let pendingIDs = [pendingA, pendingB, pendingC].map(\.objectID)
        let reorderedCompleted = [completedC, completedA, completedB]
        let completedIDs = reorderedCompleted.map(\.objectID)
        let completionDates = reorderedCompleted.map(\.completedAt)
        #expect(completionDates.allSatisfy { $0 != nil })

        // A drag inside the completed section supplies all pending IDs first so
        // moving a completed row cannot disturb the other section's order.
        try store.move(ids: pendingIDs + completedIDs)
        try store.refresh()
        #expect(store.items.filter { $0.completedAt == nil }.map(\.objectID) == pendingIDs)
        #expect(store.items.filter { $0.completedAt != nil }.map(\.objectID) == completedIDs)
        #expect(store.items.filter { $0.completedAt != nil }.map(\.completedAt) == completionDates)

        let reloaded = stack.makeStore()
        #expect(reloaded.items.map(\.objectID) == pendingIDs + completedIDs)
        #expect(reloaded.items.filter { $0.completedAt == nil }.map(\.objectID) == pendingIDs)
        #expect(reloaded.items.filter { $0.completedAt != nil }.map(\.objectID) == completedIDs)
        #expect(reloaded.items.filter { $0.completedAt != nil }.map(\.completedAt) == completionDates)
        #expect(!reloaded.context.hasChanges)
    }

    @Test func explicitCompletionIsIdempotentAndSupportsRestoringAcrossSQLiteReload() throws {
        let stack = try Stack()
        let store = stack.makeStore()
        let item = try #require(try store.create(title: "小组件完成事项"))
        let saves = SaveCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave, object: store.context, queue: nil
        ) { _ in
            MainActor.assumeIsolated { saves.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try store.setCompletion(item, completed: true)
        let completedAt = try #require(item.completedAt)
        let completedUpdatedAt = try #require(item.updatedAt)
        #expect(saves.count == 1)
        try store.setCompletion(item, completed: true)
        try store.setCompletion(item, completed: true)
        #expect(item.completedAt == completedAt)
        #expect(item.updatedAt == completedUpdatedAt)
        #expect(saves.count == 1)
        #expect(!store.context.hasChanges)
        let completedReader = stack.makeStore()
        let completed = try #require(completedReader.items.first)
        #expect(completed.completedAt == completedAt)
        #expect(completed.updatedAt == completedUpdatedAt)

        try store.setCompletion(item, completed: false)
        let restoredUpdatedAt = try #require(item.updatedAt)
        #expect(item.completedAt == nil)
        #expect(saves.count == 2)
        try store.setCompletion(item, completed: false)
        #expect(item.completedAt == nil)
        #expect(item.updatedAt == restoredUpdatedAt)
        #expect(saves.count == 2)
        #expect(!store.context.hasChanges)
        let restoredReader = stack.makeStore()
        let restored = try #require(restoredReader.items.first)
        #expect(restored.completedAt == nil)
        #expect(restored.updatedAt == restoredUpdatedAt)
    }

    @Test func explicitCompletionUsesTheLatestSavedStateInsteadOfResettingAnotherContextsDate() throws {
        let stack = try Stack()
        let store = stack.makeStore()
        let item = try #require(try store.create(title: "另一端已完成"))
        let other = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        other.persistentStoreCoordinator = stack.coordinator
        let remote = try #require(try other.existingObject(with: item.objectID) as? TodoItem)
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let updatedAt = completedAt.addingTimeInterval(10)
        remote.completedAt = completedAt
        remote.updatedAt = updatedAt
        try other.save()

        try store.setCompletion(item, completed: true)
        #expect(item.completedAt == completedAt)
        #expect(item.updatedAt == updatedAt)
        let reader = stack.makeStore()
        let reloaded = try #require(reader.items.first)
        #expect(reloaded.completedAt == completedAt)
        #expect(reloaded.updatedAt == updatedAt)
        #expect(!store.context.hasChanges)
    }

    @Test(arguments: [false, true])
    func reschedulingPreservesLatestSavedContentAndOrderAcrossSQLiteReload(fromAnotherContext: Bool) throws {
        let stack = try Stack()
        let store = stack.makeStore()
        let originalDate = try instant("2026-11-06T09:00:00+08:00")
        let destination = try instant("2026-12-01T01:30:00+08:00")
        let expectedDate = try instant("2026-11-30T16:00:00Z")
        let first = try #require(try store.create(title: "确认报价"))
        let item = try #require(try store.create(title: "旧标题", notes: "旧备注", dueDate: originalDate))
        let neighbor = try #require(try store.create(title: "同日另一项", dueDate: expectedDate))
        try store.move(ids: [neighbor.objectID, item.objectID, first.objectID])
        let originalOrder = store.items.map(\.objectID)
        let originalSortOrders = store.items.map(\.sortOrder)
        let originalCreatedAt = item.createdAt
        let link = TodoContentLink(kind: .pool, recordIDs: [UUID()], fallbackTitle: "历史关联内容")

        let other = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        other.persistentStoreCoordinator = stack.coordinator
        let remote = try #require(try other.existingObject(with: item.objectID) as? TodoItem)
        remote.title = "另一端的新标题"
        remote.notes = "另一端保留的历史备注"
        remote.linkedContent = link.encodedValue
        try other.save()

        // Do not wait for automatic merging. A caller may also hold the object
        // from another context; only the store-owned instance may be mutated.
        let source = fromAnotherContext ? remote : item
        let resolvedDate = try store.reschedule(source, to: destination)
        #expect(resolvedDate == expectedDate)
        #expect(item.managedObjectContext === store.context)
        #expect(remote.managedObjectContext === other)
        #expect(!other.hasChanges)
        let reader = stack.makeStore()
        let restored = try #require(reader.items.first { $0.objectID == item.objectID })
        #expect(restored.dueDate == expectedDate)
        #expect(restored.title == "另一端的新标题")
        #expect(restored.notes == "另一端保留的历史备注")
        #expect(restored.contentLink == link)
        #expect(restored.createdAt == originalCreatedAt)
        #expect(restored.completedAt == nil)
        #expect(reader.items.map(\.objectID) == originalOrder)
        #expect(reader.items.map(\.sortOrder) == originalSortOrders)
        #expect(reader.items.first { $0.objectID == neighbor.objectID }?.dueDate == expectedDate)
        #expect(!store.context.hasChanges)
    }

    @Test func reschedulingWithinTheSameShanghaiDayDoesNotSaveOrReplaceHistoricalTime() throws {
        let stack = try Stack()
        let store = stack.makeStore()
        let originalDate = try instant("2026-11-06T23:59:00+08:00")
        let item = try #require(try store.create(title: "当天事项", dueDate: originalDate))
        let originalUpdatedAt = item.updatedAt
        let saves = SaveCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave, object: store.context, queue: nil
        ) { _ in
            MainActor.assumeIsolated { saves.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let resolvedDate = try store.reschedule(item, to: instant("2026-11-06T00:01:00+08:00"))
        #expect(resolvedDate == (try instant("2026-11-05T16:00:00Z")))
        #expect(saves.count == 0)
        #expect(item.dueDate == originalDate)
        #expect(item.updatedAt == originalUpdatedAt)
        let restored = try #require(stack.makeStore().items.first)
        #expect(restored.dueDate == originalDate)
        #expect(restored.updatedAt == originalUpdatedAt)
        #expect(!store.context.hasChanges)
    }

    @Test func reschedulingRejectsCompletionSavedBeforeAutomaticMerge() throws {
        let stack = try Stack()
        let store = stack.makeStore()
        let originalDate = try instant("2026-11-06T00:00:00+08:00")
        let item = try #require(try store.create(title: "另一端刚完成", dueDate: originalDate))
        let other = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        other.persistentStoreCoordinator = stack.coordinator
        let remote = try #require(try other.existingObject(with: item.objectID) as? TodoItem)
        let completedAt = try instant("2026-11-06T11:00:00+08:00")
        remote.completedAt = completedAt
        remote.updatedAt = completedAt
        try other.save()

        #expect(throws: TodoStore.StoreError.self) {
            try store.reschedule(item, to: instant("2026-11-07T00:00:00+08:00"))
        }
        let restored = try #require(stack.makeStore().items.first)
        #expect(restored.completedAt == completedAt)
        #expect(restored.updatedAt == completedAt)
        #expect(restored.dueDate == originalDate)
        #expect(!store.context.hasChanges)
    }

    @Test func reschedulingRejectsDateClearedBeforeAutomaticMerge() throws {
        let stack = try Stack()
        let store = stack.makeStore()
        let item = try #require(try store.create(title: "另一端刚清除日期", dueDate: instant("2026-11-06T00:00:00+08:00")))
        let other = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        other.persistentStoreCoordinator = stack.coordinator
        let remote = try #require(try other.existingObject(with: item.objectID) as? TodoItem)
        let clearedAt = try instant("2026-11-06T11:00:00+08:00")
        remote.dueDate = nil
        remote.updatedAt = clearedAt
        try other.save()

        #expect(throws: TodoStore.StoreError.self) {
            try store.reschedule(item, to: instant("2026-11-07T00:00:00+08:00"))
        }
        let restored = try #require(stack.makeStore().items.first)
        #expect(restored.completedAt == nil)
        #expect(restored.dueDate == nil)
        #expect(restored.updatedAt == clearedAt)
        #expect(!store.context.hasChanges)
    }

    @Test func reschedulingTodoDoesNotMoveLinkedVideoOrSaveAnUnfinishedBusinessForm() throws {
        let stack = try Stack()
        let space = stack.makeSpace(store: stack.coordinator.persistentStores[0])
        let record = AdRecord(context: stack.context)
        record.id = UUID()
        record.brandName = "视频品牌"
        record.videoTitle = "已安排的视频"
        record.publishDate = try instant("2026-11-10T00:00:00+08:00")
        record.dueDate = try instant("2026-11-10T15:00:00+08:00")
        record.updatedAt = try instant("2026-11-01T00:00:00+08:00")
        record.syncSpace = space
        try stack.context.save()
        let originalVideoDate = record.publishDate
        let originalPublicationDate = record.dueDate
        let originalVideoUpdatedAt = record.updatedAt
        let link = TodoContentLink(kind: .video, recordIDs: [try #require(record.id)], fallbackTitle: "已安排的视频")
        let store = stack.makeStore()
        let item = try #require(try store.create(title: "准备素材", dueDate: instant("2026-11-06T00:00:00+08:00"), link: link))
        let unfinished = AdRecord(context: stack.context)
        unfinished.id = UUID()
        unfinished.brandName = "未保存的另一份表单"

        try store.reschedule(item, to: instant("2026-11-12T10:00:00+08:00"))
        let verification = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        verification.persistentStoreCoordinator = stack.coordinator
        let savedVideo = try #require(try verification.existingObject(with: record.objectID) as? AdRecord)
        #expect(savedVideo.publishDate == originalVideoDate)
        #expect(savedVideo.dueDate == originalPublicationDate)
        #expect(savedVideo.updatedAt == originalVideoUpdatedAt)
        #expect(try verification.count(for: AdRecord.fetchRequest()) == 1)
        #expect(stack.context.hasChanges)
        #expect(item.contentLink == link)
        #expect(link.resolvedRecords(in: try store.contentRecords()).map(\.objectID) == [record.objectID])
    }

    @Test func scopesItemsAndWritesToTheCurrentSharedStore() throws {
        let stack = try Stack(twoStores: true)
        let privateSpace = stack.makeSpace(store: stack.coordinator.persistentStores[0])
        let sharedSpace = stack.makeSpace(store: stack.coordinator.persistentStores[1])
        try stack.context.save()
        stack.selectedSpaceID = privateSpace.objectID
        let store = stack.makeStore()
        let originalDate = try instant("2026-11-06T00:00:00+08:00")
        let personal = try #require(try store.create(title: "个人事项", dueDate: originalDate))
        stack.selectedSpaceID = sharedSpace.objectID
        try store.refresh()
        #expect(store.items.isEmpty)
        let shared = try #require(try store.create(title: "共享事项"))
        #expect(store.items.map(\.title) == ["共享事项"])
        #expect(shared.objectID.persistentStore == sharedSpace.objectID.persistentStore)
        #expect(shared.syncSpace?.objectID == sharedSpace.objectID)
        #expect(throws: TodoStore.StoreError.self) { try store.rename(personal, title: "错误空间") }
        #expect(throws: TodoStore.StoreError.self) { try store.setCompletion(personal, completed: true) }
        #expect(throws: TodoStore.StoreError.self) { try store.setCompletion(personal, completed: false) }
        #expect(throws: TodoStore.StoreError.self) { try store.reschedule(personal, to: originalDate) }
        stack.selectedSpaceID = privateSpace.objectID
        try store.refresh()
        #expect(store.items.map(\.title) == ["个人事项"])
        #expect(store.items.first?.dueDate == originalDate)
    }

    @Test func readOnlyShareRejectsCreateEditToggleMoveAndDelete() throws {
        let stack = try Stack()
        let store = stack.makeStore()
        let originalDate = try instant("2026-11-06T00:00:00+08:00")
        let item = try #require(try store.create(title: "保持内容", dueDate: originalDate))
        let other = try #require(try store.create(title: "保持顺序"))
        stack.writable = false
        #expect(!store.canCreate)
        #expect(!store.canEdit(item))
        #expect(throws: TodoStore.StoreError.self) { try store.create(title: "不应保存") }
        #expect(throws: TodoStore.StoreError.self) { try store.rename(item, title: "不应更名") }
        #expect(throws: TodoStore.StoreError.self) { try store.toggleCompletion(item) }
        #expect(throws: TodoStore.StoreError.self) { try store.setCompletion(item, completed: true) }
        #expect(throws: TodoStore.StoreError.self) { try store.setCompletion(item, completed: false) }
        #expect(throws: TodoStore.StoreError.self) { try store.reschedule(item, to: originalDate) }
        #expect(throws: TodoStore.StoreError.self) { try store.move(ids: [other.objectID, item.objectID]) }
        #expect(throws: TodoStore.StoreError.self) { try store.delete(item) }
        #expect(stack.makeStore().items.map(\.title) == ["保持内容", "保持顺序"])
        #expect(item.completedAt == nil)
        #expect(item.dueDate == originalDate)
        #expect(!store.context.hasChanges)
    }

    @Test func deletedRowsAreRejectedRatherThanRecreated() throws {
        let stack = try Stack()
        let store = stack.makeStore()
        let item = try #require(try store.create(title: "另一端会删除", dueDate: instant("2026-11-06T00:00:00+08:00")))
        let id = item.objectID
        let other = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        other.persistentStoreCoordinator = stack.coordinator
        other.delete(try other.existingObject(with: id))
        try other.save()
        #expect(throws: TodoStore.StoreError.self) { try store.rename(item, title: "不应复活") }
        #expect(throws: TodoStore.StoreError.self) { try store.toggleCompletion(item) }
        #expect(throws: TodoStore.StoreError.self) { try store.setCompletion(item, completed: true) }
        #expect(throws: TodoStore.StoreError.self) { try store.setCompletion(item, completed: false) }
        #expect(throws: TodoStore.StoreError.self) {
            try store.reschedule(item, to: instant("2026-11-07T00:00:00+08:00"))
        }
        #expect(try other.count(for: TodoItem.fetchRequest()) == 0)
        #expect(stack.makeStore().items.isEmpty)
    }

    @Test func todoSaveDoesNotCommitAnUnfinishedBusinessForm() throws {
        let stack = try Stack()
        let unfinished = AdRecord(entity: stack.coordinator.managedObjectModel.entitiesByName["AdRecord"]!, insertInto: stack.context)
        unfinished.id = UUID()
        unfinished.brandName = "尚未点保存"
        let store = stack.makeStore()
        _ = try store.create(title: "独立保存")
        #expect(stack.context.hasChanges)
        let verification = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        verification.persistentStoreCoordinator = stack.coordinator
        #expect(try verification.count(for: AdRecord.fetchRequest()) == 0)
        #expect(try verification.count(for: TodoItem.fetchRequest()) == 1)
    }

    @Test func blankRenameDoesNotDestroyAnExistingItem() throws {
        let stack = try Stack()
        let store = stack.makeStore()
        let item = try #require(try store.create(title: "待办保留"))
        #expect(throws: TodoStore.StoreError.self) { try store.rename(item, title: " \n ") }
        #expect(stack.makeStore().items.first?.title == "待办保留")
    }

    @Test func otherContextChangesAppearWithoutRecreatingTheStore() async throws {
        let stack = try Stack()
        let observer = stack.makeStore()
        let writer = stack.makeStore()
        _ = try writer.create(title: "其他窗口新建")
        await waitForChanges { observer.items.map(\.title) == ["其他窗口新建"] }
        #expect(observer.items.map(\.title) == ["其他窗口新建"])
        try writer.rename(try #require(writer.items.first), title: "其他窗口修改")
        await waitForChanges { observer.items.first?.title == "其他窗口修改" }
        #expect(observer.items.first?.title == "其他窗口修改")
    }

    @Test func linksSaveUpdateRemoveAndKeepStableVideoAnchors() throws {
        let stack = try Stack()
        let space = stack.makeSpace(store: stack.coordinator.persistentStores[0])
        let record = AdRecord(context: stack.context)
        record.id = UUID()
        record.brandName = "品牌"
        record.videoTitle = "十月穿搭"
        record.publishDate = Date(timeIntervalSince1970: 1_800_000_000)
        record.syncSpace = space
        try stack.context.save()
        let link = TodoContentLink(kind: .video, recordIDs: [try #require(record.id)], fallbackTitle: "十月穿搭")
        let store = stack.makeStore()
        let todo = try #require(try store.create(title: "安排拍摄", link: link))
        #expect(todo.contentLink == link)
        #expect(todo.notes == "")
        try store.update(todo, title: "安排拍摄确认", notes: "备注", dueDate: nil)
        #expect(todo.contentLink == link)
        let restored = try #require(stack.makeStore().items.first)
        #expect(restored.contentLink == link)
        #expect(link.resolvedRecords(in: try store.contentRecords()).map(\.id) == [record.id])
        try store.update(todo, title: "取消关联", notes: "备注", dueDate: nil, link: nil)
        #expect(todo.linkedContent == nil)
        #expect(stack.makeStore().items.first?.linkedContent == nil)
    }

    @Test func contentLinksRejectOtherSpacesStoresMissingAndReadOnlyWithoutSavingPartialChanges() throws {
        let stack = try Stack(twoStores: true)
        let personal = stack.makeSpace(store: stack.coordinator.persistentStores[0])
        let shared = stack.makeSpace(store: stack.coordinator.persistentStores[1])
        let otherSameStore = stack.makeSpace(store: stack.coordinator.persistentStores[1])
        var records: [AdRecord] = []
        for space in [personal, shared, otherSameStore] {
            let record = AdRecord(context: stack.context)
            stack.context.assign(record, to: try #require(space.objectID.persistentStore))
            record.id = UUID()
            record.brandName = "不同空间同名品牌"
            record.syncSpace = space
            records.append(record)
        }
        try stack.context.save()
        stack.selectedSpaceID = shared.objectID
        let store = stack.makeStore()
        #expect(try store.contentRecords().map(\.id) == [records[1].id])
        let link = TodoContentLink(kind: .pool, recordIDs: [try #require(records[1].id)], fallbackTitle: "共享品牌")
        let todo = try #require(try store.create(title: "核对报价", link: link))
        for id in [try #require(records[0].id), try #require(records[2].id), UUID()] {
            let invalid = TodoContentLink(kind: .pool, recordIDs: [id], fallbackTitle: "不应关联")
            #expect(throws: TodoStore.StoreError.self) { try store.create(title: "不应保存", link: invalid) }
            #expect(throws: TodoStore.StoreError.self) {
                try store.update(todo, title: "不应改名", notes: "不应改备注", dueDate: nil, link: invalid)
            }
        }
        #expect(store.items.map(\.title) == ["核对报价"])
        #expect(todo.contentLink == link)
        #expect(!store.context.hasChanges)
        stack.writable = false
        #expect(throws: TodoStore.StoreError.self) {
            try store.update(todo, title: "不应改名", notes: "", dueDate: nil, link: nil)
        }
        #expect(todo.contentLink == link)
    }

    @Test func deletedLinkedContentDoesNotBlockEditingOrRemovingExistingLink() throws {
        let stack = try Stack()
        let space = stack.makeSpace(store: stack.coordinator.persistentStores[0])
        let record = AdRecord(context: stack.context)
        record.id = UUID()
        record.brandName = "稍后删除"
        record.syncSpace = space
        try stack.context.save()
        let link = TodoContentLink(kind: .pool, recordIDs: [try #require(record.id)], fallbackTitle: "稍后删除")
        let store = stack.makeStore()
        let todo = try #require(try store.create(title: "独立待办", link: link))
        let deleter = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        deleter.persistentStoreCoordinator = stack.coordinator
        deleter.delete(try deleter.existingObject(with: record.objectID))
        try deleter.save()
        try store.update(todo, title: "内容已删除仍能编辑", notes: "", dueDate: nil, link: link)
        #expect(todo.contentLink == link)
        #expect(link.resolvedRecords(in: try store.contentRecords()).isEmpty)
        try store.update(todo, title: "保留待办", notes: "", dueDate: nil, link: nil)
        #expect(todo.linkedContent == nil)
    }

    private func instant(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private func waitForChanges(_ condition: () -> Bool) async {
        // Other suites can briefly occupy the main queue before Core Data delivers its merge.
        for _ in 0..<40 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor
    private final class SaveCounter {
        var count = 0
    }

    private final class Stack {
        let directory: URL
        let coordinator: NSPersistentStoreCoordinator
        let context: NSManagedObjectContext
        var selectedSpaceID: NSManagedObjectID?
        var writable = true
        var sharedCreatedIDs: [NSManagedObjectID] = []

        private static let managedObjectModel: NSManagedObjectModel = {
            #if SWIFT_PACKAGE
            PersistenceController(inMemory: true).container.managedObjectModel
            #else
            PersistenceController.shared.container.managedObjectModel
            #endif
        }()

        init(twoStores: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let model = Self.managedObjectModel
            coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            for index in 0..<(twoStores ? 2 : 1) {
                try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                    at: directory.appendingPathComponent("test-\(index).sqlite"), options: nil)
            }
            context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
        }

        deinit {
            context.reset()
            for store in coordinator.persistentStores { try? coordinator.remove(store) }
            try? FileManager.default.removeItem(at: directory)
        }

        func makeSpace(store: NSPersistentStore) -> SyncSpace {
            let space = SyncSpace(entity: coordinator.managedObjectModel.entitiesByName["SyncSpace"]!, insertInto: context)
            context.assign(space, to: store)
            space.id = UUID()
            space.createdAt = Date()
            return space
        }

        @MainActor
        func makeStore() -> TodoStore {
            let isolated = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            isolated.persistentStoreCoordinator = coordinator
            return TodoStore(context: isolated, existingSpace: { [self] context in
                try existing(in: context)
            }, activeSpace: { [self] context in
                if let current = try existing(in: context) { return current }
                let space = SyncSpace(entity: coordinator.managedObjectModel.entitiesByName["SyncSpace"]!, insertInto: context)
                context.assign(space, to: coordinator.persistentStores[0])
                space.id = UUID()
                space.createdAt = Date()
                return space
            }, canUpdate: { [self] _ in writable }, canDelete: { [self] _ in writable },
               didCreate: { [self] in sharedCreatedIDs.append(contentsOf: $0.map(\.objectID)) })
        }

        private func existing(in context: NSManagedObjectContext) throws -> SyncSpace? {
            let request: NSFetchRequest<SyncSpace> = SyncSpace.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \SyncSpace.createdAt, ascending: true)]
            if let selectedSpaceID {
                request.predicate = NSPredicate(format: "SELF == %@", selectedSpaceID)
                request.affectedStores = selectedSpaceID.persistentStore.map { [$0] }
            }
            return try context.fetch(request).first
        }
    }
}
