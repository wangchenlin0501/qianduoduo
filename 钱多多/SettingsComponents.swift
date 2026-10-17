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
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    content
                }
                .font(.body)
                .labelStyle(SettingsRowLabelStyle())
                .buttonStyle(.plain)
                .recordCard()

                if let footer {
                    Text(footer)
                        .font(.footnote)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, AppLayout.cardContentPadding)
                }
            }
            .wideListRow()
        } header: {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .textCase(nil)
        }
    }
}

private struct SettingsRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.readablePrimary)
                .frame(width: 24)
                .accessibilityHidden(true)
            configuration.title
                .multilineTextAlignment(.leading)
        }
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Divider().padding(.leading, 34)
    }
}

extension View {
    func settingsRow() -> some View {
        frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
    }
}
