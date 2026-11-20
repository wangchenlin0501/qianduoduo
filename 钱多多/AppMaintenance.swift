//
//  AppMaintenance.swift
//  钱多多
//

import CoreData
import Combine
import SwiftUI

// MARK: - App Logger

final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published private(set) var logs: [String] = []

    let sessionID = String(UUID().uuidString.prefix(8))
    let sessionStartedAt = Date()

    var sessionDescription: String {
        "\(sessionID)，开始于 \(dateFormatter.string(from: sessionStartedAt))"
    }

    private let maxLogs = 240
    private let logKey = "app_logs"

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "zh_CN")
        df.timeZone = qddTimeZone
        return df
    }()

    init() {
        let savedLogs = UserDefaults.standard.stringArray(forKey: logKey) ?? []
        logs = Array(savedLogs.suffix(maxLogs))
        if logs.count != savedLogs.count {
            UserDefaults.standard.set(logs, forKey: logKey)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        log("启动会话 \(sessionID)，版本 \(version)（\(build)）；此前日志为历史记录")
    }

    func log(_ message: String) {
        let entry = "[\(dateFormatter.string(from: Date()))] \(message)"
        DispatchQueue.main.async {
            self.logs.append(entry)
            if self.logs.count > self.maxLogs {
                self.logs = Array(self.logs.suffix(self.maxLogs))
            }
            UserDefaults.standard.set(self.logs, forKey: self.logKey)
        }
    }

}

// MARK: - Background Photo Maintenance (compression only)

/// Screenshots are compressed but never deleted automatically. The former age-based cleanup ran
/// silently, synced the deletion to every device and share member, and also wiped screenshots of
/// back-filled or imported older records. Any future removal needs an explicit, user-initiated flow.
@MainActor
final class PhotoMaintenanceService {
    static let shared = PhotoMaintenanceService()
    private var runningCoordinators: Set<ObjectIdentifier> = []
    private var completedCoordinators: Set<ObjectIdentifier> = []

    func schedule(using context: NSManagedObjectContext) {
        guard let coordinator = context.persistentStoreCoordinator else { return }
        let key = ObjectIdentifier(coordinator)
        guard !runningCoordinators.contains(key), !completedCoordinators.contains(key) else { return }
        runningCoordinators.insert(key)

        let startedAt = Date()
        // Snapshot identities only. Never fault or decode image data on the UI context.
        let editedIDs = Set(context.updatedObjects.union(context.insertedObjects)
            .union(context.deletedObjects).map(\.objectID))
        let byteLimit = photoTargetByteCount

        Task(priority: .utility) {
            defer { runningCoordinators.remove(key) }
            do {
                let summary = try await PhotoMaintenanceWorker.run(
                    coordinator: coordinator, startedAt: startedAt,
                    targetByteCount: byteLimit, excluding: editedIDs,
                    compress: { MaintenancePhotoEncoder.normalizedData($0, targetByteCount: byteLimit) }
                )
                completedCoordinators.insert(key)
                // Keep managed objects on their own queue; only stable IDs leave the worker.
                for offset in stride(from: 0, to: summary.compressedObjectIDs.count, by: 8) {
                    let end = min(offset + 8, summary.compressedObjectIDs.count)
                    let records = summary.compressedObjectIDs[offset..<end].compactMap {
                        context.object(with: $0) as? AdRecord
                    }
                    PersistenceController.shared.shareOwnedRecordsIfNeeded(records)
                    await Task.yield()
                }
                if !summary.compressedObjectIDs.isEmpty {
                    AppLogger.shared.log("后台压缩了 \(summary.compressedObjectIDs.count) 条过大的截图")
                }
                if summary.conflictedCount > 0 {
                    AppLogger.shared.log("截图维护跳过了 \(summary.conflictedCount) 条同时被修改的记录")
                }
            } catch {
                AppLogger.shared.log("后台截图维护失败: \(PersistenceController.describe(error))")
            }
        }
    }
}

// MARK: - Export / Import

