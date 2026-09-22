//
//  SummaryViews.swift
//  钱多多
//

import Charts
import CoreData
import SwiftUI

private enum SummaryPalette {
    static let positive = Color(
        red: 53.0 / 255.0,
        green: 193.0 / 255.0,
        blue: 90.0 / 255.0
    )
    static let negative = Color(
        red: 237.0 / 255.0,
        green: 75.0 / 255.0,
        blue: 67.0 / 255.0
    )
}

struct SummaryPage: View {
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
            NSSortDescriptor(keyPath: \FollowerSnapshot.date, ascending: true)
        ],
        animation: .default
    )
    private var allFollowerSnapshots: FetchedResults<FollowerSnapshot>

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \VideoLikeSnapshot.recordedAt, ascending: true)
        ],
        animation: .default
    )
    private var allVideoLikeSnapshots: FetchedResults<VideoLikeSnapshot>

    @State private var refreshToken = UUID()
    @State private var selectedMonth = Date()
    @State private var showingFollowerDataEditor = false
    @AppStorage(demoDataHiddenKey) private var isDemoDataHidden = false

    private var records: [AdRecord] {
        _ = refreshToken
        guard !isDemoDataHidden else { return [] }
        return Array(allRecords)
    }

    private var followerSnapshots: [FollowerSnapshot] {
        guard !isDemoDataHidden else { return [] }
        return Array(allFollowerSnapshots)
    }

    private var videoLikeSnapshots: [VideoLikeSnapshot] {
        guard !isDemoDataHidden else { return [] }
        return Array(allVideoLikeSnapshots)
    }

    private var previousMonth: Date {
        qddCalendar.date(byAdding: .month, value: -1, to: selectedMonth) ?? selectedMonth
    }

    private var businessRecordsForSelectedMonth: [AdRecord] {
        businessRecords(for: selectedMonth)
    }

    private var businessRecordsForPreviousMonth: [AdRecord] {
        businessRecords(for: previousMonth)
    }

    private var businessStats: MonthStats {
        MonthStats(records: businessRecordsForSelectedMonth)
    }

    private var previousBusinessStats: MonthStats {
        MonthStats(records: businessRecordsForPreviousMonth)
    }

    private func businessRecords(for month: Date) -> [AdRecord] {
        records.filter { record in
            (record.publishedDate != nil || record.statusValue == .paid) &&
                qddCalendar.isDate(record.reportDate, equalTo: month, toGranularity: .month)
        }
    }

    private var chartItems: [MonthChartItem] {
        recentMonths.flatMap { month in
            let stats = MonthStats(records: businessRecords(for: month))
            return [
                MonthChartItem(month: month, kind: "已回款", amount: stats.paid),
                MonthChartItem(month: month, kind: "待回款", amount: stats.unpaid)
            ]
        }
    }

    private var recentMonths: [Date] {
        let currentMonth = monthStart(selectedMonth)
        return (0..<12).reversed().compactMap { offset in
            qddCalendar.date(byAdding: .month, value: -offset, to: currentMonth)
        }
    }

    private var publishedVideoGroupsForSelectedMonth: [VideoGroup] {
        makeVideoGroups(from: records).filter { group in
            guard group.allPublished,
                  let publishedDate = group.records.compactMap(\.publishedDate).first else {
                return false
            }
            return qddCalendar.isDate(
                publishedDate,
                equalTo: selectedMonth,
                toGranularity: .month
            )
        }
    }

    private var contentPerformanceItems: [ContentPerformanceItem] {
        publishedVideoGroupsForSelectedMonth.compactMap { group in
            guard let publishedDate = group.records.compactMap(\.publishedDate).first else {
                return nil
            }

            let latestSnapshot = videoLikeSnapshots
                .filter { snapshot in
                    guard snapshot.videoName.nonEmptyOr("未命名视频") == group.title,
                          snapshot.publishedDate == publishedDate,
                          let recordedAt = snapshot.recordedAt,
                          recordedAt >= publishedDate else {
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
                .max { first, second in
                    (first.recordedAt ?? .distantPast) < (second.recordedAt ?? .distantPast)
                }

            return ContentPerformanceItem(
                videoName: group.title,
                likeCount: latestSnapshot?.likeCount,
                publishedDate: publishedDate,
                likeRecordedAt: latestSnapshot?.recordedAt,
                nextDayFollowerGain: nextDayFollowerGain(after: publishedDate)
            )
        }
        .sorted {
            $0.publishedDate > $1.publishedDate
        }
    }

    private func nextDayFollowerGain(after publishedDate: Date) -> Int64? {
        let calendar = qddCalendar
        let publishedDay = dayOnly(publishedDate)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: publishedDay),
              let baseline = followerSnapshots.last(where: { snapshot in
                  guard let date = snapshot.date else { return false }
                  return calendar.isDate(date, inSameDayAs: publishedDay)
              }),
              let comparison = followerSnapshots.last(where: { snapshot in
                  guard let date = snapshot.date else { return false }
                  return calendar.isDate(date, inSameDayAs: nextDay)
              }) else {
            return nil
        }
        return comparison.followerCount - baseline.followerCount
    }

    private var categoryBreakdown: [(category: AdCategory, count: Int, amount: Double)] {
        let grouped = Dictionary(grouping: businessRecordsForSelectedMonth) { $0.categoryValue }
        return AdCategory.allCases.compactMap { cat in
            guard let records = grouped[cat], !records.isEmpty else { return nil }
            let amount = records.reduce(0) { $0 + $1.billableAmount }
            return (category: cat, count: records.count, amount: amount)
        }
        .sorted { $0.amount > $1.amount }
    }

    private var partnershipBreakdown: [(type: PartnershipType, count: Int)] {
        let grouped = Dictionary(grouping: businessRecordsForSelectedMonth) { $0.partnershipValue }
        return PartnershipType.allCases.compactMap { pt in
            guard let records = grouped[pt], !records.isEmpty else { return nil }
            return (type: pt, count: records.count)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    MonthSelector(selectedMonth: $selectedMonth)

                    SummaryDashboard(
                        businessStats: businessStats,
                        previousBusinessStats: previousBusinessStats,
                        partnershipItems: partnershipBreakdown,
                        categoryItems: categoryBreakdown
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            AppCardTitle(title: "合作金额趋势", symbol: "chart.bar.fill")
                            Spacer()
                            Label("轻点查看 · 左右滑动", systemImage: "hand.draw")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        MonthlyChartView(items: chartItems)
                            .frame(height: 320)
                    }
                    .padding(.vertical, 4)
                    .recordCard()

                    FollowerTrendCard(snapshots: followerSnapshots) {
                        showingFollowerDataEditor = true
                    }
                    .padding(.vertical, 4)
                    .recordCard()

                    if !publishedVideoGroupsForSelectedMonth.isEmpty {
                        ContentPerformanceCard(items: contentPerformanceItems)
                    }
                }
                .padding(.horizontal, AppLayout.editorHorizontalInset)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .navigationTitle("汇总")
            .softPageBackground()
            .onReceive(NotificationCenter.default.publisher(for: .adRecordsDidChange)) { _ in
                refreshToken = UUID()
            }
            .onAppear {
                recompressLargePhotos(context: viewContext)
                cleanupOldPhotos(context: viewContext)
            }
            .sheet(isPresented: $showingFollowerDataEditor) {
                NavigationStack {
                    FollowerDataEditor()
                }
                .environment(\.managedObjectContext, viewContext)
            }
        }
    }
}

