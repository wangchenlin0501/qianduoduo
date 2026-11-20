//
//  SharedComponents.swift
//  钱多多
//

import SwiftUI
import UIKit

enum AppTheme {
    static var primary: Color { AppThemeSettings.shared.color.swiftUIColor }
    static var primaryUIColor: UIColor { AppThemeSettings.shared.color.uiColor }
    static var onPrimary: Color { AppThemeSettings.shared.color.foregroundColor }
    static var onPrimaryUIColor: UIColor { AppThemeSettings.shared.color.prefersWhiteForeground ? .white : .black }

    static var readablePrimary: Color { Color(uiColor: readablePrimaryUIColor) }
    static var readablePrimaryUIColor: UIColor {
        let color = AppThemeSettings.shared.color
        return UIColor { traits in color.readableTint(onDarkBackground: traits.userInterfaceStyle == .dark).uiColor }
    }

    static func foreground(on color: Color) -> Color {
        AppThemeColor(uiColor: UIColor(color))?.foregroundColor ?? .white
    }

    static func readable(_ color: Color) -> Color {
        let source = UIColor(color)
        return Color(uiColor: UIColor { traits in
            let resolved = source.resolvedColor(with: traits)
            return AppThemeColor(uiColor: resolved)?
                .readableTint(onDarkBackground: traits.userInterfaceStyle == .dark).uiColor ?? resolved
        })
    }

    // 状态色：全 App 统一直接使用，不再经 readable() 压暗。
    // 浅色 #DC2626 / #F59E0B / #16A34A，深色用同色系亮一档的 #F87171 / #FBBF24 / #4ADE80。
    static let danger = adaptive(light: (220, 38, 38), dark: (248, 113, 113))
    static let warning = adaptive(light: (245, 158, 11), dark: (251, 191, 36))
    static let success = adaptive(light: (22, 163, 74), dark: (74, 222, 128))

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1)
        })
    }

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
}

enum AppLayout {
    static let listHorizontalInset: CGFloat = 4
    static let editorHorizontalInset: CGFloat = 16
    // Main pages share the ledger's 16 pt list margin plus its 4 pt row inset.
    static let homePageHorizontalInset: CGFloat = 20
    static var homeListContentMargin: CGFloat { homePageHorizontalInset - listHorizontalInset }
    static let homePageTopInset: CGFloat = 8
    // The ledger has two 8 pt row insets and a 12 pt compact section gap.
    static let homeMonthSelectorContentSpacing: CGFloat = 28
    static let monthSelectorMinimumHeight: CGFloat = 50
    static let cardCornerRadius: CGFloat = 20
    static let insetCornerRadius: CGFloat = 16
    static let controlCornerRadius: CGFloat = 14
    static let compactControlCornerRadius: CGFloat = 12
    static let thumbnailCornerRadius: CGFloat = 10
    static let cardContentPadding: CGFloat = 14
    // Keep the light shadow inside the space around list cards.
    static let lightCardShadowRadius: CGFloat = 3
    static let lightCardShadowOffset: CGFloat = 1
    static let lightCardShadowOpacity = 0.045

    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    static func listRowInsets(top: CGFloat = 8, bottom: CGFloat = 8) -> EdgeInsets {
        EdgeInsets(top: top, leading: listHorizontalInset, bottom: bottom, trailing: listHorizontalInset)
    }
}

extension View {
    func dismissibleKeyboard() -> some View {
        scrollDismissesKeyboard(.interactively)
    }
}

struct SoftPageBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        (colorScheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
            .ignoresSafeArea()
    }
}

struct CardSurfaceBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = AppLayout.cardShape
        shape
            .fill(cardFill)
            .shadow(
                color: cardShadow,
                radius: colorScheme == .dark ? 10 : AppLayout.lightCardShadowRadius,
                x: 0,
                y: colorScheme == .dark ? 5 : AppLayout.lightCardShadowOffset
            )
            .overlay {
                shape.strokeBorder(cardStroke, lineWidth: 1)
            }
    }

    private var cardFill: Color {
        colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground).opacity(0.88)
            : Color(uiColor: .systemBackground)
    }

    private var cardStroke: Color {
        colorScheme == .dark ? AppTheme.readablePrimary.opacity(0.2) : .clear
    }

    private var cardShadow: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.42)
            : Color.black.opacity(AppLayout.lightCardShadowOpacity)
    }
}

struct AppCardTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.readablePrimary)
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
    var completeTint: Color = AppTheme.success

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
                    .foregroundStyle(progress >= 1 ? completeTint : AppTheme.readablePrimary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill((progress >= 1 ? completeTint : AppTheme.readablePrimary).gradient)
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
                    .foregroundStyle(AppTheme.foreground(on: tint))
                Text(chineseMonthText(date))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.foreground(on: tint).opacity(0.85))
            }
        }
        .frame(width: 54, height: 54)
        .background(
            LinearGradient(
                colors: [tint, tint.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: AppLayout.controlCornerRadius, style: .continuous)
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
            .foregroundStyle(isLookOne ? AppTheme.readablePrimary : .secondary)
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
            .foregroundStyle(AppTheme.readablePrimary)
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
            .foregroundStyle(AppTheme.readable(category.tint))
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
        // The pale capsule keeps the mid-saturation tint; only the small text is deepened for legibility.
        .foregroundStyle(AppTheme.readable(type.tint))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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
            .foregroundStyle(AppTheme.warning)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppTheme.warning.opacity(0.12), in: Capsule())
        }
    }
}

// Shared by the dashboard and pool so their layout and expansion stay identical.
struct ExpandableSummaryCard<Overview: View, Details: View>: View {
    @Binding var isExpanded: Bool
    var hasDetails = true
    var showsToggle = true
    @ViewBuilder var overview: Overview
    @ViewBuilder var details: Details

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            VStack(alignment: .leading, spacing: 14) {
                overview
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .transaction { transaction in
                        transaction.animation = nil
                    }

                if isExpanded && hasDetails {
                    Divider()

                    details
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 4)
            .recordCard()

            if showsToggle {
                CardExpansionButton(isExpanded: $isExpanded)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}
