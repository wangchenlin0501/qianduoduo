//
//  VideoViews.swift
//  钱多多
//

import CoreData
import Photos
import SwiftUI
import UIKit

struct VideosPage: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \AdRecord.createdAt, ascending: false)
        ],
        animation: .default
    )
    private var allRecords: FetchedResults<AdRecord>

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \VideoLikeSnapshot.recordedAt, ascending: false)
        ],
        animation: .default
    )
    private var allLikeSnapshots: FetchedResults<VideoLikeSnapshot>

    @State private var selectedMonth = Date()
    @State private var filter: VideoListFilter = .all
    @State private var searchText = ""
    @State private var showingNewVideo = false
    @State private var refreshToken = UUID()
    @AppStorage(demoDataHiddenKey) private var isDemoDataHidden = false

    private var records: [AdRecord] {
        _ = refreshToken
        guard !isDemoDataHidden else { return [] }
        return Array(allRecords)
    }

    private var allGroups: [VideoGroup] {
        makeVideoGroups(from: records)
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleGroups: [VideoGroup] {
        allGroups.filter { group in
            let matchesMonth = query.isEmpty ? groupMatchesSelectedMonth(group) : true
            let matchesSearch = query.isEmpty || group.searchableText.localizedCaseInsensitiveContains(query)
            return matchesMonth && matchesSearch
        }
        .filter { group in
            switch filter {
            case .all:
                true
            case .unshot:
                !group.allPublished
            }
        }
    }

    private var pendingGroups: [VideoGroup] {
        visibleGroups
            .filter { $0.date == nil && !$0.allPublished }
            .sorted { first, second in
                if first.createdSortDate != second.createdSortDate {
                    return first.createdSortDate < second.createdSortDate
                }
                return first.title.localizedStandardCompare(second.title) == .orderedAscending
            }
    }

    private var scheduledGroups: [VideoGroup] {
        visibleGroups
            .filter { $0.date != nil && !$0.allPublished }
            .sorted(by: videoGroupPublishSort)
    }

    private var publishedGroups: [VideoGroup] {
        visibleGroups
            .filter(\.allPublished)
            .sorted(by: videoGroupPublishSort)
    }

    private var hasVisibleGroups: Bool {
        !pendingGroups.isEmpty || !scheduledGroups.isEmpty || !publishedGroups.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MonthSelector(selectedMonth: $selectedMonth)
                }
                .wideListRow()

                if !hasVisibleGroups {
                    Section("视频排期") {
                        ContentUnavailableView(
                            query.isEmpty ? "还没有视频" : "没有找到视频",
                            systemImage: query.isEmpty ? "calendar.badge.plus" : "magnifyingglass",
                            description: Text(query.isEmpty ? "从池子里选择广告，组成一期视频" : "换个品牌名或微信号试试")
                        )
                    }
                }

                if !pendingGroups.isEmpty {
                    videoSection(title: "待定区", groups: pendingGroups, delete: deletePendingVideoGroups)
                }

                if !scheduledGroups.isEmpty {
                    videoSection(title: "已选发布时间", groups: scheduledGroups, delete: deleteScheduledVideoGroups)
                }

                if !publishedGroups.isEmpty {
                    videoSection(title: "已发布视频", groups: publishedGroups, delete: deletePublishedVideoGroups)
                }
            }
            .navigationTitle("视频")
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .softPageBackground()
            .searchable(text: $searchText, prompt: "搜索品牌、微信、视频")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        filter = filter == .unshot ? .all : .unshot
                    } label: {
                        VideoFilterButton(isUnshot: filter == .unshot)
                    }
                    .buttonStyle(.plain)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingNewVideo = true
                    } label: {
                        Label("新视频", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewVideo) {
                NavigationStack {
                    NewVideoView(initialDate: selectedMonth)
                }
                .environment(\.managedObjectContext, viewContext)
            }
            .onReceive(NotificationCenter.default.publisher(for: .adRecordsDidChange)) { _ in
                refreshToken = UUID()
            }
        }
    }

    @ViewBuilder
    private func videoSection(title: String, groups: [VideoGroup], delete: @escaping (IndexSet) -> Void) -> some View {
        Section(title) {
            ForEach(groups) { group in
                ZStack {
                    NavigationLink {
                        VideoDetailView(group: group)
                            .environment(\.managedObjectContext, viewContext)
                    } label: {
                        EmptyView()
                    }
                    .opacity(0)

                    VideoGroupRow(
                        group: group,
                        latestLikeCount: latestLikeSnapshot(for: group)?.likeCount
                    )
                        .recordCard()
                }
                .floatingCardRow()
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        releaseVideo(group)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
            .onDelete(perform: delete)
        }
    }

    private func groupMatchesSelectedMonth(_ group: VideoGroup) -> Bool {
        if group.date == nil && !group.allPublished {
            return true
        }
        guard let monthDate = group.monthDate else { return true }
        return qddCalendar.isDate(monthDate, equalTo: selectedMonth, toGranularity: .month)
    }

    private func latestLikeSnapshot(for group: VideoGroup) -> VideoLikeSnapshot? {
        guard !isDemoDataHidden,
              group.allPublished,
              let publishedDate = group.records.compactMap(\.publishedDate).first else {
            return nil
        }

        return allLikeSnapshots.first { snapshot in
            guard snapshot.videoName.nonEmptyOr("未命名视频") == group.title,
                  snapshot.publishedDate == publishedDate else {
                return false
            }

            switch (snapshot.videoDate, group.date) {
            case (nil, nil):
                return true
            case let (snapshotDate?, groupDate?):
                return qddCalendar.isDate(snapshotDate, inSameDayAs: groupDate)
            default:
                return false
            }
        }
    }

    private func videoGroupPublishSort(_ first: VideoGroup, _ second: VideoGroup) -> Bool {
        let firstDate = first.date ?? first.publishedSortDate
        let secondDate = second.date ?? second.publishedSortDate
        if firstDate != secondDate {
            return firstDate < secondDate
        }
        if first.order != second.order {
            return first.order < second.order
        }
        return first.title.localizedStandardCompare(second.title) == .orderedAscending
    }

    private func deletePendingVideoGroups(offsets: IndexSet) {
        offsets.map { pendingGroups[$0] }.forEach(releaseVideo)
    }

    private func deleteScheduledVideoGroups(offsets: IndexSet) {
        offsets.map { scheduledGroups[$0] }.forEach(releaseVideo)
    }

    private func deletePublishedVideoGroups(offsets: IndexSet) {
        offsets.map { publishedGroups[$0] }.forEach(releaseVideo)
    }

    private func releaseVideo(_ group: VideoGroup) {
        withAnimation {
            deleteVideoLikeSnapshots(videoName: group.name, videoDate: group.date, in: viewContext)
            group.records.forEach(moveRecordBackToPool)
            saveContext()
        }
    }

    private func saveContext() {
        do {
            try viewContext.save()
            viewContext.processPendingChanges()
            notifyRecordsChanged()
        } catch {
            let nsError = error as NSError
            assertionFailure("Unresolved CoreData error \(nsError), \(nsError.userInfo)")
        }
    }
}

