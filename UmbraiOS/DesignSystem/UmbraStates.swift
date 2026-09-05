// 三态五件（批次 015 后，骨架 `iosShell.states`）：空 / 无结果 / 离线 / 骨架 / 错误卡。
//
// 「空」和「无结果」共用 `UmbraEmptyState`（在 UmbraPrimitives.swift，靠 tone 分档）；
// 这个文件装剩下三件：骨架、离线条、错误卡，外加卡内无数据的 compact 档。
//
// 为什么单独一个文件而不是塞进 UmbraPrimitives：这三件是**页面级状态**，不是视觉基元 ——
// 它们要读页面的加载/离线/错误标志，改一处会同时影响二十来个页面的首屏。
// 混进基元文件里，下次有人调基元时不知道自己动的是全站首屏。
//
// ⚠️ 落地范围：这一批做的是**件本身 + 不依赖数据层的收编**。
// 「离线条 + 内容压 opacity」和「各页首屏骨架」还差数据层的两个标志位 ——
// 现在只有 VaultStore 有 `offline`，MoneyStore 的 Phase 把「离线」和「出错」并成了一档，
// 任务 / 灵感 / 提醒三个 store 连首屏 loading 都没有。件先摆好，标志位是下一轮的活。
import SwiftUI

// MARK: - 骨架
//
// 首屏加载用骨架，**不转圈也不周期呼吸**（`states.skeleton`）。
// 不呼吸这条是和 PC 对齐的硬规矩：呼吸动画会让人以为「它在动 = 它在进展」，
// 而骨架其实什么都不知道；静止的灰条老实得多。
//
// 三行、每行两条，宽度沿用 PC 的 62/84、48/72、55/66%；只把条高从 PC 的 12/10
// 提到 14/11、圆角 6→7（iOS 正文 16 对 PC 的 12.5，密度提一档）。

/// 首屏骨架。**只在「一条数据都还没有」时用** —— 下拉刷新已有列表不换骨架
/// （`states.skeleton` 最后一句）：列表已经在了还闪回灰条，人会以为数据没了。
struct UmbraSkeleton: View {
    /// 画几组。一组 = 稿里的「一行」（其实是上下两条）。
    var groups: Int = 3

    /// 每组两条的宽度比例，照稿的 62/84、48/72、55/66。
    private static let widths: [(CGFloat, CGFloat)] = [(0.62, 0.84), (0.48, 0.72), (0.55, 0.66)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<max(1, groups), id: \.self) { i in
                let w = Self.widths[i % Self.widths.count]
                VStack(alignment: .leading, spacing: 8) {
                    bar(w.0, height: 14)
                    bar(w.1, height: 11)
                }
            }
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.top, UmbraMetric.sp5)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 骨架不是内容，不该被读屏逐条念出来。
        .accessibilityElement()
        .accessibilityLabel("正在读取")
    }

    /// 宽度按容器比例给，不写死点数 —— 同一副骨架要在 iPhone SE 和 Pro Max 上都像内容。
    private func bar(_ frac: CGFloat, height: CGFloat) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(UmbraColor.track)
                .frame(width: geo.size.width * frac, height: height)
        }
        .frame(height: height)
    }
}

// MARK: - 离线条
//
// `states.offline`：「有缓存可看时：顶部 warning-soft 条 + 内容留着压 opacity .6，**不清屏**；
// 没缓存才退成错误卡。」
//
// 「不清屏」是这条的全部重点。密码管理器 / 记账这类东西，最该顶用的时刻恰恰是网络不通的时刻，
// 拿不到新数据就把旧数据也擦掉，等于把「有点旧」升级成「什么都没有」。

// 这里**故意没有单独的 UmbraOfflineBar**。离线条就是错误卡的 banner 形取 warning 档
//（`UmbraErrorCard(variant: .banner, tone: .warning, …)`）—— 稿自己写着「一件三形，
// **不新造第四形**」。多摆一个只服务一个场景的件，下场参照 UmbraSwipeRow：
// 定义完整、全项目零引用，谁也不敢删。

extension View {
    /// 离线时把内容压到 .6（`states.offline`）。**压不是禁用** —— 内容照样能点、能滚，
    /// 压的是「这不是最新的」这层意思。
    ///
    /// ⚠️ 现在**只有保险箱有真的 offline 标志位**（`VaultStore.offline`），
    /// 记账 / 任务 / 灵感 / 提醒四个 store 都还分不出「离线看缓存」和「拿不到数据」——
    /// MoneyStore 的 Phase 干脆把这两件事并成了一档 `.error`。
    /// 所以这条修饰符这一批**还没有调用点**，是给下一轮（数据层补标志位）准备的。
    /// 它只有一行，不构成 UmbraSwipeRow 那种「定义完整、谁也不敢删」的死件。
    func umbraOfflineDimmed(_ offline: Bool) -> some View {
        opacity(offline ? 0.6 : 1)
    }
}

