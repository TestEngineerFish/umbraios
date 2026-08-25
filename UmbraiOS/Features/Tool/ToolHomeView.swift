// 工具页（Tab 2 根页，稿 tool.home）。
//
// TabBar 从五个减到三个（2026-08-23 稿）：任务和提醒都是「待办清单」，并列在
// 一级 tab 上分不清该点哪个 —— 全部收进这一页，由「记录」组统一收口；
// 记账和保险箱是最常进出的两个工具，给两张大卡放最上面。
//
// 与稿的两处一期取舍（记回流台账）：
//   · 记账大卡不带「N 笔待确认」标签 —— 待确认是四期截图导入的产物，现在没有；
//   · 「小组件与轻点背面」一行不画 —— 那是一整屏教学页（稿 widgets），
//     iOS 还没有这一屏，放一个点了没反应的入口比不放更糟。
import SwiftUI

struct UmbraToolHomeView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var money: MoneyStore
    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var tasks: TasksViewModel
    @EnvironmentObject private var inspirations: InspirationsViewModel
    @ObservedObject private var reminders = ReminderStore.shared

    var body: some View {
        UmbraScreen {
            VStack(alignment: .leading, spacing: UmbraMetric.sp6) {
                bigCards
                group(name: "记录", rows: recordRows)
                group(name: "输入辅助", rows: inputRows)
            }
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.top, 2)
        }
        .navigationTitle("工具")
        // 进页就把三份清单静默拉起来 —— 大卡和行里的数字是真数据，
        // 不拉就只能摆假的；顺带把记账页预热了（点进去秒开）。
        .onAppear {
            money.loadIfNeeded()
            Task { await tasks.loadJobs() }
            Task { await inspirations.load() }
        }
    }

    // MARK: 大卡（记账 + 保险箱）

    private var bigCards: some View {
        HStack(spacing: 9) {
            bigCard(
                label: "记账",
                sub: moneySub,
                icon: UmbraIconPath.wallet,
                accent: true
            ) { router.go(.moneyHome) }
            bigCard(
                label: "密码保险箱",
                sub: vaultSub,
                icon: UmbraIconPath.lockKeyhole,
                accent: false
            ) { router.go(.vaultHome) }
        }
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

    private func bigCard(label: String, sub: String, icon: String, accent: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(accent ? UmbraColor.orange : UmbraColor.chip)
                    .frame(width: 36, height: 36)
                    .overlay(
                        UmbraIcon(d: icon, size: 18, strokeWidth: 1.9)
                            .foregroundColor(accent ? .white : UmbraColor.muted)
                    )
                Text(label)
                    .font(UmbraFont.sans(15.5, .w600))
                    .foregroundColor(UmbraColor.text)
                Text(sub)
                    .font(UmbraFont.sans(12.5))
                    .foregroundColor(accent ? UmbraColor.orangeText : UmbraColor.faint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(accent ? UmbraColor.orangeSoft : UmbraColor.card))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(accent ? UmbraColor.orange : UmbraColor.border, lineWidth: UmbraMetric.borderW))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 分组行

    private struct ToolRow: Identifiable {
        let id: String
        let label: String
        let sub: String
        let icon: String
        /// 右侧数字胶囊。0 = 不显示。attn = true 时橙底白字（要人来处理的数）。
        var count: Int = 0
        var attn: Bool = false
        let action: () -> Void
    }

    private var recordRows: [ToolRow] {
        let running = tasks.jobs.filter { UmbraStatus(jobStatus: $0.status) == .running }.count
        let taskAttn = tasks.jobs.filter { UmbraStatus(jobStatus: $0.status) == .awaitingReview }.count
        let undone = reminders.items.filter { !$0.done }.count
        let overdue = reminders.items.filter { !$0.done && $0.group == "已过期" }.count
        // 命名避开 open —— 它是 Swift 的访问级别关键字，检查器也会拦。
        let inspOpen = inspirations.list.filter { $0.status == "open" }.count
        return [
            ToolRow(id: "task", label: "任务",
                    sub: tasks.jobs.isEmpty ? "还没有任务"
                        : "\(running) 个执行中 · \(taskAttn) 个待确认",
                    icon: UmbraIconPath.task,
                    count: taskAttn > 0 ? taskAttn : running, attn: taskAttn > 0) {
                router.go(.taskList)
            },
            ToolRow(id: "rem", label: "提醒",
                    sub: reminders.items.isEmpty ? "还没有提醒"
                        : (undone == 0 ? "都完成了" : "\(undone) 个未完成 · \(overdue) 个已逾期"),
                    icon: UmbraIconPath.bell,
                    count: overdue > 0 ? overdue : undone, attn: overdue > 0) {
                router.go(.remList)
            },
            ToolRow(id: "insp", label: "灵感",
                    sub: inspirations.list.isEmpty ? "还没有灵感"
                        : "\(inspirations.list.count) 条 · \(inspOpen) 条待整理",
                    icon: UmbraIconPath.bulb,
                    count: inspOpen) {
                router.go(.inspList)
            }
        ]
    }

    private var inputRows: [ToolRow] {
        [
            ToolRow(id: "phrase", label: "常用语",
                    sub: "跨端同步，聊天里随取随用",
                    icon: UmbraIconPath.messageText) {
                router.go(.mePhrases)
            }
        ]
    }

    private func group(name: String, rows: [ToolRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(UmbraFont.sans(12, .w600))
                .foregroundColor(UmbraColor.faint)
                .padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { UmbraRowDivider() }
                    rowView(row)
                }
            }
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                .fill(UmbraColor.card))
            .overlay(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW))
        }
    }

    private func rowView(_ row: ToolRow) -> some View {
        Button(action: row.action) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(UmbraColor.chip)
                    .frame(width: 32, height: 32)
                    .overlay(
                        UmbraIcon(d: row.icon, size: 16, strokeWidth: 1.9)
                            .foregroundColor(UmbraColor.muted)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .font(UmbraFont.sans(15, .w560))
                        .foregroundColor(UmbraColor.text)
                    Text(row.sub)
                        .font(UmbraFont.sans(12))
                        .foregroundColor(UmbraColor.faint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if row.count > 0 {
                    Text("\(row.count)")
                        .font(UmbraFont.mono(11.5, .w600))
                        .foregroundColor(row.attn ? .white : UmbraColor.muted)
                        .padding(.horizontal, 7).frame(minWidth: 20, minHeight: 19)
                        .background(Capsule().fill(row.attn ? UmbraColor.orange : UmbraColor.chip))
                }
                UmbraIcon(d: UmbraIconPath.chevronRight, size: 15, strokeWidth: 2)
                    .foregroundColor(UmbraColor.faint)
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
