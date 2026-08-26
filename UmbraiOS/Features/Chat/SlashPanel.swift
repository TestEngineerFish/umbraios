// 「/」快捷输入（批次 005 稿）：输入框以「/」开头时弹出输入条上方的浮层卡，
// 继续输入按动作名过滤；点条目 → 输入框左侧留一枚可点掉的前缀芯片 + 灰色参数占位。
// 只归聊天用，所以放 Features/Chat/、类型不带 Umbra 前缀（工程约定：前缀只给 DesignSystem）。
//
// 发送形态（批次 005 拍板）：动作名以 【动作名】 前缀并进正文随消息发出，
// 服务端**零改动** —— 秘书的 LLM 认这个人话前缀，不新增协议字段。
import SwiftUI

// MARK: - 动作目录

/// 一个快捷动作。icon 是 UmbraIconPath 里的路径串（解析器只认 M/L/C/Z 归一化路径，
/// 所以不能直接抄稿里的原始 SVG —— 全部选用图标表里已有的条目）。
struct SlashAction: Identifiable, Equatable {
    let k: String        // 过滤用的英文键（money / insp / rem / task），也当 id
    let label: String    // 动作名，芯片和发送前缀都用它
    let desc: String     // 面板行里的一句说明
    let params: String   // 选中后输入框的灰色参数占位
    let icon: String
    let tag: String?     // Skill / MCP 胶囊标签；内建动作为 nil
    var id: String { k }
}

struct SlashGroup {
    let name: String
    let items: [SlashAction]
}

/// 动作目录。按「可增长的目录」设计：分组渲染、条数不定、整卡可滚。
/// 「接入的能力」组**故意不在**：稿里的翻译/压视频/查天气只是示例，
/// 现在没有真实的 Skill / MCP 接入，摆假动作等于骗用户点一个不存在的功能 ——
/// 等能力接入打通后由真实数据追加成第三组（脚注文案已经把这个预期说出去了）。
enum SlashCatalog {
    static let groups: [SlashGroup] = [
        SlashGroup(name: "记录", items: [
            SlashAction(k: "money", label: "记一笔", desc: "金额、分类，几秒记完",
                        params: "金额 分类 备注", icon: UmbraIconPath.wallet, tag: nil),
            SlashAction(k: "insp", label: "记灵感", desc: "先存下来，标题和标签秘书补",
                        params: "想到什么就写什么", icon: UmbraIconPath.bulb, tag: nil),
            SlashAction(k: "rem", label: "建提醒", desc: "时间 + 要提醒你做什么",
                        params: "时间 要提醒你做什么", icon: UmbraIconPath.bell, tag: nil),
        ]),
        SlashGroup(name: "任务", items: [
            SlashAction(k: "task", label: "创建任务", desc: "描述目标，Umbra 拆步骤去做",
                        params: "要它做什么", icon: UmbraIconPath.task, tag: nil),
        ]),
    ]

    static var total: Int { groups.reduce(0) { $0 + $1.items.count } }

    /// 灵感页「让 Umbra 去做这件事」预填用的就是目录里这枚「创建任务」——
    /// 单独取出来，免得调用方硬编码一份会跟目录漂移的副本。
    static var taskAction: SlashAction { groups[1].items[0] }

    /// 过滤：动作名包含查询串，或英文键包含小写查询串（稿的口径，两端一致）。
    /// 空查询返回全目录。空组整组不出。
    static func filtered(_ q: String) -> [SlashGroup] {
        guard !q.isEmpty else { return groups }
        let lower = q.lowercased()
        return groups.compactMap { g in
            let items = g.items.filter { $0.label.contains(q) || $0.k.contains(lower) }
            return items.isEmpty ? nil : SlashGroup(name: g.name, items: items)
        }
    }
}

// MARK: - 浮层面板

/// 输入条上方的浮层卡：左右 12、圆角 16、玻璃底 + 模态阴影，行高 ≥56，
/// 目录区最大高 296 可滚，底部脚注写清共几个动作。空态给一句话 + 「当普通消息发」出口。
struct SlashPanelView: View {
    let query: String
    let onPick: (SlashAction) -> Void
    let onSendPlain: () -> Void