struct ExportRecord: Codable {
    let id: String
    let brandName: String?
    let contactWeChat: String?
    let platform: String?
    let productCode: String?
    let adFee: Double
    let lookNumber: Int16
    let videoTitle: String?
    let paymentStatus: String?
    let paymentAccount: String?
    let paymentNote: String?
    let paidAmount: Double
    let poolOrder: Double?
    let videoOrder: Double?
    let createdAt: Date?
    let updatedAt: Date?
    let publishDate: Date?
    let dueDate: Date?
    let paidDate: Date?
    let arrivalDate: Date?
    let commentReminderID: String?
    let brandCommentedAt: Date?
    let clothingName: String?
    let photoData: Data?
}

struct ExportFollowerSnapshot: Codable {
    let id: String
    let date: Date?
    let followerCount: Int64
    let createdAt: Date?
    let updatedAt: Date?
}

struct ExportVideoLikeSnapshot: Codable {
    let id: String
    let videoName: String?
    let videoDate: Date?
    let publishedDate: Date?
    let recordedAt: Date?
    let likeCount: Int64
    let createdAt: Date?
    let updatedAt: Date?
}

struct ExportTodoItem: Codable {
    let id: String
    let title: String?
    let notes: String?
    let createdAt: Date?
    let updatedAt: Date?
    let completedAt: Date?
    let dueDate: Date?
    let sortOrder: Double
    var linkedContent: String? = nil
}

struct ExportDataBundle: Codable {
    let formatVersion: Int?
    let records: [ExportRecord]
    let followerSnapshots: [ExportFollowerSnapshot]
    let videoLikeSnapshots: [ExportVideoLikeSnapshot]?
    let todoItems: [ExportTodoItem]?
    var assistantMemory: [AIMemoryItem]? = nil
    var assistantModel: String? = nil
    var assistantBaseURL: String? = nil

    init(
        formatVersion: Int?, records: [ExportRecord],
        followerSnapshots: [ExportFollowerSnapshot], videoLikeSnapshots: [ExportVideoLikeSnapshot]?,
        todoItems: [ExportTodoItem]? = nil,
        assistantMemory: [AIMemoryItem]? = nil,
        assistantModel: String? = nil,
        assistantBaseURL: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.records = records
        self.followerSnapshots = followerSnapshots
        self.videoLikeSnapshots = videoLikeSnapshots
        self.todoItems = todoItems
        self.assistantMemory = assistantMemory
        self.assistantModel = assistantModel
        self.assistantBaseURL = assistantBaseURL
    }
}

