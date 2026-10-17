import Foundation

nonisolated struct AppThemeColor: Equatable, Hashable, Sendable {
    let red: Int
    let green: Int
    let blue: Int

    static let `default` = AppThemeColor(red: 139, green: 94, blue: 60)

    init(red: Int, green: Int, blue: Int) {
        self.red = min(255, max(0, red))
        self.green = min(255, max(0, green))
        self.blue = min(255, max(0, blue))
    }

    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(red: Int((rgb >> 16) & 255), green: Int((rgb >> 8) & 255), blue: Int(rgb & 255))
    }

    var hex: String { String(format: "%02X%02X%02X", red, green, blue) }

    var luminance: Double {
        func linear(_ channel: Int) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    var prefersWhiteForeground: Bool {
        contrast(with: .init(red: 255, green: 255, blue: 255)) >= contrast(with: .init(red: 0, green: 0, blue: 0))
    }

    func contrast(with other: AppThemeColor) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }

    /// Keep colored text readable on the app's white or black page background.
    func readableTint(onDarkBackground: Bool) -> AppThemeColor {
        let background = AppThemeColor(red: onDarkBackground ? 0 : 255, green: onDarkBackground ? 0 : 255, blue: onDarkBackground ? 0 : 255)
        if contrast(with: background) >= 4.5 { return self }
        let target = onDarkBackground ? 255 : 0
        for step in 1...100 {
            let amount = Double(step) / 100
            func mix(_ value: Int) -> Int { Int((Double(value) + Double(target - value) * amount).rounded()) }
            let candidate = AppThemeColor(red: mix(red), green: mix(green), blue: mix(blue))
            if candidate.contrast(with: background) >= 4.5 { return candidate }
        }
        return AppThemeColor(red: target, green: target, blue: target)
    }
}
