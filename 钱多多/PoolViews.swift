//
//  PoolViews.swift
//  钱多多
//

import CoreData
import SwiftUI
import UIKit

struct PoolPage: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \AdRecord.createdAt, ascending: false)
        ],
        animation: .default
    )
    private var allRecords: FetchedResults<AdRecord>

    @State private var refreshToken = UUID()
    @State private var searchText = ""
    @State private var scheduleFilter: PoolScheduleFilter = .all
    @State private var categoryFilter: AdCategory?
    @State private var partnershipFilter: PartnershipType?
    @State private var arrivalFilter: ArrivalFilter = .all
    @State private var lookFilter: Int?
    @State private var selectedMonth = Date()
    @AppStorage("poolViewMode") private var viewMode: PoolViewMode = .large
    @State private var showingEditor = false
    @State private var selectedCompactRecord: PoolRecordSelection?
    @State private var selectedCompactPhoto: PoolPhotoSelection?
    @AppStorage(demoDataHiddenKey) private var isDemoDataHidden = false

    private var records: [AdRecord] {
        _ = refreshToken
        guard !isDemoDataHidden else { return [] }
        return Array(allRecords)
    }

    private var pendingPoolRecords: [AdRecord] {
        records
            .filter { $0.workflowValue == .pool || $0.workflowValue == .scheduled }
            .filter { record in
                qddCalendar.isDate(record.poolMonthDate, equalTo: selectedMonth, toGranularity: .month)
            }
    }

    private var poolRecords: [AdRecord] {
        pendingPoolRecords
            .filter { record in
                let matchesSchedule = scheduleFilter == .all || record.workflowValue == .pool
                let matchesCategory = categoryFilter.map { record.categoryValue == $0 } ?? true
                let matchesPartnership = partnershipFilter.map { record.partnershipValue == $0 } ?? true
                let matchesArrival = arrivalFilter.matches(record)
                let matchesLook = record.matchesLookFilter(lookFilter)
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                let matchesSearch = query.isEmpty || record.searchableText.localizedCaseInsensitiveContains(query)
                return matchesSchedule && matchesCategory && matchesPartnership && matchesArrival && matchesLook && matchesSearch
            }
            .sorted(by: poolRecordSort)
    }

    private var availableLookNumbers: [Int] {
        sortedLookNumbers(from: pendingPoolRecords)
    }

    private var totalPendingAmount: Double {
        pendingPoolRecords.reduce(0) { $0 + $1.billableAmount }
    }

    private var categorySummary: [PoolCategorySummary] {
        let grouped = Dictionary(grouping: pendingPoolRecords) { $0.categoryValue }
        return AdCategory.allCases.compactMap { category in
            guard let records = grouped[category], !records.isEmpty else { return nil }
            let amount = records.reduce(0) { $0 + $1.billableAmount }
            return PoolCategorySummary(category: category, count: records.count, amount: amount)
        }
    }

    var body: some View {
        GeometryReader { rootProxy in
            ZStack {
                NavigationStack {
                    poolContent
                .navigationTitle("池子")
                .softPageBackground()
                .searchable(text: $searchText, prompt: "搜索品牌、微信")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            scheduleFilter = scheduleFilter == .unscheduled ? .all : .unscheduled
                        } label: {
                            PoolScheduleFilterButton(isUnscheduled: scheduleFilter == .unscheduled)
                        }
                        .buttonStyle(.plain)
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showingEditor = true
                        } label: {
                            Label("新增", systemImage: "plus")
                        }
                    }
                }
                .sheet(isPresented: $showingEditor) {
                    NavigationStack {
                        PoolRecordEditor(poolMonth: selectedMonth)
                    }
                    .environment(\.managedObjectContext, viewContext)
                }
                .sheet(item: $selectedCompactRecord) { selection in
                    NavigationStack {
                        if let record = record(for: selection) {
                            PoolRecordEditor(record: record)
                        } else {
                            ContentUnavailableView("记录不存在", systemImage: "questionmark.folder")
                        }
                    }
                    .environment(\.managedObjectContext, viewContext)
                }
                .onReceive(NotificationCenter.default.publisher(for: .adRecordsDidChange)) { _ in
                    refreshToken = UUID()
                }
                }

                if let selectedCompactPhoto {
                    FloatingPhotoPreview(
                        image: selectedCompactPhoto.image,
                        sourceFrame: selectedCompactPhoto.sourceFrame,
                        rootSize: rootProxy.size
                    ) {
                        self.selectedCompactPhoto = nil
                    }
                    .zIndex(1_000)
                }
            }
            .frame(width: rootProxy.size.width, height: rootProxy.size.height)
        }
    }

    private var poolContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MonthSelector(selectedMonth: $selectedMonth)
                poolSummaryCard
                poolFilterCard
                PoolListHeader(viewMode: $viewMode)
                    .padding(.top, 2)

                if poolRecords.isEmpty {
                    ContentUnavailableView("池子是空的", systemImage: "tray", description: Text("点右上角添加新的待拍摄广告"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                } else {
                    PoolRecordCollectionContainer(
                        records: poolRecords,
                        viewMode: viewMode,
                        hiddenPhotoID: selectedCompactPhoto?.sourceRecordID,
                        toggleArrival: toggleArrival,
                        deleteRecord: deletePoolRecord,
                        openRecord: { record in
                            selectedCompactRecord = PoolRecordSelection(recordID: record.objectID)
                        },
                        showPhoto: { record, sourceFrame in
                            guard let image = PhotoImageCache.shared.image(from: record.photoData) else { return }
                            presentPhoto(image: image, sourceFrame: sourceFrame, sourceRecordID: record.objectID)
                        },
                        commitOrder: applyPoolOrder
                    )
                }
            }
            .padding(.horizontal, AppLayout.editorHorizontalInset + AppLayout.listHorizontalInset)
            .padding(.top, 10)
            .padding(.bottom, 118)
        }
    }

    private var poolSummaryCard: some View {
        PoolSummaryPanel(
            totalCount: pendingPoolRecords.count,
            totalAmount: totalPendingAmount,
            categorySummary: categorySummary
        )
    }

    private var poolFilterCard: some View {
        PoolFilterControls(
            categoryFilter: $categoryFilter,
            partnershipFilter: $partnershipFilter,
            arrivalFilter: $arrivalFilter,
            lookFilter: $lookFilter,
            availableLookNumbers: availableLookNumbers,
            resultCount: poolRecords.count
        )
        .recordCard()
    }

    private func record(for selection: PoolRecordSelection) -> AdRecord? {
        try? viewContext.existingObject(with: selection.recordID) as? AdRecord
    }

    private func presentPhoto(
        image: UIImage,
        sourceFrame: CGRect,
        sourceRecordID: NSManagedObjectID?
    ) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedCompactPhoto = PoolPhotoSelection(
                image: image,
                sourceFrame: sourceFrame,
                sourceRecordID: sourceRecordID
            )
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

    private func deletePoolRecord(_ record: AdRecord) {
        withAnimation {
            viewContext.delete(record)
            saveContext()
        }
    }

    private func applyPoolOrder(visibleRecordIDs: [NSManagedObjectID]) {
        let recordsByID = Dictionary(uniqueKeysWithValues: poolRecords.map { ($0.objectID, $0) })
        let visibleRecords = visibleRecordIDs.compactMap { recordsByID[$0] }
        guard visibleRecords.count == visibleRecordIDs.count else { return }
        persistVisibleOrderChange(from: poolRecords, to: visibleRecords)
    }

    private func persistVisibleOrderChange(from oldVisibleRecords: [AdRecord], to newVisibleRecords: [AdRecord]) {
        let oldIDs = oldVisibleRecords.map(\.objectID)
        let newIDs = newVisibleRecords.map(\.objectID)
        guard oldIDs != newIDs else { return }

        if let movedID = movedRecordID(from: oldIDs, to: newIDs),
           let movedRecord = newVisibleRecords.first(where: { $0.objectID == movedID }),
           let newIndex = newVisibleRecords.firstIndex(where: { $0.objectID == movedID }) {
            let previousRecord = newIndex > 0 ? newVisibleRecords[newIndex - 1] : nil
            let nextIndex = newVisibleRecords.index(after: newIndex)
            let nextRecord = nextIndex < newVisibleRecords.endIndex ? newVisibleRecords[nextIndex] : nil
            assignPoolOrder(to: movedRecord, previous: previousRecord, next: nextRecord)
        } else {
            assignPoolOrder(to: newVisibleRecords)
        }
        if viewContext.hasChanges {
            saveContext()
        }
    }

    private func movedRecordID(from oldIDs: [NSManagedObjectID], to newIDs: [NSManagedObjectID]) -> NSManagedObjectID? {
        for candidate in oldIDs where newIDs.contains(candidate) {
            if oldIDs.filter({ $0 != candidate }) == newIDs.filter({ $0 != candidate }) {
                return candidate
            }
        }
        return nil
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

struct PoolRecordRow: View {
    @ObservedObject var record: AdRecord
    @State private var isShowingRemark = false
    var isPhotoHidden = false
    var photoCoordinateSpace: CoordinateSpace = .global
    var onToggleArrival: (() -> Void)? = nil
    var onShowPhoto: ((UIImage, CGRect) -> Void)? = nil

    private var remarkText: String? {
        guard let text = record.paymentNote?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.titleText)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .layoutPriority(2)
                PartnershipBadge(type: record.partnershipValue)
                if record.usesLook {
                    LookChip(lookNumber: record.lookNumber)
                }
                Spacer(minLength: 8)
                if record.hasPriceValue {
                    Text(record.priceDisplayText)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(minWidth: 72, alignment: .trailing)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        CategoryBadge(category: record.categoryValue)
                        if record.workflowValue == .scheduled {
                            ScheduledBadge()
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label(record.contactWeChat.nonEmptyOr("未填微信"), systemImage: "person.2.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Button {
                            onToggleArrival?()
                        } label: {
                            Label(record.arrivalText, systemImage: "shippingbox.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(record.arrivalDate == nil ? Color.secondary : AppTheme.readablePrimary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, remarkText == nil ? 0 : 94)
                    .overlay(alignment: .topTrailing) {
                        if let remarkText {
                            Button {
                                isShowingRemark = true
                            } label: {
                                Text(remarkText)
                                    .font(.caption)
                                    .foregroundStyle(Color.orange)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .padding(6)
                                    .frame(width: 86, height: 48)
                                    .clipped()
                                    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: AppLayout.thumbnailCornerRadius, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: AppLayout.thumbnailCornerRadius, style: .continuous)
                                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: AppLayout.thumbnailCornerRadius, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看和编辑备注")
                            .accessibilityHint(remarkText)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                GeometryReader { proxy in
                    RecordThumbnail(photoData: record.photoData, size: 80) { image in
                        onShowPhoto?(image, proxy.frame(in: photoCoordinateSpace))
                    }
                    .opacity(isPhotoHidden ? 0 : 1)
                }
                .frame(width: 80, height: 80)
            }
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $isShowingRemark) {
            NavigationStack {
                RecordRemarkEditor(record: record)
            }
        }
    }
}

private struct FloatingPhotoPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let image: UIImage
    let sourceFrame: CGRect
    let rootSize: CGSize
    let onDismiss: () -> Void

    @State private var phase: FlipPhase = .idle
    @State private var progress: CGFloat = 0
    @State private var contentOpacity = 1.0
    @State private var dragTranslation: CGSize = .zero
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { overlayProxy in
            // Both thumbnail paths report global coordinates. Convert against the
            // actual overlay origin, including its current safe-area placement.
            let overlayOrigin = overlayProxy.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissPreview)

                let collapsedRect = resolvedSourceFrame(in: rootSize, overlayOrigin: overlayOrigin)
                let previewSize = fittedPreviewSize(in: rootSize)

                let targetRect = CGRect(
                    x: (rootSize.width - previewSize.width) / 2,
                    y: (rootSize.height - previewSize.height) / 2,
                    width: previewSize.width,
                    height: previewSize.height
                )

                PoolPhotoFlipOverlay(
                    image: image,
                    sourceRect: collapsedRect,
                    targetRect: targetRect,
                    progress: progress,
                    reduceMotion: reduceMotion,
                    dragTranslation: dragTranslation
                )
                    .opacity(contentOpacity)
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                if phase == .expanded {
                                    dragTranslation = value.translation
                                }
                            }
                            .onEnded { value in
                                guard phase == .expanded else { return }
                                let distance = hypot(value.translation.width, value.translation.height)
                                if distance > 110 {
                                    dismissPreview()
                                } else {
                                    withAnimation(.easeOut(duration: 0.16)) {
                                        dragTranslation = .zero
                                    }
                                }
                            }
                    )
                    .accessibilityLabel("截图预览")
                    .accessibilityHint("拖动图片即可关闭")
            }
            .frame(width: rootSize.width, height: rootSize.height, alignment: .topLeading)
        }
        .frame(width: rootSize.width, height: rootSize.height, alignment: .topLeading)
        .onAppear {
            expandPreview()
        }
        .onDisappear {
            animationTask?.cancel()
        }
    }

    private func expandPreview() {
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            // Commit the exact source geometry before starting the only 0 → 1 animation.
            await Task.yield()
            guard !Task.isCancelled else { return }
            phase = .animatingToExpanded
            if reduceMotion {
                contentOpacity = 0.35
            }
            withAnimation(.easeInOut(duration: 0.58), completionCriteria: .removed) {
                progress = 1
                contentOpacity = 1
            } completion: {
                phase = .expanded
            }
        }
    }

    private func dismissPreview() {
        guard phase == .expanded else { return }
        animationTask?.cancel()
        phase = .animatingToCollapsed
        withAnimation(.easeInOut(duration: 0.58), completionCriteria: .removed) {
            progress = 0
            dragTranslation = .zero
            if reduceMotion {
                contentOpacity = 0.35
            }
        } completion: {
            // Restore the thumbnail only after the last frame is rendered.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                onDismiss()
            }
        }
    }

    private func resolvedSourceFrame(in containerSize: CGSize, overlayOrigin: CGPoint) -> CGRect {
        guard !sourceFrame.isEmpty else {
            return CGRect(
                x: (containerSize.width - 80) / 2,
                y: (containerSize.height - 80) / 2,
                width: 80,
                height: 80
            )
        }
        return sourceFrame.offsetBy(dx: -overlayOrigin.x, dy: -overlayOrigin.y)
    }

    private func fittedPreviewSize(in containerSize: CGSize) -> CGSize {
        let availableSize = CGSize(
            width: min(max(containerSize.width - 48, 1), 620),
            height: min(max(containerSize.height - 160, 1), 720)
        )
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return availableSize }

        let scale = min(availableSize.width / imageSize.width, availableSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

private enum FlipPhase: Equatable {
    case idle
    case animatingToExpanded
    case expanded
    case animatingToCollapsed
}

private struct PoolPhotoFlipOverlay: View, Animatable {
    let image: UIImage
    let sourceRect: CGRect
    let targetRect: CGRect
    var progress: CGFloat
    let reduceMotion: Bool
    let dragTranslation: CGSize

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private var translationProgress: CGFloat {
        let p = min(max(progress, 0), 1)
        let delayed = min(max((p - 0.06) / 0.94, 0), 1)
        return delayed * delayed * (3 - 2 * delayed)
    }

    private var sizeProgress: CGFloat {
        let p = min(max(progress, 0), 1)
        return CGFloat(1 - pow(Double(1 - p), 1.6))
    }

    private var currentCenter: CGPoint {
        CGPoint(
            x: interpolate(
                sourceRect.midX,
                targetRect.midX,
                progress: translationProgress
            ),
            y: interpolate(
                sourceRect.midY,
                targetRect.midY,
                progress: translationProgress
            )
        )
    }

    private var currentSize: CGSize {
        CGSize(
            width: interpolate(
                sourceRect.width,
                targetRect.width,
                progress: sizeProgress
            ),
            height: interpolate(
                sourceRect.height,
                targetRect.height,
                progress: sizeProgress
            )
        )
    }

    private var currentCornerRadius: CGFloat {
        let sourceCornerRadius = AppLayout.thumbnailCornerRadius
        let targetCornerRadius = AppLayout.thumbnailCornerRadius
        return sourceCornerRadius + (targetCornerRadius - sourceCornerRadius) * sizeProgress
    }

    private var rotationY: Double {
        guard !reduceMotion else { return 0 }
        let p = min(max(progress, 0), 1)

        if p < 0.5 {
            let local = p / 0.5
            let eased = CGFloat(1 - pow(Double(1 - local), 2.2))
            return Double(90 * eased)
        } else {
            let local = (p - 0.5) / 0.5
            let eased = CGFloat(1 - pow(Double(1 - local), 2.2))
            return Double(-90 + 90 * eased)
        }
    }

    private var dragDistance: CGFloat {
        hypot(dragTranslation.width, dragTranslation.height)
    }

    var body: some View {
        PoolPhotoFlipFace(image: image, isExpanded: progress >= 0.5)
            .frame(width: currentSize.width, height: currentSize.height)
            .clipShape(RoundedRectangle(cornerRadius: currentCornerRadius, style: .continuous))
            .compositingGroup()
            .shadow(
                color: .black.opacity(0.18 * sizeProgress),
                radius: 10 + 16 * sizeProgress,
                y: 5 + 9 * sizeProgress
            )
            .rotation3DEffect(
                .degrees(rotationY),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                perspective: 0.7
            )
            .scaleEffect(max(0.78, 1 - dragDistance / 900), anchor: .center)
            .position(x: currentCenter.x, y: currentCenter.y)
            .offset(dragTranslation)
    }

    private func interpolate(
        _ source: CGFloat,
        _ target: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        source + (target - source) * progress
    }
}

private struct PoolPhotoFlipFace: View {
    let image: UIImage
    let isExpanded: Bool

    var body: some View {
        ZStack {
            if isExpanded {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay {
                    RoundedRectangle(cornerRadius: AppLayout.thumbnailCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.75), lineWidth: 1)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordRemarkEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var record: AdRecord
    @State private var note: String

    init(record: AdRecord) {
        self.record = record
        _note = State(initialValue: record.paymentNote ?? "")
    }

    var body: some View {
        Form {
            Section("备注") {
                TextEditor(text: $note)
                    .frame(minHeight: 180)
            }
        }
        .navigationTitle("编辑备注")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    save()
                }
            }
        }
    }

    private func save() {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        record.paymentNote = trimmedNote.isEmpty ? nil : trimmedNote
        record.updatedAt = Date()

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

struct PoolListHeader: View {
    @Binding var viewMode: PoolViewMode

    var body: some View {
        HStack(spacing: 12) {
            Text("待拍摄池子")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .textCase(nil)
            Spacer()
            PoolViewModeToggle(viewMode: $viewMode)
        }
        .textCase(nil)
    }
}

struct PoolViewModeToggle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var viewMode: PoolViewMode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PoolViewMode.allCases) { mode in
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.42, extraBounce: 0)) {
                        viewMode = mode
                    }
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(viewMode == mode ? AppTheme.onPrimary : Color.secondary)
                        .frame(width: 36, height: 36)
                        .background(buttonFill(for: mode), in: Circle())
                        .overlay {
                            Circle()
                                .stroke(buttonStroke(for: mode), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.rawValue)
            }
        }
    }

    private func buttonFill(for mode: PoolViewMode) -> Color {
        viewMode == mode ? AppTheme.primary : Color(uiColor: .tertiarySystemFill)
    }

    private func buttonStroke(for mode: PoolViewMode) -> Color {
        viewMode == mode ? AppTheme.primary.opacity(0.35) : Color.primary.opacity(0.05)
    }
}

