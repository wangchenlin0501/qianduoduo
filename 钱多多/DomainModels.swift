//
//  DomainModels.swift
//  钱多多
//

import CoreData
import SwiftUI

enum PaymentStatus: String, CaseIterable, Identifiable {
    case unpaid = "未打款"
    case paid = "已打款"

    var id: String { rawValue }

    init(storedValue: String?) {
        switch storedValue {
        case Self.paid.rawValue, "已到账":
            self = .paid
        default:
            self = .unpaid
        }
    }

    var tint: Color {
        switch self {
        case .unpaid:
            .red
        case .paid:
            .green
        }
    }

    var symbolName: String {
        switch self {
        case .unpaid:
            "exclamationmark.circle.fill"
        case .paid:
            "checkmark.circle.fill"
        }
    }
}

enum PaymentMethod: String, CaseIterable, Identifiable {
    case weChat = "微信"
    case alipay = "支付宝"
    case bankCard = "银行卡"

    var id: String { rawValue }

    init(storedValue: String?) {
        switch storedValue {
        case Self.alipay.rawValue:
            self = .alipay
        case Self.bankCard.rawValue, "招商银行卡", "银行卡转账":
            self = .bankCard
        default:
            self = .weChat
        }
    }

    var symbolName: String {
        switch self {
        case .weChat:
            "message.fill"
        case .alipay:
            "qrcode"
        case .bankCard:
            "creditcard.fill"
        }
    }
}

enum AdCategory: String, CaseIterable, Identifiable {
    case clothing = "衣服"
    case pants = "裤子"
    case skirt = "裙子"
    case outfit = "整套"
    case shoes = "鞋子"
    case accessory = "配饰"
    case other = "其他"

    var id: String { rawValue }

    init(storedValue: String?) {
        self = AdCategory(rawValue: storedValue ?? "") ?? .clothing
    }

    var tint: Color { AppTheme.primary }

    var symbolName: String {
        switch self {
        case .clothing:
            "tshirt.fill"
        case .pants:
            "figure.walk"
        case .skirt:
            "sparkles"
        case .outfit:
            "person.fill"
        case .shoes:
            "shoeprints.fill"
        case .accessory:
            "sunglasses.fill"
        case .other:
            "shippingbox.fill"
        }
    }
}

enum AdWorkflow: String, CaseIterable, Identifiable {
    case pool = "待拍摄"
    case scheduled = "已排期"
    case published = "已发布"
    case paid = "已打款"

    var id: String { rawValue }

    var tint: Color {
        switch self {
        case .pool:
            .gray
        case .scheduled:
            AppTheme.primary
        case .published:
            AppTheme.primary
        case .paid:
            .green
        }
    }

    var symbolName: String {
        switch self {
        case .pool:
            "tray.full.fill"
        case .scheduled:
            "calendar.badge.clock"
        case .published:
            "play.rectangle.fill"
        case .paid:
            "checkmark.circle.fill"
        }
    }
}

enum LedgerFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case unpaid = "未打款"
    case paid = "已打款"

    var id: String { rawValue }
}

enum LedgerSortOption: String, CaseIterable, Identifiable {
    case dateNewest = "日期新到旧"
    case dateOldest = "日期旧到新"
    case amountHigh = "金额高到低"
    case amountLow = "金额低到高"
    case brandName = "品牌名称"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .dateNewest:
            "calendar.badge.clock"
        case .dateOldest:
            "calendar"
        case .amountHigh:
            "arrow.down.circle.fill"
        case .amountLow:
            "arrow.up.circle.fill"
        case .brandName:
            "textformat"
        }
    }

    func areInIncreasingOrder(_ first: AdRecord, _ second: AdRecord) -> Bool {
        switch self {
        case .dateNewest:
            compareDates(first, second, newestFirst: true)
        case .dateOldest:
            compareDates(first, second, newestFirst: false)
        case .amountHigh:
            compareAmounts(first, second, highestFirst: true)
        case .amountLow:
            compareAmounts(first, second, highestFirst: false)
        case .brandName:
            compareBrands(first, second)
        }
    }

    private func compareDates(_ first: AdRecord, _ second: AdRecord, newestFirst: Bool) -> Bool {
        if first.reportDate != second.reportDate {
            return newestFirst ? first.reportDate > second.reportDate : first.reportDate < second.reportDate
        }
        return first.titleText.localizedStandardCompare(second.titleText) == .orderedAscending
    }

    private func compareAmounts(_ first: AdRecord, _ second: AdRecord, highestFirst: Bool) -> Bool {
        if first.billableAmount != second.billableAmount {
            return highestFirst ? first.billableAmount > second.billableAmount : first.billableAmount < second.billableAmount
        }
        return compareDates(first, second, newestFirst: true)
    }

    private func compareBrands(_ first: AdRecord, _ second: AdRecord) -> Bool {
        let comparison = first.titleText.localizedStandardCompare(second.titleText)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        return compareDates(first, second, newestFirst: true)
    }
}

