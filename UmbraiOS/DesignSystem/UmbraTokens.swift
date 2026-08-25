// Umbra 设计 token —— 唯一取值来源。
//
// 对应设计交接包里的：
//   _ds/…/tokens/colors.css      浅色 :root + 深色 [data-theme="dark"]
//   _ds/…/tokens/typography.css  字号 / 字重 / 行高
//   _ds/…/tokens/spacing.css     间距 / 圆角 / 控件尺寸
//   _ds/…/tokens/elevation.css   描边 / 阴影
//   ds-handoff-ios/tokens/ios.css  iOS 覆盖层（[data-platform="ios"]）
//
// 规则：**页面和组件里不许出现字面量颜色、字号、圆角**，一律从这里取。
// 交接文档写的是「按 token 精确还原，不要目测」，而目测出来的偏差在评审时是查不出来的 ——
// 只有「代码里根本没有字面量」这一条能保证它不发生。
//
// iOS 覆盖层不做成运行时开关：这个工程只有 iOS 一个目标，
// 直接把 ios.css 的值写进对应 token 即可，桌面端的原值写在注释里备查。
import SwiftUI
import UIKit

// MARK: - 颜色
//
// 每个 token 都是「随浅深色自动切换」的动态色：底层用 UIColor 的 trait 解析，
// 所以它既跟随系统外观，也跟随 .preferredColorScheme 的强制指定（外观设置要用到）。
//
// 注意：这里的取值以交接包的 colors.css 为准。工程原来那套 UmbraColors(isDark:) 有几处对不上
//（bg 深色写成了 #15110E、chip/track 浅色偏了一档、缺 borderSoft/faint/nav/hover/titlebar/desk），
// 已按 token 修正。旧那套现在**已经删掉**，全项目只认这一份颜色。
// MARK: - 十六进制取色
//
// 交接包的 colors.css 里颜色全是 #RRGGBB，所以这里需要一个从字符串构造的入口。
// 原来它和一整套旧配色（UmbraColors(isDark:)）挤在 Utils/ColorHelpers.swift 里，
// 旧配色删掉时**它被一起带走了** —— 而它其实只服务本文件下面这批 token。
// 放在这里：唯一的使用者就在同一个文件，不必为一个 20 行的扩展单开一个文件。
extension Color {
    /// 从 "RRGGBB" 或 "AARRGGBB" 构造。位数不对时返回不透明黑 ——
    /// 静默返回透明色会让整块 UI 直接消失，反而更难查。
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
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}

enum UmbraColor {

    // 表面 / 中性
    /// v2（iOS 26 Liquid Glass 版）把底色调到贴近 systemGroupedBackground 但仍偏暖：
    /// 浅色 #F6F5F2→#F1EFEA、深色 #1C1A17→#151310。其余表面色不变。
    static let bg        = dyn(light: "F1EFEA", dark: "151310")   // 页面底色：暖灰 / 暖棕黑，不是纯白或冷黑
    static let card      = dyn(light: "FFFFFF", dark: "26231F")   // 卡片、列表分组
    static let titlebar  = dyn(light: "EFEDE8", dark: "1C1A17")
    static let rail      = dyn(light: "FBFAF8", dark: "1F1C18")
    static let chip      = dyn(light: "F2F0EC", dark: "2A251F")   // 分段控件底、进度条槽、置灰按钮
    static let hover     = dyn(light: "F1EFEA", dark: "2A251F")
    static let track     = dyn(light: "EDEBE6", dark: "302B24")
    static let desk      = dyn(light: "DEDBD5", dark: "151310")   // 只给设计稿的外壳用，App 内不出现

    // 描边与文字
    static let border     = dyn(light: "E6E3DC", dark: "332E26")
    static let borderSoft = dyn(light: "EEEBE4", dark: "2B2721")
    static let text       = dyn(light: "1F2320", dark: "EDEAE3")
    static let muted      = dyn(light: "6B716B", dark: "9A938A")
    static let faint      = dyn(light: "9A9992", dark: "6E675E")