final class PhotoImageCache {
    static let shared = PhotoImageCache()

    private let cache = NSCache<NSData, UIImage>()

    private init() {
        cache.countLimit = 320
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func image(from data: Data?) -> UIImage? {
        guard let data else { return nil }
        let key = data as NSData
        if let cachedImage = cache.object(forKey: key) {
            return cachedImage
        }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key, cost: data.count)
        return image
    }
}

struct PoolRecordCollectionContainer: View {
    let records: [AdRecord]
    let viewMode: PoolViewMode
    let hiddenPhotoID: NSManagedObjectID?
    let toggleArrival: (AdRecord) -> Void
    let deleteRecord: (AdRecord) -> Void
    let openRecord: (AdRecord) -> Void
    let showPhoto: (AdRecord, CGRect) -> Void
    let commitOrder: ([NSManagedObjectID]) -> Void

    @State private var availableWidth: CGFloat = 0

    var body: some View {
        PoolRecordCollectionView(
            records: records,
            viewMode: viewMode,
            hiddenPhotoID: hiddenPhotoID,
            toggleArrival: toggleArrival,
            deleteRecord: deleteRecord,
            openRecord: openRecord,
            showPhoto: showPhoto,
            commitOrder: commitOrder
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PoolCollectionWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .frame(height: gridHeight)
        .onPreferenceChange(PoolCollectionWidthPreferenceKey.self) { width in
            guard width > 0, abs(availableWidth - width) > 0.5 else { return }
            availableWidth = width
        }
    }

    private var gridHeight: CGFloat {
        let fallbackWidth = max(
            UIScreen.main.bounds.width - AppLayout.listHorizontalInset * 2,
            PoolRecordCollectionView.minimumCellWidth
        )
        let width = availableWidth > 0 ? availableWidth : fallbackWidth
        return PoolRecordCollectionView.height(for: width, count: records.count, mode: viewMode)
    }
}

struct PoolCollectionWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

struct PoolRecordCollectionView: UIViewRepresentable {
    @Environment(\.appThemeColor) private var appThemeColor
    let records: [AdRecord]
    let viewMode: PoolViewMode
    let hiddenPhotoID: NSManagedObjectID?
    let toggleArrival: (AdRecord) -> Void
    let deleteRecord: (AdRecord) -> Void
    let openRecord: (AdRecord) -> Void
    let showPhoto: (AdRecord, CGRect) -> Void
    let commitOrder: ([NSManagedObjectID]) -> Void

