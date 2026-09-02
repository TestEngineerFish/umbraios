// 工具页（Tab 3 根页，稿 tool.home）。
//
// 2026-09-02 稿重排：两张大卡取消，改成**三组、每组两张同尺寸卡片**的网格
//（token iosToolGrid）。理由：这些入口通向的是不同类型的功能，彼此没有主次 ——
// 长列表把它们读成「同一类数据的若干行」，大小卡混排又凭空造出一层主次；
// 分类交给组标题承担，卡片一律同尺寸、同配色。
//   · 图标块走 --chip 底 + --muted 描边图标，**不用橙底**：一屏六张橙卡等于
//     没有重点，且 iOS 上橙底会被读成选中态（批次 004 已定过这条）。
//   · 每张卡底部压一行当前状态（真数据），不写功能介绍。
//   · 红角标只在「有需要人处理的项」时出现 —— 目前只有失败的任务。
//   · 提醒 09-02 提回一级 tab，从这页移除（一个入口只有一个位置）；任务留下。
//
// 与稿的两处一期取舍（记回流台账）：
//   · 记账卡不带「N 笔待确认」—— 待确认是四期截图导入的产物，现在没有；
//   · 常用语卡的状态行写「跨端同步」而不是稿里的「可在键盘上取」——
//     iOS 还没有键盘扩展，写了就是许了个还不存在的愿。
import SwiftUI