    // 品牌
    /// 浮层底板色。iOS 上**只用于**录音面板和 toast，不做页面底色。
    static let nav        = dyn(light: "15110E", dark: "15110E")
    /// 唯一重点色，跨主题不变。
    static let orange     = Color(hex: "E8590C")
    static let orangeDeep = Color(hex: "C2410C")
    /// 选中底、问答卡头部。深色下是半透明橙（实色浅橙在暗底上会脏）。
    static let orangeSoft = dynColor(light: Color(hex: "FFF1E6"), dark: Color(hex: "E8590C").opacity(0.16))
    /// 橙色**文字**。深色下提亮到 #F0A878 保对比度，不要直接用 orange 当文字色。
    static let orangeText = dyn(light: "9A3412", dark: "F0A878")

    // 语义四档
    static let success     = dyn(light: "0F766E", dark: "34B5A6")
    static let successSoft = dynColor(light: Color(hex: "E2F1EF"), dark: Color(hex: "0F766E").opacity(0.20))
    static let warning     = dyn(light: "B45309", dark: "D98A29")
    static let warningSoft = dynColor(light: Color(hex: "FBEEDD"), dark: Color(hex: "B45309").opacity(0.22))
    static let danger      = dyn(light: "B42318", dark: "E0675C")
    static let dangerSoft  = dynColor(light: Color(hex: "FBE9E7"), dark: Color(hex: "B42318").opacity(0.22))
    /// 计数角标专用红：取系统 systemRed（浅 #FF3B30 / 深 #FF453A，系统自适应），
    /// 跟系统底栏徽标同色。不复用 --danger —— 那是破坏性操作的红（偏深偏哑），
    /// 底栏回归系统 bar 后两个红并排出现像色差事故（实机可辨，老板点名统一）。
    /// 稿的口径偏离已记台账，待设计确认：iOS 端「角标红」→ systemRed。
    static let badgeRed    = Color(UIColor.systemRed)

    /// 用户气泡。这一条不在 colors.css 里，来自主设计稿对话页的取值。
    // 我方气泡。浅色是交接包给的冷调蓝灰（衬白卡片）；
    // ⚠️ 深色原值 2B2620 与 card 的 26231F 只差几个色阶，**实机上根本分不出你我**
    //（用户点名：浅色正常、深色下两边一样）。深色沿用同一套逻辑 ——
    // 卡片是暖棕黑，我方气泡就走冷调，冷暖对比在暗背景下最容易辨认。
    static let userBubble = dyn(light: "EAF1F7", dark: "1E2A35")
    // 设备（非秘书）发来的气泡。在设备会话里，秘书用 card、设备用这一档，
    // 两边都在左侧但颜色不同，一眼分得出是谁说的。
    //
    // 取值改自 F4F1EA / 302A22 → 跟 2026-08-22 那版设计包的 `ios.deviceBubble`。
    // 这个 token 原本是实现侧自己加的（我们在批次 001 里报过「不在 colors.css 也不在 ios.css」），
    // 这轮 ClaudeDesign 把它正式收进了稿，并且定了自己的值。既然有正本了就跟正本。
    static let deviceBubble = dyn(light: "EDEAE4", dark: "2E2A25")

    /// toast 上的字色。toast 底板是 --nav（两个主题都是深色），所以字色不跟主题变。
    /// 原来是从主设计稿 toast 上取的实测值 F5F2EC；2026-08-22 那版稿把它定成了
    /// `rgba(255,255,255,.92)`，改用半透明白 —— 好处是叠在任何深色底上都自洽，
    /// 不像固定色号那样换个底就偏色。
    static let onNavText = Color.white.opacity(0.92)
    /// toast 里「撤销」的字色。深色底上的提亮橙，和 --orange-text 的深色值同源。
    static let onNavAccent = Color(hex: "F0A878")