struct MonthStats {
    let paid: Double
    let unpaid: Double
    let total: Double
    let unitPrice: Double
    let recordCount: Int
    let billableRecordCount: Int

    init(records: [AdRecord]) {
        paid = records.reduce(0) { $0 + $1.paidValue }
        unpaid = records.reduce(0) { $0 + $1.remainingAmount }
        total = paid + unpaid
        recordCount = records.count
        billableRecordCount = records.count(where: \.needsPayment)
        unitPrice = billableRecordCount == 0 ? 0 : total / Double(billableRecordCount)
    }
}

struct MonthChartItem: Identifiable {
    let id = UUID()
    let month: Date
    let kind: String
    let amount: Double

    var monthLabel: String {
        chineseMonthText(month)
    }
}

struct ContentPerformanceItem: Identifiable {
    let videoName: String
    let likeCount: Int64?
    let publishedDate: Date
    let likeRecordedAt: Date?
    let nextDayFollowerGain: Int64?

    var id: String {
        "\(videoName)-\(publishedDate.timeIntervalSinceReferenceDate)"
    }

    var likeElapsedText: String? {
        guard let likeRecordedAt else { return nil }
        return videoPublishedElapsedText(from: publishedDate, to: likeRecordedAt)
    }
}

private struct CardExpansionButton: View {
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.34, extraBounce: 0)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))

                Text(isExpanded ? "收起" : "展开")
                    .font(.subheadline.weight(.semibold))
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }
            .foregroundStyle(AppTheme.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(AppTheme.primary.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "收起" : "展开")
    }
}

struct ContentPerformanceCard: View {
    let items: [ContentPerformanceItem]

    @State private var isExpanded = false

    private var averageLikes: Int64? {
        averageValue(items.compactMap(\.likeCount))
    }

    private var averageFollowerGain: Int64? {
        averageValue(items.compactMap(\.nextDayFollowerGain))
    }

    private var bestLikeItem: ContentPerformanceItem? {
        items
            .filter { $0.likeCount != nil }
            .max { ($0.likeCount ?? 0) < ($1.likeCount ?? 0) }
    }