    var body: some View {
        let groups = SlashCatalog.filtered(query)
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    if groups.isEmpty {
                        emptyState
                    } else {
                        ForEach(groups, id: \.name) { g in group(g) }
                    }
                }
            }
            .frame(maxHeight: 296)
            // 内容不满 296 时卡片贴内容高 —— ScrollView 默认吃满父高，会留一截空底。
            .fixedSize(horizontal: false, vertical: true)

            Text("共 \(SlashCatalog.total) 个动作。新接入的 Skill / MCP 会自动出现在这里。")
                .font(UmbraFont.sans(11, .w400))
                .foregroundColor(UmbraColor.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 9)
                .padding(.bottom, 10)
                .overlay(alignment: .top) {
                    Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
                }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
        )
        .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
    }

    private func group(_ g: SlashGroup) -> some View {
        VStack(spacing: 0) {
            Text(g.name)
                .font(UmbraFont.sans(11, .w600))
                .kerning(11 * 0.06)
                .foregroundColor(UmbraColor.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 3)
            ForEach(Array(g.items.enumerated()), id: \.element.id) { i, a in
                row(a, first: i == 0)
            }
        }
    }

    private func row(_ a: SlashAction, first: Bool) -> some View {
        Button { onPick(a) } label: {
            HStack(spacing: 12) {
                UmbraIcon(d: a.icon, size: 19, strokeWidth: 1.9)
                    .foregroundColor(UmbraColor.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.label)
                        .font(UmbraFont.sans(15.5, .w560))
                        .foregroundColor(UmbraColor.text)
                    Text(a.desc)
                        .font(UmbraFont.sans(12.5, .w400))
                        .foregroundColor(UmbraColor.faint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let tag = a.tag {
                    Text(tag)
                        .font(UmbraFont.mono(10.5, .w400))
                        .foregroundColor(UmbraColor.faint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if !first {
                    Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
                        .padding(.horizontal, 14)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// 空态：一句话 + 出口，不写「暂无数据」（稿的硬规则）。
    /// iOS 稿只有「当普通消息发」一个出口（PC 另有「去能力」，iOS 没画 —— 不擅自加）。
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("没有叫「\(query)」的动作")
                .font(UmbraFont.sans(15, .w560))
                .foregroundColor(UmbraColor.text)
            Text("还没有这个能力。接入 Skill / MCP 之后它会自动出现在这张表里。")
                .font(UmbraFont.sans(12.5, .w400))
                .foregroundColor(UmbraColor.faint)
                .lineSpacing(12.5 * 0.6)
            Button(action: onSendPlain) {
                Text("当普通消息发")
                    .font(UmbraFont.sans(15, .w560))
                    .foregroundColor(UmbraColor.orange)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }
}

// MARK: - 前缀芯片

/// 输入框左侧的动作芯片：orange 描边 + orange-soft 底 + orange-text 字，圆角 8，
/// 图标 + 动作名 + 一个弱化的 ×。整枚芯片就是删除按钮（稿：iOS 点芯片本身删，
/// 没给独立的 × 小按钮）——负 inset 把热区从 26pt 撑到 ≈44pt，不放大视觉。
struct SlashChipView: View {
    let action: SlashAction
    let onDelete: () -> Void

    var body: some View {
        Button(action: onDelete) {
            HStack(spacing: 5) {
                UmbraIcon(d: action.icon, size: 13, strokeWidth: 1.9)
                Text(action.label)
                    .font(UmbraFont.sans(13, .w560))
                UmbraIcon(d: UmbraIconPath.x, size: 12, strokeWidth: 2.2)
                    .opacity(0.75)
            }
            .foregroundColor(UmbraColor.orangeText)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UmbraColor.orangeSoft))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(UmbraColor.orange, lineWidth: UmbraMetric.borderW)
            )
            .contentShape(Rectangle().inset(by: -9))
        }
        .buttonStyle(.plain)
    }
}