enum ArrivalFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case arrived = "已到货"
    case notArrived = "未到货"

    var id: String { rawValue }

    var symbolName: String? {
        switch self {
        case .all:
            nil
        case .arrived:
            "shippingbox.fill"
        case .notArrived:
            "shippingbox"
        }
    }

    func matches(_ record: AdRecord) -> Bool {
        switch self {
        case .all:
            true
        case .arrived:
            record.arrivalDate != nil
        case .notArrived:
            record.arrivalDate == nil
        }
    }
}

enum VideoListFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case unshot = "未拍摄"

    var id: String { rawValue }
}

enum PoolScheduleFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case unscheduled = "未排期"

    var id: String { rawValue }
}

enum PoolViewMode: String, CaseIterable, Identifiable {
    case large = "大图"
    case compact = "小图"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .large:
            "rectangle.grid.1x2.fill"
        case .compact:
            "square.grid.2x2.fill"
        }
    }
}

enum PartnershipType: String, CaseIterable, Identifiable {
    case consignment = "寄拍"
    case giftedShoot = "送拍"
    case exchange = "置换"

    var id: String { rawValue }

    init(storedValue: String?) {
        self = PartnershipType(rawValue: storedValue ?? "") ?? .consignment
    }

    var needsPayment: Bool {
        self != .exchange
    }

    var tint: Color {
        switch self {
        case .consignment:
            AppTheme.consignment
        case .giftedShoot:
            AppTheme.giftedShoot
        case .exchange:
            AppTheme.exchange
        }
    }

    var symbolName: String {
        switch self {
        case .consignment:
            "shippingbox.fill"
        case .giftedShoot:
            "gift.fill"
        case .exchange:
            "arrow.2.squarepath"
        }
    }
}

struct VideoGroup: Identifiable, Hashable {
    let name: String
    let date: Date?
    let order: Double
    let records: [AdRecord]

    var id: String {
        let status = records
            .map { "\($0.objectID.uriRepresentation().absoluteString):\($0.publishedDate == nil ? 0 : 1):\($0.arrivalDate == nil ? 0 : 1):\($0.lookNumber):\($0.videoOrder)" }
            .joined(separator: "|")
        let dateKey = date.map { dayOnly($0).timeIntervalSinceReferenceDate } ?? -1
        return "\(dateKey)-\(name)-\(status)"
    }

    var title: String {
        name.nonEmptyOr("未命名视频")
    }

    var totalAmount: Double {
        records.reduce(0) { $0 + $1.billableAmount }
    }

    var unpaidAmount: Double {
        records.reduce(0) { $0 + $1.remainingAmount }
    }

    var hasLedgerRecords: Bool {
        records.contains { $0.needsPayment }
    }

    var allPublished: Bool {
        !records.isEmpty && records.allSatisfy { $0.publishedDate != nil }
    }

    var allArrived: Bool {
        !records.isEmpty && records.allSatisfy { $0.arrivalDate != nil }
    }

    var createdSortDate: Date {
        records.compactMap(\.createdAt).min() ?? Date.distantFuture
    }

    var publishedSortDate: Date {
        records.compactMap(\.publishedDate).min() ?? date ?? createdSortDate
    }

    var monthDate: Date? {
        date ?? records.compactMap(\.publishedDate).min()
    }

    var searchableText: String {
        ([name] + records.map(\.searchableText))
            .joined(separator: " ")
    }
}

struct ScheduleTarget: Identifiable, Hashable {
    let id: String
    let name: String
    let date: Date?
    let order: Double
    let recordCount: Int

    var title: String {
        name.nonEmptyOr("未命名视频")
    }

    var menuTitle: String {
        "\(title) · \(date.map { shortDateText($0) } ?? "待定") · \(recordCount)件"
    }
}

struct PoolCategorySummary: Identifiable, Hashable {
    let category: AdCategory
    let count: Int
    let amount: Double

    var id: AdCategory { category }
}

struct PoolRecordSelection: Identifiable {
    let recordID: NSManagedObjectID

    var id: String {
        recordID.uriRepresentation().absoluteString
    }
}

struct PoolPhotoSelection: Identifiable {
    let id = UUID()
    let image: UIImage
}

extension Notification.Name {
    static let adRecordsDidChange = Notification.Name("adRecordsDidChange")
}

let demoDataHiddenKey = "demoDataHidden"