// MARK: - 错误卡（一件三形）
//
// `states.errorCard`：「一件三形，和 PC 错误卡.dc.html 的 variant 一一对应，**不新造第四形**。」
//
//   · strip  —— 默认、最常用。挂在出错的那个东西下面一行（聊天的发送失败行就是它）。
//   · card   —— 整屏拿不到数据。
//   · banner —— 局部 / 通道问题，顶部满宽条（离线那一件就是这个形）。
//
// 三形都是三段式：**发生了什么 · 为什么 · 一颗可点的钮**。第三段一律是钮，
// 不是「稍后重试」这种说了等于没说的话。

/// 错误卡的形。
enum UmbraErrorVariant {
    case strip, card, banner
}

/// 一件三形的错误卡。
///
/// `tone` 只对 banner 有意义（提醒级 warning / 出错级 danger）；strip 和 card 恒 danger ——
/// 一条消息没发出去、一屏数据拿不到，没有「提醒级」这一说。
struct UmbraErrorCard: View {
    var variant: UmbraErrorVariant = .strip
    var tone: UmbraStateTone = .danger
    /// 第一段：发生了什么。strip 形可以省（那时正文自己就是全部）。
    var title: String? = nil
    /// 第二段：为什么。
    var reason: String
    /// 第三段：主动作。**必给** —— 没有可点的钮就不算错误卡。
    var actionTitle: String
    var action: () -> Void
    /// 第二颗动作（card 形的两颗并排各占一半）。
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    /// 原始返回。**只有 card 形会画**（`states.rawBlock`），默认收起。
    var raw: String? = nil

    @State private var showRaw = false

    private var tint: Color { tone == .warning ? UmbraColor.warning : UmbraColor.danger }
    private var soft: Color { tone == .warning ? UmbraColor.warningSoft : UmbraColor.dangerSoft }

    var body: some View {
        switch variant {
        case .strip:  stripBody
        case .card:   cardBody
        case .banner: bannerBody
        }
    }

    // MARK: strip

    /// 挂在出错的那个东西下面一行。聊天里的发送失败行已经手写了同一个形
    /// （`ChatThreadView.failedRow`），那两处**没有收编到这里**：它们的动作要拿到
    /// 具体那条消息的 blockId，塞进这个通用件反而要多传三个参数。形是一样的。
    private var stripBody: some View {
        HStack(alignment: .top, spacing: 6) {
            UmbraIcon(d: UmbraIconPath.alertOctagon, size: 14, strokeWidth: 2)
                .foregroundColor(tint)
            Text(reason)
                .font(UmbraFont.sans(12.5, .w400))
                .foregroundColor(tint)
                .fixedSize(horizontal: false, vertical: true)
            actionLink(.top)
        }
        // 行撑到真实的 44，钮的热区整块落在行内（`minTapTarget.siblingClearance`）。
        .frame(minHeight: UmbraMetric.tapMin)
    }

