import SwiftUI

// MARK: - Umbra 调色板（兼容层）
//
// 取值**唯一来源是 UmbraTokens.swift 的 UmbraColor**。这个结构体保留下来只为兼容
// 已有页面里的 `UmbraColors(isDark:)` 与 `umbraColor(\.muted)` 两种写法，新代码请直接用
// `UmbraColor.muted` —— 那一层是随浅深色自动切换的动态色，不需要自己传 isDark。
//
// 对齐设计交接包 (_ds/…/tokens/colors.css) 时改正了四处**已经跑偏**的取值，
// 以及补上了六个缺失的 token。原来的值不是「另一种风格」，是抄错了：
//   · bg  深色  #15110E → #1C1A17   （#15110E 是 --nav，被当成页面底色用了，页面比设计稿暗一档）
//   · card 深色 #232019 → #26231F   （交接包的深色卡片值）
//   · chip 浅色 #F0EEEA → #F2F0EC
//   · track    #F3F2EF / #1B1915 → #EDEBE6 / #302B24（深色下原值比卡片还浅，进度条槽会浮出来）
// 新增：borderSoft、faint、nav、hover、titlebar、desk。
struct UmbraColors {
    var isDark: Bool = false

    // 表面 / 中性
    var bg: Color { pick("F6F5F2", "1C1A17") }
    var card: Color { pick("FFFFFF", "26231F") }
    var titlebar: Color { pick("EFEDE8", "1C1A17") }
    /// --rail。旧代码里叫 bar，保留这个名字免得改动既有页面。
    var rail: Color { pick("FBFAF8", "1F1C18") }
    var bar: Color { rail }
    var chip: Color { pick("F2F0EC", "2A251F") }
    var hover: Color { pick("F1EFEA", "2A251F") }
    var track: Color { pick("EDEBE6", "302B24") }
    /// 只给设计稿外壳用，App 里不该出现。
    var desk: Color { pick("DEDBD5", "151310") }

    // 描边与文字
    var border: Color { pick("E6E3DC", "332E26") }
    var borderSoft: Color { pick("EEEBE4", "2B2721") }
    var text: Color { pick("1F2320", "EDEAE3") }
    var muted: Color { pick("6B716B", "9A938A") }
    var faint: Color { pick("9A9992", "6E675E") }

    // 品牌
    /// 浮层底板。iOS 上只用于录音面板与 toast，不做页面底色。
    var nav: Color { Color(hex: "15110E") }
    var orange: Color { Color(hex: "E8590C") }
    var orangeDeep: Color { Color(hex: "C2410C") }
    var orangeSoft: Color { isDark ? Color(hex: "E8590C").opacity(0.16) : Color(hex: "FFF1E6") }
    var orangeText: Color { pick("9A3412", "F0A878") }

    // 语义四档
    var success: Color { pick("0F766E", "34B5A6") }
    var successSoft: Color { isDark ? Color(hex: "0F766E").opacity(0.20) : Color(hex: "E2F1EF") }
    var warning: Color { pick("B45309", "D98A29") }
    var warningSoft: Color { isDark ? Color(hex: "B45309").opacity(0.22) : Color(hex: "FBEEDD") }
    var danger: Color { pick("B42318", "E0675C") }
    var dangerSoft: Color { isDark ? Color(hex: "B42318").opacity(0.22) : Color(hex: "FBE9E7") }

    var userBubble: Color { pick("EAF1F7", "2B2620") }

    private func pick(_ light: String, _ dark: String) -> Color {
        Color(hex: isDark ? dark : light)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Theme Environment
struct UmbraTheme: EnvironmentKey {
    static let defaultValue: Bool = false // false = light, true = dark
}

extension EnvironmentValues {
    var isDark: Bool {
        get { self[UmbraTheme.self] }
        set { self[UmbraTheme.self] = newValue }
    }
}
