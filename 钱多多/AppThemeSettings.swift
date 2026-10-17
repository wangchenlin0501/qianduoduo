import Foundation
import Observation

@MainActor @Observable
final class AppThemeSettings {
    static let shared = AppThemeSettings()
    static let storageKey = "appThemeColorHex"

    private let defaults: UserDefaults
    var color: AppThemeColor {
        didSet {
            guard color != oldValue else { return }
            defaults.set(color.hex, forKey: Self.storageKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        color = defaults.string(forKey: Self.storageKey).flatMap(AppThemeColor.init(hex:)) ?? .default
    }

    func restoreDefault() { color = .default }
}
