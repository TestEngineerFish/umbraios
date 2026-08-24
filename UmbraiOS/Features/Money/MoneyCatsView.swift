// 分类管理（money.cats，对齐稿 2797–2840 的结构，能力收在服务端一期以内）。
//
// 一期能做的：改名、停用、恢复。做不了的（都已记进回流台账）：
//   · 新增分类 —— 服务端没有建分类的接口（内置 16 个，slug 是稳定标识）；
//   · 子类管理（money.cat 整屏）—— 服务端不存子类表，二级只是客户端的输入建议；
//   · 色槽 —— iOS 稿本来就没画色槽管理，改色槽在 PC 的 设置 → 记账 里。
//
// 停用不是删除：选择器里不再出现，历史流水照旧挂在它名下，统计不变，随时能恢复
// （服务端 update_category 的注释就是这么定的）。locked（其他 / 其他-收入）是兜底
// 分类，不给停用 —— 别的分类停用后历史数据还有地方归，兜底自己没了就真没地方了。
import SwiftUI

struct UmbraMoneyCatsView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var money: MoneyStore

    @State private var renaming: MoneyCatDTO?
    @State private var renameText = ""
    @State private var busy = false

    var body: some View {
        UmbraScreen {
            VStack(alignment: .leading, spacing: UmbraMetric.sp6) {
                group("支出", cats: money.cats.filter { $0.direction == "expense" && $0.enabled })
                group("收入", cats: money.cats.filter { $0.direction == "income" && $0.enabled })
                disabledGroup
                Text("改名只改显示名，不影响历史数据 —— 流水里存的是稳定标识。停用的分类不再出现在选择器里，历史账目仍归它，统计不变。")
                    .font(UmbraFont.sans(12)).foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)
                    .padding(.horizontal, UmbraMetric.pagePadX)
            }
            .padding(.top, UmbraMetric.sp2)
        }
        .navigationTitle("分类管理")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await money.reload(silent: true) }
        .onAppear { money.loadIfNeeded() }
        // iOS 16 的 alert 允许放 TextField —— 一个改名不值一整张自定义弹层。
        .alert("重命名「\(renaming?.name ?? "")」", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("显示名", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") { commitRename() }
        } message: {
            Text("改名不影响历史数据。")
        }
    }

    // MARK: 分组

    private func group(_ title: String, cats: [MoneyCatDTO]) -> some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
            Text(title).font(UmbraFont.sans(12, .w600)).foregroundColor(UmbraColor.faint)
                .padding(.horizontal, UmbraMetric.pagePadX)
            VStack(spacing: 0) {
                ForEach(Array(cats.enumerated()), id: \.element.slug) { idx, c in
                    if idx > 0 { UmbraRowDivider() }
                    catRow(c)
                }
            }
            .moneyCard()
            .padding(.horizontal, UmbraMetric.pagePadX)
        }
    }

    private func catRow(_ c: MoneyCatDTO) -> some View {
        Button { openSheet(c) } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(UmbraColor.chip)
                    .frame(width: 34, height: 34)
                    .overlay(UmbraIcon(d: MoneyCatArt.icon(c.slug), size: 18, strokeWidth: 1.9)
                        .foregroundColor(MoneyCatArt.slotColor(c.slot)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(c.name).font(UmbraFont.sans(15, .w560)).foregroundColor(UmbraColor.text)
                        if c.locked {
                            Text("兜底分类")
                                .font(UmbraFont.sans(10.5, .w600)).foregroundColor(UmbraColor.faint)
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .background(Capsule().fill(UmbraColor.chip))
                        }
                    }
                    Text(meta(c)).font(UmbraFont.sans(12)).foregroundColor(UmbraColor.muted)
                }
                Spacer(minLength: 6)
                UmbraIcon(d: UmbraIconPath.chevronRight, size: 15, strokeWidth: 2.2)
                    .foregroundColor(UmbraColor.faint)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// meta：二级建议数 + 本月笔数。「本月」两个字不能省 —— 手机上只有本月数据，
    /// 光写「N 笔账」会被读成历史总数。
    private func meta(_ c: MoneyCatDTO) -> String {
        let subs = MoneySubs.of(c.slug).count
        let used = money.entries.filter { $0.cat == c.slug }.count
        let subText = subs > 0 ? "\(subs) 个二级建议" : "没有二级"
        return "\(subText) · 本月 \(used) 笔"
    }

    @ViewBuilder
    private var disabledGroup: some View {
        let hidden = money.cats.filter { !$0.enabled }
        if !hidden.isEmpty {
            VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
                Text("已停用").font(UmbraFont.sans(12, .w600)).foregroundColor(UmbraColor.faint)
                    .padding(.horizontal, UmbraMetric.pagePadX)
                VStack(spacing: 0) {
                    ForEach(Array(hidden.enumerated()), id: \.element.slug) { idx, c in
                        if idx > 0 { UmbraRowDivider() }
                        HStack(spacing: 11) {
                            Text(c.name).font(UmbraFont.sans(15)).foregroundColor(UmbraColor.muted)
                            Spacer()
                            UmbraButton(title: "恢复", kind: .secondary, height: 32) {
                                run(toast: "已恢复「\(c.name)」") {
                                    await money.updateCat(slug: c.slug, enabled: true)
                                }
                            }
                            .frame(width: 72)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 52)
                    }
                }
                .moneyCard()
                .padding(.horizontal, UmbraMetric.pagePadX)
            }
        }
    }

    // MARK: 操作

    private func openSheet(_ c: MoneyCatDTO) {
        var items: [UmbraSheetItem] = [
            UmbraSheetItem(label: "改名", note: "不影响历史数据") {
                renameText = c.name
                renaming = c
            },
        ]
        if !c.locked {
            items.append(UmbraSheetItem(label: "停用", note: "选择器里不再出现，历史不变", destructive: true) {
                run(toast: "已停用「\(c.name)」，随时能在下面恢复") {
                    await money.updateCat(slug: c.slug, enabled: false)
                }
            })
        }
        router.present(UmbraSheet(title: c.name, subtitle: meta(c), items: items))
    }

    private func commitRename() {
        guard let c = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != c.name else { return }
        run(toast: "已改名为「\(name)」") {
            await money.updateCat(slug: c.slug, name: name)
        }
    }

    /// 统一的写操作壳：防连点 + 成败吐司。失败文案不甩锅给用户，只说下一步。
    private func run(toast: String, _ op: @escaping () async -> Bool) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            let ok = await op()
            busy = false
            router.showToast(ok ? toast : "没存上，检查网络后再试")
        }
    }
}
