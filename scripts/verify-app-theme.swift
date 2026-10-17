import Foundation
import Observation
import Synchronization

@main
struct VerifyAppTheme {
    @MainActor static func main() {
        precondition(AppThemeColor.default.hex == "8B5E3C")
        precondition(AppThemeColor(hex: " #aBc123 \n")?.hex == "ABC123")
        for invalid in ["", "123", "1234567", "GG0000", "#12 345", "１２３４５６", "##FFFFFF"] {
            precondition(AppThemeColor(hex: invalid) == nil, "Invalid codes must not change the theme")
        }
        precondition(AppThemeColor(red: -1, green: 256, blue: 128).hex == "00FF80")

        let suiteName = "qdd-theme-verification-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppThemeSettings(defaults: defaults)
        precondition(settings.color == .default)
        settings.color = AppThemeColor(hex: "25AACF")!
        precondition(defaults.string(forKey: AppThemeSettings.storageKey) == "25AACF")
        precondition(AppThemeSettings(defaults: defaults).color == settings.color, "Reopening must restore the chosen color")

        let wasObserved = Mutex(false)
        withObservationTracking {
            _ = settings.color.hex
        } onChange: {
            wasObserved.withLock { $0 = true }
        }
        settings.color = AppThemeColor(hex: "000000")!
        precondition(wasObserved.withLock { $0 }, "Changing color must invalidate observers without recreating pages")
        settings.restoreDefault()
        precondition(AppThemeSettings(defaults: defaults).color == .default)
        defaults.set("invalid", forKey: AppThemeSettings.storageKey)
        precondition(AppThemeSettings(defaults: defaults).color == .default)

        let white = AppThemeColor(red: 255, green: 255, blue: 255)
        let black = AppThemeColor(red: 0, green: 0, blue: 0)
        var checked = 0
        for red in stride(from: 0, through: 255, by: 17) {
            for green in stride(from: 0, through: 255, by: 17) {
                for blue in stride(from: 0, through: 255, by: 17) {
                    let color = AppThemeColor(red: red, green: green, blue: blue)
                    precondition(AppThemeColor(hex: color.hex) == color)
                    precondition(color.contrast(with: color.prefersWhiteForeground ? white : black) >= 4.5)
                    for isDark in [false, true] {
                        let background = isDark ? black : white
                        let tint = color.readableTint(onDarkBackground: isDark)
                        precondition(tint.contrast(with: background) >= 4.5)
                        if color.contrast(with: background) >= 4.5 {
                            precondition(tint == color, "Readable selections must keep their original shade")
                        }
                    }
                    checked += 1
                }
            }
        }
        print("PASS: HEX validation, RGB bounds, persistence, reset, observation updates, and light/dark contrast for \(checked) colors.")
    }
}
