//
//  SharedComponents.swift
//  钱多多
//

import SwiftUI
import UIKit

enum AppTheme {
    // #8B5E3C · RGB(139, 94, 60)
    static let primary = Color(
        red: 139.0 / 255.0,
        green: 94.0 / 255.0,
        blue: 60.0 / 255.0
    )

    // 合作方式采用统一的中等饱和度，保持辨识度但不压过主题色。
    static let consignment = Color(
        red: 67.0 / 255.0,
        green: 138.0 / 255.0,
        blue: 200.0 / 255.0
    )
    static let giftedShoot = Color(
        red: 77.0 / 255.0,
        green: 182.0 / 255.0,
        blue: 109.0 / 255.0
    )
    static let exchange = Color(
        red: 164.0 / 255.0,
        green: 108.0 / 255.0,
        blue: 203.0 / 255.0
    )

    static let primaryUIColor = UIColor(
        red: 139.0 / 255.0,
        green: 94.0 / 255.0,
        blue: 60.0 / 255.0,
        alpha: 1
    )
}

enum AppLayout {
    static let listHorizontalInset: CGFloat = 4
    static let editorHorizontalInset: CGFloat = 16
    static let cardCornerRadius: CGFloat = 16
    static let cardContentPadding: CGFloat = 14

    static func listRowInsets(top: CGFloat = 8, bottom: CGFloat = 8) -> EdgeInsets {
        EdgeInsets(top: top, leading: listHorizontalInset, bottom: bottom, trailing: listHorizontalInset)
    }
}

private struct DismissibleKeyboardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        dismissKeyboard()
                    }
                }
            }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

extension View {
    func dismissibleKeyboard() -> some View {
        modifier(DismissibleKeyboardModifier())
    }
}

struct SoftPageBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        (colorScheme == .dark ? Color.black : Color.white)
            .ignoresSafeArea()
    }
}

struct CardSurfaceBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius, style: .continuous)
            .fill(cardFill)
            .shadow(
                color: cardShadow,
                radius: colorScheme == .dark ? 10 : 8,
                x: 0,
                y: colorScheme == .dark ? 5 : 3
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius, style: .continuous)
                    .stroke(cardStroke, lineWidth: 1)
            }
    }

    private var cardFill: Color {
        colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground).opacity(0.88)
            : Color(uiColor: .systemBackground).opacity(0.98)
    }

    private var cardStroke: Color {
        AppTheme.primary.opacity(colorScheme == .dark ? 0.2 : 0.08)
    }

    private var cardShadow: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.42)
            : Color.black.opacity(0.07)
    }
}

struct AppCardTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primary)
                .frame(width: 20)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }
}

extension View {
    func softPageBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(SoftPageBackground())
            .dismissibleKeyboard()
    }

    func recordCard() -> some View {
        padding(AppLayout.cardContentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardSurfaceBackground())
    }

    func floatingCardRow() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(AppLayout.listRowInsets())
    }

    func wideListRow(top: CGFloat = 8, bottom: CGFloat = 8) -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(AppLayout.listRowInsets(top: top, bottom: bottom))
    }

}

struct PaymentProgressSummary: View {
    let paid: Double
    let total: Double
    var height: CGFloat = 8
    var completeTint: Color = .green

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(max(paid / total, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("打款进度")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(progress >= 1 ? completeTint : AppTheme.primary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill((progress >= 1 ? completeTint : AppTheme.primary).gradient)
                        .frame(width: proxy.size.width * CGFloat(progress))
                }
            }
            .frame(height: height)
            .clipShape(Capsule())
        }
    }
}

struct DateSquare: View {
    let date: Date?
    var tint: Color = AppTheme.primary

    var body: some View {
        VStack(spacing: 2) {
            if let date {
                Text(chineseDayText(date))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text(chineseMonthText(date))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: 54, height: 54)
        .background(
            LinearGradient(
                colors: [tint, tint.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .shadow(color: tint.opacity(0.2), radius: 4, x: 0, y: 2)
    }
}

struct LookChip: View {
    let lookNumber: Int16

    private var isLookOne: Bool { lookNumber == 1 }

    var body: some View {
        Text(lookNumber > 0 ? "LOOK \(lookNumber)" : "随机")
            .font(.caption2.weight(.bold))
            .foregroundStyle(isLookOne ? AppTheme.primary : .secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background((isLookOne ? AppTheme.primary : Color.secondary).opacity(0.12), in: Capsule())
    }
}

struct ScheduledBadge: View {
    var body: some View {
        Text("已排期")
            .font(.caption2.weight(.bold))
            .foregroundStyle(AppTheme.primary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppTheme.primary.opacity(0.12), in: Capsule())
    }
}

struct CategoryBadge: View {
    let category: AdCategory

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: category.symbolName)
            Text(category.rawValue)
        }
            .font(.caption.weight(.bold))
            .foregroundStyle(category.tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(category.tint.opacity(0.12), in: Capsule())
    }
}

struct PartnershipBadge: View {
    let type: PartnershipType

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: type.symbolName)
            Text(type.rawValue)
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(type.tint)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(type.tint.opacity(0.12), in: Capsule())
    }
}

struct RemarkChip: View {
    let note: String?

    var body: some View {
        if let text = note?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "note.text")
                Text(text)
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.orange)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.orange.opacity(0.12), in: Capsule())
        }
    }
}