    // MARK: 玻璃 token（v2 · iOS 26 Liquid Glass）
    //
    // 玻璃**只给系统 chrome 层**：导航按钮、tab bar、浮层。内容卡片一律不透明 ——
    // Umbra「几乎不用透明与模糊」在内容层继续成立，这是规范增补第 4 节的原话。
    // 模糊本体交给 .ultraThinMaterial；这里只提供叠在材质上的 tint / 描边 / 阴影。
    static let glassBg  = dynColor(light: Color.white.opacity(0.55),
                                   dark: Color(hex: "2E2A25").opacity(0.55))
    static let glassBrd = dynColor(light: Color.white.opacity(0.65),
                                   dark: Color.white.opacity(0.14))
    /// 玻璃件的投影色。浅色暖黑 12%、深色纯黑 38%。
    static let glassShadow = dynColor(light: Color(hex: "1F1B16").opacity(0.12),
                                      dark: Color.black.opacity(0.38))
    /// toast 底：深色玻璃胶囊（两个主题都是深色，配 .ultraThinMaterial 使用）。
    /// 取值改自 15110E@.72 → 稿的 `rgba(28,25,21,.88)`。更不透明是有道理的：
    /// 吐司要压在任意内容之上，.72 在花哨背景上会透出底下的东西，字就糊了。
    static let toastGlass = Color(hex: "1C1915").opacity(0.88)

    // MARK: 动态色构造
    private static func dyn(light: String, dark: String) -> Color {
        dynColor(light: Color(hex: light), dark: Color(hex: dark))
    }
    private static func dynColor(light: Color, dark: Color) -> Color {
        let l = UIColor(light), d = UIColor(dark)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }
}

// MARK: - 排版
//
// 系统字体，不引入 webfont；等宽用系统等宽（SF Mono）。
// 字重只用 400 / 560 / 600 / 650 —— 这四档之外的值一律是写错了。
// SwiftUI 没有 560/650 这种数值字重，用 Font.system(size:weight:) 映射：
//   400 → .regular   560 → .medium   600 → .semibold   650 → .bold
// 560 特意映射到 .medium 而不是 .semibold：设计稿里 560 和 600 是两档，合并会让列表行主文变重。
enum UmbraFont {

    enum Weight {
        case w400, w560, w600, w650
        var swiftUI: Font.Weight {
            switch self {
            case .w400: return .regular
            case .w560: return .medium
            case .w600: return .semibold
            case .w650: return .bold
            }
        }
    }

    static func sans(_ size: CGFloat, _ weight: Weight = .w400) -> Font {
        .system(size: size, weight: weight.swiftUI)
    }
    /// 路径、JSON、密钥、TOTP、快捷键一律等宽 —— 这是硬规则，不是风格偏好。
    static func mono(_ size: CGFloat, _ weight: Weight = .w400) -> Font {
        .system(size: size, weight: weight.swiftUI, design: .monospaced)
    }

    // iOS 取值（括号内是桌面端原值，仅备查）
    static let pageTitle   = sans(27, .w650)    // 页面标题
    static let sectionTitle = sans(17, .w600)   // 区块标题 16–17
    static let detailTitle = sans(20, .w650)    // 详情页大标题
    static let body        = sans(15, .w400)    // 正文（桌面 12.5）
    static let rowTitle    = sans(16, .w560)    // 列表行主文（桌面 12.5）
    static let rowSub      = sans(13, .w400)    // 列表行副文（桌面 10.5–11）
    static let fieldLabel  = sans(12, .w560)    // 字段标签（桌面 11），配 letterSpacing .06em
    static let meta        = sans(11.5, .w400)  // 元信息 11–12
    static let button      = sans(16, .w560)
    static let tabLabel    = sans(10.5, .w400)

    /// 正文行高。CSS 里是 line-height 1.65；SwiftUI 用 lineSpacing（行间距）表达，
    /// 需要减掉字号本身：15 * 1.65 - 15 ≈ 9.75。
    ///
    /// ⚠️ **这个常数只对 15px 的正文成立**，别拿它套别的字号 ——
    /// 9.75 加在 12px 上是 1.81 的行高（太散），加在 27px 标题上只有 1.36。
    /// 别的字号一律用下面的 `lineSpacing(_:ratio:)`。
    static let bodyLineSpacing: CGFloat = 9.75