func exportRecords(context: NSManagedObjectContext) -> Data? {
    let request: NSFetchRequest<AdRecord> = AdRecord.fetchRequest()
    request.sortDescriptors = [NSSortDescriptor(keyPath: \AdRecord.createdAt, ascending: false)]

    let followerRequest: NSFetchRequest<FollowerSnapshot> = FollowerSnapshot.fetchRequest()
    followerRequest.sortDescriptors = [NSSortDescriptor(keyPath: \FollowerSnapshot.date, ascending: false)]

    let videoLikeRequest: NSFetchRequest<VideoLikeSnapshot> = VideoLikeSnapshot.fetchRequest()
    videoLikeRequest.sortDescriptors = [NSSortDescriptor(keyPath: \VideoLikeSnapshot.recordedAt, ascending: false)]

    let todoRequest: NSFetchRequest<TodoItem> = TodoItem.fetchRequest()
    todoRequest.sortDescriptors = [
        NSSortDescriptor(keyPath: \TodoItem.sortOrder, ascending: true),
        NSSortDescriptor(keyPath: \TodoItem.createdAt, ascending: true)
    ]

    do {
        let records = try context.fetch(request)
        let exportList = records.map { record in
            ExportRecord(
                id: record.id?.uuidString ?? UUID().uuidString,
                brandName: record.brandName,
                contactWeChat: record.contactWeChat,
                platform: record.platform,
                productCode: record.productCode,
                adFee: record.adFee,
                lookNumber: record.usesLook ? record.lookNumber : 0,
                videoTitle: record.videoTitle,
                paymentStatus: record.paymentStatus,
                paymentAccount: record.paymentAccount,
                paymentNote: record.paymentNote,
                paidAmount: record.paidAmount,
                poolOrder: record.poolOrder,
                videoOrder: record.videoOrder,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                publishDate: record.publishDate,
                dueDate: record.dueDate,
                paidDate: record.paidDate,
                arrivalDate: record.arrivalDate,
                commentReminderID: record.commentReminderID,
                brandCommentedAt: record.brandCommentedAt,
                clothingName: record.clothingName,
                photoData: record.photoData
            )
        }
        let followerSnapshots = try context.fetch(followerRequest).map { snapshot in
            ExportFollowerSnapshot(
                id: snapshot.id?.uuidString ?? UUID().uuidString,
                date: snapshot.date,
                followerCount: snapshot.followerCount,
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.updatedAt
            )
        }
        let videoLikeSnapshots = try context.fetch(videoLikeRequest).map { snapshot in
            ExportVideoLikeSnapshot(
                id: snapshot.id?.uuidString ?? UUID().uuidString,
                videoName: snapshot.videoName,
                videoDate: snapshot.videoDate,
                publishedDate: snapshot.publishedDate,
                recordedAt: snapshot.recordedAt,
                likeCount: snapshot.likeCount,
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.updatedAt
            )
        }
        let todoItems = try context.fetch(todoRequest).map { item in
            ExportTodoItem(
                id: item.id?.uuidString ?? UUID().uuidString,
                title: item.title,
                notes: item.notes,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                completedAt: item.completedAt,
                dueDate: item.dueDate,
                sortOrder: item.sortOrder,
                linkedContent: item.linkedContent
            )
        }
        let sharedConfig = AISharedConfig.load(in: context)
        let memoryItems = AIMemoryStore.load(in: context)
        let exportBundle = ExportDataBundle(
            // Older apps reject this version rather than silently discarding content links.
            formatVersion: 4,
            records: exportList,
            followerSnapshots: followerSnapshots,
            videoLikeSnapshots: videoLikeSnapshots,
            todoItems: todoItems,
            assistantMemory: memoryItems.isEmpty ? nil : memoryItems,
            assistantModel: AISharedConfig.nonEmpty(sharedConfig.model) ?? AISharedConfig.nonEmpty(AIAssistantConfig.model),
            assistantBaseURL: AISharedConfig.nonEmpty(sharedConfig.baseURL)
        )
        let encoder = JSONEncoder()
        // Native Date encoding preserves subsecond timestamps exactly.
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.dataEncodingStrategy = .base64
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        AppLogger.shared.log(
            "导出了 \(exportList.count) 条合作记录、\(followerSnapshots.count) 条粉丝记录、\(videoLikeSnapshots.count) 条点赞记录和 \(todoItems.count) 条待办"
        )
        return try encoder.encode(exportBundle)
    } catch {
        AppLogger.shared.log("导出失败: \(error.localizedDescription)")
        return nil
    }
}

struct RecordImportSummary {
    let importedCount: Int
    let skippedCount: Int

    var message: String {
        if importedCount == 0 {
            return skippedCount > 0
                ? "这份备份中的记录均已存在，已跳过 \(skippedCount) 条重复记录。"
                : "备份中没有可导入的记录。"
        }
        if skippedCount > 0 {
            return "成功导入 \(importedCount) 条记录，跳过 \(skippedCount) 条重复记录。"
        }
        return "成功导入 \(importedCount) 条记录。"
    }
}

nonisolated enum BackupImportError: LocalizedError {
    case invalidRecordID
    case unsupportedFormat
    case unsavedDataSpace

    var errorDescription: String? {
        switch self {
        case .invalidRecordID:
            "备份中有无效的记录标识，未导入任何数据。"
        case .unsupportedFormat:
            "这份备份来自更新版本，请先更新 App 后再导入。"
        case .unsavedDataSpace:
            "还有刚新建、尚未保存的内容。请先保存或取消正在编辑的内容，再导入备份。未导入任何数据。"
        }
    }
}

private struct BackupFormatHeader: Decodable {
    let formatVersion: Int?
}

private func backupRecordID(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else {
        throw BackupImportError.invalidRecordID
    }
    return id
}

