//
//  RecordHelpers.swift
//  钱多多
//

import CoreData
import SwiftUI
import UIKit

let qddTimeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")
    ?? TimeZone(secondsFromGMT: 8 * 60 * 60)!

let qddCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "zh_Hans_CN")
    calendar.timeZone = qddTimeZone
    return calendar
}()

extension AdRecord {
    var statusValue: PaymentStatus {
        get { PaymentStatus(storedValue: paymentStatus) }
        set { paymentStatus = newValue.rawValue }
    }

    var paymentMethodValue: PaymentMethod {
        get { PaymentMethod(storedValue: paymentAccount) }
        set { paymentAccount = newValue.rawValue }
    }

    var categoryValue: AdCategory {
        get { AdCategory(storedValue: platform) }
        set { platform = newValue.rawValue }
    }

    var partnershipValue: PartnershipType {
        get { PartnershipType(storedValue: productCode) }
        set { productCode = newValue.rawValue }
    }

    var needsPayment: Bool {
        partnershipValue.needsPayment
    }

    var billableAmount: Double {
        needsPayment ? max(adFee, 0) : 0
    }

    var amountColumnText: String {
        needsPayment ? moneyText(billableAmount) : ""
    }

    var priceDisplayText: String {
        if !needsPayment { return "" }
        return adFee > 0 ? moneyText(billableAmount) : "报价"
    }

    var hasPriceValue: Bool {
        needsPayment && adFee > 0
    }

    var ledgerCopyText: String {
        "品牌名：\(titleText)\n微信号：\(contactWeChat.nonEmptyOr("未填微信"))"
    }

    var publishedDate: Date? {
        get { dueDate }
        set { dueDate = newValue }
    }

    var workflowValue: AdWorkflow {
        if statusValue == .paid {
            return .paid
        }
        if publishedDate != nil {
            return .published
        }
        if isAssignedToVideo {
            return .scheduled
        }
        return .pool
    }

    var isAssignedToVideo: Bool {
        videoTitle.nonEmptyOr("").isEmpty == false || publishDate != nil
    }

    var titleText: String {
        brandName.nonEmptyOr("未填写品牌")
    }

    var subtitleText: String {
        let video = videoTitle.nonEmptyOr("未排视频")
        return "\(categoryValue.rawValue) · LOOK \(lookNumber) · \(video)"
    }

    var arrivalText: String {
        arrivalDate == nil ? "未到货" : "已到货"
    }

    var scheduleText: String {
        if let publishedDate {
            return "发布 " + shortDateText(publishedDate)
        }
        if let publishDate {
            return "排期 " + shortDateText(publishDate)
        }
        if isAssignedToVideo {
            return "待定"
        }
        return "待排期"
    }

    var reportDate: Date {
        publishedDate ?? publishDate ?? createdAt ?? Date.distantPast
    }

    var sortDate: Date {
        createdAt ?? publishDate ?? publishedDate ?? paidDate ?? Date.distantPast
    }

    var poolMonthDate: Date {
        createdAt ?? publishDate ?? Date.distantPast
    }

    var paidValue: Double {
        statusValue == .paid ? billableAmount : 0
    }

    var remainingAmount: Double {
        statusValue != .paid ? billableAmount : 0
    }

    var isInLedger: Bool {
        needsPayment && (publishedDate != nil || statusValue == .paid)
    }

