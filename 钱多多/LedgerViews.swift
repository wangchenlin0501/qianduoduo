//
//  LedgerViews.swift
//  钱多多
//

import CoreData
import SwiftUI

struct LedgerPage: View {
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
    @State private var filter: LedgerFilter = .all
    @State private var sortOption: LedgerSortOption = .dateNewest
    @State private var selectedMonth = Date()
    @AppStorage(demoDataHiddenKey) private var isDemoDataHidden = false

    private var records: [AdRecord] {
        _ = refreshToken
        guard !isDemoDataHidden else { return [] }
        return Array(allRecords)
    }

    private var monthLedgerRecords: [AdRecord] {
        records
            .filter(\.isInLedger)
            .filter { record in
                qddCalendar.isDate(record.reportDate, equalTo: selectedMonth, toGranularity: .month)
            }
    }

    private var ledgerRecords: [AdRecord] {
        monthLedgerRecords
            .filter { record in
                switch filter {
                case .all:
                    true
                case .unpaid:
                    record.needsPayment && record.statusValue == .unpaid
                case .paid:
                    record.statusValue == .paid
                }
            }
            .filter { record in
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                return query.isEmpty || record.searchableText.localizedCaseInsensitiveContains(query)
            }
            .sorted(by: sortOption.areInIncreasingOrder)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MonthSelector(selectedMonth: $selectedMonth)
                }
                .wideListRow()

                Section {
                    LedgerSummaryStrip(records: monthLedgerRecords)
                }
                .wideListRow()

                Section("记录") {
                    if ledgerRecords.isEmpty {
                        ContentUnavailableView("没有记录", systemImage: "list.clipboard", description: Text("视频发布后会出现在这里"))
                    } else {
                        ForEach(ledgerRecords, id: \.objectID) { record in
                            ZStack {
                                NavigationLink {
                                    AdRecordEditor(record: record)
                                } label: {
                                    EmptyView()
                                }
                                .opacity(0)

                                LedgerRecordRow(record: record)
                                    .recordCard()
                            }
                            .floatingCardRow()
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteLedgerRecord(record)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete(perform: deleteLedgerRecords)
                    }
                }
            }
            .navigationTitle("账本")
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .softPageBackground()
            .searchable(text: $searchText, prompt: "搜索品牌、微信、视频")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        filter = filter == .unpaid ? .all : .unpaid
                    } label: {
                        LedgerFilterButton(isUnpaid: filter == .unpaid)
                    }
                    .buttonStyle(.plain)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(LedgerSortOption.allCases) { option in
                            Button {
                                sortOption = option
                            } label: {
                                Label(option.rawValue, systemImage: sortOption == option ? "checkmark" : option.symbolName)
                            }
                        }
                    } label: {
                        LedgerSortButton(sortOption: sortOption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .adRecordsDidChange)) { _ in
                refreshToken = UUID()
            }
        }
    }

    private func deleteLedgerRecords(offsets: IndexSet) {
        offsets.map { ledgerRecords[$0] }.forEach(deleteLedgerRecord)
    }

    private func deleteLedgerRecord(_ record: AdRecord) {
        withAnimation {
            viewContext.delete(record)
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

struct LedgerRecordRow: View {
    @ObservedObject var record: AdRecord

    var body: some View {
        HStack(spacing: 14) {
            DateSquare(date: record.reportDate, tint: record.statusValue == .paid ? AppTheme.primary : ledgerDateTint(for: record.reportDate))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(record.titleText)
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                        .layoutPriority(1)
                    LookChip(lookNumber: record.lookNumber)
                }
                Label(record.contactWeChat.nonEmptyOr("未填微信"), systemImage: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !record.videoTitle.nonEmptyOr("").isEmpty {
                    Label(record.videoTitle.nonEmptyOr(""), systemImage: "play.rectangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            LedgerAmountColumn(record: record)
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button {
                UIPasteboard.general.string = record.ledgerCopyText
            } label: {
                Label("复制品牌和微信", systemImage: "doc.on.doc")
            }
        }
    }
}

struct LedgerAmountColumn: View {
    @ObservedObject var record: AdRecord

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if record.needsPayment {
                Text(record.amountColumnText)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(record.statusValue.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                PaymentPill(record: record)
            } else {
                Color.clear
                    .frame(height: 30)
            }
        }
        .frame(width: 92, alignment: .trailing)
    }
}

struct LedgerFilterButton: View {
    let isUnpaid: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isUnpaid ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            Text(isUnpaid ? "未打款" : "全部")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isUnpaid ? Color.red : Color.primary)
        .frame(minWidth: 86, minHeight: 44)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
    }
}

struct LedgerSortButton: View {
    let sortOption: LedgerSortOption

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.arrow.down")
            Text(sortOption.rawValue)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.primary)
        .frame(minHeight: 44)
        .lineLimit(1)
        .minimumScaleFactor(0.76)
        .contentShape(Rectangle())
    }
}

struct LedgerSummaryStrip: View {
    let records: [AdRecord]

    private var stats: MonthStats {
        MonthStats(records: records)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppCardTitle(title: "本月账本", symbol: "list.clipboard.fill")
            PaymentProgressSummary(paid: stats.paid, total: stats.total)

            HStack(spacing: 8) {
                CompactSummaryTile(title: "合计", value: moneyText(stats.total), tint: .secondary)
                CompactSummaryTile(title: "已到账", value: moneyText(stats.paid), tint: .green)
                CompactSummaryTile(title: "未打款", value: moneyText(stats.unpaid), tint: .red)
            }
        }
        .recordCard()
    }
}

struct CompactSummaryTile: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(tint == .secondary ? .primary : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint == .secondary ? Color(uiColor: .tertiarySystemFill) : tint.opacity(0.08))
        )
    }
}