/// Imports a backup and merges the new rows into `context` (normally the view context).
///
/// The rows are written by a separate context on the same coordinator: a failed import is discarded
/// there without rolling back unsaved edits in `context`, and a successful one never commits them.
/// `context` must belong to `persistence`.
func importRecords(
    data: Data,
    context: NSManagedObjectContext,
    persistence: PersistenceController = .shared
) throws -> RecordImportSummary {
    let decoder = JSONDecoder()
    decoder.dataDecodingStrategy = .base64
    let importContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    importContext.persistentStoreCoordinator = persistence.container.persistentStoreCoordinator
    importContext.name = "BackupImport"
    importContext.undoManager = nil
    importContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

    do {
        let version = (try? decoder.decode(BackupFormatHeader.self, from: data))?.formatVersion ?? 1
        switch version {
        case 1:
            decoder.dateDecodingStrategy = .iso8601
        case 2, 3, 4:
            decoder.dateDecodingStrategy = .deferredToDate
        default:
            throw BackupImportError.unsupportedFormat
        }
        let importBundle: ExportDataBundle
        if let bundle = try? decoder.decode(ExportDataBundle.self, from: data) {
            importBundle = bundle
        } else {
            let legacyRecords = try decoder.decode([ExportRecord].self, from: data)
            importBundle = ExportDataBundle(formatVersion: nil, records: legacyRecords, followerSnapshots: [], videoLikeSnapshots: nil)
        }
        // Validate IDs before inserting anything; random replacements would defeat deduplication.
        let recordIDs = try importBundle.records.map { try backupRecordID($0.id) }
        let followerIDs = try importBundle.followerSnapshots.map { try backupRecordID($0.id) }
        let likeItems = importBundle.videoLikeSnapshots ?? []
        let likeIDs = try likeItems.map { try backupRecordID($0.id) }
        let todoItems = importBundle.todoItems ?? []
        let todoIDs = try todoItems.map { try backupRecordID($0.id) }

        var existingRecordIDs = Set(try importContext.fetch(AdRecord.fetchRequest()).compactMap(\.id))
        var existingFollowerIDs = Set(try importContext.fetch(FollowerSnapshot.fetchRequest()).compactMap(\.id))
        var existingLikeIDs = Set(try importContext.fetch(VideoLikeSnapshot.fetchRequest()).compactMap(\.id))
        var existingTodoIDs = Set(try importContext.fetch(TodoItem.fetchRequest()).compactMap(\.id))

        let hasNewRecords = recordIDs.contains { !existingRecordIDs.contains($0) }
            || followerIDs.contains { !existingFollowerIDs.contains($0) }
            || likeIDs.contains { !existingLikeIDs.contains($0) }
            || todoIDs.contains { !existingTodoIDs.contains($0) }
        guard hasNewRecords else {
            return RecordImportSummary(
                importedCount: 0,
                skippedCount: recordIDs.count + followerIDs.count + likeIDs.count + todoIDs.count
            )
        }

        let syncSpace: SyncSpace
        if let existingSpace = try persistence.existingActiveSyncSpace(in: importContext) {
            syncSpace = existingSpace
        } else {
            // The caller's context may hold a space created for an edit that is not saved yet. A second
            // space here would split records across two spaces, and sharing only follows one of them.
            let hasUnsavedSpace = context.performAndWait {
                context.insertedObjects.contains { $0 is SyncSpace }
            }
            guard !hasUnsavedSpace else { throw BackupImportError.unsavedDataSpace }
            syncSpace = try persistence.activeSyncSpace(in: importContext)
        }
        var imported = 0
        var skipped = 0
        var importedRecords: [AdRecord] = []
        var importedFollowerSnapshots: [FollowerSnapshot] = []
        var importedVideoLikeSnapshots: [VideoLikeSnapshot] = []
        var importedTodoItems: [TodoItem] = []
        for (item, id) in zip(importBundle.records, recordIDs) {
            guard existingRecordIDs.insert(id).inserted else {
                skipped += 1
                continue
            }
            let record = AdRecord(context: importContext)
            if let store = syncSpace.objectID.persistentStore {
                importContext.assign(record, to: store)
            }
            record.syncSpace = syncSpace
            record.id = id
            record.brandName = item.brandName
            record.contactWeChat = item.contactWeChat
            record.platform = item.platform
            record.productCode = item.productCode
            record.adFee = item.adFee
            record.lookNumber = record.usesLook ? item.lookNumber : 0
            record.videoTitle = item.videoTitle
            record.paymentStatus = item.paymentStatus
            record.paymentAccount = item.paymentAccount
            record.paymentNote = item.paymentNote
            record.paidAmount = item.paidAmount
            record.poolOrder = item.poolOrder ?? 0
            record.videoOrder = item.videoOrder ?? 0
            record.createdAt = item.createdAt ?? Date()
            record.updatedAt = item.updatedAt ?? Date()
            record.publishDate = item.publishDate
            record.dueDate = item.dueDate
            record.paidDate = item.paidDate
            record.arrivalDate = item.arrivalDate
            record.commentReminderID = item.commentReminderID
            record.brandCommentedAt = item.brandCommentedAt
            record.clothingName = item.clothingName
            record.photoData = item.photoData
            importedRecords.append(record)
            imported += 1
        }

        for (item, id) in zip(importBundle.followerSnapshots, followerIDs) {
            guard existingFollowerIDs.insert(id).inserted else {
                skipped += 1
                continue
            }
            let snapshot = FollowerSnapshot(context: importContext)
            if let store = syncSpace.objectID.persistentStore {
                importContext.assign(snapshot, to: store)
            }
            snapshot.syncSpace = syncSpace
            snapshot.id = id
            snapshot.date = item.date
            snapshot.followerCount = max(item.followerCount, 0)
            snapshot.createdAt = item.createdAt ?? Date()
            snapshot.updatedAt = item.updatedAt ?? Date()
            importedFollowerSnapshots.append(snapshot)
            imported += 1
        }

        for (item, id) in zip(likeItems, likeIDs) {
            guard existingLikeIDs.insert(id).inserted else {
                skipped += 1
                continue
            }
            let snapshot = VideoLikeSnapshot(context: importContext)
            if let store = syncSpace.objectID.persistentStore {
                importContext.assign(snapshot, to: store)
            }
            snapshot.syncSpace = syncSpace
            snapshot.id = id
            snapshot.videoName = item.videoName
            snapshot.videoDate = item.videoDate
            snapshot.publishedDate = item.publishedDate
            snapshot.recordedAt = item.recordedAt ?? Date()
            snapshot.likeCount = max(item.likeCount, 0)
            snapshot.createdAt = item.createdAt ?? Date()
            snapshot.updatedAt = item.updatedAt ?? Date()
            importedVideoLikeSnapshots.append(snapshot)
            imported += 1
        }
        for (item, id) in zip(todoItems, todoIDs) {
            guard existingTodoIDs.insert(id).inserted else {
                skipped += 1
                continue
            }
            let todo = TodoItem(context: importContext)
            if let store = syncSpace.objectID.persistentStore {
                importContext.assign(todo, to: store)
            }
            todo.syncSpace = syncSpace
            todo.id = id
            todo.title = item.title
            todo.notes = item.notes
            todo.linkedContent = item.linkedContent
            todo.createdAt = item.createdAt
            todo.updatedAt = item.updatedAt
            todo.completedAt = item.completedAt
            todo.dueDate = item.dueDate
            todo.sortOrder = item.sortOrder
            importedTodoItems.append(todo)
            imported += 1
        }
        let insertedObjects = importContext.insertedObjects
        let updatedObjects = importContext.updatedObjects
        try importContext.save()
        // Merge now instead of waiting for automatic merging, so the caller sees the new rows and the
        // space's relationships right away. Unsaved edits in `context` are kept, not committed.
        NSManagedObjectContext.mergeChanges(
            fromRemoteContextSave: [
                NSInsertedObjectsKey: insertedObjects.map(\.objectID),
                NSUpdatedObjectsKey: updatedObjects.map(\.objectID)
            ],
            into: [context]
        )
        persistence.shareOwnedRecordsIfNeeded(importedRecords)
        persistence.shareOwnedFollowerSnapshotsIfNeeded(importedFollowerSnapshots)
        persistence.shareOwnedVideoLikeSnapshotsIfNeeded(importedVideoLikeSnapshots)
        persistence.shareOwnedTodoItemsIfNeeded(importedTodoItems)
        notifyRecordsChanged()
        AppLogger.shared.log(
            "导入了 \(importedRecords.count) 条合作记录、\(importedFollowerSnapshots.count) 条粉丝记录、\(importedVideoLikeSnapshots.count) 条点赞记录和 \(importedTodoItems.count) 条待办，跳过 \(skipped) 条重复记录"
        )
        return RecordImportSummary(importedCount: imported, skippedCount: skipped)
    } catch {
        // Only the import's own context is discarded; edits still open elsewhere are untouched.
        importContext.rollback()
        AppLogger.shared.log("导入失败，已放弃本次导入，未改动其他未保存内容: \(PersistenceController.describe(error))")
        throw error
    }
}
