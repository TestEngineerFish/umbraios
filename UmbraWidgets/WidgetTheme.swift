// 小组件用的最小配色表。
//
// 为什么不直接勾主 App 的 UmbraTokens.swift：扩展内存上限很紧，而且 UmbraTokens
// 连带 UmbraFont/UmbraMetric/图标路径一大串 —— 小组件只要七八个颜色。
// 这里的值**逐个抄自** DesignSystem/UmbraTokens.swift（v2 token），改主题色时两边一起改。
import SwiftUI
import UIKit

enum WTheme {
    /// 品牌橙，跨主题不变（UmbraColor.orange）。
    static let orange = Color(hex: "E8590C")
    /// 橙色文字：深色下提亮保对比（UmbraColor.orangeText）。
    static let orangeText = dyn("9A3412", "F0A878")

    static let bg    = dyn("F1EFEA", "151310")
    static let card  = dyn("FFFFFF", "26231F")
    static let chip  = dyn("F2F0EC", "2A251F")
    static let text  = dyn("1F2320", "EDEAE3")
    static let muted = dyn("6B716B", "9A938A")
    static let faint = dyn("9A9992", "6E675E")

    static let danger  = dyn("B42318", "E0675C")
    static let success = dyn("0F766E", "34B5A6")

    /// 锁屏实况深色卡的底（规范：锁屏通知卡 = 深色玻璃）。实况卡两个主题都走深色。
    static let activityBg = Color(hex: "15110E")

    private static func dyn(_ light: String, _ dark: String) -> Color {
        let l = UIColor(Color(hex: light)), d = UIColor(Color(hex: dark))
        return Color(UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }
}

extension Color {
    /// 和主 App UmbraTokens 里同款的 hex 构造，扩展里复制一份（不共享 token 文件）。
    init(hex: String) {
        let v = UInt64(hex, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - 进度环（三处共用一个画法）

/// 橙色进度环。percent = nil（服务端没给步骤数）时画 30% 的弧当「进行中」示意 ——
/// 弧长不代表进度，旁边的文字此时也不显示百分比，不骗人。
struct WProgressRing: View {
    var percent: Double?
    var size: CGFloat
    var lineWidth: CGFloat = 4
    var track: Color = WTheme.chip

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(percent ?? 0.3))
                .stroke(WTheme.orange, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}