    static let spacing: CGFloat = 10
    static let minimumCellWidth: CGFloat = 154
    static var largeCellHeight: CGFloat { max(154, UIFontMetrics.default.scaledValue(for: 154)) }

    func makeCoordinator() -> Coordinator {
        Coordinator(records: records, openRecord: openRecord, showPhoto: showPhoto, commitOrder: commitOrder)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.isScrollEnabled = false
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(PoolRecordCollectionCell.self, forCellWithReuseIdentifier: PoolRecordCollectionCell.reuseIdentifier)
        collectionView.dragInteractionEnabled = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.22
        collectionView.addGestureRecognizer(longPress)
        context.coordinator.collectionView = collectionView
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        _ = appThemeColor
        let coordinator = context.coordinator
        coordinator.openRecord = openRecord
        coordinator.showPhoto = showPhoto
        coordinator.commitOrder = commitOrder
        coordinator.toggleArrival = toggleArrival
        coordinator.deleteRecord = deleteRecord
        coordinator.hiddenPhotoID = hiddenPhotoID
        guard !coordinator.isReordering else { return }
        let modeChanged = coordinator.viewMode != viewMode
        let idsChanged = coordinator.records.map(\.objectID) != records.map(\.objectID)
        coordinator.records = records
        coordinator.viewMode = viewMode
        if idsChanged {
            collectionView.reloadData()
        }
        for cell in collectionView.visibleCells {
            guard let cell = cell as? PoolRecordCollectionCell,
                  let index = collectionView.indexPath(for: cell)?.item,
                  records.indices.contains(index) else { continue }
            coordinator.configure(cell, record: records[index], animated: modeChanged)
        }
        if modeChanged {
            // Keep the same cells and scroll view; UIKit interpolates each frame.
            let layout = UICollectionViewFlowLayout()
            layout.minimumInteritemSpacing = Self.spacing
            layout.minimumLineSpacing = Self.spacing
            collectionView.setCollectionViewLayout(layout, animated: !UIAccessibility.isReduceMotionEnabled)
        } else {
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICollectionView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width - AppLayout.listHorizontalInset * 2
        return CGSize(width: width, height: Self.height(for: width, count: records.count, mode: viewMode))
    }

    static func height(for width: CGFloat, count: Int, mode: PoolViewMode) -> CGFloat {
        guard count > 0 else { return 0 }
        if mode == .large { return CGFloat(count) * (largeCellHeight + spacing) - spacing + 12 }
        let columns = columnCount(for: width)
        let rows = Int(ceil(Double(count) / Double(columns)))
        return CGFloat(rows) * cellHeight(for: width) + CGFloat(max(rows - 1, 0)) * spacing + 12
    }

    static func columnCount(for width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minimumCellWidth + spacing)))
    }

    static func itemWidth(for width: CGFloat) -> CGFloat {
        let columns = columnCount(for: width)
        let availableWidth = width - CGFloat(columns - 1) * spacing
        return floor(availableWidth / CGFloat(columns))
    }

    static func cellHeight(for width: CGFloat) -> CGFloat {
        itemWidth(for: width) + 70
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
        var records: [AdRecord]
        var viewMode: PoolViewMode = .large
        var hiddenPhotoID: NSManagedObjectID?
        var toggleArrival: (AdRecord) -> Void = { _ in }
        var deleteRecord: (AdRecord) -> Void = { _ in }
        var openRecord: (AdRecord) -> Void
        var showPhoto: (AdRecord, CGRect) -> Void
        var commitOrder: ([NSManagedObjectID]) -> Void
        weak var collectionView: UICollectionView?
        var isReordering = false
        private var didMoveDuringReorder = false

        init(
            records: [AdRecord],
            openRecord: @escaping (AdRecord) -> Void,
            showPhoto: @escaping (AdRecord, CGRect) -> Void,
            commitOrder: @escaping ([NSManagedObjectID]) -> Void
        ) {
            self.records = records
            self.openRecord = openRecord
            self.showPhoto = showPhoto
            self.commitOrder = commitOrder
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            records.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PoolRecordCollectionCell.reuseIdentifier, for: indexPath)
            guard let compactCell = cell as? PoolRecordCollectionCell, records.indices.contains(indexPath.item) else {
                return cell
            }
            let record = records[indexPath.item]
            configure(compactCell, record: record, animated: false)
            return compactCell
        }

        func configure(_ cell: PoolRecordCollectionCell, record: AdRecord, animated: Bool) {
            guard let managedObjectContext = record.managedObjectContext else { return }
            cell.configure(with: record) { [weak self] frame in
                self?.showPhoto(record, frame)
            }
            let row = PoolRecordRow(
                record: record,
                isPhotoHidden: hiddenPhotoID == record.objectID,
                photoCoordinateSpace: .named("PoolCell"),
                onToggleArrival: { [weak self] in self?.toggleArrival(record) },
                onShowPhoto: { [weak self, weak cell] _, frame in
                    guard let cell else { return }
                    self?.showPhoto(record, cell.photoFrameInWindow(frame))
                }
            )
            .padding(AppLayout.cardContentPadding)
            .coordinateSpace(name: "PoolCell")
            .environment(\.managedObjectContext, managedObjectContext)
            let configuration = UIHostingConfiguration { row }.margins(.all, 0)
            cell.onRevealDelete = { [weak self, weak cell] in
                self?.closeDeleteActions(except: cell)
            }
            cell.setMode(viewMode, configuration: configuration, photoHidden: hiddenPhotoID == record.objectID, animated: animated) { [weak self] in
                self?.deleteRecord(record)
            }
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard !isReordering, records.indices.contains(indexPath.item) else { return }
            guard !closeDeleteActions() else { return }
            openRecord(records[indexPath.item])
        }

        @discardableResult
        private func closeDeleteActions(except excludedCell: PoolRecordCollectionCell? = nil) -> Bool {
            var closedAction = false
            for case let cell as PoolRecordCollectionCell in collectionView?.visibleCells ?? [] {
                guard cell !== excludedCell, cell.isDeleteRevealed else { continue }
                cell.hideDelete()
                closedAction = true
            }
            return closedAction
        }

        func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool {
            true
        }

        func collectionView(_ collectionView: UICollectionView, moveItemAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
            guard
                sourceIndexPath.item != destinationIndexPath.item,
                records.indices.contains(sourceIndexPath.item)
            else {
                return
            }
            let movedRecord = records.remove(at: sourceIndexPath.item)
            let destination = min(destinationIndexPath.item, records.count)
            records.insert(movedRecord, at: destination)
            didMoveDuringReorder = true
        }

        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
            if viewMode == .large {
                return CGSize(width: collectionView.bounds.width, height: PoolRecordCollectionView.largeCellHeight)
            }
            let width = PoolRecordCollectionView.itemWidth(for: collectionView.bounds.width)
            return CGSize(width: width, height: width + 70)
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let collectionView else { return }
            let location = gesture.location(in: collectionView)

            switch gesture.state {
            case .began:
                guard let indexPath = collectionView.indexPathForItem(at: location) else { return }
                closeDeleteActions()
                isReordering = true
                didMoveDuringReorder = false
                collectionView.beginInteractiveMovementForItem(at: indexPath)
            case .changed:
                collectionView.updateInteractiveMovementTargetPosition(location)
            case .ended:
                collectionView.endInteractiveMovement()
                finishReorderIfNeeded()
            default:
                collectionView.cancelInteractiveMovement()
                isReordering = false
                didMoveDuringReorder = false
            }
        }

        private func finishReorderIfNeeded() {
            isReordering = false
            guard didMoveDuringReorder else { return }
            didMoveDuringReorder = false
            commitOrder(records.map(\.objectID))
        }
    }
}