    var searchableText: String {
        [
            brandName,
            contactWeChat,
            platform,
            videoTitle,
            productCode,
            paymentAccount,
            paymentNote,
            paymentStatus
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

extension Optional where Wrapped == String {
    func nonEmptyOr(_ fallback: String) -> String {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return fallback
        }
        return value
    }
}

extension String {
    func nonEmptyOr(_ fallback: String) -> String {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }
}

func makeVideoGroups(from records: [AdRecord]) -> [VideoGroup] {
    let scheduledRecords = records.filter(\.isAssignedToVideo)
    let grouped = Dictionary(grouping: scheduledRecords) { record in
        let dateKey = record.publishDate.map { dayOnly($0).timeIntervalSinceReferenceDate } ?? -1
        let name = record.videoTitle.nonEmptyOr("未命名视频")
        return "\(dateKey)-\(name)"
    }

    return grouped.values.compactMap { records in
        guard let first = records.first else { return nil }
        return VideoGroup(
            name: first.videoTitle.nonEmptyOr("未命名视频"),
            date: first.publishDate.map(dayOnly),
            order: videoGroupOrder(records),
            records: records.sorted(by: videoRecordSort)
        )
    }
    .sorted { first, second in
        if (first.date == nil) != (second.date == nil) {
            return first.date == nil
        }
        guard let firstDate = first.date, let secondDate = second.date else {
            if first.order != second.order {
                return first.order < second.order
            }
            return first.createdSortDate < second.createdSortDate
        }
        if firstDate != secondDate {
            return firstDate < secondDate
        }
        if first.order != second.order {
            return first.order < second.order
        }
        return first.title.localizedStandardCompare(second.title) == .orderedAscending
    }
}

func numberedBrandNamesCopyText(_ brandNames: [String]) -> String {
    brandNames.enumerated()
        .map { index, brandName in
            "\(keycapNumberText(index + 1))应该是\(brandName.nonEmptyOr("未填写品牌"))"
        }
        .joined(separator: "\n")
}

func brandNamesListImage(_ brandNames: [String]) -> UIImage {
    brandListImage(text: numberedBrandNamesCopyText(brandNames))
}

func brandListImage(text: String) -> UIImage {
    let imageWidth: CGFloat = 960
    let horizontalPadding: CGFloat = 56
    let verticalPadding: CGFloat = 48
    let textWidth = imageWidth - horizontalPadding * 2

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byCharWrapping
    paragraphStyle.lineSpacing = 6
    paragraphStyle.paragraphSpacing = 12

    let attributedText = NSAttributedString(
        string: text,
        attributes: [
            .font: UIFont.systemFont(ofSize: 54, weight: .regular),
            .foregroundColor: UIColor(white: 0.96, alpha: 1),
            .paragraphStyle: paragraphStyle
        ]
    )
    let drawingOptions: NSStringDrawingOptions = [
        .usesLineFragmentOrigin,
        .usesFontLeading
    ]
    let measuredTextSize = attributedText.boundingRect(
        with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
        options: drawingOptions,
        context: nil
    ).integral.size
    let imageHeight = max(240, ceil(measuredTextSize.height) + verticalPadding * 2)
    let imageSize = CGSize(width: imageWidth, height: imageHeight)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true

    return UIGraphicsImageRenderer(size: imageSize, format: format).image { context in
        context.cgContext.setFillColor(UIColor.black.cgColor)
        context.cgContext.fill(CGRect(origin: .zero, size: imageSize))

        attributedText.draw(
            with: CGRect(
                x: horizontalPadding,
                y: verticalPadding,
                width: textWidth,
                height: measuredTextSize.height
            ),
            options: drawingOptions,
            context: nil
        )
    }
}

private func keycapNumberText(_ number: Int) -> String {
    if number == 10 {
        return "🔟"
    }

    return String(number)
        .map { "\($0)\u{FE0F}\u{20E3}" }
        .joined()
}

func videoGroupOrder(_ records: [AdRecord]) -> Double {
    if let existingOrder = records.map(\.videoOrder).filter({ $0 > 0 }).min() {
        return existingOrder
    }
    return records
        .compactMap(\.createdAt)
        .map(\.timeIntervalSinceReferenceDate)
        .min() ?? Date.distantFuture.timeIntervalSinceReferenceDate
}

func videoOrder(name: String, date: Date?, in context: NSManagedObjectContext) -> Double {
    let cleanedName = name.nonEmptyOr("未命名视频")
    let request: NSFetchRequest<AdRecord> = AdRecord.fetchRequest()
    if let date {
        let startDate = dayOnly(date)
        let endDate = qddCalendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate
        request.predicate = NSPredicate(
            format: "videoTitle == %@ AND publishDate >= %@ AND publishDate < %@",
            cleanedName,
            startDate as NSDate,
            endDate as NSDate
        )
    } else {
        request.predicate = NSPredicate(format: "videoTitle == %@ AND publishDate == nil", cleanedName)
    }
    request.sortDescriptors = [NSSortDescriptor(keyPath: \AdRecord.videoOrder, ascending: true)]
    request.fetchLimit = 1

    if let record = try? context.fetch(request).first, record.videoOrder > 0 {
        return record.videoOrder
    }
    return nextVideoOrder(in: context)
}

func nextVideoItemOrder(name: String, date: Date?, in context: NSManagedObjectContext) -> Double {
    let cleanedName = name.nonEmptyOr("未命名视频")
    let request: NSFetchRequest<AdRecord> = AdRecord.fetchRequest()
    if let date {
        let startDate = dayOnly(date)
        let endDate = qddCalendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate
        request.predicate = NSPredicate(
            format: "videoTitle == %@ AND publishDate >= %@ AND publishDate < %@ AND videoOrder > 0",
            cleanedName,
            startDate as NSDate,
            endDate as NSDate
        )
    } else {
        request.predicate = NSPredicate(format: "videoTitle == %@ AND publishDate == nil AND videoOrder > 0", cleanedName)
    }
    request.sortDescriptors = [NSSortDescriptor(keyPath: \AdRecord.videoOrder, ascending: false)]
    request.fetchLimit = 1

    if let maxOrder = try? context.fetch(request).first?.videoOrder, maxOrder > 0 {
        return maxOrder + 1
    }
    return videoOrder(name: cleanedName, date: date.map(dayOnly), in: context)
}

func nextVideoOrder(in context: NSManagedObjectContext) -> Double {
    let request: NSFetchRequest<AdRecord> = AdRecord.fetchRequest()
    request.predicate = NSPredicate(format: "videoOrder > 0")
    request.sortDescriptors = [NSSortDescriptor(keyPath: \AdRecord.videoOrder, ascending: false)]
    request.fetchLimit = 1

    let currentMax = (try? context.fetch(request).first?.videoOrder) ?? 0
    return max(currentMax + 1, Date().timeIntervalSinceReferenceDate)
}

func scheduleTargetID(name: String, date: Date?) -> String {
    let dateKey = date.map { String(dayOnly($0).timeIntervalSinceReferenceDate) } ?? "pending"
    return "\(dateKey)-\(name.nonEmptyOr("未命名视频"))"
}

func fetchVideoLikeSnapshots(
    videoName: String,
    videoDate: Date?,
    in context: NSManagedObjectContext
) throws -> [VideoLikeSnapshot] {
    let request: NSFetchRequest<VideoLikeSnapshot> = VideoLikeSnapshot.fetchRequest()
    let cleanedName = videoName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOr("未命名视频")

    if let videoDate {
        let startDate = dayOnly(videoDate)
        let endDate = qddCalendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate
        request.predicate = NSPredicate(
            format: "videoName == %@ AND videoDate >= %@ AND videoDate < %@",
            cleanedName,
            startDate as NSDate,
            endDate as NSDate
        )
    } else {
        request.predicate = NSPredicate(format: "videoName == %@ AND videoDate == nil", cleanedName)
    }
    request.sortDescriptors = [
        NSSortDescriptor(keyPath: \VideoLikeSnapshot.recordedAt, ascending: false)
    ]
    return try context.fetch(request)
}

func deleteVideoLikeSnapshots(
    videoName: String,
    videoDate: Date?,
    in context: NSManagedObjectContext
) {
    do {
        try fetchVideoLikeSnapshots(videoName: videoName, videoDate: videoDate, in: context)
            .forEach(context.delete)
    } catch {
        AppLogger.shared.log("删除视频点赞记录失败: \(error.localizedDescription)")
    }
}

func moneyText(_ amount: Double) -> String {
    amount.formatted(.currency(code: "CNY").precision(.fractionLength(0...2)))
}

func monthTitle(_ date: Date) -> String {
    let components = qddCalendar.dateComponents([.year, .month], from: date)
    return "\(components.year ?? 0)年\(components.month ?? 1)月"
}

func shortDateText(_ date: Date?) -> String {
    guard let date else { return "未填" }
    let components = qddCalendar.dateComponents([.month, .day], from: date)
    return "\(components.month ?? 1)月\(components.day ?? 1)日"
}

func chineseDateText(_ date: Date) -> String {
    let components = qddCalendar.dateComponents([.year, .month, .day], from: date)
    return "\(components.year ?? 0)年\(components.month ?? 1)月\(components.day ?? 1)日"
}

func chineseMonthText(_ date: Date) -> String {
    let month = qddCalendar.component(.month, from: date)
    return "\(month)月"
}

func chineseDayText(_ date: Date) -> String {
    let day = qddCalendar.component(.day, from: date)
    return String(format: "%02d", day)
}

func dayOnly(_ date: Date) -> Date {
    qddCalendar.startOfDay(for: date)
}

func ledgerDateTint(for date: Date) -> Color {
    let calendar = qddCalendar
    let startDate = calendar.startOfDay(for: date)
    let today = calendar.startOfDay(for: Date())
    let elapsedDays = calendar.dateComponents([.day], from: startDate, to: today).day ?? 0

    if elapsedDays > 20 {
        return .red
    }
    if elapsedDays > 15 {
        return .orange
    }
    return AppTheme.primary
}

func monthStart(_ date: Date) -> Date {
    let components = qddCalendar.dateComponents([.year, .month], from: date)
    return qddCalendar.date(from: components) ?? qddCalendar.startOfDay(for: date)
}

func sortedLookNumbers(from records: [AdRecord]) -> [Int] {
    Array(Set(records.map { Int($0.lookNumber) }.filter { $0 > 0 })).sorted()
}

func poolRecordSort(_ first: AdRecord, _ second: AdRecord) -> Bool {
    let firstOrder = effectivePoolOrder(first)
    let secondOrder = effectivePoolOrder(second)
    if firstOrder != secondOrder {
        return firstOrder > secondOrder
    }
    return (first.createdAt ?? Date.distantPast) > (second.createdAt ?? Date.distantPast)
}

func effectivePoolOrder(_ record: AdRecord) -> Double {
    record.poolOrder > 0 ? record.poolOrder : record.sortDate.timeIntervalSinceReferenceDate
}

func assignPoolOrder(to record: AdRecord, previous: AdRecord?, next: AdRecord?) {
    let previousOrder = previous.map(effectivePoolOrder)
    let nextOrder = next.map(effectivePoolOrder)
    let newOrder: Double

    switch (previousOrder, nextOrder) {
    case let (previousOrder?, nextOrder?):
        let gap = previousOrder - nextOrder
        newOrder = gap > 0.000_001 ? (previousOrder + nextOrder) / 2 : previousOrder - 0.000_001
    case let (nil, nextOrder?):
        newOrder = nextOrder + 1
    case let (previousOrder?, nil):
        newOrder = max(previousOrder / 2, 0.000_001)
    case (nil, nil):
        newOrder = Date().timeIntervalSinceReferenceDate
    }

    guard abs(record.poolOrder - newOrder) > 0.000_000_1 else { return }
    record.poolOrder = newOrder
    record.updatedAt = Date()
}

func assignPoolOrder(to records: [AdRecord]) {
    let baseOrder = Date().timeIntervalSinceReferenceDate
    let count = records.count
    records.enumerated().forEach { index, record in
        let newOrder = baseOrder + Double(count - index)
        guard abs(record.poolOrder - newOrder) > 0.000_000_1 else { return }
        record.poolOrder = newOrder
        record.updatedAt = Date()
    }
}

func filterPoolRecords(
    _ records: [AdRecord],
    category: AdCategory?,
    partnership: PartnershipType?,
    arrival: ArrivalFilter,
    lookNumber: Int?,
    searchText: String = ""
) -> [AdRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return records.filter { record in
        let categoryMatches = category.map { record.categoryValue == $0 } ?? true
        let partnershipMatches = partnership.map { record.partnershipValue == $0 } ?? true
        let arrivalMatches = arrival.matches(record)
        let lookMatches = lookNumber.map { Int(record.lookNumber) == $0 } ?? true
        let searchMatches = query.isEmpty || record.searchableText.localizedCaseInsensitiveContains(query)
        return categoryMatches && partnershipMatches && arrivalMatches && lookMatches && searchMatches
    }
}

func videoRecordSort(_ first: AdRecord, _ second: AdRecord) -> Bool {
    if first.videoOrder > 0, second.videoOrder > 0, first.videoOrder != second.videoOrder {
        return first.videoOrder < second.videoOrder
    }
    if (first.videoOrder > 0) != (second.videoOrder > 0) {
        return first.videoOrder > 0
    }

    let firstLook = first.lookNumber > 0 ? first.lookNumber : Int16.max
    let secondLook = second.lookNumber > 0 ? second.lookNumber : Int16.max
    if firstLook != secondLook {
        return firstLook < secondLook
    }
    return (first.createdAt ?? Date.distantPast) < (second.createdAt ?? Date.distantPast)
}

func prepareRecordsForVideo(_ records: [AdRecord], name: String, date: Date?) {
    let scheduledDate = date.map(dayOnly)
    records.forEach { record in
        record.videoTitle = name
        record.publishDate = scheduledDate
        record.publishedDate = nil
        record.commentReminderID = nil
        record.brandCommentedAt = nil
        record.statusValue = .unpaid
        record.paidDate = nil
        record.paymentAccount = nil
        record.paidAmount = 0
        record.updatedAt = Date()
    }
}

func assignVideoOrder(to records: [AdRecord], startingAt start: Double) {
    records.enumerated().forEach { index, record in
        let newOrder = start + Double(index)
        guard abs(record.videoOrder - newOrder) > 0.000_000_1 else { return }
        record.videoOrder = newOrder
        record.updatedAt = Date()
    }
}

func assignLookNumbers(to records: [AdRecord], startingAt start: Int = 1) {
    records.enumerated().forEach { index, record in
        record.lookNumber = Int16(clamping: start + index)
        record.updatedAt = Date()
    }
}

let photoTargetByteCount = 180_000

nonisolated func decodedPhotoImage(from data: Data) async -> UIImage? {
    await Task.detached(priority: .userInitiated) {
        UIImage(data: data)
    }.value
}

func normalizedPhotoData(_ data: Data) -> Data? {
    guard let image = UIImage(data: data) else { return data }
    return normalizedPhotoData(image)
}

func normalizedPhotoData(_ image: UIImage) -> Data? {
    let maxSide: CGFloat = 560
    let longestSide = max(image.size.width, image.size.height)
    let scale = longestSide > maxSide ? maxSide / longestSide : 1
    let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

    let renderer = UIGraphicsImageRenderer(size: targetSize)
    let renderedImage = renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: targetSize))
    }

    for quality in stride(from: 0.62, through: 0.36, by: -0.08) {
        guard let compressedData = renderedImage.jpegData(compressionQuality: quality) else { continue }
        if compressedData.count <= photoTargetByteCount {
            return compressedData
        }
    }
    return renderedImage.jpegData(compressionQuality: 0.32)
}

func moveRecordBackToPool(_ record: AdRecord) {
    record.videoTitle = nil
    record.publishDate = nil
    record.publishedDate = nil
    record.commentReminderID = nil
    record.brandCommentedAt = nil
    record.statusValue = .unpaid
    record.paidDate = nil
    record.paymentAccount = nil
    record.paidAmount = 0
    record.lookNumber = 0
    record.poolOrder = Date().timeIntervalSinceReferenceDate
    record.videoOrder = 0
    record.updatedAt = Date()
}

func notifyRecordsChanged() {
    NotificationCenter.default.post(name: .adRecordsDidChange, object: nil)
}
