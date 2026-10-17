import SwiftUI
import UIKit

struct ThemeColorSettingsSection: View {
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

    var body: some View {
        SettingsCardSection("主题色", footer: "修改会自动保存，仅影响这台设备。") {
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

            VStack(alignment: .leading, spacing: 4) {
                Text("常用配色")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 6), spacing: 0) {
                    ForEach(Self.presets.indices, id: \.self) { index in
                        let preset = Self.presets[index]
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
            .padding(.vertical, 10)

            SettingsRowDivider()

            DisclosureGroup(isExpanded: $showsFineTuning) {
                fineTuning
            } label: {
                Label("精细调整", systemImage: "slider.horizontal.3")
                    .settingsRow()
            }

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
    }

    private var fineTuning: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("颜色代码").font(.subheadline)
                Spacer(minLength: 4)
                TextField("8B5E3C", text: $hexInput)
                    .font(.subheadline.monospaced())
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($isEditingHex)
                    .onSubmit(applyHex)
                    .padding(8)
                    .frame(width: 100)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: AppLayout.thumbnailCornerRadius))
                    .accessibilityLabel("六位颜色代码")
                Button("应用", action: applyHex)
                    .foregroundStyle(AppTheme.readablePrimary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            if let hexError {
                Text(hexError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            channelSlider("红", keyPath: \.red)
            channelSlider("绿", keyPath: \.green)
            channelSlider("蓝", keyPath: \.blue)
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { preferences.color.swiftUIColor },
            set: { if let color = AppThemeColor(uiColor: UIColor($0)) { preferences.color = color } }
        )
    }

    private func channelSlider(_ title: String, keyPath: KeyPath<AppThemeColor, Int>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.subheadline).frame(width: 20)
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
                .frame(width: 30, alignment: .trailing)
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