final class PoolRecordCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "PoolRecordCollectionCell"

    private let cardView = UIView()
    private var largeContent: (UIView & UIContentView)?
    private var mode: PoolViewMode = .compact
    private let deleteButton = UIButton(type: .system)
    private let deleteIconView = UIImageView(image: UIImage(systemName: "trash"))
    private let deleteLabel = UILabel()
    private var deleteAction: (() -> Void)?
    private(set) var isDeleteRevealed = false
    var onRevealDelete: (() -> Void)?

    private var deleteIconDiameter: CGFloat { UIFontMetrics.default.scaledValue(for: 50) }
    private var deleteActionWidth: CGFloat { deleteIconDiameter + 20 }

    func setMode(_ mode: PoolViewMode, configuration: any UIContentConfiguration, photoHidden: Bool, animated: Bool, deleteAction: @escaping () -> Void) {
        if self.mode != mode {
            setDeleteRevealed(false, animated: false)
        }
        self.mode = mode
        self.deleteAction = deleteAction
        if let largeContent {
            largeContent.configuration = configuration
        } else {
            let content = configuration.makeContentView()
            cardView.addSubview(content)
            largeContent = content
        }
        largeContent?.frame = cardView.bounds
        let changes = {
            self.largeContent?.alpha = mode == .large ? 1 : 0
            self.imageView.alpha = mode == .compact && !photoHidden ? 1 : 0
            self.placeholderView.alpha = mode == .compact ? 1 : 0
            self.titleLabel.alpha = mode == .compact ? 1 : 0
            self.lookLabel.alpha = mode == .compact ? 1 : 0
        }
        largeContent?.isUserInteractionEnabled = mode == .large
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.35, animations: changes)
        } else {
            changes()
        }
        setNeedsLayout()
    }

    func photoFrameInWindow(_ frame: CGRect) -> CGRect {
        guard let largeContent, let window else { return frame }
        return largeContent.convert(frame, to: window)
    }

    @objc private func revealDelete() {
        guard mode == .large else { return }
        onRevealDelete?()
        setDeleteRevealed(true, animated: true)
    }

    @objc func hideDelete() {
        setDeleteRevealed(false, animated: true)
    }

    private func setDeleteRevealed(_ revealed: Bool, animated: Bool) {
        isDeleteRevealed = revealed
        contentView.isUserInteractionEnabled = !revealed
        deleteButton.isUserInteractionEnabled = revealed
        let changes = {
            self.contentView.transform = revealed
                ? CGAffineTransform(translationX: -self.deleteActionWidth, y: 0)
                : .identity
            self.deleteButton.alpha = revealed ? 1 : 0
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.24, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: changes)
        } else {
            changes()
        }
    }

    @objc private func deleteTapped() {
        guard isDeleteRevealed else { return }
        deleteAction?()
    }

    @objc private func accessibilityDelete() -> Bool {
        guard let deleteAction else { return false }
        deleteAction()
        return true
    }

    private let imageView = UIImageView()
    private let placeholderView = UIImageView(image: UIImage(systemName: "photo"))
    private let titleLabel = UILabel()
    private let lookLabel = UILabel()
    private var onPhotoTap: ((CGRect) -> Void)?
    private var styleTraitRegistration: UITraitChangeRegistration?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        placeholderView.isHidden = true
        titleLabel.text = nil
        lookLabel.text = nil
        onPhotoTap = nil
        onRevealDelete = nil
        deleteAction = nil
        setDeleteRevealed(false, animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Move the complete card, including its border and shadow, beside the action.
        contentView.bounds = bounds
        contentView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        contentView.transform = isDeleteRevealed
            ? CGAffineTransform(translationX: -deleteActionWidth, y: 0)
            : .identity
        cardView.frame = contentView.bounds
        largeContent?.bounds = bounds
        largeContent?.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let actionHeight = deleteIconDiameter + 6 + deleteLabel.font.lineHeight
        deleteButton.frame = CGRect(x: bounds.width - deleteActionWidth, y: (bounds.height - actionHeight) / 2, width: deleteActionWidth, height: actionHeight)
        deleteIconView.frame = CGRect(x: 10, y: 0, width: deleteIconDiameter, height: deleteIconDiameter)
        deleteIconView.layer.cornerRadius = deleteIconDiameter / 2
        deleteLabel.frame = CGRect(x: 0, y: deleteIconDiameter + 6, width: deleteActionWidth, height: deleteLabel.font.lineHeight)
        contentView.layer.shadowPath = AppLayout.cardShape.path(in: contentView.bounds).cgPath

        let padding: CGFloat = 10
        let contentWidth = bounds.width - padding * 2
        let imageHeight = contentWidth
        imageView.frame = CGRect(x: padding, y: padding, width: contentWidth, height: imageHeight)
        placeholderView.frame = imageView.frame
        titleLabel.frame = CGRect(x: padding, y: padding + imageHeight + 10, width: contentWidth, height: 24)
        lookLabel.sizeToFit()
        let chipWidth = min(lookLabel.bounds.width + 20, contentWidth)
        lookLabel.frame = CGRect(x: padding, y: padding + imageHeight + 42, width: chipWidth, height: 28)
        lookLabel.layer.cornerRadius = 14
    }

    func configure(with record: AdRecord, onPhotoTap: @escaping (CGRect) -> Void) {
        applyCardStyle()
        titleLabel.text = record.titleText
        if let image = PhotoImageCache.shared.image(from: record.photoData) {
            imageView.image = image
            placeholderView.isHidden = true
            imageView.isUserInteractionEnabled = true
            self.onPhotoTap = onPhotoTap
        } else {
            imageView.image = nil
            placeholderView.isHidden = false
            imageView.isUserInteractionEnabled = false
            self.onPhotoTap = nil
        }

        let isLookOne = record.lookNumber == 1
        lookLabel.isHidden = !record.usesLook
        lookLabel.text = record.lookNumber > 0 ? "LOOK \(record.lookNumber)" : "随机"
        lookLabel.textColor = isLookOne ? AppTheme.readablePrimaryUIColor : .secondaryLabel
        lookLabel.backgroundColor = (isLookOne ? AppTheme.primaryUIColor : UIColor.secondaryLabel).withAlphaComponent(0.12)
        setNeedsLayout()
    }

    private func setup() {
        backgroundColor = .clear
        layer.masksToBounds = false

        contentView.backgroundColor = .clear
        contentView.clipsToBounds = false
        cardView.layer.cornerRadius = Self.cardCornerRadius
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 1
        cardView.clipsToBounds = true
        contentView.addSubview(cardView)
        applyCardStyle()
        styleTraitRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: PoolRecordCollectionCell, _) in
            cell.applyCardStyle()
        }

        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = .tertiarySystemFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = AppLayout.thumbnailCornerRadius
        imageView.layer.cornerCurve = .continuous
        let imageTap = UITapGestureRecognizer(target: self, action: #selector(handlePhotoTap))
        imageTap.cancelsTouchesInView = true
        imageView.addGestureRecognizer(imageTap)

        placeholderView.contentMode = .center
        placeholderView.tintColor = .secondaryLabel
        placeholderView.backgroundColor = .tertiarySystemFill
        placeholderView.layer.cornerRadius = AppLayout.thumbnailCornerRadius
        placeholderView.layer.cornerCurve = .continuous
        placeholderView.clipsToBounds = true
        placeholderView.isHidden = true

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail

        lookLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .bold)
        )
        lookLabel.textAlignment = .center
        lookLabel.clipsToBounds = true

        deleteIconView.tintColor = AppTheme.onPrimaryUIColor
        deleteIconView.backgroundColor = AppTheme.primaryUIColor
        deleteIconView.contentMode = .center
        deleteIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
        deleteIconView.isUserInteractionEnabled = false
        deleteLabel.text = "删除"
        deleteLabel.font = .preferredFont(forTextStyle: .caption1)
        deleteLabel.adjustsFontForContentSizeCategory = true
        deleteLabel.textColor = .secondaryLabel
        deleteLabel.textAlignment = .center
        deleteLabel.isUserInteractionEnabled = false
        deleteButton.addSubview(deleteIconView)
        deleteButton.addSubview(deleteLabel)
        deleteButton.accessibilityLabel = "删除"
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        deleteButton.alpha = 0
        deleteButton.isUserInteractionEnabled = false
        addSubview(deleteButton)
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "删除", target: self, selector: #selector(accessibilityDelete))]
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(revealDelete))
        swipeLeft.direction = .left
        addGestureRecognizer(swipeLeft)
        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(hideDelete))
        swipeRight.direction = .right
        addGestureRecognizer(swipeRight)

        cardView.addSubview(imageView)
        cardView.addSubview(placeholderView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(lookLabel)
    }

    @objc private func handlePhotoTap() {
        guard let window else { return }
        let sourceFrame = imageView.convert(imageView.bounds, to: window)
        onPhotoTap?(sourceFrame)
    }

    private func applyCardStyle() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        cardView.backgroundColor = isDark
            ? UIColor.secondarySystemBackground.withAlphaComponent(0.88)
            : UIColor.systemBackground
        deleteIconView.tintColor = AppTheme.onPrimaryUIColor
        deleteIconView.backgroundColor = AppTheme.primaryUIColor
        cardView.layer.borderColor = AppTheme.readablePrimaryUIColor.resolvedColor(with: traitCollection)
            .withAlphaComponent(isDark ? 0.2 : 0.08)
            .cgColor

        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = isDark ? 0.42 : Float(AppLayout.lightCardShadowOpacity)
        contentView.layer.shadowRadius = isDark ? 10 : AppLayout.lightCardShadowRadius
        contentView.layer.shadowOffset = CGSize(width: 0, height: isDark ? 5 : AppLayout.lightCardShadowOffset)
    }

    private static let cardCornerRadius = AppLayout.cardCornerRadius
}

