import Combine
import CoreData
import SwiftUI

/// Selection reads the todo's data space and the previous, current, and next calendar months.
struct TodoContentLinkPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var store: TodoStore
    let selection: TodoContentLink?
    let onSelect: (TodoContentLink?) -> Void

    @State private var kind: TodoContentLink.Kind
    @State private var query = ""
    @State private var records: [AdRecord] = []
    @State private var errorMessage: String?
    @State private var loading = true
    @State private var monthReferenceDate = Date()

    init(store: TodoStore, selection: TodoContentLink?, onSelect: @escaping (TodoContentLink?) -> Void) {
        self.store = store
        self.selection = selection
        self.onSelect = onSelect
        _kind = State(initialValue: selection?.kind ?? .video)
    }

    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var monthWindow: TodoLinkMonthWindow {
        TodoLinkMonthWindow(containing: monthReferenceDate, calendar: qddCalendar)
    }

    private var videos: [VideoGroup] {
        makeVideoGroups(from: records.filter { $0.id != nil })
            .filter { monthWindow.contains($0.monthDate ?? $0.createdSortDate) }
            .filter { search.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(search) }
            .sorted { $0.publishedSortDate > $1.publishedSortDate }
    }

    private var poolRecords: [AdRecord] {
        records.filter { record in
            record.id != nil && (record.workflowValue == .pool || record.workflowValue == .scheduled)
                && monthWindow.contains(record.poolMonthDate)
                && (search.isEmpty || record.searchableText.localizedCaseInsensitiveContains(search))
        }
        .sorted(by: poolRecordSort)
    }

    private var isEmpty: Bool { kind == .video ? videos.isEmpty : poolRecords.isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("关联内容类型", selection: $kind) {
                    Text("视频").tag(TodoContentLink.Kind.video)
                    Text("池子").tag(TodoContentLink.Kind.pool)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 8)

                List {
                    if selection != nil {
                        Section {
                            Button {
                                onSelect(nil)
                                dismiss()
                            } label: {
                                Label("移除关联", systemImage: "link")
                                    .foregroundStyle(AppTheme.readablePrimary)
                            }
                            .frame(minHeight: 44)
                            .listRowSeparator(.hidden)
                        }
                    }

                    Section("上月、本月、下月") {
                        if kind == .video {
                            ForEach(videos) { group in
                                let link = TodoContentLink(
                                    kind: .video,
                                    recordIDs: group.records.compactMap(\.id),
                                    fallbackTitle: group.title
                                )
                                selectionRow(
                                    title: group.title,
                                    subtitle: videoSubtitle(group),
                                    symbol: "play.rectangle",
                                    link: link
                                )
                            }
                        } else {
                            ForEach(poolRecords, id: \.objectID) { record in
                                if let id = record.id {
                                    selectionRow(
                                        title: record.titleText,
                                        subtitle: "\(record.categoryValue.rawValue) · \(record.partnershipValue.rawValue) · \(record.scheduleText)",
                                        symbol: "tray.full",
                                        link: TodoContentLink(kind: .pool, recordIDs: [id], fallbackTitle: record.titleText),
                                        poolRecord: record
                                    )
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay {
                    if loading {
                        ProgressView()
                    } else if let errorMessage {
                        ContentUnavailableView {
                            Label("暂时无法加载", systemImage: "exclamationmark.icloud")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button("重试", action: load)
                        }
                    } else if isEmpty {
                        ContentUnavailableView(
                            search.isEmpty ? (kind == .video ? "还没有视频" : "池子里暂无内容") : "没有找到内容",
                            systemImage: search.isEmpty ? (kind == .video ? "play.rectangle" : "tray") : "magnifyingglass",
                            description: Text(search.isEmpty ? "这里显示当前数据空间上月、本月和下月的内容。" : "试试其他视频名、品牌或微信；这里只显示上月、本月和下月的内容。")
                        )
                        .allowsHitTesting(false)
                        .padding(.top, selection == nil ? 0 : 80)
                    }
                }
            }
            .navigationTitle("关联内容")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索视频、品牌、微信")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                monthReferenceDate = Date()
                load()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    monthReferenceDate = Date()
                    load()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .adRecordsDidChange).receive(on: RunLoop.main)) { _ in
                load()
            }
            .onReceive(store.$items.dropFirst()) { _ in load() }
        }
        .tint(AppTheme.readablePrimary)
    }

    private func selectionRow(title: String, subtitle: String, symbol: String, link: TodoContentLink, poolRecord: AdRecord? = nil) -> some View {
        Button {
            onSelect(link)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                if let poolRecord {
                    TodoLinkedPoolThumbnail(record: poolRecord)
                } else {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(AppTheme.readablePrimary)
                        .frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected(link) {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.readablePrimary)
                        .accessibilityLabel("已关联")
                }
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .accessibilityHint("关联到此待办")
    }

    private func isSelected(_ link: TodoContentLink) -> Bool {
        guard let selection, selection.kind == link.kind else { return false }
        return !Set(selection.recordIDs).isDisjoint(with: link.recordIDs)
    }

    private func videoSubtitle(_ group: VideoGroup) -> String {
        let date = group.date.map(shortDateText) ?? "日期待定"
        let brands = group.records.prefix(3).map(\.titleText).joined(separator: "、")
        return "\(date) · \(brands)"
    }

    private func load() {
        do {
            records = try store.contentRecords()
            errorMessage = nil
        } catch {
            records = []
            errorMessage = "请稍后重试，或检查当前数据空间是否仍可访问。"
        }
        loading = false
    }
}

/// Business editors use the app's view context, keeping their saves out of TodoStore's context.
struct TodoContentLinkDestination: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: TodoStore
    let link: TodoContentLink
    let spaceID: NSManagedObjectID

    @State private var destination: Destination = .loading

    private enum Destination {
        case loading
        case unavailable
        case video(VideoGroup)
        case pool(AdRecord)
        case readOnly([AdRecord])
    }

    var body: some View {
        NavigationStack {
            Group {
                switch destination {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .unavailable:
                    ContentUnavailableView(
                        "关联内容不可用",
                        systemImage: "link",
                        description: Text("内容可能已删除，或当前数据空间已切换。你可以返回待办重新关联。")
                    )
                case .video(let group):
                    VideoDetailView(group: group)
                case .pool(let record):
                    PoolRecordEditor(record: record)
                case .readOnly(let records):
                    TodoLinkedContentReadOnlyView(link: link, records: records)
                }
            }
            .toolbar {
                // The pool editor already supplies its own native cancellation and save controls.
                if showsCloseButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
            }
            .task { load() }
            .onReceive(NotificationCenter.default.publisher(for: .adRecordsDidChange).receive(on: RunLoop.main)) { _ in
                load()
            }
        }
        .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
        .tint(AppTheme.readablePrimary)
    }

    private func load() {
        let persistence = PersistenceController.shared
        let context = persistence.container.viewContext
        do {
            let currentRecords = try store.contentRecords()
            guard let currentSpace = try persistence.existingActiveSyncSpace(in: context),
                  currentSpace.objectID == spaceID,
                  currentRecords.allSatisfy({ $0.syncSpace?.objectID == spaceID }) else {
                destination = .unavailable
                return
            }

            // Exact object IDs retain store identity even if different spaces contain the same UUID.
            let savedTargets = link.resolvedRecords(in: currentRecords)
            let resolved = try savedTargets.compactMap { source -> AdRecord? in
                guard let record = try context.existingObject(with: source.objectID) as? AdRecord,
                      !record.isDeleted, record.syncSpace?.objectID == spaceID else { return nil }
                return record
            }
            guard !resolved.isEmpty, resolved.count == savedTargets.count else {
                destination = .unavailable
                return
            }

            let canEdit = isEditable(currentSpace, persistence: persistence)
                && resolved.allSatisfy { isEditable($0, persistence: persistence) }
            let allRequest: NSFetchRequest<AdRecord> = AdRecord.fetchRequest()
            allRequest.includesPendingChanges = false
            let allRecords = try context.fetch(allRequest)
            switch link.kind {
            case .video:
                guard let group = makeVideoGroups(from: resolved).first else {
                    destination = .unavailable
                    return
                }
                // Legacy video details match name/date globally. Never open their editor when a
                // same-name video in another space could be included by that matching rule.
                let collides = allRecords.contains { record in
                    record.syncSpace?.objectID != spaceID && record.isAssignedToVideo
                        && record.videoTitle.nonEmptyOr("未命名视频") == group.name
                        && sameVideoDay(record.publishDate, group.date)
                }
                let snapshotsRequest: NSFetchRequest<VideoLikeSnapshot> = VideoLikeSnapshot.fetchRequest()
                snapshotsRequest.includesPendingChanges = false
                let publishedDate = group.records.compactMap(\.publishedDate).first
                let hasOtherSpaceLikes = try context.fetch(snapshotsRequest).contains { snapshot in
                    snapshot.syncSpace?.objectID != spaceID
                        && snapshot.videoName.nonEmptyOr("未命名视频") == group.name
                        && sameVideoDay(snapshot.videoDate, group.date)
                        && snapshot.publishedDate == publishedDate
                }
                let matchesLegacyTitle = resolved.allSatisfy { $0.videoTitle == group.name }
                destination = canEdit && !collides && !hasOtherSpaceLikes && matchesLegacyTitle
                    ? .video(group) : .readOnly(resolved)
            case .pool:
                // Legacy pool editors offer schedule targets globally, so keep a cross-space
                // picker from becoming reachable through this association detail.
                let hasOtherSpaceSchedules = allRecords.contains {
                    $0.syncSpace?.objectID != spaceID && $0.isAssignedToVideo
                }
                // A saved pool link may later reach a published/paid record. Viewing it must
                // not send that record through a pool editor that resets publication/payment.
                let remainsInPool = resolved[0].workflowValue == .pool || resolved[0].workflowValue == .scheduled
                destination = canEdit && !hasOtherSpaceSchedules && remainsInPool
                    ? .pool(resolved[0]) : .readOnly(resolved)
            }
        } catch {
            destination = .unavailable
        }
    }

    private func isEditable(_ object: NSManagedObject, persistence: PersistenceController) -> Bool {
        object.objectID.persistentStore != persistence.sharedPersistentStore
            || persistence.container.canUpdateRecord(forManagedObjectWith: object.objectID)
    }

    private var showsCloseButton: Bool {
        if case .pool = destination { return false }
        return true
    }

    private func sameVideoDay(_ first: Date?, _ second: Date?) -> Bool {
        switch (first, second) {
        case (nil, nil): true
        case let (first?, second?): qddCalendar.isDate(first, inSameDayAs: second)
        default: false
        }
    }
}

