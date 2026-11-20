import SwiftUI

struct SettingsCardSection<Content: View>: View {
    let title: String
    let footer: String?
    private let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .font(.body)
                .labelStyle(SettingsRowLabelStyle())
                .buttonStyle(SettingsRowButtonStyle())
                .padding(.horizontal, AppLayout.cardContentPadding)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CardSurfaceBackground())

                if let footer {
                    SettingsFooterText(footer)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .wideListRow()
        }
    }
}

struct SettingsFooterText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsRowLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var iconWidth = 24

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.readablePrimary)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            configuration.title
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.55 : 1)
    }
}

struct SettingsValueRow<Value: View>: View {
    let title: String
    let systemImage: String
    let value: Value
    @ScaledMetric(relativeTo: .body) private var iconWidth = 24

    init(_ title: String, systemImage: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.systemImage = systemImage
        self.value = value()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Label(title, systemImage: systemImage)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                value.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage)
                value.padding(.leading, iconWidth + 10)
            }
        }
        .settingsRow()
    }
}

struct SettingsRowDivider: View {
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .body) private var iconWidth = 24

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 1 / displayScale)
            .frame(maxWidth: .infinity)
            .padding(.leading, iconWidth + 10)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }
}

extension View {
    func settingsRow() -> some View {
        frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }
}