    private var bestFollowerItem: ContentPerformanceItem? {
        items
            .filter { $0.nextDayFollowerGain != nil }
            .max { ($0.nextDayFollowerGain ?? .min) < ($1.nextDayFollowerGain ?? .min) }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    AppCardTitle(title: "内容表现", symbol: "heart.text.square.fill")
                    Spacer()
                    Text("本月 \(items.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 18)

                HStack(alignment: .top, spacing: 0) {
                    summaryMetric(
                        title: "平均点赞",
                        symbol: "heart.fill",
                        value: averageLikes.map(contentCountText) ?? "—",
                        tint: averageLikes == nil ? .secondary : .primary
                    )

                    Divider()
                        .frame(height: 70)
                        .padding(.horizontal, 16)

                    summaryMetric(
                        title: "平均次日涨粉",
                        symbol: "person.crop.circle.badge.plus",
                        value: averageFollowerGain.map(signedContentCountText) ?? "—",
                        tint: followerGainTint(averageFollowerGain)
                    )
                }

                if isExpanded {
                    Divider()
                        .padding(.top, 18)

                    expandedAnalysis
                        .padding(.top, 16)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 4)
            .recordCard()

            CardExpansionButton(isExpanded: $isExpanded)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var expandedAnalysis: some View {
        VStack(alignment: .leading, spacing: 22) {
            if items.count > 1,
               bestLikeItem != nil || bestFollowerItem != nil {
                VStack(alignment: .leading, spacing: 0) {
                    Text("本月亮点")
                        .font(.subheadline.weight(.semibold))
                        .padding(.bottom, 6)

                    if let bestLikeItem, let likeCount = bestLikeItem.likeCount {
                        highlightRow(
                            title: "点赞最高",
                            symbol: "heart.fill",
                            item: bestLikeItem,
                            value: contentCountText(likeCount),
                            tint: AppTheme.primary
                        )
                    }

                    if bestLikeItem != nil, bestFollowerItem != nil {
                        Divider()
                            .padding(.leading, 34)
                    }

                    if let bestFollowerItem,
                       let followerGain = bestFollowerItem.nextDayFollowerGain {
                        highlightRow(
                            title: "涨粉最高",
                            symbol: "person.crop.circle.badge.plus",
                            item: bestFollowerItem,
                            value: signedContentCountText(followerGain),
                            tint: followerGainTint(followerGain)
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("视频明细")
                    .font(.subheadline.weight(.semibold))

                VStack(spacing: 0) {
                    ForEach(items) { item in
                        videoPerformanceRow(item)

                        if item.id != items.last?.id {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(
                    Color(uiColor: .tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }

            Label(
                "点赞量取该次发布后的最新记录；次日涨粉仅在发布当天和次日都有粉丝量记录时计算。",
                systemImage: "info.circle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summaryMetric(
        title: String,
        symbol: String,
        value: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(value)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .scaleEffect(isExpanded ? 1.055 : 1, anchor: .leading)
                .animation(.smooth(duration: 0.4, extraBounce: 0), value: isExpanded)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func highlightRow(
        title: String,
        symbol: String,
        item: ContentPerformanceItem,
        value: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.videoName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Text(value)
                .font(.headline)
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
    }

    private func videoPerformanceRow(_ item: ContentPerformanceItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.videoName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(shortDateText(item.publishedDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                detailMetric(
                    title: "点赞量",
                    value: item.likeCount.map(contentCountText) ?? "—",
                    tint: .primary
                )
                detailMetric(
                    title: "次日涨粉",
                    value: item.nextDayFollowerGain.map(signedContentCountText) ?? "—",
                    tint: followerGainTint(item.nextDayFollowerGain)
                )
            }

            if let likeElapsedText = item.likeElapsedText {
                Label(likeElapsedText, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }

    private func detailMetric(
        title: String,
        value: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func followerGainTint(_ value: Int64?) -> Color {
        guard let value else { return .secondary }
        if value > 0 { return SummaryPalette.positive }
        if value < 0 { return SummaryPalette.negative }
        return .secondary
    }

    private func averageValue(_ values: [Int64]) -> Int64? {
        guard !values.isEmpty else { return nil }
        let total = values.reduce(Int64(0), +)
        return Int64((Double(total) / Double(values.count)).rounded())
    }

    private func contentCountText(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func signedContentCountText(_ value: Int64) -> String {
        let prefix = value > 0 ? "+" : ""
        return prefix + contentCountText(value)
    }
}

struct SummaryDashboard: View {
    let businessStats: MonthStats
    let previousBusinessStats: MonthStats
    let partnershipItems: [(type: PartnershipType, count: Int)]
    let categoryItems: [(category: AdCategory, count: Int, amount: Double)]

    @State private var isExpanded = false

    private var comparisonMetrics: [MonthComparisonMetric] {
        [
            MonthComparisonMetric(
                title: "合作金额",
                current: businessStats.total,
                previous: previousBusinessStats.total
            ),
            MonthComparisonMetric(
                title: "合作件数",
                current: Double(businessStats.recordCount),
                previous: Double(previousBusinessStats.recordCount)
            ),
            MonthComparisonMetric(
                title: "平均报价",
                current: businessStats.unitPrice,
                previous: previousBusinessStats.unitPrice
            )
        ]
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            VStack(alignment: .leading, spacing: 14) {
                fixedOverview
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .transaction { transaction in
                        transaction.animation = nil
                    }

                if isExpanded {
                    Divider()

                    detailsContent
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 4)
            .recordCard()

            CardExpansionButton(isExpanded: $isExpanded)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var fixedOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                AppCardTitle(title: "合作概览", symbol: "chart.pie.fill")
                Spacer()
                Text("\(businessStats.recordCount) 件")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(AppTheme.primary.gradient, in: Capsule())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("当月合作金额")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(moneyText(businessStats.total))
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(businessStats.total > 0 ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                    .scaleEffect(isExpanded ? 1.055 : 1, anchor: .leading)
                    .animation(.smooth(duration: 0.4, extraBounce: 0), value: isExpanded)
            }

            PaymentProgressSummary(
                paid: businessStats.paid,
                total: businessStats.total,
                completeTint: SummaryPalette.positive
            )
        }
    }

    private var detailsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    SummaryTile(title: "已回款", value: moneyText(businessStats.paid), symbol: "checkmark.circle.fill", tint: SummaryPalette.positive)
                    SummaryTile(title: "待回款", value: moneyText(businessStats.unpaid), symbol: "clock.fill", tint: SummaryPalette.negative)
                }

                GridRow {
                    SummaryTile(title: "合作件数", value: "\(businessStats.recordCount) 件", symbol: "number.circle.fill", tint: AppTheme.primary)
                    SummaryTile(title: "平均报价", value: moneyText(businessStats.unitPrice), symbol: "tag.fill", tint: .orange)
                }
            }
            .frame(maxWidth: .infinity)

            MonthComparisonView(metrics: comparisonMetrics)

            if !partnershipItems.isEmpty {
                Divider()
                PartnershipDistributionView(items: partnershipItems)
            }

            if !categoryItems.isEmpty {
                Divider()
                CategoryDistributionView(items: categoryItems)
            }
        }
    }
}

struct MonthComparisonMetric: Identifiable {
    let title: String
    let current: Double
    let previous: Double

    var id: String { title }

    var direction: ComparisonDirection {
        guard previous != current else { return .same }
        return current > previous ? .up : .down
    }

    var changeText: String {
        if previous == 0 {
            return current == 0 ? "持平" : "新增"
        }
        let percentage = abs((current - previous) / previous) * 100
        return String(format: "%.0f%%", percentage)
    }
}

enum ComparisonDirection {
    case up
    case down
    case same

    var symbolName: String {
        switch self {
        case .up:
            "arrow.up.right"
        case .down:
            "arrow.down.right"
        case .same:
            "minus"
        }
    }

    var tint: Color {
        switch self {
        case .up:
            SummaryPalette.positive
        case .down:
            SummaryPalette.negative
        case .same:
            .secondary
        }
    }
}

struct MonthComparisonView: View {
    let metrics: [MonthComparisonMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("较上月")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(metric.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Label(metric.changeText, systemImage: metric.direction.symbolName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(metric.direction.tint)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }
}

struct PartnershipDistributionView: View {
    let items: [(type: PartnershipType, count: Int)]

    private var totalCount: Int {
        items.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                AppCardTitle(title: "合作方式", symbol: "person.2.fill")
                Spacer()
                Text("共 \(totalCount) 件")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(items, id: \.type) { item in
                        Rectangle()
                            .fill(item.type.tint.gradient)
                            .frame(width: segmentWidth(for: item.count, totalWidth: proxy.size.width))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            .background(Color.secondary.opacity(0.1), in: Capsule())

            VStack(spacing: 10) {
                ForEach(items, id: \.type) { item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(item.type.tint)
                            .frame(width: 9, height: 9)
                        Label(item.type.rawValue, systemImage: item.type.symbolName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(item.type.tint)
                        Spacer()
                        Text("\(item.count) 件")
                            .font(.subheadline.weight(.semibold))
                        Text(percentageText(for: item.count))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func segmentWidth(for count: Int, totalWidth: CGFloat) -> CGFloat {
        guard totalCount > 0 else { return 0 }
        return totalWidth * CGFloat(count) / CGFloat(totalCount)
    }

    private func percentageText(for count: Int) -> String {
        guard totalCount > 0 else { return "0%" }
        return "\(Int((Double(count) / Double(totalCount) * 100).rounded()))%"
    }
}

struct CategoryDistributionView: View {
    let items: [(category: AdCategory, count: Int, amount: Double)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppCardTitle(title: "品类分布", symbol: "chart.pie.fill")

            ForEach(items, id: \.category) { item in
                HStack(spacing: 10) {
                    CategoryBadge(category: item.category)
                    Spacer()
                    Text("\(item.count) 件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(moneyText(item.amount))
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 70, alignment: .trailing)
                }
            }
        }
    }
}

struct FollowerTrendPoint: Identifiable {
    let id: NSManagedObjectID
    let date: Date
    let count: Int64
}

private let followerThemeColor = AppTheme.primary

struct FollowerTrendCard: View {
    let snapshots: [FollowerSnapshot]
    let addData: () -> Void

    private var points: [FollowerTrendPoint] {
        let allPoints = snapshots.compactMap { snapshot -> FollowerTrendPoint? in
            guard let date = snapshot.date else { return nil }
            return FollowerTrendPoint(
                id: snapshot.objectID,
                date: dayOnly(date),
                count: max(snapshot.followerCount, 0)
            )
        }
        .sorted { $0.date < $1.date }

        guard let latestDate = allPoints.last?.date else { return [] }
        let cutoff = qddCalendar.date(byAdding: .year, value: -1, to: latestDate) ?? Date.distantPast
        return allPoints.filter { $0.date >= cutoff }
    }

    private var latestPoint: FollowerTrendPoint? {
        points.last
    }

    private var monthlyChange: Int64? {
        guard
            let latestPoint,
            let targetDate = qddCalendar.date(byAdding: .month, value: -1, to: latestPoint.date)
        else {
            return nil
        }

        let historicalPoints = points.dropLast()
        guard let baseline = historicalPoints.min(by: { first, second in
            abs(first.date.timeIntervalSince(targetDate)) < abs(second.date.timeIntervalSince(targetDate))
        }) else {
            return nil
        }
        return latestPoint.count - baseline.count
    }

    private var yDomain: ClosedRange<Double> {
        guard let minimum = points.map(\.count).min(), let maximum = points.map(\.count).max() else {
            return 0...1
        }
        let lower = Double(minimum)
        let upper = Double(maximum)
        let span = max(upper - lower, 1)
        let padding = max(span * 0.14, max(upper * 0.01, 10))
        return max(lower - padding, 0)...(upper + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                AppCardTitle(title: "粉丝量", symbol: "person.2.fill")
                Spacer()
                Button(action: addData) {
                    Label("记录", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(followerThemeColor)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(followerThemeColor.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if let latestPoint {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(followerCountText(latestPoint.count))
                        .font(.title.weight(.bold))
                    Text("粉丝")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label(
                        "近一月 \(monthlyChange.map(followerChangeText) ?? "—")",
                        systemImage: monthlyChange.map {
                            $0 > 0 ? "arrow.up.right" : ($0 < 0 ? "arrow.down.right" : "minus")
                        } ?? "minus"
                    )
                    .font(.caption.weight(.bold))
                    .foregroundStyle(monthlyChange.map {
                        $0 > 0 ? SummaryPalette.positive : ($0 < 0 ? SummaryPalette.negative : Color.secondary)
                    } ?? Color.secondary)
                }

                Chart(points) { point in
                    AreaMark(
                        x: .value("日期", point.date),
                        yStart: .value("起点", yDomain.lowerBound),
                        yEnd: .value("粉丝量", Double(point.count))
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [followerThemeColor.opacity(0.22), followerThemeColor.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("日期", point.date),
                        y: .value("粉丝量", Double(point.count))
                    )
                    .foregroundStyle(followerThemeColor)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("日期", point.date),
                        y: .value("粉丝量", Double(point.count))
                    )
                    .foregroundStyle(followerThemeColor)
                    .symbolSize(24)
                }
                .chartYScale(domain: yDomain)
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let count = value.as(Double.self) {
                                Text(compactFollowerCountText(count))
                            }
                        }
                    }
                }
                .frame(height: 210)
            } else {
                Button(action: addData) {
                    VStack(spacing: 9) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.title2)
                        Text("记录第一条粉丝数据")
                            .font(.subheadline.weight(.semibold))
                        Text("以后每次记录都会连成趋势线")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(followerThemeColor)
                    .frame(maxWidth: .infinity, minHeight: 130)
                    .background(followerThemeColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FollowerDataEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \FollowerSnapshot.date, ascending: false)
        ],
        animation: .default
    )
    private var snapshots: FetchedResults<FollowerSnapshot>

    @State private var countText = ""
    @State private var errorMessage: String?
    @State private var editingSnapshot: FollowerSnapshot?

    private var parsedCount: Int64? {
        parseFollowerCount(countText)
    }

    private var snapshotForToday: FollowerSnapshot? {
        snapshots.first { snapshot in
            guard let date = snapshot.date else { return false }
            return qddCalendar.isDateInToday(date)
        }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    FollowerCountInputCard(
                        title: "今天的粉丝量",
                        subtitle: chineseDateText(Date()),
                        countText: $countText,
                        errorMessage: errorMessage
                    )

    Button {
        save()
    } label: {
        Text(snapshotForToday == nil ? "保存今天的数据" : "更新今天的数据")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 48)
            .multilineTextAlignment(.center)
    }
                    .buttonStyle(.borderedProminent)
                    .tint(followerThemeColor)
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
                        HStack {
                            Text(snapshot.date.map(chineseDateText) ?? "日期未知")
                            Spacer()
                            Text(followerCountText(snapshot.followerCount))
                                .fontWeight(.semibold)
                        }
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
                            .tint(followerThemeColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("粉丝量")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(SoftPageBackground())
        .tint(followerThemeColor)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
        .onAppear {
            loadCountForToday()
        }
        .sheet(item: $editingSnapshot) { snapshot in
            NavigationStack {
                FollowerSnapshotEditor(snapshot: snapshot) {
                    loadCountForToday()
                }
            }
            .environment(\.managedObjectContext, viewContext)
        }
    }

    private func loadCountForToday() {
        countText = snapshotForToday.map { String($0.followerCount) } ?? ""
        errorMessage = nil
    }

    private func save() {
        guard let parsedCount else {
            errorMessage = "请输入正确的粉丝数量"
            return
        }

        let isNewSnapshot = snapshotForToday == nil
        let snapshot = snapshotForToday ?? FollowerSnapshot(context: viewContext)
        if isNewSnapshot {
            PersistenceController.shared.prepareNewFollowerSnapshot(snapshot, in: viewContext)
            snapshot.id = UUID()
            snapshot.createdAt = Date()
        }
        snapshot.date = dayOnly(Date())
        snapshot.followerCount = parsedCount
        snapshot.updatedAt = Date()

        do {
            try viewContext.save()
            viewContext.processPendingChanges()
            if isNewSnapshot {
                PersistenceController.shared.shareOwnedFollowerSnapshotIfNeeded(snapshot)
            }
            notifyRecordsChanged()
            dismiss()
        } catch {
            errorMessage = "保存失败，请稍后重试"
            AppLogger.shared.log("保存粉丝数据失败: \(error.localizedDescription)")
        }
    }

    private func deleteSnapshot(_ snapshot: FollowerSnapshot) {
        let deletedToday = snapshot.date.map(qddCalendar.isDateInToday) ?? false
        viewContext.delete(snapshot)
        do {
            try viewContext.save()
            viewContext.processPendingChanges()
            if deletedToday {
                countText = ""
            }
            notifyRecordsChanged()
        } catch {
            errorMessage = "删除失败，请稍后重试"
            AppLogger.shared.log("删除粉丝数据失败: \(error.localizedDescription)")
        }
    }
}

struct FollowerSnapshotEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \FollowerSnapshot.date, ascending: false)
        ],
        animation: .default
    )
    private var snapshots: FetchedResults<FollowerSnapshot>

    @ObservedObject var snapshot: FollowerSnapshot
    let onSaved: () -> Void

    @State private var countText: String
    @State private var selectedDate: Date
    @State private var errorMessage: String?

    init(snapshot: FollowerSnapshot, onSaved: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onSaved = onSaved
        _countText = State(initialValue: String(snapshot.followerCount))
        _selectedDate = State(initialValue: dayOnly(snapshot.date ?? Date()))
    }

    private var parsedCount: Int64? {
        parseFollowerCount(countText)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                FollowerCountInputCard(
                    title: "粉丝量",
                    subtitle: "修改这条历史记录",
                    countText: $countText,
                    errorMessage: errorMessage
                )

                HStack(spacing: 12) {
                    Label("记录日期", systemImage: "calendar")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    DatePicker(
                        "记录日期",
                        selection: $selectedDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                }
                .padding(16)
                .background(CardSurfaceBackground())
            }
            .padding(.horizontal, AppLayout.listHorizontalInset)
            .padding(.top, 28)
            .padding(.bottom, 24)
        }
        .navigationTitle("编辑粉丝量")
        .navigationBarTitleDisplayMode(.inline)
        .background(SoftPageBackground())
        .tint(followerThemeColor)
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
                .disabled(parsedCount == nil)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func save() {
        guard let parsedCount else {
            errorMessage = "请输入正确的粉丝数量"
            return
        }

        let normalizedDate = dayOnly(selectedDate)
        let hasDateConflict = snapshots.contains { item in
            guard item.objectID != snapshot.objectID, let date = item.date else { return false }
            return qddCalendar.isDate(date, inSameDayAs: normalizedDate)
        }
        guard !hasDateConflict else {
            errorMessage = "这个日期已经有一条粉丝记录"
            return
        }

        snapshot.date = normalizedDate
        snapshot.followerCount = parsedCount
        snapshot.updatedAt = Date()

        do {
            try viewContext.save()
            viewContext.processPendingChanges()
            notifyRecordsChanged()
            onSaved()
            dismiss()
        } catch {
            errorMessage = "保存失败，请稍后重试"
            AppLogger.shared.log("更新粉丝数据失败: \(error.localizedDescription)")
        }
    }
}

private struct FollowerCountInputCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String
    @Binding var countText: String
    let errorMessage: String?
    @FocusState private var isCountFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.fill")
                .font(.title2)
                .foregroundStyle(followerThemeColor)
                .frame(width: 48, height: 48)
                .background(followerThemeColor.opacity(0.1), in: Circle())

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("0", text: $countText)
                .font(.system(size: 54, weight: .black, design: .rounded))
                .monospacedDigit()
                .tracking(1.2)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .foregroundStyle(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color.white, Color.white.opacity(0.78)]
                            : [Color.primary, Color.primary.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .tint(followerThemeColor)
                .frame(maxWidth: .infinity, minHeight: 82)
                .scaleEffect(isCountFocused ? 1.025 : 1)
                .shadow(
                    color: followerThemeColor.opacity(isCountFocused ? 0.28 : 0.14),
                    radius: isCountFocused ? 10 : 6,
                    y: 2
                )
                .focused($isCountFocused)
                .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isCountFocused)
                .minimumScaleFactor(0.65)
                .accessibilityLabel("粉丝量")

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(CardSurfaceBackground())
    }
}

private func parseFollowerCount(_ text: String) -> Int64? {
    let normalized = text
        .replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: "，", with: "")
        .replacingOccurrences(of: " ", with: "")
    guard
        !normalized.isEmpty,
        normalized.allSatisfy(\.isNumber),
        let value = Int64(normalized),
        value >= 0
    else {
        return nil
    }
    return value
}

private func followerCountText(_ count: Int64) -> String {
    count.formatted(.number.grouping(.automatic))
}

private func followerChangeText(_ change: Int64) -> String {
    let prefix = change >= 0 ? "+" : "−"
    return prefix + followerCountText(abs(change))
}

private func compactFollowerCountText(_ count: Double) -> String {
    if count >= 10_000 {
        return String(format: "%.1f万", count / 10_000)
    }
    if count >= 1_000 {
        return String(format: "%.1fk", count / 1_000)
    }
    return String(format: "%.0f", count)
}

struct SummaryTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.08), lineWidth: 0.6)
        }
    }
}

struct MonthlyChartView: View {
    let items: [MonthChartItem]

    private var totals: [MonthChartTotal] {
        Dictionary(grouping: items, by: { monthStart($0.month) })
            .map { month, items in
                MonthChartTotal(month: month, amount: items.reduce(0) { $0 + $1.amount })
            }
            .sorted { $0.month < $1.month }
    }

    var body: some View {
        GeometryReader { geometry in
            let visibleCount = min(max(Int((geometry.size.width - 42) / 50), 1), max(totals.count, 1))
            MonthlyAmountChart(items: items, totals: totals, visibleCount: visibleCount)
                .id("\(visibleCount)-\(totals.last?.month.timeIntervalSinceReferenceDate ?? 0)")
        }
    }
}

private struct MonthlyAmountChart: View {
    let items: [MonthChartItem]
    let totals: [MonthChartTotal]
    let visibleCount: Int
    @State private var scrollPosition: Double

    @State private var selectedMonthPosition: Double?

    private let averageColor = AppTheme.primary

    private var selectedMonth: MonthChartTotal? {
        guard let position = selectedMonthPosition, position.isFinite,
              position >= 0, position < Double(totals.count) else { return nil }
        return totals[Int(position.rounded(.down))]
    }

    init(items: [MonthChartItem], totals: [MonthChartTotal], visibleCount: Int) {
        self.items = items
        self.totals = totals
        self.visibleCount = visibleCount
        _scrollPosition = State(initialValue: Double(max(totals.count - visibleCount, 0)))
    }

    private var window: MonthlyAmountWindow {
        MonthlyAmountWindow(totals: totals, scrollPosition: scrollPosition, visibleCount: visibleCount)
    }

    private var rangeText: String {
        guard let first = window.months.first?.month, let last = window.months.last?.month else {
            return "暂无月份数据"
        }
        let formatter = DateFormatter()
        formatter.calendar = qddCalendar
        formatter.timeZone = qddTimeZone
        formatter.dateFormat = "yyyy年M月"
        if first == last { return formatter.string(from: first) }
        return formatter.string(from: first) + "—" + formatter.string(from: last)
    }

    private var upperBound: Double {
        max((totals.map(\.amount).max() ?? 0) * 1.18, 1)
    }

    private func xPosition(for month: Date) -> Double {
        Double(totals.firstIndex { $0.month == monthStart(month) } ?? 0) + 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            averageSummary
            amountChart
            chartLegend
        }
        .background {
            ChartSelectionDismissObserver(selection: $selectedMonthPosition)
        }
        .onDisappear { selectedMonthPosition = nil }

    }

    private var averageSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(selectedMonth.map { chineseMonthText($0.month) + "合作金额" } ?? "平均每月合作金额")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text((selectedMonth?.amount ?? window.average).map(moneyText) ?? "—")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(rangeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var amountChart: some View {
        Chart {
            amountBars
            averageRule
        }
        .chartForegroundStyleScale([
            "已回款": SummaryPalette.positive,
            "待回款": SummaryPalette.negative
        ])
        .chartLegend(.hidden)
        .chartYScale(domain: 0...upperBound)
        // Equal month slots prevent 28/30/31-day months from shifting the visible range.
        .chartXScale(
            domain: 0...Double(max(totals.count, 1)),
            range: .plotDimension(startPadding: 0, endPadding: 0)
        )
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: Double(visibleCount))
        .chartScrollPosition(x: $scrollPosition)
        .chartScrollTargetBehavior(.valueAligned(unit: 1))
        .chartXSelection(value: $selectedMonthPosition)
        .chartGesture { proxy in
            SpatialTapGesture()
                .onEnded { value in
                    if selectedMonthPosition != nil {
                        selectedMonthPosition = nil
                    } else {
                        proxy.selectXValue(at: value.location.x)
                    }
                }
        }
        .onChange(of: scrollPosition) { _, _ in
            selectedMonthPosition = nil
        }
        .chartXAxis {
            AxisMarks(values: totals.indices.map { Double($0) + 0.5 }) { value in
                AxisValueLabel(centered: false, anchor: .top, collisionResolution: .disabled) {
                    if let position = value.as(Double.self) {
                        let index = Int(position)
                        if totals.indices.contains(index) {
                            Text(chineseMonthText(totals[index].month))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel()
            }
        }
    }

    @ChartContentBuilder
    private var amountBars: some ChartContent {
        ForEach(items) { item in
            BarMark(
                x: .value("月份", xPosition(for: item.month)),
                y: .value("合作金额", item.amount),
                width: .fixed(22)
            )
            .foregroundStyle(by: .value("状态", item.kind))
            .opacity(selectedMonth == nil || selectedMonth?.month == monthStart(item.month) ? 0.8 : 0.35)
            .cornerRadius(4)
            .accessibilityLabel("\(chineseMonthText(item.month))\(item.kind)")
            .accessibilityValue(moneyText(item.amount))
        }
    }

    @ChartContentBuilder
    private var averageRule: some ChartContent {
        if let average = window.average {
            RuleMark(
                xStart: .value("范围起点", max(scrollPosition, 0) + 0.04),
                xEnd: .value("范围终点", min(scrollPosition + Double(visibleCount), Double(totals.count)) - 0.04),
                y: .value("平均每月合作金额", average)
            )
            .foregroundStyle(averageColor)
            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
            .accessibilityLabel("平均每月合作金额")
            .accessibilityValue(moneyText(average))
        }
    }

    private var chartLegend: some View {
        HStack(spacing: 16) {
            legendItem("已回款", color: SummaryPalette.positive)
            legendItem("待回款", color: SummaryPalette.negative)
            HStack(spacing: 5) {
                Capsule().fill(averageColor).frame(width: 16, height: 3)
                Text("月均金额")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color.opacity(0.8)).frame(width: 7, height: 7)
            Text(title)
        }
    }
}

struct MonthSelector: View {
    @Binding var selectedMonth: Date
    @State private var showingMonthPicker = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                moveMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.borderless)

            Spacer()

            Button {
                showingMonthPicker = true
            } label: {
                HStack(spacing: 6) {
                    Text(monthTitle(selectedMonth))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(AppTheme.primary)
                .padding(.horizontal, 16)
                .frame(minHeight: 38)
                .background(AppTheme.primary.opacity(0.1), in: Capsule())
                .contentTransition(.numericText())
            }
            .buttonStyle(.borderless)

            Spacer()

            Button {
                moveMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(uiColor: .systemBackground).opacity(0.72), in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .sheet(isPresented: $showingMonthPicker) {
            NavigationStack {
                MonthPickerView(selectedMonth: $selectedMonth)
            }
            .presentationDetents([.medium])
        }
    }

    private func moveMonth(by value: Int) {
        if let newMonth = qddCalendar.date(byAdding: .month, value: value, to: selectedMonth) {
            selectedMonth = newMonth
        }
    }
}

struct MonthPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedMonth: Date

    @State private var year: Int

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    init(selectedMonth: Binding<Date>) {
        _selectedMonth = selectedMonth
        _year = State(initialValue: qddCalendar.component(.year, from: selectedMonth.wrappedValue))
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Button {
                        year -= 1
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Text(verbatim: "\(year)年")
                        .font(.title3.weight(.bold))
                        .contentTransition(.numericText())

                    Spacer()

                    Button {
                        year += 1
                    } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .listRowBackground(Color.clear)

            Section {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(1...12, id: \.self) { month in
                        Button {
                            selectMonth(month)
                        } label: {
                            Text("\(month)月")
                                .font(.headline)
                                .foregroundStyle(isSelected(month) ? .white : .primary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSelected(month) ? AppTheme.primary : Color(uiColor: .tertiarySystemFill))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("选择月份")
        .navigationBarTitleDisplayMode(.inline)
        .softPageBackground()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("本月") {
                    selectedMonth = monthStart(Date())
                    dismiss()
                }
            }
        }
    }

    private func isSelected(_ month: Int) -> Bool {
        let components = qddCalendar.dateComponents([.year, .month], from: selectedMonth)
        return components.year == year && components.month == month
    }

    private func selectMonth(_ month: Int) {
        selectedMonth = qddCalendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? selectedMonth
        dismiss()
    }
}
