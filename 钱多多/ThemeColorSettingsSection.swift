import SwiftUI
import UIKit

struct ThemeColorSettingsSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var hexFieldWidth = 104
    @ScaledMetric(relativeTo: .subheadline) private var channelLabelWidth = 20
    private let preferences = AppThemeSettings.shared
    @State private var showsFineTuning = false
    @State private var hexInput = ""
    @State private var hexError: String?
    @FocusState private var isEditingHex: Bool

    private static let presets: [(name: String, color: AppThemeColor)] = [
        ("经典棕", .default),
        ("玫瑰", AppThemeColor(red: 183, green: 81, blue: 104)),
        ("海蓝", AppThemeColor(red: 57, green: 118, blue: 168)),
        ("松绿", AppThemeColor(red: 55, green: 124, blue: 114)),
        ("雾紫", AppThemeColor(red: 123, green: 98, blue: 158)),
        ("石墨", AppThemeColor(red: 89, green: 97, blue: 107))
    ]

    private static let earthPresets: [(name: String, color: AppThemeColor)] = [
        ("沙丘桃", AppThemeColor(red: 242, green: 194, blue: 153)),
        ("杏尘", AppThemeColor(red: 228, green: 156, blue: 105)),
        ("余烬岩", AppThemeColor(red: 197, green: 108, blue: 57)),
        ("土坯棕", AppThemeColor(red: 138, green: 75, blue: 47)),
        ("可可壳", AppThemeColor(red: 92, green: 59, blue: 46))
    ]

    var body: some View {
        SettingsCardSection("主题色") {
            ColorPicker(selection: colorBinding, supportsOpacity: false) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自定义颜色")
                        Text("#" + preferences.color.hex)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "paintpalette.fill")
                }
            }
            .settingsRow()

            SettingsRowDivider()

            VStack(alignment: .leading, spacing: 10) {
                presetGroup("常用配色", presets: Self.presets)
                presetGroup("大地暖色", presets: Self.earthPresets)
            }
            .padding(.vertical, 10)

            SettingsRowDivider()

            DisclosureGroup(isExpanded: $showsFineTuning) {
                fineTuning
            } label: {
                Label("精细调整", systemImage: "slider.horizontal.3")
                    .settingsRow()
            }
            .disclosureGroupStyle(ThemeFineTuningDisclosureStyle())

            SettingsRowDivider()

            Button {
                preferences.restoreDefault()
            } label: {
                Label("恢复默认主题色", systemImage: "arrow.counterclockwise")
                    .settingsRow()
            }
            .disabled(preferences.color == .default)
        }
        .onAppear { hexInput = preferences.color.hex }
        .onChange(of: preferences.color) { _, color in
            if !isEditingHex {
                hexInput = color.hex
                hexError = nil
            }
        }
        .onChange(of: showsFineTuning) { _, isExpanded in
            if !isExpanded { isEditingHex = false }
        }
    }

    private func presetGroup(_ title: String, presets: [(name: String, color: AppThemeColor)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 60), spacing: 4)], alignment: .leading, spacing: 4) {
                ForEach(presets.indices, id: \.self) { index in
                    let preset = presets[index]
                    let isSelected = preferences.color == preset.color
                    Button {
                        preferences.color = preset.color
                    } label: {
                        Circle()
                            .fill(preset.color.swiftUIColor)
                            .frame(width: 28, height: 28)
                            .overlay {
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(preset.color.foregroundColor)
                                }
                            }
                            .frame(width: 38, height: 38)
                            .overlay {
                                Circle().stroke(isSelected ? AppTheme.readablePrimary : .clear, lineWidth: 1.5)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private var fineTuning: some View {
        VStack(alignment: .leading, spacing: 12) {
            colorCodeLayout {
                Text("颜色代码").font(.subheadline)
                colorCodeLayout {
                    if !usesStackedControls { Spacer(minLength: 4) }
                    TextField("8B5E3C", text: $hexInput)
                        .font(.subheadline.monospaced())
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($isEditingHex)
                        .onSubmit(applyHex)
                        .padding(8)
                        .frame(width: usesStackedControls ? nil : hexFieldWidth)
                        .frame(maxWidth: usesStackedControls ? .infinity : nil, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: AppLayout.thumbnailCornerRadius))
                        .accessibilityLabel("六位颜色代码")
                    Button("应用", action: applyHex)
                        .foregroundStyle(AppTheme.readablePrimary)
                        .frame(minWidth: 44, minHeight: 44)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            if let hexError {
                Text(hexError)
                    .font(.caption)
                    .foregroundStyle(AppTheme.danger)
            }
            channelSlider("红", keyPath: \.red)
            channelSlider("绿", keyPath: \.green)
            channelSlider("蓝", keyPath: \.blue)
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var colorCodeLayout: AnyLayout {
        usesStackedControls
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
    }

    private var usesStackedControls: Bool { dynamicTypeSize >= .xLarge }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { preferences.color.swiftUIColor },
            set: { if let color = AppThemeColor(uiColor: UIColor($0)) { preferences.color = color } }
        )
    }

    private func channelSlider(_ title: String, keyPath: KeyPath<AppThemeColor, Int>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.subheadline).frame(width: channelLabelWidth)
            Slider(value: Binding(
                get: { Double(preferences.color[keyPath: keyPath]) },
                set: { value in
                    let color = preferences.color
                    let byte = Int(value.rounded())
                    preferences.color = AppThemeColor(
                        red: keyPath == \.red ? byte : color.red,
                        green: keyPath == \.green ? byte : color.green,
                        blue: keyPath == \.blue ? byte : color.blue
                    )
                }
            ), in: 0...255, step: 1)
            .tint(AppTheme.readablePrimary)
            .accessibilityLabel(title + "色")
            Text("\(preferences.color[keyPath: keyPath])")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func applyHex() {
        guard let color = AppThemeColor(hex: hexInput) else {
            hexError = "请输入六位颜色代码，例如 8B5E3C。"
            return
        }
        preferences.color = color
        hexInput = color.hex
        hexError = nil
        isEditingHex = false
    }
}

/// This disclosure lives inside one self-sizing List row. Keep its height change out of
/// the animation transaction so the card and UIKit-backed controls are laid out once.
private struct ThemeFineTuningDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    configuration.label
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.readablePrimary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isExpanded)
                        .transaction { $0.disablesAnimations = false }
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")

            if configuration.isExpanded {
                configuration.content
                    .transition(.identity)
            }
        }
    }
}
