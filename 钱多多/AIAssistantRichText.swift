//
//  AIAssistantRichText.swift
//  钱多多
//

import CoreData
import SwiftUI

struct AIMarkdownText: View {
    let text: String

    private enum Block: Hashable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                result.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                result.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(value):
                    let parts = Self.splitBadge(value)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        inline(parts.title)
                            .font(.system(size: 18, weight: .bold))
                        Spacer(minLength: 4)
                        if let badge = parts.badge {
                            Text(badge)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.16), in: Capsule())
                        }
                    }
                    .padding(.top, 6)
                case let .bullet(value):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(AppTheme.primary.opacity(0.7))
                            .frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        inline(value)
                    }
                case let .paragraph(value):
                    inline(value)
                        .lineSpacing(3)
                }
            }
        }
        .textSelection(.enabled)
    }

    private static func splitBadge(_ value: String) -> (title: String, badge: String?) {
        guard let open = value.range(of: "{{"), let close = value.range(of: "}}", range: open.upperBound..<value.endIndex) else {
            return (value, nil)
        }
        let badge = String(value[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        let title = (String(value[..<open.lowerBound]) + String(value[close.upperBound...])).trimmingCharacters(in: .whitespaces)
        return (title, badge.isEmpty ? nil : badge)
    }

    private func inline(_ value: String) -> Text {
        let value = value.replacingOccurrences(of: "{{", with: "").replacingOccurrences(of: "}}", with: "")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: value, options: options) {
            return Text(attributed)
        }
        return Text(value)
    }
}

struct AIRecordCardView: View {
    let card: AIRecordCard
    var isBusy = false
    var onMakeVideo: (([String], String, Date?) -> Void)? = nil
    @State private var expanded = false
    @State private var order: [AIRecordCard.Row] = []
    @State private var selected: Set<String> = []
    @State private var showingVideoSheet = false
    @State private var editingRecord: AdRecord?
    @State private var showingAbandoned = false
    @Environment(\.managedObjectContext) private var viewContext

    private var rows: [AIRecordCard.Row] { order.isEmpty ? card.rows : order }
    private var selectable: Bool { onMakeVideo != nil && card.rows.contains { $0.canSchedule } }

    private let collapsedCount = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.headline)
                if let subtitle = card.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            let visible = expanded ? rows : Array(rows.prefix(collapsedCount))
            ForEach(visible) { row in
                Divider().padding(.leading, 14)
                selectableRow(row)
            }

            if card.rows.count > collapsedCount {
                Divider()
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Text(expanded ? "收起" : "展开全部 \(card.rows.count) 条")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.primary)
            }

            if !card.abandoned.isEmpty {
                Divider()
                Button {
                    showingAbandoned = true
                } label: {
                    Text("已放弃 \(card.abandoned.count) 条")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.plain)
            }

            if selectable {
                Divider()
                Button {
                    showingVideoSheet = true
                } label: {
                    Label(selected.isEmpty ? "点选记录，生成新视频" : "用选中的 \(selected.count) 条生成视频", systemImage: "film.stack")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected.isEmpty || isBusy ? Color.secondary : AppTheme.primary)
                .disabled(selected.isEmpty || isBusy)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if order.isEmpty { order = card.rows } }
        .sheet(item: $editingRecord) { record in
            NavigationStack { AdRecordEditor(record: record) }
        }
        .sheet(isPresented: $showingAbandoned) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(card.abandoned) { row in
                            Divider().padding(.leading, 14)
                            rowView(row)
                                .contentShape(Rectangle())
                                .onTapGesture { openEditor(row) }
                        }
                    }
                }
                .navigationTitle("已放弃")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showingAbandoned = false }
                    }
                }
                .sheet(item: $editingRecord) { record in
                    NavigationStack { AdRecordEditor(record: record) }
                }
            }
        }
        .sheet(isPresented: $showingVideoSheet) {
            AIMakeVideoSheet(
                defaultTitle: suggestedTitle,
                rows: rows.filter { selected.contains($0.ref) }
            ) { title, date in
                showingVideoSheet = false
                onMakeVideo?(rows.filter { selected.contains($0.ref) }.map(\.ref), title, date)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var suggestedTitle: String {
        var title = card.title
        for prefix in ["推荐：", "推荐:", "推荐"] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
            break
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    @ViewBuilder
    private func selectableRow(_ row: AIRecordCard.Row) -> some View {
        if selectable {
            HStack(spacing: 0) {
                Image(systemName: selected.contains(row.ref) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(row.canSchedule ? (selected.contains(row.ref) ? AppTheme.primary : Color.secondary) : Color.secondary.opacity(0.3))
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard row.canSchedule else { return }
                        if selected.contains(row.ref) { selected.remove(row.ref) } else { selected.insert(row.ref) }
                    }
                rowView(row)
                    .contentShape(Rectangle())
                    .onTapGesture { openEditor(row) }
            }
            .draggable(row.ref)
            .dropDestination(for: String.self) { items, _ in
                guard let ref = items.first, ref != row.ref,
                      let from = order.firstIndex(where: { $0.ref == ref }),
                      let to = order.firstIndex(where: { $0.ref == row.ref }) else { return false }
                withAnimation(.snappy) {
                    let moved = order.remove(at: from)
                    order.insert(moved, at: to)
                }
                return true
            }
        } else {
            rowView(row)
                .contentShape(Rectangle())
                .onTapGesture { openEditor(row) }
        }
    }

    private func openEditor(_ row: AIRecordCard.Row) {
        guard let objectID = row.objectID,
              let record = try? viewContext.existingObject(with: objectID) as? AdRecord else { return }
        editingRecord = record
    }

    private func rowView(_ row: AIRecordCard.Row) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(urgencyColor(row.urgency))
                .frame(width: 3)
            if let photo = row.photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let tag = row.tag {
                        Text(tag.rawValue)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(tag.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tag.tint.opacity(0.15), in: Capsule())
                    }
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(row.urgency >= 2 ? Color.red : Color.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(row.amount)
                .font(.subheadline.weight(.bold).monospacedDigit())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func urgencyColor(_ urgency: Int) -> Color {
        switch urgency {
        case 2: return .red
        case 1: return .orange
        default: return .clear
        }
    }
}

private struct AIMakeVideoSheet: View {
    let rows: [AIRecordCard.Row]
    let onDone: (String, Date?) -> Void
    @State private var title: String
    @State private var hasDate = false
    @State private var date = Date()

    init(defaultTitle: String, rows: [AIRecordCard.Row], onDone: @escaping (String, Date?) -> Void) {
        self.rows = rows
        self.onDone = onDone
        _title = State(initialValue: defaultTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("视频标题") {
                    TextField("比如：秋冬裤子合集", text: $title)
                }
                Section {
                    Toggle("定排期日期", isOn: $hasDate)
                    if hasDate {
                        DatePicker("日期", selection: $date, displayedComponents: .date)
                    }
                }
                Section("按这个顺序排进视频") {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Text("\(index + 1). \(row.title)")
                    }
                }
            }
            .navigationTitle("生成新视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("下一步") {
                        onDone(title.trimmingCharacters(in: .whitespacesAndNewlines), hasDate ? date : nil)
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