struct UmbraToolHomeView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var money: MoneyStore
    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var tasks: TasksViewModel
    @EnvironmentObject private var inspirations: InspirationsViewModel
    @ObservedObject private var phrases = PhraseStore.shared

    var body: some View {
        UmbraScreen {
            // 组间距 18（= sp6，稿 margin-bottom:18）。
            VStack(alignment: .leading, spacing: UmbraMetric.sp6) {
                // 稿在大标题下有一句定位说明 —— 它解释了这页的分区逻辑，照抄。
                Text("按类收着，每个入口一张卡")
                    .font(UmbraFont.sans(13))
                    .foregroundColor(UmbraColor.faint)
                group(name: "记录", cards: recordCards)
                group(name: "账目与安全", cards: moneyCards)
                group(name: "输入辅助", cards: inputCards)
            }
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.top, 2)
        }
        .navigationTitle("工具")
        // 进页就把清单静默拉起来 —— 卡底的状态行是真数据，不拉就只能摆假的；
        // 顺带把记账页预热了（点进去秒开）。提醒 09-02 移出本页，不再从这里拉。
        .onAppear {
            money.loadIfNeeded()
            Task { await tasks.loadTasks() }
            Task { await inspirations.load() }
        }
    }

    // MARK: 卡片数据

    private struct ToolCard: Identifiable {
        let id: String
        let label: String
        let sub: String
        let icon: String
        /// 右上角红角标 —— 只放「需要人来处理的数」，0 = 不显示。
        var attn: Int = 0
        let action: () -> Void
    }

    private var recordCards: [ToolCard] {
        let running = tasks.items.filter { UmbraStatus(taskStatus: $0.status) == .running }.count
        // 「待确认」随旧代理状态一起删了（B 批）：现在要人来处理的是**失败**的任务
        // （看一眼原因 → 重试或重新发起）。语义变化已记回流台账，设计已在稿里采纳。
        let failed = tasks.items.filter { UmbraStatus(taskStatus: $0.status) == .failed }.count
        // 命名避开 open —— 它是 Swift 的访问级别关键字，检查器也会拦。
        let inspOpen = inspirations.list.filter { $0.status == "open" }.count
        return [
            ToolCard(id: "task", label: "任务",
                     sub: tasks.items.isEmpty ? "还没有任务"
                         : "\(running) 个执行中 · \(failed) 个失败",
                     icon: UmbraIconPath.task, attn: failed) {
                router.go(.taskList)
            },
            ToolCard(id: "insp", label: "灵感",
                     sub: inspirations.list.isEmpty ? "还没有灵感"
                         : "\(inspirations.list.count) 条 · \(inspOpen) 条待整理",
                     icon: UmbraIconPath.bulb) {
                router.go(.inspList)
            }
        ]
    }

    private var moneyCards: [ToolCard] {
        [
            ToolCard(id: "money", label: "记账", sub: moneySub,
                     icon: UmbraIconPath.wallet) { router.go(.moneyHome) },
            ToolCard(id: "vault", label: "密码保险箱", sub: vaultSub,
                     icon: UmbraIconPath.lockKeyhole) { router.go(.vaultHome) }
        ]
    }

    private var inputCards: [ToolCard] {
        [
            ToolCard(id: "phrase", label: "常用语",
                     sub: phrases.items.isEmpty ? "还没有常用语"
                         : "\(phrases.items.count) 条 · 跨端同步",
                     icon: UmbraIconPath.messageText) {
                router.go(.mePhrases)
            },
            ToolCard(id: "widgets", label: "小组件与轻点背面",
                     sub: "中号 + 小号 · 双击背面记一笔",
                     icon: UmbraIconPath.layoutGrid) {
                router.go(.toolWidgets)
            }
        ]
    }

    /// 本月支出。统计还没拉到时写「—」，不编一个 0（0 是「本月没花钱」，是数据）。
    private var moneySub: String {
        guard let s = money.stats else { return "本月 —" }
        return "本月 \(MoneyFmt.yuan(s.expense))"
    }

    /// 三种真状态：没建过 / 锁着 / 开着（N 条只有解锁后才知道，锁着时不编数）。
    private var vaultSub: String {
        if vault.unlocked { return "\(vault.items.count) 条 · 已解锁" }
        return vault.recordExists || vault.hasSecretKey ? "已锁定" : "还没创建"
    }

    // MARK: 布局

    /// 组标题（11.5-600 / 字距 .08em / --faint）+ 两列网格（列间距 11）。
    /// 每组恒定两张卡，直接 HStack 摆 —— LazyVGrid 是给「不知道几个」的场合准备的。
    private func group(name: String, cards: [ToolCard]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(name)
                .font(UmbraFont.sans(11.5, .w600))
                .kerning(11.5 * 0.08)
                .foregroundColor(UmbraColor.faint)
                .padding(.horizontal, 2)
            HStack(alignment: .top, spacing: 11) {
                ForEach(cards) { card in cardView(card) }
            }
        }
    }

    private func cardView(_ card: ToolCard) -> some View {
        Button(action: card.action) {
            VStack(alignment: .leading, spacing: 9) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(UmbraColor.chip)
                    .frame(width: 36, height: 36)
                    .overlay(
                        UmbraIcon(d: card.icon, size: 19, strokeWidth: 1.8)
                            .foregroundColor(UmbraColor.muted)
                    )
                Text(card.label)
                    .font(UmbraFont.sans(15.5, .w600))
                    .foregroundColor(UmbraColor.text)
                    .multilineTextAlignment(.leading)
                // 状态行压卡底（稿 margin-top:auto）：中间的 Spacer 把它推下去，
                // 两张卡高度由 minHeight 拉平，行数差异不会让它们参差。
                Spacer(minLength: 0)
                Text(card.sub)
                    .font(UmbraFont.sans(12.5))
                    .foregroundColor(UmbraColor.faint)
                    .lineSpacing(12.5 * 0.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            // 先 padding 再 frame：稿的 min-height:126 是含内边距的盒高
            // （box-sizing:border-box），倒过来会把卡撑到 152。
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(UmbraColor.card))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(UmbraColor.borderSoft, lineWidth: UmbraMetric.borderW))
            // 催办数字 = 计数角标（系统底栏徽标同款红），右上角绝对定位（稿 top/right 12）。
            // 中性数量不做角标 —— 「有多少条」已经写在状态行里，角标只留给催人的数。
            .overlay(alignment: .topTrailing) {
                UmbraCountBadge(count: card.attn)
                    .padding(12)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
