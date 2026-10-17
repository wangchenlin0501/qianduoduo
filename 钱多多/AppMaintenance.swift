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

    private let maxLogs = 80
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

// MARK: - Photo Cleanup (3 months)

func recompressLargePhotos(context: NSManagedObjectContext) {
    let request: NSFetchRequest<AdRecord> = AdRecord.fetchRequest()
    request.predicate = NSPredicate(format: "photoData != nil")

    do {
        let records = try context.fetch(request)
        var changedRecords: [AdRecord] = []
        for record in records {
            guard
                let photoData = record.photoData,
                photoData.count > photoTargetByteCount,
                let compressedData = normalizedPhotoData(photoData),
                compressedData.count < photoData.count
            else {
                continue
            }
            record.photoData = compressedData
            record.updatedAt = Date()
            changedRecords.append(record)
        }

        guard !changedRecords.isEmpty else { return }
        try context.save()
        context.processPendingChanges()
        PersistenceController.shared.shareOwnedRecordsIfNeeded(changedRecords)
        AppLogger.shared.log("压缩了 \(changedRecords.count) 条过大的截图")
    } catch {
        AppLogger.shared.log("压缩旧截图失败: \(PersistenceController.describe(error))")
    }
}

func cleanupOldPhotos(context: NSManagedObjectContext) {
    let threeMonthsAgo = qddCalendar.date(byAdding: .month, value: -3, to: Date()) ?? Date()
    let request: NSFetchRequest<AdRecord> = AdRecord.fetchRequest()
    request.predicate = NSPredicate(format: "photoData != nil AND createdAt < %@", threeMonthsAgo as NSDate)

    do {
        let oldRecords = try context.fetch(request)
        guard !oldRecords.isEmpty else { return }
        var count = 0
        for record in oldRecords {
            if record.photoData != nil {
                record.photoData = nil
                count += 1
            }
        }
        if count > 0 {
            try context.save()
            AppLogger.shared.log("自动清理了 \(count) 条超过三个月的截图数据")
        }
    } catch {
        AppLogger.shared.log("清理旧截图失败: \(error.localizedDescription)")
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

struct ExportDataBundle: Codable {
    let formatVersion: Int?
    let records: [ExportRecord]
    let followerSnapshots: [ExportFollowerSnapshot]
    let videoLikeSnapshots: [ExportVideoLikeSnapshot]?
}

func exportRecords(context: NSManagedObjectContext) -> Data? {
    let request: NSFetchRequest<AdRecord> = AdRecord.fetchRequest()
    request.sortDescriptors = [NSSortDescriptor(keyPath: \AdRecord.createdAt, ascending: false)]

    let followerRequest: NSFetchRequest<FollowerSnapshot> = FollowerSnapshot.fetchRequest()
    followerRequest.sortDescriptors = [NSSortDescriptor(keyPath: \FollowerSnapshot.date, ascending: false)]

    let videoLikeRequest: NSFetchRequest<VideoLikeSnapshot> = VideoLikeSnapshot.fetchRequest()
    videoLikeRequest.sortDescriptors = [NSSortDescriptor(keyPath: \VideoLikeSnapshot.recordedAt, ascending: false)]

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
        let exportBundle = ExportDataBundle(
            formatVersion: 2,
            records: exportList,
            followerSnapshots: followerSnapshots,
            videoLikeSnapshots: videoLikeSnapshots
        )
        let encoder = JSONEncoder()
        // Native Date encoding preserves subsecond timestamps exactly.
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.dataEncodingStrategy = .base64
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        AppLogger.shared.log(
            "导出了 \(exportList.count) 条合作记录、\(followerSnapshots.count) 条粉丝记录和 \(videoLikeSnapshots.count) 条点赞记录"
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

private enum BackupImportError: LocalizedError {
    case invalidRecordID
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .invalidRecordID:
            "备份中有无效的记录标识，未导入任何数据。"
        case .unsupportedFormat:
            "这份备份来自更新版本，请先更新 App 后再导入。"
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

func importRecords(
    data: Data,
    context: NSManagedObjectContext,
    persistence: PersistenceController = .shared
) throws -> RecordImportSummary {
    let decoder = JSONDecoder()
    decoder.dataDecodingStrategy = .base64

    do {
        let version = (try? decoder.decode(BackupFormatHeader.self, from: data))?.formatVersion ?? 1
        switch version {
        case 1:
            decoder.dateDecodingStrategy = .iso8601
        case 2:
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

        var existingRecordIDs = Set(try context.fetch(AdRecord.fetchRequest()).compactMap(\.id))
        var existingFollowerIDs = Set(try context.fetch(FollowerSnapshot.fetchRequest()).compactMap(\.id))
        var existingLikeIDs = Set(try context.fetch(VideoLikeSnapshot.fetchRequest()).compactMap(\.id))

        let hasNewRecords = recordIDs.contains { !existingRecordIDs.contains($0) }
            || followerIDs.contains { !existingFollowerIDs.contains($0) }
            || likeIDs.contains { !existingLikeIDs.contains($0) }
        guard hasNewRecords else {
            return RecordImportSummary(
                importedCount: 0,
                skippedCount: recordIDs.count + followerIDs.count + likeIDs.count
            )
        }

        let syncSpace = try persistence.activeSyncSpace(in: context)
        var imported = 0
        var skipped = 0
        var importedRecords: [AdRecord] = []
        var importedFollowerSnapshots: [FollowerSnapshot] = []
        var importedVideoLikeSnapshots: [VideoLikeSnapshot] = []
        for (item, id) in zip(importBundle.records, recordIDs) {
            guard existingRecordIDs.insert(id).inserted else {
                skipped += 1
                continue
            }
            let record = AdRecord(context: context)
            if let store = syncSpace.objectID.persistentStore {
                context.assign(record, to: store)
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
            let snapshot = FollowerSnapshot(context: context)
            if let store = syncSpace.objectID.persistentStore {
                context.assign(snapshot, to: store)
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
            let snapshot = VideoLikeSnapshot(context: context)
            if let store = syncSpace.objectID.persistentStore {
                context.assign(snapshot, to: store)
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
        try context.save()
        context.processPendingChanges()
        persistence.shareOwnedRecordsIfNeeded(importedRecords)
        persistence.shareOwnedFollowerSnapshotsIfNeeded(importedFollowerSnapshots)
        persistence.shareOwnedVideoLikeSnapshotsIfNeeded(importedVideoLikeSnapshots)
        notifyRecordsChanged()
        AppLogger.shared.log(
            "导入了 \(importedRecords.count) 条合作记录、\(importedFollowerSnapshots.count) 条粉丝记录和 \(importedVideoLikeSnapshots.count) 条点赞记录，跳过 \(skipped) 条重复记录"
        )
        return RecordImportSummary(importedCount: imported, skippedCount: skipped)
    } catch {
        AppLogger.shared.log("导入失败: \(error.localizedDescription)")
        context.rollback()
        throw error
    }
}
