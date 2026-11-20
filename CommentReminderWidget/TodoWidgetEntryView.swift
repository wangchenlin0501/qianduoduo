import AppIntents
import SwiftUI
import WidgetKit

enum TodoWidgetSize {
    case small
    case medium
    case large
}

/// Kept independent of UIKit and Core Data so the same layout can be rendered for design previews.
struct TodoWidgetEntryView: View {
    let snapshot: TodoWidgetSnapshot
    let size: TodoWidgetSize
    var referenceDate: Date = .now

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var circleSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) private var titleSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2) private var detailSize: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var footerSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var rowScale: CGFloat = 1

    private var accent: Color {
        Color(todoWidgetHex: colorScheme == .dark ? snapshot.darkAccentHex : snapshot.lightAccentHex)
    }

    private var columnCount: Int {
        size == .small || dynamicTypeSize.isAccessibilitySize ? 1 : 2
    }

    private var compactAccessibility: Bool {
        size != .large && dynamicTypeSize >= .accessibility3
    }

    private var rowsPerColumn: Int {
        let standard: Int
        if dynamicTypeSize.isAccessibilitySize {
            standard = size == .large ? (dynamicTypeSize >= .accessibility3 ? 2 : 3) : 1
        } else if dynamicTypeSize >= .xxxLarge {
            standard = size == .large ? 5 : (size == .small ? 2 : 1)
        } else if dynamicTypeSize >= .xxLarge {
            standard = size == .large ? 6 : 2
        } else if dynamicTypeSize > .large {
            standard = size == .large ? 6 : (size == .small ? 3 : 2)
        } else {
            standard = size == .large ? 8 : (size == .small ? 4 : 3)
        }
        return actionMessage == nil ? standard : max(1, standard - 1)
    }

    private var rowHeight: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 0 }
        let base: CGFloat = size == .small ? 22 : (size == .medium ? 30 : 32)
        return base * rowScale
    }

    private var rowSpacing: CGFloat {
        let base: CGFloat = size == .small ? 3 : (size == .medium ? 4 : 5)
        return base * rowScale
    }

    private var visibleItems: [TodoWidgetSnapshot.Item] { Array(snapshot.items.prefix(rowsPerColumn * columnCount)) }
    private var remainingCount: Int { max(0, snapshot.pendingCount - visibleItems.count) }
    private var actionMessage: String? {
        guard let message = snapshot.actionMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return nil }
        return message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, size == .small ? 4 : 5)

            if snapshot.status == .unavailable || (snapshot.pendingCount > 0 && visibleItems.isEmpty) {
                statusMessage(
                    icon: "arrow.clockwise",
                    title: "待办暂未更新",
                    detail: actionMessage ?? "轻点打开 App 后再试"
                )
            } else if snapshot.pendingCount == 0 {
                statusMessage(
                    icon: "checkmark.circle",
                    title: "没有未完成待办",
                    detail: "轻点打开，添加新事项"
                )
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        VStack(alignment: .leading, spacing: rowSpacing) {
                            ForEach(items(in: column)) { item in
                                itemRow(item)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityElement(children: .contain)

                Spacer(minLength: 0)

                if let actionMessage {
                    Text(actionMessage)
                        .font(.system(size: footerSize))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .padding(.top, 2)
                } else if remainingCount > 0 && !compactAccessibility {
                    Text("还有 \(remainingCount) 项")
                        .font(.system(size: footerSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                        .accessibilityLabel("还有 \(remainingCount) 项未完成待办，轻点在 App 中查看")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(accent)
    }

    private func items(in column: Int) -> [TodoWidgetSnapshot.Item] {
        Array(visibleItems.dropFirst(column * rowsPerColumn).prefix(rowsPerColumn))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("ToDo List")
                .font(compactAccessibility ? .caption2.weight(.bold) : .subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if snapshot.status == .ready {
                Text(snapshot.pendingCount, format: .number)
                    .font(compactAccessibility ? .caption2.weight(.bold) : .subheadline.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel("\(snapshot.pendingCount) 项未完成，还有 \(remainingCount) 项未显示")
            }
        }
        .foregroundStyle(accent)
    }

    private func itemRow(_ item: TodoWidgetSnapshot.Item) -> some View {
        HStack(alignment: .top, spacing: 6) {
            completionControl(item)

            Link(destination: TodoWidgetSnapshot.destinationURL) {
                rowText(item)
                    .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .topLeading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(itemAccessibilityLabel(item))
            .accessibilityHint("打开 App 的 ToDo List 页面")
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func completionControl(_ item: TodoWidgetSnapshot.Item) -> some View {
        if item.canComplete, let recordURI = item.recordURI, let spaceURI = snapshot.spaceURI {
            Button(intent: CompleteTodoIntent(recordURI: recordURI, spaceURI: spaceURI)) {
                completionCircle
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成\(item.title)")
            .accessibilityHint("仅标记这项待办完成")
        } else {
            Link(destination: TodoWidgetSnapshot.destinationURL) {
                completionCircle
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看\(item.title)")
            .accessibilityHint("当前待办只可查看，打开 App 的 ToDo List 页面")
        }
    }

    private func rowText(_ item: TodoWidgetSnapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.title)
                .font(.system(size: titleSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .invalidatableContent()

            if size != .small && !compactAccessibility {
                itemDetail(item)
            }
        }
    }

    private func itemAccessibilityLabel(_ item: TodoWidgetSnapshot.Item) -> String {
        ([item.title, item.dueDate.map(dateLabel), item.linkedContentTitle].compactMap { $0 }).joined(separator: "，")
    }

    private var completionCircle: some View {
        Image(systemName: "circle")
            .font(.system(size: circleSize, weight: .regular))
            .foregroundStyle(accent)
            .frame(width: circleSize + 6, height: circleSize + 6)
            .contentShape(.interaction, Circle())
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func itemDetail(_ item: TodoWidgetSnapshot.Item) -> some View {
        let linkedContent = item.linkedContentTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if item.dueDate != nil || !linkedContent.isEmpty {
            HStack(spacing: 4) {
                if let date = item.dueDate {
                    Label(dateLabel(date), systemImage: "calendar")
                        .foregroundStyle(accent)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if !linkedContent.isEmpty {
                    Text(linkedContent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: detailSize))
            .lineLimit(1)
        }
    }

    private func dateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: referenceDate)
        let distance = calendar.dateComponents([.day], from: today, to: day).day
        let label: String
        switch distance {
        case 0: label = "今天"
        case 1: label = "明天"
        case -1: label = "昨天"
        default: label = date.formatted(.dateTime.month().day())
        }
        return day < today ? "已过期 · \(label)" : label
    }

    private func statusMessage(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.title2.weight(.regular))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension Color {
    init(todoWidgetHex hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt64(digits, radix: 16) else {
            self = .primary
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