struct VideoDetailView: View {
    @ObservedObject private var reminders = VideoCommentNotificationManager.shared
    @State private var reminderError: String?
    @State private var isMarkingComment = false
    @Environment(\.managedObjectContext) private var viewContext

    let group: VideoGroup

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \AdRecord.videoOrder, ascending: true),
            NSSortDescriptor(keyPath: \AdRecord.lookNumber, ascending: true),
            NSSortDescriptor(keyPath: \AdRecord.createdAt, ascending: false)
        ],
        animation: .default
    )
    private var allRecords: FetchedResults<AdRecord>

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \VideoLikeSnapshot.recordedAt, ascending: false)
        ],
        animation: .default
    )
    private var allLikeSnapshots: FetchedResults<VideoLikeSnapshot>

    @State private var showingAddSheet = false
    @State private var showingVideoEditor = false
    @State private var showingLikeDataEditor = false
    @State private var videoName: String
    @State private var videoDate: Date?
    @State private var isPublished: Bool
    @State private var publishedDate: Date?
    @State private var editMode: EditMode = .inactive
    @State private var showingPublishCelebration = false
    @State private var showingNotificationSettingsAlert = false

    init(group: VideoGroup) {
        self.group = group
        _videoName = State(initialValue: group.name)
        _videoDate = State(initialValue: group.date)
        _isPublished = State(initialValue: group.allPublished)
        _publishedDate = State(initialValue: group.records.compactMap(\.publishedDate).first)
    }

    private var records: [AdRecord] {
        Array(allRecords)
            .filter { record in
                guard record.videoTitle == videoName else { return false }
                if let videoDate {
                    guard let publishDate = record.publishDate else { return false }
                    return qddCalendar.isDate(publishDate, inSameDayAs: videoDate)
                }
                return record.publishDate == nil
            }
            .sorted(by: videoRecordSort)
    }

    private var totalAmount: Double {
        records.reduce(0) { $0 + $1.billableAmount }
    }

    private var unpaidAmount: Double {
        records.reduce(0) { $0 + $1.remainingAmount }
    }

    private var likeSnapshots: [VideoLikeSnapshot] {
        Array(allLikeSnapshots)
            .filter { snapshot in
                guard snapshot.videoName.nonEmptyOr("未命名视频") == videoName,
                      snapshot.publishedDate == publishedDate else {
                    return false
                }

                switch (snapshot.videoDate, videoDate) {
                case (nil, nil):
                    return true
                case let (snapshotDate?, currentDate?):
                    return qddCalendar.isDate(snapshotDate, inSameDayAs: currentDate)
                default:
                    return false
                }
            }
            .sorted { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(videoName.nonEmptyOr("未命名视频"))
                            .font(.title2.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .layoutPriority(1)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = videoName.nonEmptyOr("未命名视频")
                                } label: {
                                    Label("复制名称", systemImage: "doc.on.doc")
                                }
                            }
                        VideoStatusPill(isPublished: isPublished)
                    }

                    Text(videoDate.map(chineseDateText) ?? "待定")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        VideoMetricTile(title: "内容", value: "\(records.count) 条", tint: AppTheme.primary)
                        VideoMetricTile(title: "合计", value: moneyText(totalAmount), tint: .primary)
                        VideoMetricTile(
                            title: isPublished ? "待结" : "状态",
                            value: isPublished ? moneyText(unpaidAmount) : "未发布",
                            tint: isPublished && unpaidAmount == 0 ? .green : .red
                        )
                    }
                }
                .padding(.vertical, 6)
                .recordCard()
                .floatingCardRow()

                PublishToggleRow(
                    isPublished: Binding(
                        get: { isPublished },
                        set: { setPublished($0) }
                    ),
                    publishedDate: publishedDate
                )
                .recordCard()
                .floatingCardRow()

                if let event = CommentReminderStore.events(from: records).first {
                    commentReminderRow(event)
                        .recordCard()
                        .floatingCardRow()
                }
            }

            if isPublished, let publishedDate {
                Section("点赞量") {
                    Button {
                        showingLikeDataEditor = true
                    } label: {
                        VideoLikeLatestCard(
                            snapshot: likeSnapshots.first,
                            publishedDate: publishedDate
                        )
                    }
                    .buttonStyle(.plain)
                    .recordCard()
                    .floatingCardRow()
                }
            }

            Section("本期内容（长按拖动排序）") {
                ForEach(records, id: \.objectID) { record in
                    ZStack {
                        NavigationLink {
                            AdRecordEditor(record: record)
                        } label: {
                            EmptyView()
                        }
                        .opacity(0)

                        RecordRow(record: record, onToggleArrival: {
                            toggleArrival(record)
                        })
                            .recordCard()
                    }
                    .floatingCardRow()
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            removeRecordFromVideo(record)
                        } label: {
                            Label("移出", systemImage: "tray.and.arrow.down")
                        }
                    }
                }
                .onMove(perform: moveRecords)
                .onDelete(perform: removeRecordsFromVideo)
            }
        }
        .navigationTitle(videoName.nonEmptyOr("未命名视频"))
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .softPageBackground()
        .overlay {
            if showingPublishCelebration {
                PublishCelebrationOverlay {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showingPublishCelebration = false
                    }
                }
                .zIndex(10)
            }
        }
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showingVideoEditor = true
                } label: {
                    Label("编辑视频", systemImage: "pencil")
                }

                Button {
                    showingAddSheet = true
                } label: {
                    Label("添加", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            NavigationStack {
                AddPoolItemsView(videoName: videoName, videoDate: videoDate)
            }
            .environment(\.managedObjectContext, viewContext)
        }
        .sheet(isPresented: $showingVideoEditor) {
            NavigationStack {
                VideoInfoEditorView(videoName: videoName, videoDate: videoDate) { newName, newDate in
                    updateVideoInfo(name: newName, date: newDate)
                }
            }
        }
        .sheet(isPresented: $showingLikeDataEditor) {
            if let publishedDate {
                NavigationStack {
                    VideoLikeDataEditor(
                        videoName: videoName,
                        videoDate: videoDate,
                        publishedDate: publishedDate
                    )
                }
                .environment(\.managedObjectContext, viewContext)
            }
        }
        .alert("需要开启通知", isPresented: $showingNotificationSettingsAlert) {
            Button("前往设置") {
                guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(settingsURL)
            }
            Button("暂不", role: .cancel) { }
        } message: {
            Text("开启通知后，视频发布2小时55分钟会提醒你评论品牌名。")
        }
        .onAppear(perform: syncPublishedState)
        .task { await reminders.reconcileNow() }
        .alert("操作未完成", isPresented: Binding(
            get: { reminderError != nil },
            set: { if !$0 { reminderError = nil } }
        )) {
            Button("好的", role: .cancel) { reminderError = nil }
        } message: {
            Text(reminderError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .adRecordsDidChange)) { _ in
            syncPublishedState()
        }
    }

    private func toggleArrival(_ record: AdRecord) {
        withAnimation {
            if record.arrivalDate != nil {
                record.arrivalDate = nil
            } else {
                record.arrivalDate = dayOnly(Date())
            }
            record.updatedAt = Date()
            saveContext()
        }
    }

    private func removeRecordsFromVideo(offsets: IndexSet) {
        offsets.map { records[$0] }.forEach(removeRecordFromVideo)
    }

    private func removeRecordFromVideo(_ record: AdRecord) {
        withAnimation {
            if records.count == 1 {
                deleteVideoLikeSnapshots(videoName: videoName, videoDate: videoDate, in: viewContext)
            }
            moveRecordBackToPool(record)
            saveContext()
        }
    }

    private func setPublished(_ published: Bool) {
        guard published != isPublished else { return }
        let previousValues = records.map { record in
            (record, record.dictionaryWithValues(forKeys: [
                "dueDate", "updatedAt", "commentReminderID", "brandCommentedAt",
                "paymentStatus", "paidDate", "paymentAccount", "paidAmount"
            ]))
        }
        let newDate: Date? = published ? Date() : nil
        let publicationID: String? = published ? UUID().uuidString : nil
        records.forEach { record in
            record.publishedDate = newDate
            record.commentReminderID = publicationID
            record.brandCommentedAt = nil
            record.updatedAt = Date()
            if record.statusValue == .paid, newDate == nil {
                record.statusValue = .unpaid
                record.paidDate = nil
                record.paymentAccount = nil
                record.paidAmount = 0
            }
        }
        guard saveContext() else {
            previousValues.forEach { $0.0.setValuesForKeys($0.1) }
            syncPublishedState()
            return
        }
        syncPublishedState()
        Task {
            if published {
                await reminders.publicationDidSave()
                showingNotificationSettingsAlert = reminders.authorizationText == "未允许"
            } else {
                await reminders.reconcileNow()
            }
        }
        if published {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                showingPublishCelebration = true
            }
        }
    }

    private func updateVideoInfo(name: String, date: Date?) {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOr("未命名视频")
        let cleanedDate = date.map(dayOnly)
        let snapshots = (try? fetchVideoLikeSnapshots(
            videoName: videoName,
            videoDate: videoDate,
            in: viewContext
        )) ?? []
        records.forEach { record in
            // Keep the publication identity when renaming legacy videos too.
            record.commentReminderID = CommentReminderStore.eventID(for: record)
            record.videoTitle = cleanedName
            record.publishDate = cleanedDate
            record.updatedAt = Date()
        }
        snapshots.forEach { snapshot in
            snapshot.videoName = cleanedName
            snapshot.videoDate = cleanedDate
            snapshot.updatedAt = Date()
        }
        videoName = cleanedName
        videoDate = cleanedDate
        saveContext()
    }

    private func syncPublishedState() {
        isPublished = !records.isEmpty && records.allSatisfy { $0.publishedDate != nil }
        publishedDate = records.compactMap(\.publishedDate).first
    }

    private func moveRecords(from source: IndexSet, to destination: Int) {
        var reorderedRecords = records
        reorderedRecords.move(fromOffsets: source, toOffset: destination)
        assignVideoOrder(to: reorderedRecords, startingAt: videoGroupOrder(records))
        saveContext()
    }

    private func commentReminderRow(_ event: CommentReminderEvent) -> some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    if reminders.authorizationText == "未允许" || reminders.authorizationText == "尚未开启" {
                        await reminders.enableNotifications()
                    } else {
                        await reminders.reconcileNow()
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Label("评论品牌名", systemImage: event.completedAt == nil ? "bell" : "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(event.completedAt == nil ? (reminders.statuses[event.id] ?? "正在检查本机提醒") : "已评论品牌名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            if event.completedAt == nil {
                Button {
                    isMarkingComment = true
                    Task {
                        let saved = await reminders.markCompleted(id: event.id)
                        if !saved { reminderError = reminders.lastError ?? "暂时无法保存，请稍后再试。" }
                        isMarkingComment = false
                    }
                } label: {
                    Text(isMarkingComment ? "保存中" : "已评论")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.primary)
                .disabled(isMarkingComment)
            }
        }
        .padding(.vertical, 4)
    }

    @discardableResult
    private func saveContext() -> Bool {
        do {
            try viewContext.save()
            viewContext.processPendingChanges()
            notifyRecordsChanged()
            return true
        } catch {
            reminderError = "保存失败：\(error.localizedDescription)"
            return false
        }
    }
}

