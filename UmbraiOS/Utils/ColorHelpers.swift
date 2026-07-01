import SwiftUI
import UIKit

// MARK: - Color Extensions
extension Color {
    static var umbraMuted: Color {
        umbraColor(\.muted)
    }

    static var orangeText: Color {
        umbraColor(\.orangeText)
    }

    /// 主题橙 (#E8590C)。作为全局 tint / accent 使用，避免依赖可能解析为透明的 AccentColor 资源。
    static var umbraOrange: Color {
        umbraColor(\.orange)
    }
}

// MARK: - Dynamic color resolver
// 返回随系统浅/深色自动切换的颜色：深色模式下背景变深、文字变浅，二者一起变，避免白字白底。
private let umbraLightPalette = UmbraColors(isDark: false)
private let umbraDarkPalette = UmbraColors(isDark: true)

func umbraColor(_ keyPath: KeyPath<UmbraColors, Color>) -> Color {
    let light = UIColor(umbraLightPalette[keyPath: keyPath])
    let dark = UIColor(umbraDarkPalette[keyPath: keyPath])
    return Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? dark : light
    })
}