struct PoolSummaryPanel: View {
    let totalCount: Int
    let totalAmount: Double
    let categorySummary: [PoolCategorySummary]

    @State private var isExpanded = false

    var body: some View {
        ExpandableSummaryCard(isExpanded: $isExpanded, hasDetails: !categorySummary.isEmpty) {
            fixedOverview
        } details: {
            categoryDetails
        }
    }

    private var fixedOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                AppCardTitle(title: "池子汇总", symbol: "tray.full.fill")
                Spacer()
                Text("\(totalCount) 件")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("待拍总金额")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(moneyText(totalAmount))
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(totalAmount > 0 ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                    .scaleEffect(isExpanded ? 1.055 : 1, anchor: .leading)
                    .animation(.smooth(duration: 0.4, extraBounce: 0), value: isExpanded)
            }
        }
    }

    private var categoryDetails: some View {
        VStack(spacing: 10) {
            ForEach(categorySummary) { item in
                HStack(spacing: 10) {
                    CategoryBadge(category: item.category)
                    Spacer()
                    Text("\(item.count) 件")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(moneyText(item.amount))
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 76, alignment: .trailing)
                }
            }
        }
    }
}

struct PoolFilterControls: View {
    @Binding var categoryFilter: AdCategory?
    @Binding var partnershipFilter: PartnershipType?
    @Binding var arrivalFilter: ArrivalFilter
    @Binding var lookFilter: Int?