struct VideoLikeLatestCard: View {
    let snapshot: VideoLikeSnapshot?
    let publishedDate: Date

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("最新点赞量", systemImage: "heart.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.primary)
                    .frame(width: 28, height: 28)
                    .background(AppTheme.primary.opacity(0.1), in: Circle())
            }

            if let snapshot {
                Text(videoLikeCountText(snapshot.likeCount))
                    .font(.system(size: 52, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                    .shadow(color: AppTheme.primary.opacity(0.14), radius: 6, y: 2)

                if let recordedAt = snapshot.recordedAt {
                    HStack(spacing: 7) {
                        Image(systemName: "clock.fill")
                        Text(videoPublishedElapsedText(from: publishedDate, to: recordedAt))
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                    .foregroundStyle(AppTheme.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(AppTheme.primary.opacity(0.1), in: Capsule())
                }
            } else {
                VStack(spacing: 5) {
                    Text("暂无数据")
                        .font(.title2.weight(.bold))
                    Text("点按卡片记录当前点赞量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .top)
    }
}

struct VideoLikeDataEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \VideoLikeSnapshot.recordedAt, ascending: false)
        ],
        animation: .default
    )
    private var allSnapshots: FetchedResults<VideoLikeSnapshot>

    let videoName: String
    let videoDate: Date?
    let publishedDate: Date

    @State private var countText = ""
    @State private var recordedAt = Date()
    @State private var errorMessage: String?
    @State private var editingSnapshot: VideoLikeSnapshot?

    private var parsedCount: Int64? {
        parseVideoLikeCount(countText)
    }

    private var snapshots: [VideoLikeSnapshot] {
        Array(allSnapshots)
            .filter { snapshot in
                guard snapshot.videoName.nonEmptyOr("未命名视频") == videoName,
                      snapshot.publishedDate == publishedDate else {
                    return false
                }

                switch (snapshot.videoDate, videoDate) {
                case (nil, nil):
                    return true
                case let (snapshotDate?, currentDate?):
                    return qddCalendar.isDate(snapshotDate, inSameDayAs: currentDate)
                default:
                    return false
                }
            }
            .sorted { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    VStack(spacing: 14) {
                        Image(systemName: "heart.fill")
                            .font(.title2)
                            .foregroundStyle(AppTheme.primary)
                            .frame(width: 48, height: 48)
                            .background(AppTheme.primary.opacity(0.1), in: Circle())

                        VStack(spacing: 4) {
                            Text("当前点赞量")
                                .font(.headline)
                            Text(videoLikeRecordedAtText(recordedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        TextField("0", text: $countText)
                            .font(.system(size: 54, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .tint(AppTheme.primary)
                            .frame(maxWidth: .infinity, minHeight: 82)
                            .minimumScaleFactor(0.6)
                            .accessibilityLabel("点赞量")

                        Text(videoPublishedElapsedText(from: publishedDate, to: recordedAt))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.primary)

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                    .background(CardSurfaceBackground())

                    Button(action: saveCurrentData) {
                        Text("保存当前数据")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .multilineTextAlignment(.center)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
                    .disabled(parsedCount == nil)
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(AppLayout.listRowInsets(top: 12, bottom: 8))

            Section("历史记录") {
                if snapshots.isEmpty {
                    Text("还没有记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshots, id: \.objectID) { snapshot in
                        Button {
                            editingSnapshot = snapshot
                        } label: {
                            VideoLikeHistoryRow(snapshot: snapshot, publishedDate: publishedDate)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteSnapshot(snapshot)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                editingSnapshot = snapshot
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(AppTheme.primary)
                        }
                    }
                }
            }
        }
        .navigationTitle("点赞量")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(SoftPageBackground())
        .tint(AppTheme.primary)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
        .onAppear(perform: loadLatestCount)
        .sheet(item: $editingSnapshot) { snapshot in
            NavigationStack {
                VideoLikeEditorView(
                    videoName: videoName,
                    videoDate: videoDate,
                    publishedDate: publishedDate,
                    snapshot: snapshot
                )
            }
            .environment(\.managedObjectContext, viewContext)
        }
    }

    private func loadLatestCount() {
        recordedAt = Date()
        countText = snapshots.first.map { String($0.likeCount) } ?? ""
        errorMessage = nil
    }

    private func saveCurrentData() {
        guard let parsedCount else {
            errorMessage = "请输入正确的点赞量"
            return
        }

        let snapshot = VideoLikeSnapshot(context: viewContext)
        PersistenceController.shared.prepareNewVideoLikeSnapshot(snapshot, in: viewContext)
        snapshot.id = UUID()
        snapshot.videoName = videoName
        snapshot.videoDate = videoDate.map(dayOnly)
        snapshot.publishedDate = publishedDate
        snapshot.recordedAt = recordedAt
        snapshot.likeCount = parsedCount
        snapshot.createdAt = Date()
        snapshot.updatedAt = Date()

        do {
            try viewContext.save()
            viewContext.processPendingChanges()
            PersistenceController.shared.shareOwnedVideoLikeSnapshotIfNeeded(snapshot)
            notifyRecordsChanged()
            dismiss()
        } catch {
            errorMessage = "保存失败，请稍后重试"
            AppLogger.shared.log("保存视频点赞量失败: \(error.localizedDescription)")
        }
    }

    private func deleteSnapshot(_ snapshot: VideoLikeSnapshot) {
        viewContext.delete(snapshot)
        do {
            try viewContext.save()
            viewContext.processPendingChanges()
            notifyRecordsChanged()
            loadLatestCount()
        } catch {
            errorMessage = "删除失败，请稍后重试"
            AppLogger.shared.log("删除视频点赞量失败: \(error.localizedDescription)")
        }
    }
}

struct VideoLikeHistoryRow: View {
    @ObservedObject var snapshot: VideoLikeSnapshot
    let publishedDate: Date

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.subheadline)
                .foregroundStyle(AppTheme.primary)
                .frame(width: 34, height: 34)
                .background(AppTheme.primary.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                if let recordedAt = snapshot.recordedAt {
                    Text(videoPublishedElapsedText(from: publishedDate, to: recordedAt))
                        .font(.subheadline.weight(.semibold))
                    Text(videoLikeRecordedAtText(recordedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("记录时间未知")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 10)

            HStack(spacing: 7) {
                Text(videoLikeCountText(snapshot.likeCount))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct VideoLikeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    let videoName: String
    let videoDate: Date?
    let publishedDate: Date
    let snapshot: VideoLikeSnapshot?

    @State private var countText: String
    @State private var recordedAt: Date
    @State private var errorMessage: String?
    @FocusState private var isCountFocused: Bool

    init(
        videoName: String,
        videoDate: Date?,
        publishedDate: Date,
        snapshot: VideoLikeSnapshot? = nil
    ) {
        self.videoName = videoName
        self.videoDate = videoDate
        self.publishedDate = publishedDate
        self.snapshot = snapshot
        _countText = State(initialValue: snapshot.map { String($0.likeCount) } ?? "")
        _recordedAt = State(initialValue: snapshot?.recordedAt ?? Date())
    }

    private var parsedCount: Int64? {
        parseVideoLikeCount(countText)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 14) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(AppTheme.primary)
                        .frame(width: 58, height: 58)
                        .background(AppTheme.primary.opacity(0.1), in: Circle())

                    Text(snapshot == nil ? "现在有多少点赞" : "修改点赞量")
                        .font(.headline)

                    TextField("0", text: $countText)
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .focused($isCountFocused)
                        .tint(AppTheme.primary)
                        .frame(maxWidth: .infinity, minHeight: 74)
                        .minimumScaleFactor(0.6)
                        .accessibilityLabel("点赞量")

                    Capsule()
                        .fill(AppTheme.primary.opacity(0.35))
                        .frame(width: 92, height: 3)

                    VStack(spacing: 5) {
                        Text(snapshot == nil ? "自动记录当前时刻" : "保留原记录时刻")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(videoLikeRecordedAtText(recordedAt))
                            .font(.subheadline.weight(.semibold))
                        Text(videoPublishedElapsedText(from: publishedDate, to: recordedAt))
                            .font(.caption)
                            .foregroundStyle(AppTheme.primary)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity)
                .background(CardSurfaceBackground())

                Button(action: save) {
                    Text(snapshot == nil ? "保存点赞量" : "保存修改")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .disabled(parsedCount == nil)
            }
            .padding(.horizontal, AppLayout.editorHorizontalInset)
            .padding(.vertical, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(SoftPageBackground())
        .navigationTitle(snapshot == nil ? "记录点赞量" : "编辑点赞量")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
        }
        .onAppear {
            if snapshot == nil {
                isCountFocused = true
            }
        }
    }

    private func save() {
        guard let parsedCount else {
            errorMessage = "请输入正确的点赞量"
            return
        }

        let isNewSnapshot = snapshot == nil
        let target = snapshot ?? VideoLikeSnapshot(context: viewContext)
        if isNewSnapshot {
            PersistenceController.shared.prepareNewVideoLikeSnapshot(target, in: viewContext)
            target.id = UUID()
            target.createdAt = Date()
        }
        target.videoName = videoName
        target.videoDate = videoDate.map(dayOnly)
        target.publishedDate = publishedDate
        target.recordedAt = recordedAt
        target.likeCount = parsedCount
        target.updatedAt = Date()

        do {
            try viewContext.save()
            viewContext.processPendingChanges()
            if isNewSnapshot {
                PersistenceController.shared.shareOwnedVideoLikeSnapshotIfNeeded(target)
            }
            notifyRecordsChanged()
            dismiss()
        } catch {
            errorMessage = "保存失败，请稍后重试"
            AppLogger.shared.log("保存视频点赞量失败: \(error.localizedDescription)")
        }
    }
}

private func parseVideoLikeCount(_ text: String) -> Int64? {
    let normalized = text
        .replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: "，", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
          normalized.allSatisfy(\.isNumber),
          let value = Int64(normalized),
          value >= 0 else {
        return nil
    }
    return value
}

private func videoLikeCountText(_ count: Int64) -> String {
    count.formatted(.number.grouping(.automatic))
}

private func videoLikeRecordedAtText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.timeZone = qddTimeZone
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter.string(from: date)
}

func videoPublishedElapsedText(from publishedDate: Date, to recordedAt: Date) -> String {
    let publishedDay = dayOnly(publishedDate)
    if abs(publishedDate.timeIntervalSince(publishedDay)) < 1 {
        let elapsedDays = max(
            qddCalendar.dateComponents(
                [.day],
                from: publishedDay,
                to: dayOnly(recordedAt)
            ).day ?? 0,
            0
        )
        return elapsedDays == 0 ? "发布当天" : "发布后 \(elapsedDays) 天"
    }

    let totalMinutes = max(Int(recordedAt.timeIntervalSince(publishedDate) / 60), 0)
    if totalMinutes < 1 {
        return "发布后刚刚"
    }
    if totalMinutes < 60 {
        return "发布后 \(totalMinutes) 分钟"
    }

    let totalHours = totalMinutes / 60
    let remainingMinutes = totalMinutes % 60
    if totalHours < 24 {
        return remainingMinutes == 0
            ? "发布后 \(totalHours) 小时"
            : "发布后 \(totalHours) 小时 \(remainingMinutes) 分钟"
    }

    let days = totalHours / 24
    let remainingHours = totalHours % 24
    return remainingHours == 0
        ? "发布后 \(days) 天"
        : "发布后 \(days) 天 \(remainingHours) 小时"
}

struct NewVideoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \AdRecord.createdAt, ascending: false)
        ],
        animation: .default
    )
    private var allRecords: FetchedResults<AdRecord>

    @State private var videoName = ""
    @State private var hasVideoDate = false
    @State private var videoDate = Date()
    @State private var selectedIDs = Set<NSManagedObjectID>()
    @State private var searchText = ""
    @State private var categoryFilter: AdCategory?
    @State private var partnershipFilter: PartnershipType?
    @State private var arrivalFilter: ArrivalFilter = .all
    @State private var lookFilter: Int?
    @AppStorage(demoDataHiddenKey) private var isDemoDataHidden = false

    init(initialDate: Date = Date()) {
        _videoDate = State(initialValue: initialDate)
    }

    private var poolRecords: [AdRecord] {
        guard !isDemoDataHidden else { return [] }
        return Array(allRecords)
            .filter { $0.workflowValue == .pool }
            .sorted { $0.sortDate > $1.sortDate }
    }

    private var availableLookNumbers: [Int] {
        sortedLookNumbers(from: poolRecords)
    }

    private var filteredPoolRecords: [AdRecord] {
        filterPoolRecords(
            poolRecords,
            category: categoryFilter,
            partnership: partnershipFilter,
            arrival: arrivalFilter,
            lookNumber: lookFilter,
            searchText: searchText
        )
    }

    var body: some View {
        Form {
            Section("视频") {
                TextField("视频名称/期数", text: $videoName)
                Toggle("设置发布时间", isOn: $hasVideoDate)
                if hasVideoDate {
                    DatePicker("发布日期", selection: $videoDate, displayedComponents: .date)
                } else {
                    Label("发布时间待定", systemImage: "calendar.badge.clock")
                        .foregroundStyle(.secondary)
                }
            }

            PoolPickFilterControls(
                categoryFilter: $categoryFilter,
                partnershipFilter: $partnershipFilter,
                arrivalFilter: $arrivalFilter,
                lookFilter: $lookFilter,
                availableLookNumbers: availableLookNumbers,
                selectedCount: selectedIDs.count
            )

            PoolRecordSelectionSection(
                title: "从池子添加",
                emptyTitle: "池子是空的",
                emptySystemImage: "tray",
                emptyDescription: "先去池子添加待拍摄广告",
                poolRecords: poolRecords,
                filteredPoolRecords: filteredPoolRecords,
                selectedIDs: $selectedIDs
            )
        }
        .navigationTitle("新视频")
        .searchable(text: $searchText, prompt: "搜索品牌、微信")
        .softPageBackground()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("创建") {
                    createVideo()
                }
                .disabled(selectedIDs.isEmpty || videoName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func createVideo() {
        let name = videoName.trimmingCharacters(in: .whitespacesAndNewlines)
        let videoOrder = nextVideoOrder(in: viewContext)
        let scheduledDate = hasVideoDate ? dayOnly(videoDate) : nil
        let selectedRecords = poolRecords
            .filter { selectedIDs.contains($0.objectID) }
            .sorted(by: videoRecordSort)
        prepareRecordsForVideo(selectedRecords, name: name, date: scheduledDate)
        assignVideoOrder(to: selectedRecords, startingAt: videoOrder)
        saveAndDismiss()
    }

    private func saveAndDismiss() {
        do {
            try viewContext.save()
            viewContext.processPendingChanges()
            dismiss()
            DispatchQueue.main.async {
                notifyRecordsChanged()
            }
        } catch {
            let nsError = error as NSError
            assertionFailure("Unresolved CoreData error \(nsError), \(nsError.userInfo)")
        }
    }
}

struct AddPoolItemsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \AdRecord.createdAt, ascending: false)
        ],
        animation: .default
    )
    private var allRecords: FetchedResults<AdRecord>

    let videoName: String
    let videoDate: Date?

    @State private var selectedIDs = Set<NSManagedObjectID>()
    @State private var searchText = ""
    @State private var categoryFilter: AdCategory?
    @State private var partnershipFilter: PartnershipType?
    @State private var arrivalFilter: ArrivalFilter = .all
    @State private var lookFilter: Int?
    @AppStorage(demoDataHiddenKey) private var isDemoDataHidden = false

    private var poolRecords: [AdRecord] {
        guard !isDemoDataHidden else { return [] }
        return Array(allRecords)
            .filter { $0.workflowValue == .pool }
            .sorted { $0.sortDate > $1.sortDate }
    }

    private var availableLookNumbers: [Int] {
        sortedLookNumbers(from: poolRecords)
    }

    private var filteredPoolRecords: [AdRecord] {
        filterPoolRecords(
            poolRecords,
            category: categoryFilter,
            partnership: partnershipFilter,
            arrival: arrivalFilter,
            lookNumber: lookFilter,
            searchText: searchText
        )
    }

    var body: some View {
        List {
            PoolPickFilterControls(
                categoryFilter: $categoryFilter,
                partnershipFilter: $partnershipFilter,
                arrivalFilter: $arrivalFilter,
                lookFilter: $lookFilter,
                availableLookNumbers: availableLookNumbers,
                selectedCount: selectedIDs.count
            )

            PoolRecordSelectionSection(
                title: "可添加的池子内容",
                emptyTitle: "没有可添加内容",
                emptySystemImage: "tray",
                emptyDescription: "已排期的广告不会再出现在这里",
                poolRecords: poolRecords,
                filteredPoolRecords: filteredPoolRecords,
                selectedIDs: $selectedIDs
            )
        }
        .navigationTitle("添加到视频")
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .searchable(text: $searchText, prompt: "搜索品牌、微信")
        .softPageBackground()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("添加") {
                    addSelected()
                }
                .disabled(selectedIDs.isEmpty)
            }
        }
    }

    private func addSelected() {
        let selectedRecords = poolRecords
            .filter { selectedIDs.contains($0.objectID) }
            .sorted(by: videoRecordSort)
        let existingRecords = allRecords.filter {
            $0.isAssignedToVideo && $0.videoTitle == videoName
                && $0.publishDate.map(dayOnly) == videoDate.map(dayOnly)
        }
        let publication = CommentReminderStore.events(from: existingRecords).first
        let firstNewOrder = nextVideoItemOrder(name: videoName, date: videoDate, in: viewContext)
        prepareRecordsForVideo(selectedRecords, name: videoName, date: videoDate)
        if let publication {
            // Adding another brand to a published video is not a new publication.
            for record in selectedRecords {
                record.publishedDate = publication.publishedAt
                record.commentReminderID = publication.id
                record.brandCommentedAt = publication.completedAt
            }
        }
        assignVideoOrder(to: selectedRecords, startingAt: firstNewOrder)
        do {
            try viewContext.save()
            viewContext.processPendingChanges()
            notifyRecordsChanged()
            dismiss()
        } catch {
            let nsError = error as NSError
            assertionFailure("Unresolved CoreData error \(nsError), \(nsError.userInfo)")
        }
    }
}

struct VideoInfoEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var videoName: String
    @State private var hasVideoDate: Bool
    @State private var videoDate: Date

