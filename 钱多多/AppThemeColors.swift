import SwiftUI
import UIKit

extension AppThemeColor {
    var uiColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    var swiftUIColor: Color { Color(uiColor: uiColor) }
    var foregroundColor: Color { prefersWhiteForeground ? .white : .black }

    init?(uiColor: UIColor) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = uiColor.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3,
              components.prefix(3).allSatisfy({ $0.isFinite }) else { return nil }
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        self.init(red: byte(components[0]), green: byte(components[1]), blue: byte(components[2]))
    }
}

private struct AppThemeColorKey: EnvironmentKey {
    static let defaultValue = AppThemeColor.default
}

extension EnvironmentValues {
    var appThemeColor: AppThemeColor {
        get { self[AppThemeColorKey.self] }
        set { self[AppThemeColorKey.self] = newValue }
    }
}
