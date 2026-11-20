//
//  AIAssistantTools.swift
//  钱多多
//

import CoreData
import ImageIO
import SwiftUI
import UIKit

struct AIPendingAction: Identifiable {
    let id = UUID()
    let title: String
    let lines: [String]
    var isDestructive = false
    var image: UIImage? = nil
    var note: AINoteBox? = nil
    var confirmLabel: String? = nil
    let perform: () throws -> AIUndoToken
}

/// Note text the user can edit on the confirmation card before confirming.
final class AINoteBox {
    var text: String
    var label = "备注："
    init(_ text: String, label: String = "备注：") {
        self.text = text
        self.label = label
    }
}

struct AIUndoToken {
    let id = UUID()
    let summary: String
    let undo: () throws -> Void
}

/// A list rendered natively in the chat (amounts and dates come from the app, not the model).
struct AIRecordCard: Identifiable {
    struct Row: Identifiable {
        let id = UUID()
        let title: String
        let amount: String
        let tag: PartnershipType?
        let detail: String
        let urgency: Int
        var photo: UIImage? = nil
        var ref: String = ""
        var canSchedule = false
        var objectID: NSManagedObjectID? = nil
    }

    let id = UUID()
    let title: String
    let subtitle: String?
    let rows: [Row]
    var abandoned: [Row] = []
}

enum AIToolOutcome {
    case result(String)
    case proposal(AIPendingAction)
    case card(AIRecordCard, String)
}

final class AIAssistantToolbox {
    private let context: NSManagedObjectContext
    private lazy var todoStore = TodoStore()
    private var refToID: [String: NSManagedObjectID] = [:]
    private var idToRef: [NSManagedObjectID: String] = [:]
    var latestImages: [UIImage] = []

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    // MARK: - Definitions

    private static let recordFields: [String: Any] = [
        "brand": ["type": "string", "description": "品牌名"],
        "fee": ["type": "number", "description": "金额（元）；置换为 0"],
        "partnership": ["type": "string", "enum": ["寄拍", "送拍", "置换", "报备"]],
        "look": ["type": "integer", "description": "第几个 look。用户没明确说 look 号就不要传（默认随机）；报备不用"],
        "category": ["type": "string", "enum": AdCategory.allCases.map(\.rawValue), "description": "品类按实物选：裤子选“裤子”，裙子选“裙子”，上衣/外套选“衣服”，成套选“整套”"],
        "deal_month": ["type": "string", "description": "谈下合作的月份 yyyy-MM；截图有标注月份按标注，否则本月"],
        "note": ["type": "string", "description": "只写款式、颜色、档期等补充；不要写对接人或微信"],
        "wechat": ["type": "string", "description": "对接人：微信名或微信号（如截图里的对接人 Youu），填这里，不要写进 note"],
        "arrived": ["type": "boolean", "description": "衣服是否已到货（true 标到货，false 改回未到货）"],
        "arrival_date": ["type": "string", "description": "到货日期 yyyy-MM-dd，可省略（默认今天）"],
        "clothing_name": ["type": "string", "description": "衣服/款式名，如“湖蓝连体泳衣”"],
        "published_date": ["type": "string", "description": "发布日期 yyyy-MM-dd；传 none 表示改回未发布"]
    ]