    let onSave: (String, Date?) -> Void

    init(videoName: String, videoDate: Date?, onSave: @escaping (String, Date?) -> Void) {
        _videoName = State(initialValue: videoName)
        _hasVideoDate = State(initialValue: videoDate != nil)
        _videoDate = State(initialValue: videoDate ?? Date())
        self.onSave = onSave
    }

    var body: some View {
        EditorFormContainer {
            EditorCardSection("视频信息", symbol: "play.rectangle.fill") {
                EditorCardRow {
                    TextField("视频名称/期数", text: $videoName)
                        .textInputAutocapitalization(.never)
                }
                EditorCardRow(showsDivider: false) {
                    Toggle("设置发布时间", isOn: $hasVideoDate)
                }
                if hasVideoDate {
                    EditorCardRow(showsDivider: false) {
                        DatePicker("发布日期", selection: $videoDate, displayedComponents: .date)
                    }
                } else {
                    EditorCardRow(showsDivider: false) {
                        Label("发布时间待定", systemImage: "calendar.badge.clock")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("编辑视频")
        .softPageBackground()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    onSave(videoName, hasVideoDate ? videoDate : nil)
                    dismiss()
                }
                .disabled(videoName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

struct RecordRow: View {
    @ObservedObject var record: AdRecord
    var onToggleArrival: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            RecordThumbnail(photoData: record.photoData, size: 64)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.titleText)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .layoutPriority(1)
                    LookChip(lookNumber: record.lookNumber)
                    Spacer(minLength: 12)
                    Text(record.amountColumnText)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(minWidth: 78, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    CategoryBadge(category: record.categoryValue)
                    PartnershipBadge(type: record.partnershipValue)
                    RemarkChip(note: record.paymentNote)
                }

                HStack(spacing: 10) {
                    Label(record.contactWeChat.nonEmptyOr("未填微信"), systemImage: "person.2.fill")
                    Spacer()
                    if let onToggleArrival {
                        Button(action: onToggleArrival) {
                            Label(record.arrivalText, systemImage: "shippingbox.fill")
                                .foregroundStyle(record.arrivalDate != nil ? AppTheme.primary : .secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label(record.arrivalText, systemImage: "shippingbox.fill")
                            .foregroundStyle(record.arrivalDate != nil ? AppTheme.primary : .secondary)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
        }
        .padding(.vertical, 8)
    }
}

struct VideoGroupRow: View {
    let group: VideoGroup
    let latestLikeCount: Int64?
    @State private var generatedBrandListDraft: GeneratedBrandListDraft?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            DateSquare(date: group.date)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(group.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                        .layoutPriority(1)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = numberedBrandNamesCopyText(
                                    group.records.map(\.titleText)
                                )
                            } label: {
                                Label("复制品牌名", systemImage: "doc.on.doc")
                            }

                            Button {
                                generatedBrandListDraft = GeneratedBrandListDraft(
                                    text: numberedBrandNamesCopyText(group.records.map(\.titleText))
                                )
                            } label: {
                                Label("生成图片", systemImage: "photo.badge.plus")
                            }
                        }

                    Spacer(minLength: 6)

                    Text(moneyText(group.totalAmount))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.66)
                        .fixedSize(horizontal: true, vertical: false)
                }

                HStack(spacing: 7) {
                    HStack(spacing: 6) {
                        VideoStatusPill(isPublished: group.allPublished)
                        if group.allArrived {
                            VideoArrivalPill()
                        }
                        if let latestLikeCount {
                            VideoLikeCountPill(count: latestLikeCount)
                        }
                    }

                    Spacer(minLength: 8)

                    Text("\(group.records.count) 条")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .sheet(item: $generatedBrandListDraft) { draft in
            BrandListImagePreview(initialText: draft.text)
        }
    }
}

struct VideoLikeCountPill: View {
    let count: Int64

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "heart.fill")
                .font(.caption2.weight(.bold))
            Text(compactVideoLikeCountText(count))
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(AppTheme.primary.gradient, in: Capsule())
        .shadow(color: AppTheme.primary.opacity(0.2), radius: 4, y: 2)
        .accessibilityLabel("最新点赞量 \(videoLikeCountText(count))")
    }
}

private func compactVideoLikeCountText(_ count: Int64) -> String {
    if count >= 10_000 {
        return String(format: "%.1f万", Double(count) / 10_000)
    }
    return videoLikeCountText(count)
}

private struct GeneratedBrandListDraft: Identifiable {
    let id = UUID()
    let text: String
}

private struct BrandListImagePreview: View {
    @Environment(\.dismiss) private var dismiss

    @State private var editableText: String
    @State private var previewImage: UIImage
    @State private var saveState: PhotoSaveState = .idle
    @State private var showingSaveResult = false
    @State private var saveResultTitle = ""
    @State private var saveResultMessage = ""
    @State private var shouldOfferSettings = false

    init(initialText: String) {
        _editableText = State(initialValue: initialText)
        _previewImage = State(initialValue: brandListImage(text: initialText))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("图片文字")
                            .font(.headline)

                        Text("修改下面的文字或换行，上方图片会立即同步。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $editableText)
                            .font(.body)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 180)
                            .padding(10)
                            .background(
                                Color(uiColor: .systemBackground),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            }
                            .disabled(saveState == .saving)
                    }
                }
                .padding(16)
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .dismissibleKeyboard()
            .navigationTitle("图片预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                saveButton
            }
            .onChange(of: editableText) { _, newText in
                previewImage = brandListImage(text: newText)
                if saveState == .saved {
                    saveState = .idle
                }
            }
            .alert(saveResultTitle, isPresented: $showingSaveResult) {
                if shouldOfferSettings {
                    Button("前往设置") {
                        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(settingsURL)
                    }
                }
                Button("好的", role: .cancel) { }
            } message: {
                Text(saveResultMessage)
            }
        }
    }

    private var saveButton: some View {
        Button(action: saveToPhotoLibrary) {
            HStack(spacing: 8) {
                if saveState == .saving {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: saveState == .saved ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                }
                Text(saveState.buttonTitle)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(saveState == .saved ? .green : AppTheme.primary)
        .controlSize(.large)
        .disabled(saveState != .idle)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func saveToPhotoLibrary() {
        saveState = .saving
        let imageToSave = previewImage

        Task {
            let authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorizationStatus == .authorized || authorizationStatus == .limited else {
                saveState = .idle
                shouldOfferSettings = authorizationStatus == .denied || authorizationStatus == .restricted
                saveResultTitle = "无法保存到相册"
                saveResultMessage = shouldOfferSettings
                    ? "请在系统设置中允许“钱多多”添加照片。"
                    : "未获得添加照片的权限，请稍后重试。"
                showingSaveResult = true
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: imageToSave)
                }
                saveState = .saved
                shouldOfferSettings = false
                saveResultTitle = "保存成功"
                saveResultMessage = "图片已保存到系统相册。"
            } catch {
                saveState = .idle
                shouldOfferSettings = false
                saveResultTitle = "保存失败"
                saveResultMessage = error.localizedDescription
            }
            showingSaveResult = true
        }
    }
}