    let availableLookNumbers: [Int]
    let resultCount: Int

    private var hasFilters: Bool {
        categoryFilter != nil || partnershipFilter != nil || arrivalFilter != .all || lookFilter != nil
    }

    private var lookTitle: String {
        guard let lookFilter else { return "Look" }
        return lookFilter == 0 ? "随机" : "Look \(lookFilter)"
    }

    private var filterColumns: [GridItem] {
        if partnershipFilter?.usesLook == false {
            return Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
        }
        return [GridItem(.adaptive(minimum: 90), spacing: 8)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                AppCardTitle(title: "筛选", symbol: "line.3.horizontal.decrease.circle")
                Text("\(resultCount) 件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if hasFilters {
                    Button("重置") {
                        categoryFilter = nil
                        partnershipFilter = nil
                        arrivalFilter = .all
                        lookFilter = nil
                    }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
                    .accessibilityLabel("重置品类、合作方式、到货和 Look 筛选")
                }
            }

            Picker("到货状态", selection: $arrivalFilter) {
                Text("全部").tag(ArrivalFilter.all)
                Text("未到货").tag(ArrivalFilter.notArrived)
                Text("已到货").tag(ArrivalFilter.arrived)
            }
            .pickerStyle(.segmented)

            LazyVGrid(columns: filterColumns, spacing: 8) {
                Menu {
                    Picker("品类", selection: $categoryFilter) {
                        Text("全部品类").tag(nil as AdCategory?)
                        ForEach(AdCategory.allCases) { category in
                            Label(category.rawValue, systemImage: category.symbolName)
                                .tag(Optional(category))
                        }
                    }
                } label: {
                    PoolFilterMenuLabel(title: categoryFilter?.rawValue ?? "品类", isSelected: categoryFilter != nil)
                }
                .accessibilityLabel("品类：\(categoryFilter?.rawValue ?? "全部")")

                Menu {
                    Picker("合作方式", selection: $partnershipFilter) {
                        Text("全部方式").tag(nil as PartnershipType?)
                        ForEach(PartnershipType.allCases) { type in
                            Text(type.rawValue).tag(Optional(type))
                        }
                    }
                } label: {
                    PoolFilterMenuLabel(title: partnershipFilter?.rawValue ?? "合作方式", isSelected: partnershipFilter != nil)
                }
                .accessibilityLabel("合作方式：\(partnershipFilter?.rawValue ?? "全部")")

                if partnershipFilter?.usesLook != false {
                    Menu {
                        Picker("Look", selection: $lookFilter) {
                            Text("全部 Look").tag(nil as Int?)
                            Text("随机").tag(Optional(0))
                            ForEach(availableLookNumbers, id: \.self) { number in
                                Text("Look \(number)").tag(Optional(number))
                            }
                        }
                    } label: {
                        PoolFilterMenuLabel(title: lookTitle, isSelected: lookFilter != nil)
                    }
                    .accessibilityLabel("Look：\(lookFilter == nil ? "全部" : lookTitle)")
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .onChange(of: partnershipFilter) { _, type in
            if type?.usesLook == false {
                lookFilter = nil
            }
        }
    }
}

private struct PoolFilterMenuLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(isSelected ? AppTheme.readablePrimary : Color.secondary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(isSelected ? AppTheme.primary.opacity(0.12) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppLayout.compactControlCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppLayout.compactControlCornerRadius, style: .continuous))
    }
}