    static let definitions: [[String: Any]] = [
        function("find_ads", "查询合作记录。返回 id，后续操作只能用这里返回的 id。", [
            "query": ["type": "string", "description": "品牌名、微信、备注等关键词"],
            "month": ["type": "string", "description": "谈下合作的月份 yyyy-MM"],
            "status": ["type": "string", "enum": ["unpaid", "paid", "all"]],
            "include_abandoned": ["type": "boolean", "description": "未回款时是否包含发布满 100 天的放弃记录，默认 false；用户追问放弃的记录时才设为 true"],
            "stage": ["type": "string", "enum": AdWorkflow.allCases.map(\.rawValue), "description": "待拍摄=池子里未排期"],
            "partnership": ["type": "string", "enum": ["寄拍", "送拍", "置换", "报备"]]
        ]),
        function("unpaid_summary", "统计未回款，并在聊天里自动展示“已发布未回款”卡片。置换不计入。", [
            "month": ["type": "string", "description": "只统计某月谈下的合作 yyyy-MM"],
            "include_abandoned": ["type": "boolean", "description": "是否把发布满 100 天的放弃记录算进来，默认 false"]
        ]),
        function("list_videos", "列出视频（标题、排期日期、包含的记录）。", [
            "include_published": ["type": "boolean", "description": "是否包含已发布视频，默认 false"]
        ]),
        function("search_todos", "查询待办。", [
            "query": ["type": "string"],
            "include_completed": ["type": "boolean"]
        ]),
        function("show_records", "在聊天里用带照片的卡片展示记录。推荐、对比或列出 2 条以上记录时都用它，正文不要再逐条重复。可多次调用分组展示（如“推荐拍”和“还没到货”）。", [
            "title": ["type": "string", "description": "卡片标题"],
            "ids": ["type": "array", "items": ["type": "string"]]
        ], required: ["title", "ids"]),
        function("propose_create_ad", "提议在池子里新增一条合作记录（弹确认卡片）。", recordFields.merging([
            "photo_index": ["type": "integer", "description": "用用户最近发来的第几张图片作为记录照片（从 1 开始）。选衣服/产品图，不要选聊天截图；省略时默认第 1 张"]
        ]) { $1 }, required: ["brand"]),
        function("propose_update_ad", "提议修改一条记录（弹确认卡片）。只传要改的字段。", recordFields.merging([
            "id": ["type": "string"],
            "photo_index": ["type": "integer", "description": "把用户最近发来的第几张图设为记录照片（从 1 开始），不换照片就省略"]
        ]) { $1 }, required: ["id"]),
        function("propose_delete_ad", "提议删除一条记录（弹确认卡片，可撤销）。", [
            "id": ["type": "string"]
        ], required: ["id"]),
        function("propose_schedule_video", "提议新建视频或把记录排进已有视频（标题+日期相同即同一个视频）。", [
            "title": ["type": "string", "description": "视频标题"],
            "date": ["type": "string", "description": "排期日期 yyyy-MM-dd，可省略表示待定"],
            "ids": ["type": "array", "items": ["type": "string"], "description": "要排进去的记录 id"]
        ], required: ["title", "ids"]),
        function("propose_unschedule", "提议把记录移回池子（取消排期）。", [
            "ids": ["type": "array", "items": ["type": "string"]]
        ], required: ["ids"]),
        function("propose_mark_paid", "提议把已发布的合作标记为已打款。", [
            "id": ["type": "string"],
            "paid_date": ["type": "string", "description": "yyyy-MM-dd，默认今天"],
            "account": ["type": "string", "enum": ["微信", "支付宝", "银行卡"]]
        ], required: ["id"]),
        function("propose_create_todo", "提议新建待办。", [
            "title": ["type": "string"],
            "notes": ["type": "string"],
            "due_date": ["type": "string", "description": "yyyy-MM-dd"]
        ], required: ["title"]),
        function("propose_update_todo", "提议修改待办或标记完成（弹确认卡片）。id 来自 search_todos。", [
            "id": ["type": "string"],
            "title": ["type": "string"],
            "notes": ["type": "string"],
            "due_date": ["type": "string", "description": "yyyy-MM-dd；none 表示清除"],
            "completed": ["type": "boolean"]
        ], required: ["id"]),
        function("propose_delete_todo", "提议删除待办（弹确认卡片）。", [
            "id": ["type": "string"]
        ], required: ["id"]),
        function("navigate_to", "跳转到 App 的某个页面（会关闭助手）。用户明确要求“带我去/打开/看看某页”时使用。", [
            "page": ["type": "string", "enum": ["汇总", "池子", "视频", "账本", "待办"]]
        ], required: ["page"]),
        function("propose_chase_payment", "催款：为一条已发布未回款的记录写催款话术，弹确认卡片；确认后话术复制到剪贴板，并新建“3 天后再催”待办。话术礼貌简短，先问好，再提发布日期和金额，请对方确认打款时间。", [
            "id": ["type": "string"],
            "message": ["type": "string", "description": "发给对接人的催款话术（中文，2-4 句）"]
        ], required: ["id", "message"]),
        function("propose_remember", "提议把一条信息或习惯记进共用记忆（弹确认卡片）。", [
            "text": ["type": "string", "description": "简短的一句话"]
        ], required: ["text"]),
        function("propose_forget", "提议删除一条记忆。", [
            "memory_id": ["type": "string"]
        ], required: ["memory_id"])
    ]