    /// 行内文字动作。横向不撑（`minTapTarget.horizontalNot44`：横向只能从邻居身上抢），
    /// 纵向**跟着行长满** —— strip / banner 两个形的行本身已经撑到 44（见下面两处
    /// `.frame(minHeight: tapMin)`）。
    ///
    /// ⚠️ 这里原来是 `.frame(minHeight: 44)` + `.padding(.vertical, -13)`：行高不变，
    /// 但那 13pt 是从上下邻居身上借的。`minTapTarget.siblingClearance`（批次 016）
    /// 点名这种写法 —— 差的那截会吐到邻居身上，而这一行在绘制顺序里靠后、它赢，
    /// 于是邻居那条窄带上的点击 / 长按被这颗钮吃掉。
    /// 正确做法是把行撑到真实的 44，钮在行里长满。
    /// - Parameter align: 文字在这 44 里靠哪儿。**strip 形必须传 `.top`** ——
    ///   它那个 HStack 是 `.top` 对齐的，44 的框被顶到行首，文字若还居中就比同一句话里的
    ///   图标和正文低了约 13pt，读起来不像一句话里的钮。banner 形的 HStack 是 `.center`，
    ///   用默认的居中正好。
    private func actionLink(_ align: Alignment = .center) -> some View {
        Button(action: action) {
            Text(actionTitle)
                .font(UmbraFont.sans(12.5, .w600))
                .foregroundColor(tint)
                .fixedSize()
                // **定尺 44**，不是 `maxHeight: .infinity`：贪婪写法会把整行的尺寸范围
                // 变成 [44, ∞)，在非滚动容器里（比如离线条将来要挂的页面顶部）会被拉长。
                .frame(height: UmbraMetric.tapMin, alignment: align)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: card

    /// 整屏拿不到数据。**不设 520 上限** —— 手机宽度就是它的宽度（稿里那句原话）。
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                UmbraIcon(d: UmbraIconPath.alertOctagon, size: 16, strokeWidth: 2)
                    .foregroundColor(tint)
                VStack(alignment: .leading, spacing: 5) {
                    if let t = title {
                        Text(t)
                            .font(UmbraFont.sans(13.5, .w600))
                            .foregroundColor(UmbraColor.text)
                    }
                    Text(reason)
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .lineSpacing(13 * 0.6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let r = raw, !r.isEmpty { rawSection(r) }
            // 两颗并排各占一半（稿：底部 44 高描边钮两颗并排各 flex:1）。
            // 只有一颗时它自己撑满 —— 不留半个空位。
            HStack(spacing: 8) {
                UmbraButton(title: actionTitle, kind: .secondary, height: 44, action: action)
                if let t = secondaryTitle, let a = secondaryAction {
                    UmbraButton(title: t, kind: .secondary, height: 44, action: a)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(soft))
        // strokeBorder 而不是 stroke：stroke 压线画，外侧一半会被裁掉，1px 只剩 0.5px。
        .overlay(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
            .strokeBorder(tint, lineWidth: UmbraMetric.borderW))
        .padding(.horizontal, UmbraMetric.pagePadX)
        // 纵向留白**做在件里面**，不留给调用方：这张卡经常被塞在两节内容之间
        // （任务详情就是），外层 VStack 的 spacing 是 0，忘了补就会和上一节的
        // 发丝线贴死 —— 一个每个调用点都要记得的事，就该由件自己管。
        .padding(.vertical, UmbraMetric.sp4)
    }

    /// 原始返回块（`states.rawBlock`）：`--track` 底 / 圆角 9 / padding 9-11 /
    /// 12px 等宽 / 长串强断 / **max-height 96 内部滚动**。
    /// 默认收起，按钮在「看原始返回 / 收起原始返回」之间切 —— 它是给排查用的，
    /// 常显会让一张本来在说人话的卡变成一坨日志。
    @ViewBuilder
    private func rawSection(_ r: String) -> some View {
        // ⚠️ 这颗折叠钮**不给负边距**（`minTapTarget.siblingClearance`）：它上下都是
        // 卡里的真内容（上面是原因文字、下面是两颗 44 高的动作钮），负 13.5 会直接
        // 盖到下面那两颗钮的上沿 —— 那是「向可点的东西借」，规矩明令不许。
        // 卡因此高出约 27pt，认这个代价。
        Button { withAnimation(UmbraMotion.tint) { showRaw.toggle() } } label: {
            Text(showRaw ? "收起原始返回" : "看原始返回")
                .font(UmbraFont.sans(12, .w600))
                .foregroundColor(UmbraColor.muted)
                .frame(maxWidth: .infinity, minHeight: UmbraMetric.tapMin, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if showRaw {
            ScrollView {
                Text(r)
                    .font(UmbraFont.mono(12))
                    .foregroundColor(UmbraColor.muted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 96 是**上限**不是固定高：短的原始返回不该被撑成一个空盒子。
            .frame(maxHeight: 96)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UmbraColor.track))
        }
    }

    // MARK: banner

    /// 顶部满宽条。**离线态就用这个形取 warning 档**，不另立一个件（见文件上方那段注释）。
    private var bannerBody: some View {
        HStack(spacing: 8) {
            UmbraIcon(d: tone == .warning ? UmbraIconPath.alertTriangle : UmbraIconPath.alertOctagon,
                      size: 15, strokeWidth: 2)
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 2) {
                if let t = title {
                    Text(t)
                        .font(UmbraFont.sans(12.5, .w560))
                        .foregroundColor(tint)
                }
                Text(reason)
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(tint.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actionLink()
        }
        .frame(minHeight: UmbraMetric.tapMin)
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(soft)
    }
}

// MARK: - 卡内无数据
//
// `states.cardNoData`：「屏上某一张卡取不到数（记账统计卡、任务进度卡）就在卡内套 compact 档，
// **不用整屏态**。块 48 / 圆角 14 / 字形 22 / gap 9 / padding 26-16，标题 560 14，
// **不给正文也不给按钮**。」
//
// 「不给正文也不给按钮」是这一档的定义：整屏空态要教人怎么开始，卡内空态只需要说明
// 「这块没数」—— 屏上别的卡还有数，人不是无事可做。

struct UmbraCardNoData: View {
    var iconPath: String
    let title: String

    var body: some View {
        VStack(spacing: 9) {
            UmbraIconBlock(d: iconPath, block: 48, icon: 22,
                           bg: UmbraColor.chip, fg: UmbraColor.muted, corner: 14)
            Text(title)
                .font(UmbraFont.sans(14, .w560))
                .foregroundColor(UmbraColor.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 26)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }
}