private enum PhotoSaveState {
    case idle
    case saving
    case saved

    var buttonTitle: String {
        switch self {
        case .idle:
            "保存到相册"
        case .saving:
            "正在保存"
        case .saved:
            "已保存到相册"
        }
    }
}

struct PoolRecordSelectionSection: View {
    let title: String
    let emptyTitle: String
    let emptySystemImage: String
    let emptyDescription: String
    let poolRecords: [AdRecord]
    let filteredPoolRecords: [AdRecord]
    @Binding var selectedIDs: Set<NSManagedObjectID>

    var body: some View {
        Section(title) {
            if poolRecords.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptySystemImage, description: Text(emptyDescription))
            } else if filteredPoolRecords.isEmpty {
                ContentUnavailableView(
                    "没有符合条件的广告",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("换一个筛选或搜索词试试")
                )
            } else {
                ForEach(filteredPoolRecords, id: \.objectID) { record in
                    SelectableRecordRow(
                        record: record,
                        isSelected: selectedIDs.contains(record.objectID)
                    ) {
                        toggle(record)
                    }
                    .recordCard()
                    .floatingCardRow()
                }
            }
        }
    }

    private func toggle(_ record: AdRecord) {
        if selectedIDs.contains(record.objectID) {
            selectedIDs.remove(record.objectID)
        } else {
            selectedIDs.insert(record.objectID)
        }
    }
}

