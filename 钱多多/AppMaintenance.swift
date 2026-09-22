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

    func clearLogs() {
        logs.removeAll()
        UserDefaults.standard.removeObject(forKey: logKey)
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
                lookNumber: record.lookNumber,
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
                brandCommentedAt: record.brandCommentedAt
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
            records: exportList,
            followerSnapshots: followerSnapshots,
            videoLikeSnapshots: videoLikeSnapshots
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
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

func importRecords(data: Data, context: NSManagedObjectContext) -> Int {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    do {
        let importBundle: ExportDataBundle
        if let bundle = try? decoder.decode(ExportDataBundle.self, from: data) {
            importBundle = bundle
        } else {
            let legacyRecords = try decoder.decode([ExportRecord].self, from: data)
            importBundle = ExportDataBundle(records: legacyRecords, followerSnapshots: [], videoLikeSnapshots: nil)
        }
        let syncSpace = try? PersistenceController.shared.activeSyncSpace(in: context)
        var imported = 0
        var importedRecords: [AdRecord] = []
        var importedFollowerSnapshots: [FollowerSnapshot] = []
        var importedVideoLikeSnapshots: [VideoLikeSnapshot] = []
        for item in importBundle.records {
            let record = AdRecord(context: context)
            if let syncSpace {
                if let store = syncSpace.objectID.persistentStore {
                    context.assign(record, to: store)
                }
                record.syncSpace = syncSpace
            }
            record.id = UUID(uuidString: item.id) ?? UUID()
            record.brandName = item.brandName
            record.contactWeChat = item.contactWeChat
            record.platform = item.platform
            record.productCode = item.productCode
            record.adFee = item.adFee
            record.lookNumber = item.lookNumber
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
            importedRecords.append(record)
            imported += 1
        }

        for item in importBundle.followerSnapshots {
            let snapshot = FollowerSnapshot(context: context)
            if let syncSpace {
                if let store = syncSpace.objectID.persistentStore {
                    context.assign(snapshot, to: store)
                }
                snapshot.syncSpace = syncSpace
            }
            snapshot.id = UUID(uuidString: item.id) ?? UUID()
            snapshot.date = item.date
            snapshot.followerCount = max(item.followerCount, 0)
            snapshot.createdAt = item.createdAt ?? Date()
            snapshot.updatedAt = item.updatedAt ?? Date()
            importedFollowerSnapshots.append(snapshot)
            imported += 1
        }

        for item in importBundle.videoLikeSnapshots ?? [] {
            let snapshot = VideoLikeSnapshot(context: context)
            if let syncSpace {
                if let store = syncSpace.objectID.persistentStore {
                    context.assign(snapshot, to: store)
                }
                snapshot.syncSpace = syncSpace
            }
            snapshot.id = UUID(uuidString: item.id) ?? UUID()
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
        PersistenceController.shared.shareOwnedRecordsIfNeeded(importedRecords)
        PersistenceController.shared.shareOwnedFollowerSnapshotsIfNeeded(importedFollowerSnapshots)
        PersistenceController.shared.shareOwnedVideoLikeSnapshotsIfNeeded(importedVideoLikeSnapshots)
        notifyRecordsChanged()
        AppLogger.shared.log(
            "导入了 \(importedRecords.count) 条合作记录、\(importedFollowerSnapshots.count) 条粉丝记录和 \(importedVideoLikeSnapshots.count) 条点赞记录"
        )
        return imported
    } catch {
        AppLogger.shared.log("导入失败: \(error.localizedDescription)")
        context.rollback()
        return 0
    }
}
