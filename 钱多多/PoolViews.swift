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
    @State private var viewMode: PoolViewMode = .large
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
                let matchesLook = lookFilter.map { Int(record.lookNumber) == $0 } ?? true
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
            .fullScreenCover(item: $selectedCompactPhoto) { selection in
                PhotoFullScreenView(image: selection.image)
            }
            .onReceive(NotificationCenter.default.publisher(for: .adRecordsDidChange)) { _ in
                refreshToken = UUID()
            }
        }
    }

    @ViewBuilder
    private var poolContent: some View {
        if viewMode == .compact {
            compactPoolContent
        } else {
            largePoolContent
        }
    }

    private var largePoolContent: some View {
        List {
            Section {
                MonthSelector(selectedMonth: $selectedMonth)
            }
            .wideListRow()

            Section {
                poolSummaryCard
            }
            .floatingCardRow()

            Section {
                poolFilterCard
            }
            .floatingCardRow()

            Section {
                PoolListHeader(viewMode: $viewMode)
                    .wideListRow()

                if poolRecords.isEmpty {
                    ContentUnavailableView("池子是空的", systemImage: "tray", description: Text("点右上角添加新的待拍摄广告"))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(poolRecords, id: \.objectID) { record in
                        ZStack {
                            NavigationLink {
                                PoolRecordEditor(record: record)
                            } label: {
                                EmptyView()
                            }
                            .opacity(0)

                            PoolRecordRow(record: record, onToggleArrival: {
                                toggleArrival(record)
                            })
                            .recordCard()
                        }
                        .floatingCardRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deletePoolRecord(record)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    .onMove(perform: movePoolRecords)
                    .onDelete(perform: deletePoolRecords)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
    }

    private var compactPoolContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
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
                    PoolCompactCollectionContainer(
                        records: poolRecords,
                        openRecord: { record in
                            selectedCompactRecord = PoolRecordSelection(recordID: record.objectID)
                        },
                        showPhoto: { photoData in
                            guard let image = PhotoImageCache.shared.image(from: photoData) else { return }
                            selectedCompactPhoto = PoolPhotoSelection(image: image)
                        },
                        commitOrder: applyPoolOrder
                    )
                }
            }
            .padding(.horizontal, AppLayout.listHorizontalInset)
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
        .recordCard()
    }

    private var poolFilterCard: some View {
        PoolFilterControls(
            categoryFilter: $categoryFilter,
            partnershipFilter: $partnershipFilter,
            arrivalFilter: $arrivalFilter,
            lookFilter: $lookFilter,
            availableLookNumbers: availableLookNumbers
        )
        .recordCard()
    }

    private var compactColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 154, maximum: 220), spacing: 10)]
    }

    private func record(for selection: PoolRecordSelection) -> AdRecord? {
        try? viewContext.existingObject(with: selection.recordID) as? AdRecord
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

    private func deletePoolRecords(offsets: IndexSet) {
        offsets.map { poolRecords[$0] }.forEach(deletePoolRecord)
    }

    private func deletePoolRecord(_ record: AdRecord) {
        withAnimation {
            viewContext.delete(record)
            saveContext()
        }
    }

    private func movePoolRecords(from source: IndexSet, to destination: Int) {
        let oldVisibleRecords = poolRecords
        var reorderedVisibleRecords = oldVisibleRecords
        reorderedVisibleRecords.move(fromOffsets: source, toOffset: destination)
        persistVisibleOrderChange(from: oldVisibleRecords, to: reorderedVisibleRecords)
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
    var onToggleArrival: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.titleText)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .layoutPriority(1)
                LookChip(lookNumber: record.lookNumber)
                if record.workflowValue == .scheduled {
                    ScheduledBadge()
                }
                Spacer(minLength: 8)
                Text(record.priceDisplayText)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(record.hasPriceValue ? Color.primary : Color.gray.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(minWidth: 72, alignment: .trailing)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        CategoryBadge(category: record.categoryValue)
                        PartnershipBadge(type: record.partnershipValue)
                        RemarkChip(note: record.paymentNote)
                    }

                    Label(record.contactWeChat.nonEmptyOr("未填微信"), systemImage: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Button {
                        onToggleArrival?()
                    } label: {
                        Label(record.arrivalText, systemImage: "shippingbox.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(record.arrivalDate == nil ? Color.secondary : AppTheme.primary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RecordThumbnail(photoData: record.photoData, size: 80)
            }
        }
        .padding(.vertical, 6)
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
    @Binding var viewMode: PoolViewMode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PoolViewMode.allCases) { mode in
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        viewMode = mode
                    }
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(viewMode == mode ? Color.white : Color.secondary)
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

struct PoolCompactCollectionContainer: View {
    let records: [AdRecord]
    let openRecord: (AdRecord) -> Void
    let showPhoto: (Data?) -> Void
    let commitOrder: ([NSManagedObjectID]) -> Void

    @State private var availableWidth: CGFloat = 0

    var body: some View {
        PoolCompactCollectionView(
            records: records,
            openRecord: openRecord,
            showPhoto: showPhoto,
            commitOrder: commitOrder
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PoolCompactWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .frame(height: gridHeight)
        .onPreferenceChange(PoolCompactWidthPreferenceKey.self) { width in
            guard width > 0, abs(availableWidth - width) > 0.5 else { return }
            availableWidth = width
        }
    }

    private var gridHeight: CGFloat {
        let fallbackWidth = max(
            UIScreen.main.bounds.width - AppLayout.listHorizontalInset * 2,
            PoolCompactCollectionView.minimumCellWidth
        )
        let width = availableWidth > 0 ? availableWidth : fallbackWidth
        return PoolCompactCollectionView.height(for: width, count: records.count)
    }
}

struct PoolCompactWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

struct PoolCompactCollectionView: UIViewRepresentable {
    let records: [AdRecord]
    let openRecord: (AdRecord) -> Void
    let showPhoto: (Data?) -> Void
    let commitOrder: ([NSManagedObjectID]) -> Void

    static let spacing: CGFloat = 10
    static let minimumCellWidth: CGFloat = 154

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
        collectionView.register(PoolCompactCollectionCell.self, forCellWithReuseIdentifier: PoolCompactCollectionCell.reuseIdentifier)
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
        context.coordinator.openRecord = openRecord
        context.coordinator.showPhoto = showPhoto
        context.coordinator.commitOrder = commitOrder
        guard !context.coordinator.isReordering else { return }
        let newIDs = records.map(\.objectID)
        if context.coordinator.records.map(\.objectID) != newIDs {
            context.coordinator.records = records
            collectionView.reloadData()
        } else {
            context.coordinator.records = records
        }
        collectionView.collectionViewLayout.invalidateLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICollectionView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width - AppLayout.listHorizontalInset * 2
        return CGSize(width: width, height: Self.height(for: width, count: records.count))
    }

    static func height(for width: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
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
        var openRecord: (AdRecord) -> Void
        var showPhoto: (Data?) -> Void
        var commitOrder: ([NSManagedObjectID]) -> Void
        weak var collectionView: UICollectionView?
        var isReordering = false
        private var didMoveDuringReorder = false

        init(
            records: [AdRecord],
            openRecord: @escaping (AdRecord) -> Void,
            showPhoto: @escaping (Data?) -> Void,
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
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PoolCompactCollectionCell.reuseIdentifier, for: indexPath)
            guard let compactCell = cell as? PoolCompactCollectionCell, records.indices.contains(indexPath.item) else {
                return cell
            }
            let record = records[indexPath.item]
            compactCell.configure(with: record) { [weak self] in
                self?.showPhoto(record.photoData)
            }
            return compactCell
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard !isReordering, records.indices.contains(indexPath.item) else { return }
            openRecord(records[indexPath.item])
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
            let width = PoolCompactCollectionView.itemWidth(for: collectionView.bounds.width)
            return CGSize(width: width, height: width + 70)
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let collectionView else { return }
            let location = gesture.location(in: collectionView)

            switch gesture.state {
            case .began:
                guard let indexPath = collectionView.indexPathForItem(at: location) else { return }
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

final class PoolCompactCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "PoolCompactCollectionCell"

    private let imageView = UIImageView()
    private let placeholderView = UIImageView(image: UIImage(systemName: "photo"))
    private let titleLabel = UILabel()
    private let lookLabel = UILabel()
    private var onPhotoTap: (() -> Void)?
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
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.frame = bounds
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: PoolCompactCollectionCell.cardCornerRadius
        ).cgPath

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

    func configure(with record: AdRecord, onPhotoTap: @escaping () -> Void) {
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
        lookLabel.text = record.lookNumber > 0 ? "LOOK \(record.lookNumber)" : "随机"
        lookLabel.textColor = isLookOne ? AppTheme.primaryUIColor : .secondaryLabel
        lookLabel.backgroundColor = (isLookOne ? AppTheme.primaryUIColor : UIColor.secondaryLabel).withAlphaComponent(0.12)
        setNeedsLayout()
    }

    private func setup() {
        backgroundColor = .clear
        layer.masksToBounds = false

        contentView.layer.cornerRadius = Self.cardCornerRadius
        contentView.layer.cornerCurve = .continuous
        contentView.layer.borderWidth = 1
        contentView.clipsToBounds = true
        applyCardStyle()
        styleTraitRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: PoolCompactCollectionCell, _) in
            cell.applyCardStyle()
        }

        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = .tertiarySystemFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        imageView.layer.cornerCurve = .continuous
        let imageTap = UITapGestureRecognizer(target: self, action: #selector(handlePhotoTap))
        imageTap.cancelsTouchesInView = true
        imageView.addGestureRecognizer(imageTap)

        placeholderView.contentMode = .center
        placeholderView.tintColor = .secondaryLabel
        placeholderView.backgroundColor = .tertiarySystemFill
        placeholderView.layer.cornerRadius = 8
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

        contentView.addSubview(imageView)
        contentView.addSubview(placeholderView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(lookLabel)
    }

    @objc private func handlePhotoTap() {
        onPhotoTap?()
    }

    private func applyCardStyle() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        contentView.backgroundColor = isDark
            ? UIColor.secondarySystemBackground.withAlphaComponent(0.88)
            : UIColor.systemBackground.withAlphaComponent(0.98)
        contentView.layer.borderColor = AppTheme.primaryUIColor
            .withAlphaComponent(isDark ? 0.2 : 0.08)
            .cgColor

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = isDark ? 0.42 : 0.07
        layer.shadowRadius = isDark ? 10 : 8
        layer.shadowOffset = isDark ? CGSize(width: 0, height: 5) : CGSize(width: 0, height: 3)
    }

    private static let cardCornerRadius = AppLayout.cardCornerRadius
}

struct PoolSummaryPanel: View {
    let totalCount: Int
    let totalAmount: Double
    let categorySummary: [PoolCategorySummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                AppCardTitle(title: "池子汇总", symbol: "tray.full.fill")
                Spacer()
                Text("\(totalCount) 件")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("待拍总金额")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(moneyText(totalAmount))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(totalAmount > 0 ? Color.primary : Color.secondary)
                }
                Spacer()
            }

            if !categorySummary.isEmpty {
                Divider()
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
        .padding(.vertical, 4)
    }
}

struct PoolFilterControls: View {
    @Binding var categoryFilter: AdCategory?
    @Binding var partnershipFilter: PartnershipType?
    @Binding var arrivalFilter: ArrivalFilter
    @Binding var lookFilter: Int?

    let availableLookNumbers: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppCardTitle(title: "筛选池子", symbol: "line.3.horizontal.decrease.circle")

            PoolFilterFields(
                categoryFilter: $categoryFilter,
                partnershipFilter: $partnershipFilter,
                arrivalFilter: $arrivalFilter,
                lookFilter: $lookFilter,
                availableLookNumbers: availableLookNumbers
            )
        }
        .padding(.vertical, 4)
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
                        .foregroundStyle(selectedCount > 0 ? AppTheme.primary : .secondary)
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
        .foregroundStyle(tint)
        .contentShape(Rectangle())
    }
}