    /// ── 关于全项目 90 多处硬编码的 `.lineSpacing(...)` ──
    ///
    /// 现状：写法一律是 `13 * 0.6` 这种「字号 × 系数」，而这个系数其实就是
    /// 「行高倍数 - 1」。没人这么想，于是同类文字在不同页面上从 1.3 散到 1.81。
    ///
    /// **但这不能一把梭。** 行高不是一个全局值，是按角色分的（设计规范 598-604 字阶表）：
    ///   页面标题 1.25 · 分区标题 1.35 · 详情标题 1.45 · 列表项标题 1.5
    ///   正文 1.7 · 元信息 1.5 · 字段标签 1.4
    /// 「正文段落不低于 1.65」这条硬规则**只管正文**。拿它去套标题会把 27px 的
    /// 页面标题撑成 1.65（表里是 1.25），比现在还糟。
    ///
    /// 所以这里刻意**没有**加一个 `lineSpacing(size:ratio:)` helper ——
    /// 加了也没人用（本文件里已经有过 UmbraSwipeRow / radiusSwipeRow 这种
    /// 「定义完整、全项目零引用」的前车之鉴）。真要收敛，得先逐处判定每段文字是哪个角色，
    /// 那是一次跨全端、会改变视觉密度的清扫，需要单独排期。已记进回流台账。
    /// 字段标签的字距，对应 letter-spacing:.06em。
    static func labelTracking(_ size: CGFloat) -> CGFloat { size * 0.06 }
}

// MARK: - 间距 / 圆角 / 尺寸
enum UmbraMetric {
    /// 聊天气泡对侧留出的最小空白。气泡宽度**随内容自适应**，
    /// 靠这个 Spacer 的下限保证长消息不会一路顶到屏幕另一边
    /// （不能用 frame(maxWidth:) 限宽 —— 那会让短消息也撑满，见 ChatThreadView 的注释）。
    static let bubbleGutter: CGFloat = 56

    // 间距
    static let sp1: CGFloat = 4
    static let sp2: CGFloat = 7
    static let sp3: CGFloat = 9
    static let sp4: CGFloat = 12
    static let sp5: CGFloat = 14
    static let sp6: CGFloat = 18
    static let sp7: CGFloat = 20
    static let sp8: CGFloat = 28

    // 圆角（v2 · iOS 26 覆盖）
    // 规则：**胶囊只给按钮、分段控件、tab bar**；输入框统一 12、不用胶囊；
    // 卡片 18 且描边转 borderSoft；操作表/弹窗 26–28。
    static let radiusControl: CGFloat = 10    // 小控件（图标块、行内徽标）
    // 卡片 18。一期是 14，v2 液态玻璃改版提到 18。
    // ⚠️ 这个值曾经名存实亡：token 写着 18，但 41 个调用点全都写的是 `radiusCard - 2`，
    // 实际渲染出来是 16 —— 谁也没在这个文件里看出问题。已经全部改回直接用 radiusCard。
    // 以后要调卡片圆角改这一行就够了，别再在调用点上做减法。
    static let radiusCard: CGFloat = 18
    static let radiusInput: CGFloat = 12      // 单行 / 多行 / 搜索输入框
    // 左滑操作行 16。注意：目前 UmbraSwipeRow 组件本身是零引用的（各页一律走系统
    // .swipeActions），所以这个 token 暂时只在那个组件里生效。
    static let radiusSwipeRow: CGFloat = 16
    static let radiusSheet: CGFloat = 26      // 操作表 / 底部面板（弹窗 28）
    static let radiusPill: CGFloat = 999
    /// 过程截图专用。**8 是桌面的值，iOS 是 12。**
    /// 设计系统 readme 第 59 行写的是「圆角 8px」，但那句话在桌面语境里；
    /// `ios.css` 与 `umbra-tokens.json` 的 `ios.radiusShot` 都给的 12（注释：「比卡片小一档」，
    /// iOS 卡片是 18）。这里是 iOS，取 12。
    /// （readme 那句没写明是桌面，容易被当成全局规则，已记进台账让 ClaudeDesign 补一句限定。）
    static let radiusShot: CGFloat = 12