    private static func function(
        _ name: String, _ description: String, _ properties: [String: Any], required: [String] = []
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": ["type": "object", "properties": properties, "required": required] as [String: Any]
            ] as [String: Any]
        ]
    }

    // MARK: - Dispatch

    func run(name: String, arguments: String) -> AIToolOutcome {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        switch name {
        case "find_ads": return .result(findAds(args))
        case "unpaid_summary": return unpaidSummary(args)
        case "list_videos": return .result(listVideos(args))
        case "search_todos": return .result(searchTodos(args))
        case "show_records": return showRecords(args)
        case "propose_create_ad": return proposeCreateAd(args)
        case "propose_update_ad": return proposeUpdateAd(args)
        case "propose_update_todo": return proposeUpdateTodo(args)
        case "propose_delete_todo": return proposeDeleteTodo(args)
        case "propose_delete_ad": return proposeDeleteAd(args)
        case "propose_schedule_video": return proposeSchedule(args)
        case "propose_unschedule": return proposeUnschedule(args)
        case "propose_mark_paid": return proposeMarkPaid(args)
        case "propose_create_todo": return proposeCreateTodo(args)
        case "navigate_to": return navigate(args)
        case "propose_chase_payment": return proposeChasePayment(args)
        case "propose_remember": return proposeRemember(args)
        case "propose_forget": return proposeForget(args)
        default: return error("未知工具 \(name)")
        }
    }

    private func error(_ message: String) -> AIToolOutcome {
        .result(Self.json(["error": message]))
    }

    // MARK: - Read

    private func navigate(_ args: [String: Any]) -> AIToolOutcome {
        let pages = ["汇总", "池子", "视频", "账本", "待办"]
        guard let page = args["page"] as? String, let index = pages.firstIndex(of: page) else {
            return error("没有这个页面")
        }
        NotificationCenter.default.post(name: .aiAssistantNavigate, object: nil, userInfo: ["tab": index])
        return .result(Self.json(["ok": true, "page": page]))
    }

    private func allRecords() -> [AdRecord] {
        let request = NSFetchRequest<AdRecord>(entityName: "AdRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    private func record(for ref: Any?) -> AdRecord? {
        guard let ref = ref as? String, let objectID = refToID[ref] else { return nil }
        guard let record = try? context.existingObject(with: objectID) as? AdRecord, !record.isDeleted else { return nil }
        return record
    }

    private func records(for refs: Any?) -> [AdRecord]? {
        guard let refs = refs as? [String], !refs.isEmpty else { return nil }
        let found = refs.compactMap { record(for: $0) }
        return found.count == refs.count ? found : nil
    }

    private func findAds(_ args: [String: Any]) -> String {
        let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let month = Self.parseMonth(args["month"] as? String)
        let status = args["status"] as? String ?? "all"
        let stage = (args["stage"] as? String).flatMap(AdWorkflow.init(rawValue:))
        let partnership = (args["partnership"] as? String).flatMap(PartnershipType.init(rawValue:))
        let includeAbandoned = args["include_abandoned"] as? Bool ?? false

        let matches = allRecords().filter { record in
            if !query.isEmpty, !record.searchableText.localizedCaseInsensitiveContains(query) { return false }
            if let month, !qddCalendar.isDate(record.poolMonthDate, equalTo: month, toGranularity: .month) { return false }
            if let partnership, record.partnershipValue != partnership { return false }
            if let stage, record.workflowValue != stage { return false }
            switch status {
            case "unpaid":
                return record.needsPayment && record.statusValue == .unpaid && (includeAbandoned || !isAbandoned(record))
            case "paid": return record.statusValue == .paid
            default: return true
            }
        }
        return Self.json(["total_matches": matches.count, "records": matches.prefix(40).map(row)])
    }

    private func unpaidSummary(_ args: [String: Any]) -> AIToolOutcome {
        let month = Self.parseMonth(args["month"] as? String)
        let includeAbandoned = args["include_abandoned"] as? Bool ?? false
        let allUnpaid = allRecords().filter { record in
            guard record.needsPayment, record.statusValue == .unpaid else { return false }
            guard let month else { return true }
            return qddCalendar.isDate(record.poolMonthDate, equalTo: month, toGranularity: .month)
        }
        let abandoned = allUnpaid.filter(isAbandoned)
        let unpaid = includeAbandoned ? allUnpaid : allUnpaid.filter { !isAbandoned($0) }
        let published = unpaid
            .filter { $0.publishedDate != nil }
            .sorted { ($0.publishedDate ?? .distantFuture) < ($1.publishedDate ?? .distantFuture) }
        let unpublished = unpaid.filter { $0.publishedDate == nil }
        func total(_ records: [AdRecord]) -> Double { records.reduce(0) { $0 + $1.remainingAmount } }
        let gifted = unpaid.filter { $0.partnershipValue == .giftedShoot }

        let result = Self.json([
            "card_shown": published.isEmpty ? false : true,
            "published_unpaid_total": total(published),
            "published_unpaid_count": published.count,
            "unpublished_total": total(unpublished),
            "unpublished_count": unpublished.count,
            "gifted_shoot_included_total": total(gifted),
            "abandoned_hidden_count": includeAbandoned ? 0 : abandoned.count,
            "published_unpaid": published.prefix(40).map { record -> [String: Any] in
                var item = row(record)
                item["days_since_published"] = daysSincePublished(record) ?? 0
                return item
            }
        ])
        guard !published.isEmpty else { return .result(result) }
        let card = AIRecordCard(
            title: "已发布未回款",
            subtitle: "\(published.count) 条 · \(moneyText(total(published)))",
            rows: published.map(cardRow),
            abandoned: includeAbandoned ? [] : abandoned
                .sorted { ($0.publishedDate ?? .distantFuture) < ($1.publishedDate ?? .distantFuture) }
                .map(cardRow)
        )
        return .card(card, result)
    }

    private func listVideos(_ args: [String: Any]) -> String {
        let includePublished = args["include_published"] as? Bool ?? false
        let groups = makeVideoGroups(from: allRecords())
            .filter { includePublished || !$0.allPublished }
            .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        return Self.json([
            "videos": groups.prefix(30).map { group -> [String: Any] in
                var item: [String: Any] = [
                    "title": group.title,
                    "published": group.allPublished,
                    "records": group.records.map { ["id": ref(for: $0), "brand": $0.titleText, "look": Int($0.lookNumber)] }
                ]
                if let date = group.date { item["date"] = Self.dayString(date) }
                return item
            }
        ])
    }

    private func searchTodos(_ args: [String: Any]) -> String {
        let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let includeCompleted = args["include_completed"] as? Bool ?? false
        try? todoStore.refresh()
        let items = todoStore.items.filter { item in
            if !includeCompleted, item.completedAt != nil { return false }
            guard !query.isEmpty else { return true }
            return ((item.title ?? "") + " " + (item.notes ?? "")).localizedCaseInsensitiveContains(query)
        }
        return Self.json([
            "total_matches": items.count,
            "todos": items.prefix(30).map { item -> [String: Any] in
                var row: [String: Any] = ["id": todoRef(for: item), "title": item.title ?? "", "completed": item.completedAt != nil]
                if let notes = item.notes, !notes.isEmpty { row["notes"] = notes }
                if let due = item.dueDate { row["due_date"] = Self.dayString(due) }
                return row
            }
        ])
    }

    private func showRecords(_ args: [String: Any]) -> AIToolOutcome {
        guard let records = records(for: args["ids"]) else { return error("有 id 找不到，请先查询。") }
        let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "记录"
        let total = records.reduce(0) { $0 + $1.billableAmount }
        let card = AIRecordCard(
            title: title.isEmpty ? "记录" : title,
            subtitle: "\(records.count) 条" + (total > 0 ? " · \(moneyText(total))" : ""),
            rows: records.map(cardRow)
        )
        return .card(card, Self.json(["card_shown": true]))
    }

    private static func thumbnail(_ data: Data) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 180
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: image)
    }

    private func daysSincePublished(_ record: AdRecord) -> Int? {
        guard let date = record.publishedDate else { return nil }
        return qddCalendar.dateComponents([.day], from: dayOnly(date), to: dayOnly(Date())).day
    }

    private func isAbandoned(_ record: AdRecord) -> Bool {
        guard record.needsPayment, record.statusValue == .unpaid,
              let days = daysSincePublished(record) else { return false }
        return days >= 100
    }

    private func cardRow(_ record: AdRecord) -> AIRecordCard.Row {
        var details: [String] = []
        if let wechat = record.contactWeChat, !wechat.isEmpty { details.append(wechat) }
        var urgency = 0
        if let days = daysSincePublished(record), record.statusValue == .unpaid, record.needsPayment {
            details.append("发布 \(days) 天")
            urgency = days >= 90 ? 2 : (days >= 30 ? 1 : 0)
        } else {
            details.append(record.workflowValue.rawValue)
            if let date = record.publishDate { details.append("排期 \(shortDateText(date))") }
        }
        return AIRecordCard.Row(
            title: record.titleText,
            amount: record.needsPayment ? moneyText(record.billableAmount) : "",
            tag: record.partnershipValue,
            detail: details.joined(separator: " · "),
            urgency: urgency,
            photo: record.photoData.flatMap(Self.thumbnail),
            ref: ref(for: record),
            canSchedule: record.publishedDate == nil,
            objectID: record.objectID
        )
    }

    private func row(_ record: AdRecord) -> [String: Any] {
        var item: [String: Any] = [
            "id": ref(for: record),
            "brand": record.titleText,
            "partnership": record.partnershipValue.rawValue,
            "category": record.categoryValue.rawValue,
            "fee": record.needsPayment ? max(record.adFee, 0) : 0,
            "payment_status": record.statusValue.rawValue,
            "stage": record.workflowValue.rawValue,
            "deal_month": Self.monthString(record.poolMonthDate),
            "arrived": record.arrivalDate != nil
        ]
        if record.usesLook, record.lookNumber > 0 { item["look"] = Int(record.lookNumber) }
        if let video = record.videoTitle, !video.isEmpty { item["video"] = video }
        if let date = record.publishDate { item["scheduled_date"] = Self.dayString(date) }
        if let date = record.publishedDate { item["published_date"] = Self.dayString(date) }
        if let date = record.paidDate { item["paid_date"] = Self.dayString(date) }
        if let wechat = record.contactWeChat, !wechat.isEmpty { item["wechat"] = wechat }
        if let note = record.paymentNote, !note.isEmpty { item["note"] = note }
        return item
    }

    private var todoRefs: [String: TodoItem] = [:]

    private func todoRef(for item: TodoItem) -> String {
        if let existing = todoRefs.first(where: { $0.value.objectID == item.objectID })?.key { return existing }
        let ref = "t\(todoRefs.count + 1)"
        todoRefs[ref] = item
        return ref
    }

    private func proposeUpdateTodo(_ args: [String: Any]) -> AIToolOutcome {
        guard let ref = args["id"] as? String, let item = todoRefs[ref], !item.isDeleted else {
            return error("找不到这个待办 id，请先用 search_todos 查询。")
        }
        let oldTitle = item.title ?? ""
        let oldNotes = item.notes ?? ""
        let oldDue = item.dueDate
        let wasDone = item.completedAt != nil
        let title = TodoRules.normalizedTitle(args["title"] as? String ?? "") ?? oldTitle
        let notes = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? oldNotes
        var due = oldDue
        if let raw = args["due_date"] as? String { due = raw.lowercased() == "none" ? nil : (Self.parseDay(raw) ?? oldDue) }
        let completed = args["completed"] as? Bool
        var lines: [String] = []
        if title != oldTitle { lines.append("标题：\(oldTitle) → \(title)") }
        if notes != oldNotes { lines.append("备注：\(notes.isEmpty ? "清空" : notes)") }
        if due != oldDue { lines.append("截止：\(due.map(shortDateText) ?? "无")") }
        if let completed, completed != wasDone { lines.append(completed ? "标记为已完成" : "改回未完成") }
        guard !lines.isEmpty else { return error("没有需要修改的内容。") }
        let store = todoStore
        return .proposal(AIPendingAction(title: "修改待办「\(oldTitle)」", lines: lines) {
            if title != oldTitle || notes != oldNotes || due != oldDue {
                try store.update(item, title: title, notes: notes, dueDate: due)
            }
            if let completed, completed != wasDone { try store.setCompletion(item, completed: completed) }
            return AIUndoToken(summary: "修改待办「\(title)」") {
                try store.update(item, title: oldTitle, notes: oldNotes, dueDate: oldDue)
                try store.setCompletion(item, completed: wasDone)
            }
        })
    }

    private func proposeDeleteTodo(_ args: [String: Any]) -> AIToolOutcome {
        guard let ref = args["id"] as? String, let item = todoRefs[ref], !item.isDeleted else {
            return error("找不到这个待办 id，请先用 search_todos 查询。")
        }
        let title = item.title ?? ""
        let notes = item.notes ?? ""
        let due = item.dueDate
        let store = todoStore
        return .proposal(AIPendingAction(title: "删除待办", lines: ["「\(title)」"], isDestructive: true) {
            try store.delete(item)
            return AIUndoToken(summary: "删除待办「\(title)」") {
                _ = try store.create(title: title, notes: notes, dueDate: due)
            }
        })
    }

    private func ref(for record: AdRecord) -> String {
        if let existing = idToRef[record.objectID] { return existing }
        let ref = "r\(refToID.count + 1)"
        refToID[ref] = record.objectID
        idToRef[record.objectID] = ref
        return ref
    }

    // MARK: - Snapshots for undo

    private typealias Snapshot = (id: NSManagedObjectID, values: [String: Any])

    private func snapshot(_ records: [AdRecord]) -> [Snapshot] {
        records.map { record in
            (record.objectID, record.dictionaryWithValues(forKeys: Array(record.entity.attributesByName.keys)))
        }
    }

    private func restore(_ snapshots: [Snapshot]) throws {
        for item in snapshots {
            guard let record = try context.existingObject(with: item.id) as? AdRecord else { continue }
            record.setValuesForKeys(item.values)
        }
        try save()
    }

    private func save() throws {
        if let error = context.saveRollingBackOnFailure() { throw error }
        context.processPendingChanges()
        notifyRecordsChanged()
    }

    // MARK: - Record proposals

    private struct RecordFields {
        var brand: String?
        var fee: Double?
        var partnership: PartnershipType?
        var look: Int?
        var category: AdCategory?
        var dealMonth: Date?
        var note: String?
        var wechat: String?
        var arrived: Bool?
        var arrivalDate: Date?
        var clothingName: String?
        var publishedDate: Date??

        init(_ args: [String: Any]) {
            brand = (args["brand"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            fee = (args["fee"] as? NSNumber)?.doubleValue
            partnership = (args["partnership"] as? String).flatMap(PartnershipType.init(rawValue:))
            look = (args["look"] as? NSNumber)?.intValue
            category = (args["category"] as? String).flatMap(AdCategory.init(rawValue:))
            dealMonth = AIAssistantToolbox.parseMonth(args["deal_month"] as? String)
            note = (args["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            wechat = (args["wechat"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            arrived = args["arrived"] as? Bool
            arrivalDate = AIAssistantToolbox.parseDay(args["arrival_date"] as? String)
            clothingName = (args["clothing_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let raw = args["published_date"] as? String {
                publishedDate = raw.lowercased() == "none" ? .some(nil) : AIAssistantToolbox.parseDay(raw).map { .some($0) }
            }
        }
    }

    private func apply(_ fields: RecordFields, to record: AdRecord) {
        if let brand = fields.brand, !brand.isEmpty { record.brandName = brand }
        if let partnership = fields.partnership { record.partnershipValue = partnership }
        if let fee = fields.fee { record.adFee = record.needsPayment ? max(fee, 0) : 0 }
        if !record.needsPayment { record.adFee = 0 }
        if let look = fields.look, record.usesLook { record.lookNumber = Int16(clamping: max(look, 0)) }
        if let category = fields.category { record.categoryValue = category }
        if let month = fields.dealMonth { record.createdAt = monthStart(month) }
        if let note = fields.note { record.paymentNote = note }
        if let wechat = fields.wechat { record.contactWeChat = wechat }
        if let arrived = fields.arrived {
            record.arrivalDate = arrived ? (fields.arrivalDate ?? record.arrivalDate ?? dayOnly(Date())) : nil
        } else if let date = fields.arrivalDate {
            record.arrivalDate = date
        }
        if let name = fields.clothingName { record.clothingName = name }
        if let published = fields.publishedDate { record.publishedDate = published }
        record.updatedAt = Date()
    }

    private func describe(_ record: AdRecord) -> [String] {
        var lines = [
            "品牌：\(record.titleText)",
            "合作：\(record.partnershipValue.rawValue) · \(record.categoryValue.rawValue)"
        ]
        if record.needsPayment { lines.append("金额：\(moneyText(record.billableAmount))") }
        if record.usesLook { lines.append("LOOK：\(record.lookNumber > 0 ? String(record.lookNumber) : "随机")") }
        lines.append("月份：\(Self.monthString(record.poolMonthDate))")
        if let note = record.paymentNote, !note.isEmpty { lines.append("备注：\(note)") }
        if let wechat = record.contactWeChat, !wechat.isEmpty { lines.append("对接人：\(wechat)") }
        if let name = record.clothingName, !name.isEmpty { lines.append("款式：\(name)") }
        lines.append("到货：\(record.arrivalDate.map { "已到货（\(shortDateText($0))）" } ?? "未到货")")
        lines.append("发布：\(record.publishedDate.map { "已发布（\(shortDateText($0))）" } ?? "未发布")")
        return lines
    }

    private func proposeCreateAd(_ args: [String: Any]) -> AIToolOutcome {
        var fields = RecordFields(args)
        guard let brand = fields.brand, !brand.isEmpty else { return error("品牌名不能为空。") }
        let partnership = fields.partnership ?? .consignment
        fields.partnership = partnership
        let month = monthStart(fields.dealMonth ?? Date())
        let look = partnership.usesLook ? max(fields.look ?? 0, 0) : 0
        let photoIndex = (args["photo_index"] as? NSNumber)?.intValue ?? 1
        let photo: UIImage? = latestImages.indices.contains(photoIndex - 1) ? latestImages[photoIndex - 1] : nil

        var lines = [
            "品牌：\(brand)",
            "合作：\(partnership.rawValue) · \((fields.category ?? .clothing).rawValue)"
        ]
        if partnership.needsPayment { lines.append("金额：\(moneyText(max(fields.fee ?? 0, 0)))") }
        if partnership.usesLook { lines.append("LOOK：\(look > 0 ? String(look) : "随机")") }
        lines.append("放进：\(Self.monthString(month)) 池子")
        if let wechat = fields.wechat, !wechat.isEmpty { lines.append("对接人：\(wechat)") }
        if let name = fields.clothingName, !name.isEmpty { lines.append("款式：\(name)") }
        if fields.arrived == true { lines.append("到货：已到货") }
        if photo == nil { lines.append("照片：无") }
        let duplicates = allRecords().filter {
            $0.titleText.caseInsensitiveCompare(brand) == .orderedSame
                && $0.partnershipValue == partnership
                && qddCalendar.isDate($0.poolMonthDate, equalTo: month, toGranularity: .month)
        }
        if !duplicates.isEmpty { lines.append("注意：这个月已有 \(duplicates.count) 条同品牌同合作方式的记录") }

        let context = context
        let noteBox = AINoteBox(fields.note ?? "")
        return .proposal(AIPendingAction(title: "新增池子记录", lines: lines, image: photo, note: noteBox) { [self] in
            let record = AdRecord(context: context)
            PersistenceController.shared.prepareNewRecord(record, in: context)
            record.id = UUID()
            record.createdAt = month
            record.poolOrder = Date().timeIntervalSinceReferenceDate
            record.brandName = brand
            record.categoryValue = fields.category ?? .clothing
            record.partnershipValue = partnership
            record.lookNumber = Int16(look)
            record.adFee = partnership.needsPayment ? max(fields.fee ?? 0, 0) : 0
            let note = noteBox.text.trimmingCharacters(in: .whitespacesAndNewlines)
            record.paymentNote = note.isEmpty ? nil : note
            record.contactWeChat = fields.wechat
            record.arrivalDate = fields.arrived == true ? (fields.arrivalDate ?? dayOnly(Date())) : nil
            record.clothingName = fields.clothingName
            record.photoData = photo.flatMap(normalizedPhotoData)
            record.statusValue = .unpaid
            record.paidAmount = 0
            record.videoOrder = 0
            record.updatedAt = Date()
            try save()
            let objectID = record.objectID
            _ = ref(for: record)
            return AIUndoToken(summary: "新增 \(brand)") {
                if let record = try? context.existingObject(with: objectID) {
                    context.delete(record)
                    try self.save()
                }
            }
        })
    }

    private func proposeUpdateAd(_ args: [String: Any]) -> AIToolOutcome {
        guard let record = record(for: args["id"]) else { return error("找不到这个 id，请先查询。") }
        let fields = RecordFields(args)
        let newPhoto: UIImage? = (args["photo_index"] as? NSNumber).flatMap { index in
            latestImages.indices.contains(index.intValue - 1) ? latestImages[index.intValue - 1] : nil
        }
        let before = describe(record)
        let snapshots = snapshot([record])
        apply(fields, to: record)
        let after = describe(record)
        context.rollback()
        let changes = zip(before, after).compactMap { old, new -> String? in
            old == new ? nil : "\(old) → \(new.split(separator: "：", maxSplits: 1).last.map(String.init) ?? new)"
        }
        var lines = changes
        if newPhoto != nil { lines.append("照片 → 换成你发的图") }
        guard !lines.isEmpty else { return error("没有需要修改的内容。") }
        let title = record.titleText
        return .proposal(AIPendingAction(title: "修改 \(title)", lines: lines, image: newPhoto) { [self] in
            guard let record = try context.existingObject(with: snapshots[0].id) as? AdRecord else {
                throw AIAssistantError.badResponse
            }
            apply(fields, to: record)
            if let newPhoto { record.photoData = normalizedPhotoData(newPhoto) }
            try save()
            return AIUndoToken(summary: "修改 \(title)") { try self.restore(snapshots) }
        })
    }

    private func proposeDeleteAd(_ args: [String: Any]) -> AIToolOutcome {
        guard let record = record(for: args["id"]) else { return error("找不到这个 id，请先查询。") }
        let values = snapshot([record])[0].values
        let title = record.titleText
        let context = context
        return .proposal(AIPendingAction(title: "删除记录", lines: describe(record), isDestructive: true) { [self] in
            guard let target = try context.existingObject(with: record.objectID) as? AdRecord else {
                throw AIAssistantError.badResponse
            }
            context.delete(target)
            try save()
            return AIUndoToken(summary: "删除 \(title)") {
                let restored = AdRecord(context: context)
                PersistenceController.shared.prepareNewRecord(restored, in: context)
                restored.setValuesForKeys(values)
                try self.save()
            }
        })
    }

    private func proposeSchedule(_ args: [String: Any]) -> AIToolOutcome {
        let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return error("视频标题不能为空。") }
        guard let targets = records(for: args["ids"]) else { return error("有 id 找不到，请先查询。") }
        let date = Self.parseDay(args["date"] as? String).map(dayOnly)
        let keepOrder = args["keep_order"] as? Bool ?? false
        if let published = targets.first(where: { $0.publishedDate != nil }) {
            return error("\(published.titleText) 已发布，不能重新排期。")
        }
        let groups = makeVideoGroups(from: allRecords())
        if let date, let conflict = groups.first(where: {
            $0.title != title && ($0.date.map { qddCalendar.isDate($0, inSameDayAs: date) } ?? false)
        }) {
            return error("\(shortDateText(date)) 已经有视频「\(conflict.title)」，一天只能排一个视频。")
        }
        let existing = groups.first { group in
            group.title == title && group.date.map { d in date.map { qddCalendar.isDate(d, inSameDayAs: $0) } ?? false } ?? (date == nil)
        }
        var lines = [
            existing == nil ? "新建视频：\(title)" : "加入已有视频：\(title)",
            "排期：\(date.map { shortDateText($0) } ?? "待定")"
        ]
        lines += targets.map { record in
            "· \(record.titleText)" + (record.usesLook ? " LOOK \(record.lookNumber)" : "")
                + (record.isAssignedToVideo ? "（原在「\(record.videoTitle.nonEmptyOr("未命名视频"))」）" : "")
        }
        let snapshots = snapshot(targets)
        let context = context
        return .proposal(AIPendingAction(title: existing == nil ? "新建视频" : "排进视频", lines: lines) { [self] in
            let found = try snapshots.compactMap { try context.existingObject(with: $0.id) as? AdRecord }
            let records = keepOrder ? found : found.sorted(by: videoRecordSort)
            let start = nextVideoItemOrder(name: title, date: date, in: context)
            prepareRecordsForVideo(records, name: title, date: date)
            assignVideoOrder(to: records, startingAt: start)
            try save()
            return AIUndoToken(summary: "排进「\(title)」") { try self.restore(snapshots) }
        })
    }

    private func proposeUnschedule(_ args: [String: Any]) -> AIToolOutcome {
        guard let targets = records(for: args["ids"]) else { return error("有 id 找不到，请先查询。") }
        if let published = targets.first(where: { $0.publishedDate != nil }) {
            return error("\(published.titleText) 已发布，不能移回池子。")
        }
        let snapshots = snapshot(targets)
        let lines = targets.map { "· \($0.titleText)（\($0.videoTitle.nonEmptyOr("未排视频"))）" }
        let context = context
        return .proposal(AIPendingAction(title: "移回池子", lines: lines) { [self] in
            for item in snapshots {
                if let record = try context.existingObject(with: item.id) as? AdRecord {
                    moveRecordBackToPool(record)
                }
            }
            try save()
            return AIUndoToken(summary: "移回池子 \(snapshots.count) 条") { try self.restore(snapshots) }
        })
    }

    private func proposeMarkPaid(_ args: [String: Any]) -> AIToolOutcome {
        guard let record = record(for: args["id"]) else { return error("找不到这个 id，请先查询。") }
        guard record.needsPayment else { return error("\(record.titleText) 是置换，不需要回款。") }
        guard record.statusValue != .paid else { return error("\(record.titleText) 已经是已打款。") }
        guard record.publishedDate != nil else { return error("\(record.titleText) 还未发布，只有已发布的合作能标记已打款。") }
        let paidDate = Self.parseDay(args["paid_date"] as? String) ?? dayOnly(Date())
        let account = (args["account"] as? String).flatMap(PaymentMethod.init(rawValue:)) ?? .weChat
        let lines = [
            "品牌：\(record.titleText)" + (record.partnershipValue == .giftedShoot ? "（送拍）" : ""),
            "金额：\(moneyText(record.billableAmount))",
            "回款：未打款 → 已打款",
            "到账：\(shortDateText(paidDate)) · \(account.rawValue)"
        ]
        let snapshots = snapshot([record])
        let title = record.titleText
        let context = context
        return .proposal(AIPendingAction(title: "标记已打款", lines: lines) { [self] in
            guard let record = try context.existingObject(with: snapshots[0].id) as? AdRecord else {
                throw AIAssistantError.badResponse
            }
            record.paidAmount = max(record.adFee, 0)
            record.statusValue = .paid
            record.paidDate = dayOnly(paidDate)
            record.paymentAccount = account.rawValue
            record.updatedAt = Date()
            try save()
            return AIUndoToken(summary: "\(title) 标记已打款") { try self.restore(snapshots) }
        })
    }

    private func proposeCreateTodo(_ args: [String: Any]) -> AIToolOutcome {
        guard let title = TodoRules.normalizedTitle(args["title"] as? String ?? "") else {
            return error("待办标题不能为空。")
        }
        let notes = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let due = Self.parseDay(args["due_date"] as? String)
        var lines = ["标题：\(title)"]
        if let due { lines.append("截止：\(shortDateText(due))") }
        if !notes.isEmpty { lines.append("备注：\(notes)") }
        return .proposal(AIPendingAction(title: "新建待办", lines: lines) { [self] in
            guard let item = try todoStore.create(title: title, notes: notes, dueDate: due) else {
                throw AIAssistantError.badResponse
            }
            let store = todoStore
            return AIUndoToken(summary: "新建待办「\(title)」") { try store.delete(item) }
        })
    }

    private func proposeChasePayment(_ args: [String: Any]) -> AIToolOutcome {
        guard let target = record(for: args["id"]) else { return error("找不到这条记录。") }
        let message = (args["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else { return error("话术不能为空。") }
        let brand = target.brandName ?? "品牌"
        let title = "3 天后再催：\(brand)"
        let due = qddCalendar.date(byAdding: .day, value: 3, to: dayOnly(Date()))
        var lines = ["品牌：\(brand)", "待回款：¥\(Int(target.remainingAmount))"]
        if let days = daysSincePublished(target) { lines.append("已发布 \(days) 天") }
        lines.append("确认后复制话术，并新建待办“\(title)”")
        let box = AINoteBox(message, label: "话术：")
        var action = AIPendingAction(title: "催款", lines: lines, note: box, confirmLabel: "复制并建待办") { [self] in
            UIPasteboard.general.string = box.text
            guard let item = try todoStore.create(title: title, notes: "", dueDate: due) else {
                throw AIAssistantError.badResponse
            }
            let store = todoStore
            return AIUndoToken(summary: "已复制催款话术，并新建待办「\(title)」") { try store.delete(item) }
        }
        action.isDestructive = false
        return .proposal(action)
    }

    // MARK: - Memory proposals

    private func proposeRemember(_ args: [String: Any]) -> AIToolOutcome {
        let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return error("记忆内容不能为空。") }
        let context = context
        return .proposal(AIPendingAction(title: "记住这件事", lines: [text]) {
            let item = try AIMemoryStore.add(text, in: context)
            return AIUndoToken(summary: "记住「\(text)」") {
                _ = try AIMemoryStore.remove(id: item.id, in: context)
            }
        })
    }

    private func proposeForget(_ args: [String: Any]) -> AIToolOutcome {
        let id = args["memory_id"] as? String ?? ""
        guard let item = AIMemoryStore.load(in: context).first(where: { $0.id == id }) else {
            return error("找不到这条记忆。")
        }
        let context = context
        return .proposal(AIPendingAction(title: "忘掉这条记忆", lines: [item.text], isDestructive: true) {
            _ = try AIMemoryStore.remove(id: item.id, in: context)
            return AIUndoToken(summary: "忘掉「\(item.text)」") {
                try AIMemoryStore.restore(item, in: context)
            }
        })
    }

    // MARK: - Formatting

    private static let dayFormatter: DateFormatter = formatter("yyyy-MM-dd")
    private static let monthFormatter: DateFormatter = formatter("yyyy-MM")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = qddCalendar
        formatter.timeZone = qddTimeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func monthString(_ date: Date) -> String { monthFormatter.string(from: date) }

    static func parseDay(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return dayFormatter.date(from: text)
    }

    static func parseMonth(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return monthFormatter.date(from: text)
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Notification.Name {
    static let aiAssistantNavigate = Notification.Name("aiAssistantNavigate")
}