struct SelectableRecordRow: View {
    @ObservedObject var record: AdRecord
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppTheme.primary : .secondary)
                    .font(.title3)
                PoolRecordRow(record: record)
            }
        }
        .buttonStyle(.plain)
    }
}

struct VideoFilterButton: View {
    let isUnshot: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isUnshot ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            Text(isUnshot ? "未拍摄" : "全部")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isUnshot ? Color.orange : Color.primary)
        .frame(minWidth: 86, minHeight: 44)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
    }
}

struct PoolScheduleFilterButton: View {
    let isUnscheduled: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isUnscheduled ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            Text(isUnscheduled ? "未排期" : "全部")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isUnscheduled ? AppTheme.primary : Color.primary)
        .frame(minWidth: 86, minHeight: 44)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
    }
}

struct VideoStatusPill: View {
    let isPublished: Bool

    private var tint: Color {
        isPublished ? .green : .orange
    }

    var body: some View {
        Image(systemName: isPublished ? "checkmark" : "clock.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(tint.gradient, in: Circle())
            .shadow(color: tint.opacity(0.22), radius: 4, x: 0, y: 2)
            .accessibilityLabel(isPublished ? "已发布" : "未发布")
    }
}

struct VideoArrivalPill: View {
    var body: some View {
        Image(systemName: "shippingbox.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Color.pink.gradient, in: Circle())
            .shadow(color: Color.pink.opacity(0.22), radius: 4, x: 0, y: 2)
            .accessibilityLabel("全部到货")
    }
}

struct VideoMetricTile: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(tint == .primary ? 0.06 : 0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct PublishToggleRow: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var isPublished: Bool

    let publishedDate: Date?

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                isPublished.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(iconBackground)
                        .frame(width: 48, height: 48)

                    Image(systemName: isPublished ? "checkmark.seal.fill" : "sparkles")
                        .font(.title3.weight(.black))
                        .foregroundStyle(statusTint)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(isPublished ? "已发布完成" : "发布这一期")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 10)

                HStack(spacing: 5) {
                    Text(isPublished ? "完成" : "发布")
                        .font(.caption.weight(.heavy))
                    Image(systemName: isPublished ? "checkmark" : "arrow.up.right")
                        .font(.caption.weight(.heavy))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(statusTint, in: Capsule(style: .continuous))
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var statusTint: Color {
        isPublished ? .green : .orange
    }

    private var subtitle: String {
        if isPublished, let publishedDate {
            return "发布日期 \(shortDateText(publishedDate))"
        }
        return isPublished ? "已进入账本 · 再点可撤回" : "完成这一期，进入账本"
    }

    private var iconBackground: some ShapeStyle {
        statusTint.opacity(colorScheme == .dark ? 0.2 : 0.12)
    }
}