    // 边距与行高
    static let pagePadX: CGFloat = 16
    static let cardPad: CGFloat = 13          // 卡片内边距 13–14
    static let groupGap: CGFloat = 11         // 分组间距 10–12
    /// Apple 触达底线。**所有点击区不得小于这个值**，自查清单里有这一条。
    static let tapMin: CGFloat = 44
    static let rowMinH: CGFloat = 44
    static let rowMinHSub: CGFloat = 60       // 带副文的列表行

    // 图标块
    static let iconBlockSM: CGFloat = 24
    static let iconBlockMD: CGFloat = 34      // 记录行徽标
    static let iconBlockLG: CGFloat = 44      // 表单 / 详情头
    static let iconBlockXL: CGFloat = 48

    // 控件
    static let progressH: CGFloat = 4
    static let statusDot: CGFloat = 7
    static let segmentH: CGFloat = 30
    static let borderW: CGFloat = 1

    // v2 chrome（玻璃层）
    /// 导航栏内容高（系统 bar 自管高度，这个值给自绘的对齐参考与玻璃钮尺寸）。
    static let navBarH: CGFloat = 54
    /// 导航栏上的玻璃圆钮（返回 / ⋯）。
    static let navGlassRound: CGFloat = 38
    /// 导航栏上的玻璃胶囊文字按钮（保存 / 取消）。
    static let navGlassPillH: CGFloat = 36
}

// MARK: - 分层
//
// **卡片一律无阴影**，分层靠 1px 描边 + 底色差。阴影只给真正浮起的层。
// 这是交接文档里的硬规则，自查清单也有 —— 给卡片加阴影是最容易犯的偏离。
enum UmbraShadow {
    /// 菜单：0 8px 24px rgba(0,0,0,.13)
    static let floatingColor = Color.black.opacity(0.13)
    static let floatingRadius: CGFloat = 24 / 2   // SwiftUI 的 radius 约等于 CSS blur 的一半
    static let floatingY: CGFloat = 8
    /// 模态 / 浮层：0 18px 48px rgba(0,0,0,.22)
    static let modalColor = Color.black.opacity(0.22)
    static let modalRadius: CGFloat = 48 / 2
    static let modalY: CGFloat = 18
}

extension View {
    /// 菜单档阴影（上下文菜单、下拉）。
    func umbraFloatingShadow() -> some View {
        shadow(color: UmbraShadow.floatingColor, radius: UmbraShadow.floatingRadius, x: 0, y: UmbraShadow.floatingY)
    }
    /// 模态档阴影（弹窗、底部 sheet、录音浮层的波形气泡）。
    func umbraModalShadow() -> some View {
        shadow(color: UmbraShadow.modalColor, radius: UmbraShadow.modalRadius, x: 0, y: UmbraShadow.modalY)
    }
}

// MARK: - 动效
//
// 克制：只有颜色/描边过渡、左滑回弹、弹框位移、运行中匀速旋转。
// **无弹跳、无缩放、无入场动画** —— 所以这里刻意不提供 spring。
//（2026-08-25 试过给自绘底栏配过冲弹簧仿系统果冻（jelly），连同自绘底栏
//  一起被实机否掉：果冻是系统私有渲染，底栏已回归系统件，spring 禁令维持。）
enum UmbraMotion {
    /// 颜色 / 描边过渡 .12s–.15s ease
    static let tint = Animation.easeInOut(duration: 0.13)
    /// 左滑回弹 .16s cubic-bezier(.2,.8,.3,1)
    static let swipe = Animation.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.16)
    /// 弹框推入 / 返回 .22s 横向位移（页面转场已交系统，这条只剩浮层在用）
    static let push = Animation.easeOut(duration: 0.22)
    /// 分段控件滑块平移 .22s cubic-bezier(.2,.8,.3,1) —— v2 交接清单点名的取值
    static let slider = Animation.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.22)
    /// 运行中图标旋转：1s linear，无限
    static let spin = Animation.linear(duration: 1).repeatForever(autoreverses: false)
}