struct PoolPickFilterControls: View {
    @Binding var categoryFilter: AdCategory?
    @Binding var partnershipFilter: PartnershipType?
    @Binding var arrivalFilter: ArrivalFilter
    @Binding var lookFilter: Int?

    let availableLookNumbers: [Int]
    let selectedCount: Int

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    AppCardTitle(title: "筛选池子", symbol: "line.3.horizontal.decrease.circle")
                    Spacer()
                    Text("已选 \(selectedCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selectedCount > 0 ? AppTheme.readablePrimary : .secondary)
                }

                PoolFilterFields(
                    categoryFilter: $categoryFilter,
                    partnershipFilter: $partnershipFilter,
                    arrivalFilter: $arrivalFilter,
                    lookFilter: $lookFilter,
                    availableLookNumbers: availableLookNumbers
                )
            }
            .padding(.vertical, 4)
            .recordCard()
            .floatingCardRow()
        }
    }
}

struct PoolFilterFields: View {
    @Binding var categoryFilter: AdCategory?
    @Binding var partnershipFilter: PartnershipType?
    @Binding var arrivalFilter: ArrivalFilter
    @Binding var lookFilter: Int?

    let availableLookNumbers: [Int]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 10) {
                PoolFilterField(title: "品类") {
                    Menu {
                        Button("全部") {
                            categoryFilter = nil
                        }
                        ForEach(AdCategory.allCases) { category in
                            Button {
                                categoryFilter = category
                            } label: {
                                Label(category.rawValue, systemImage: category.symbolName)
                            }
                        }
                    } label: {
                        PoolFilterValueLabel(value: categoryFilter?.rawValue ?? "全部")
                    }
                }

                PoolFilterField(title: "方式") {
                    Menu {
                        Button("全部") {
                            partnershipFilter = nil
                        }
                        ForEach(PartnershipType.allCases) { type in
                            Button {
                                partnershipFilter = type
                            } label: {
                                Label(type.rawValue, systemImage: type.symbolName)
                                    .foregroundStyle(type.tint)
                            }
                        }
                    } label: {
                        PoolFilterValueLabel(
                            value: partnershipFilter?.rawValue ?? "全部",
                            tint: partnershipFilter?.tint ?? AppTheme.primary
                        )
                    }
                }

                PoolFilterField(title: "到货") {
                    Menu {
                        ForEach(ArrivalFilter.allCases) { filter in
                            Button {
                                arrivalFilter = filter
                            } label: {
                                if let symbolName = filter.symbolName {
                                    Label(filter.rawValue, systemImage: symbolName)
                                } else {
                                    Text(filter.rawValue)
                                }
                            }
                        }
                    } label: {
                        PoolFilterValueLabel(value: arrivalFilter.rawValue)
                    }
                }

                if partnershipFilter?.usesLook != false {
                    PoolFilterField(title: "Look") {
                        Menu {
                            Button("全部") {
                                lookFilter = nil
                            }
                            Button("随机") {
                                lookFilter = 0
                            }
                            ForEach(availableLookNumbers, id: \.self) { lookNumber in
                                Button("Look \(lookNumber)") {
                                    lookFilter = lookNumber
                                }
                            }
                        } label: {
                            PoolFilterValueLabel(value: lookFilterTitle)
                        }
                    }
                }
            }

            if categoryFilter != nil || partnershipFilter != nil || arrivalFilter != .all || lookFilter != nil {
                Button {
                    categoryFilter = nil
                    partnershipFilter = nil
                    arrivalFilter = .all
                    lookFilter = nil
                } label: {
                    Label("清除筛选", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .tint(.red)
                .padding(.top, 8)
            }
        }
        .onChange(of: partnershipFilter) { _, type in
            if type?.usesLook == false {
                lookFilter = nil
            }
        }
    }

    private var lookFilterTitle: String {
        guard let lookFilter else { return "全部" }
        return lookFilter == 0 ? "随机" : "Look \(lookFilter)"
    }
}

struct PoolFilterField<Selection: View>: View {
    let title: String
    @ViewBuilder var selection: Selection

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 10)

            selection
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }
}

struct PoolFilterValueLabel: View {
    let value: String
    var tint: Color = AppTheme.primary

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(AppTheme.readable(tint))
        .contentShape(Rectangle())
    }
}