private struct TodoLinkedContentReadOnlyView: View {
    let link: TodoContentLink
    let records: [AdRecord]

    private var title: String {
        link.kind == .video ? records.first?.videoTitle.nonEmptyOr("未命名视频") ?? link.fallbackTitle
            : records.first?.titleText ?? link.fallbackTitle
    }

    var body: some View {
        List {
            if link.kind == .video {
                Section("视频") {
                    LabeledContent("名称", value: title)
                    LabeledContent("日期", value: records.first?.publishDate.map(shortDateText) ?? "待定")
                    LabeledContent("状态", value: records.allSatisfy { $0.publishedDate != nil } ? "已发布" : "未发布")
                }
            }
            ForEach(records, id: \.objectID) { record in
                Section(record.titleText) {
                    LabeledContent("品牌", value: record.titleText)
                    if let contact = record.contactWeChat, !contact.isEmpty {
                        LabeledContent("对接人微信", value: contact)
                    }
                    LabeledContent("品类", value: record.categoryValue.rawValue)
                    LabeledContent("合作方式", value: record.partnershipValue.rawValue)
                    if record.usesLook {
                        LabeledContent("Look", value: record.lookNumber > 0 ? "\(record.lookNumber)" : "随机")
                    }
                    if record.needsPayment {
                        LabeledContent("报价", value: moneyText(record.billableAmount))
                    }
                    LabeledContent("到货", value: record.arrivalText)
                    LabeledContent("排期", value: record.scheduleText)
                    if let notes = record.paymentNote, !notes.isEmpty {
                        Text(notes)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
