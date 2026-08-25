// 记一笔 / 编辑账目（money.add，对齐稿 2521–2636）。
//
// 与稿的三处一期取舍（都已记进回流台账）：
//   · 「新增分类」「管理子类」不画 —— 服务端一期没有建分类 / 存子类的接口，
//     放一个点了没反应的入口比不放更糟；
//   · 「附件」整段不画 —— money_entries 表没有附件字段（它属于四期截图链路）；
//   · 保存失败的文案说真话：「检查网络后再点一次保存」，不说「已排队自动重试」——
//     离线队列要等整体同步模型拍板（05 的 E15），没有队列就不许诺队列。
import SwiftUI

struct UmbraMoneyAddView: View {
    /// nil = 新建；非 nil = 编辑 store.entries 里的这一条。
    let id: String?

    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var money: MoneyStore

    @State private var expr = ""
    @State private var dir = "expense"
    @State private var cat: String?
    @State private var sub = ""
    @State private var note = ""
    @State private var atDate = Date()
    @State private var showDatePick = false
    @State private var showTimePick = false
    @State private var busy = false
    @State private var failed = false
    /// 编辑态只在**进页那一刻**灌一次值 —— save 之后 store 会静默重拉，
    /// 不挡住的话 onAppear 再跑会把用户正在改的草稿冲掉。
    @State private var seeded = false
    @FocusState private var amountFocused: Bool

    /// 编辑的原条目（身份字段 src / rule_id / batch_id / order_no 要原样带回去）。
    private var editing: MoneyEntryDTO? {
        id.flatMap { eid in money.entries.first { $0.id == eid } }
    }

    private var cents: Int? { MoneyAmount.cents(expr) }
    private var canSave: Bool { cents != nil && cat != nil && !busy }

    var body: some View {
        UmbraScreen {
            VStack(alignment: .leading, spacing: 13) {
                if failed { failBanner }
                amountCard
                recentRow
                catGrid
                subChips
                timeNoteCard
            }
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.top, UmbraMetric.sp2)
        } bottom: {
            bottomBar
        }
        .navigationTitle(id == nil ? "记一笔" : "编辑账目")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { router.back() }.tint(UmbraColor.muted)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.go(.moneyCats) } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .tint(UmbraColor.muted)
            }
            // ⚠️ 这里**不许**再挂 ToolbarItemGroup(placement: .keyboard)。
            // 上一版把 ＋－×÷ 放在键盘上方的工具条里，结果键盘收起后底部避让
            // inset 会卡住不还（tab bar 隐藏 + 键盘附件条的系统级冲突）——
            // 同一条导航栈上的**所有页面**底部都空出一大块键盘高度的黑（用户
            // 截图实锤：统计页、回收站全中招，kill App 才恢复）。
            // 运算符改放金额卡片里（见 amountCard），收键盘靠点空白 / 下拉。
        }
        .onAppear { seed() }
        .umbraWheelPicker(isPresented: $showDatePick, title: "日期", mode: .date, date: $atDate)
        .umbraWheelPicker(isPresented: $showTimePick, title: "时间", mode: .time, date: $atDate)
    }

    /// 进页灌初值：编辑态从原条目来；新建默认支出 + 当前时刻 + 该方向第一个分类。
    private func seed() {
        guard !seeded else { return }
        seeded = true
        if let e = editing {
            expr = String(format: "%.2f", Double(e.cents) / 100)
            dir = e.direction
            cat = e.cat
            sub = e.sub
            note = e.merchant
            atDate = Date(umbraMs: e.at_ms)
        } else {
            cat = money.enabledCats(dir).first?.slug
            amountFocused = true
        }
    }

    // MARK: 金额

    private var amountCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dir == "expense" ? "支出金额" : "收入金额")
                .font(UmbraFont.sans(12, .w600)).foregroundColor(UmbraColor.faint)
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("¥").font(UmbraFont.sans(22)).foregroundColor(UmbraColor.muted)
                // 纯数字键盘（验收点名：金额不该弹出符号和拼音）。
                // 算式要用的 ＋－×÷ 是下面卡片内的一排芯片 —— 不挂键盘工具条，
                // 那个方案会把整条导航栈的底部 inset 卡死（见 .toolbar 处的警告）。
                TextField("0.00", text: $expr)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(UmbraFont.mono(38, .w650))
                    .foregroundColor(cents != nil ? UmbraColor.text : UmbraColor.faint)
                    .focused($amountFocused)
            }
            // 运算符芯片：decimalPad 打不出 ＋－×÷，从这里补进算式。
            // 点芯片顺手把焦点拉回金额框 —— 键盘收着时点「＋」，多半是想接着敲数字。
            HStack(spacing: 8) {
                ForEach(["+", "-", "×", "÷"], id: \.self) { op in
                    Button {
                        expr += op
                        amountFocused = true
                    } label: {
                        Text(op)
                            .font(UmbraFont.mono(17, .w560))
                            .foregroundColor(UmbraColor.orangeText)
                            .frame(width: 44, height: 32)
                            .background(Capsule().fill(UmbraColor.chip))
                            .overlay(Capsule().strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if !expr.isEmpty {
                    Button {
                        expr = ""
                        amountFocused = true
                    } label: {
                        Text("清空")
                            .font(UmbraFont.sans(12.5, .w560))
                            .foregroundColor(UmbraColor.muted)
                            .frame(height: 32).padding(.horizontal, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
            if MoneyAmount.isExpr(expr) {
                Text(cents.map { "= \(MoneyFmt.yuan($0))" } ?? "算式还没写完")
                    .font(UmbraFont.mono(12.5))
                    .foregroundColor(cents != nil ? UmbraColor.orangeText : UmbraColor.faint)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .moneyCard()
    }

    private var failBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            // 2026-08-24 稿：错误图标从圆形改成八角形轮廓（和 info 的圆一眼分得开）。
            UmbraIcon(d: "M8.6,3L15.4,3L21,8.6L21,15.4L15.4,21L8.6,21L3,15.4L3,8.6ZM12,8L12,12.5M12,16L12.01,16", size: 15, strokeWidth: 2)
                .foregroundColor(UmbraColor.danger)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text("没存上：服务端没有响应。内容都还在，检查网络后再点一次保存。")
                    .font(UmbraFont.sans(13, .w560)).foregroundColor(UmbraColor.danger)
                UmbraButton(title: "重试保存", kind: .dangerOutline, height: 34) { save(again: false) }
                    .frame(maxWidth: 120)
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UmbraColor.dangerSoft))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(UmbraColor.danger, lineWidth: UmbraMetric.borderW))
    }

    // MARK: 方向 + 分类

    /// 方向切换放内容区第一行（稿放在导航栏中间，但系统导航栏塞不下一个像样的
    /// 分段控件 —— principal 位在小屏上会被两侧按钮挤到只剩几十点宽）。
    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            UmbraSegmentedControl(items: [
                .init(value: "expense", label: "支出"),
                .init(value: "income", label: "收入"),
            ], selection: Binding(get: { dir }, set: { switchDir($0) }))
            let recent = money.recentCats(dir)
            if !recent.isEmpty {
                Text("最近用过").font(UmbraFont.sans(12, .w600)).foregroundColor(UmbraColor.faint)
                HStack(spacing: 7) {
                    ForEach(recent, id: \.self) { slug in
                        catPill(slug)
                    }
                }
            }
        }
    }

    /// 切方向要把分类切到那一侧 —— 支出选着「餐饮」切到收入，分类栏里根本没有这一项，
    /// 保存会写出一条方向和分类打架的流水。
    private func switchDir(_ d: String) {
        guard d != dir else { return }
        dir = d
        cat = money.enabledCats(d).first?.slug
        sub = ""
    }

    private func catPill(_ slug: String) -> some View {
        let on = cat == slug
        return Button {
            cat = slug
            sub = ""
        } label: {
            HStack(spacing: 6) {
                UmbraIcon(d: MoneyCatArt.icon(slug), size: 14, strokeWidth: 1.9)
                Text(money.catName(slug)).font(UmbraFont.sans(13, .w560))
            }
            .foregroundColor(on ? UmbraColor.orangeText : UmbraColor.muted)
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(on ? UmbraColor.orangeSoft : UmbraColor.card))
            .overlay(Capsule().strokeBorder(on ? UmbraColor.orange : UmbraColor.border, lineWidth: UmbraMetric.borderW))
        }
        .buttonStyle(.plain)
    }

    private var catGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(money.enabledCats(dir)) { c in
                let on = cat == c.slug
                Button {
                    cat = c.slug
                    sub = ""
                } label: {
                    VStack(spacing: 5) {
                        UmbraIcon(d: MoneyCatArt.icon(c.slug), size: 19, strokeWidth: 1.9)
                        Text(c.name).font(UmbraFont.sans(12.5, .w560)).lineLimit(1)
                    }
                    .foregroundColor(on ? UmbraColor.orangeText : UmbraColor.text)
                    .frame(maxWidth: .infinity).frame(height: 64)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(on ? UmbraColor.orangeSoft : UmbraColor.card))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(on ? UmbraColor.orange : UmbraColor.border, lineWidth: UmbraMetric.borderW))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var subChips: some View {
        let subs = cat.map { MoneySubs.of($0) } ?? []
        if !subs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(subs, id: \.self) { s in
                        let on = sub == s
                        Button {
                            sub = on ? "" : s      // 再点一次取消 —— 二级可跳过
                        } label: {
                            Text(s).font(UmbraFont.sans(12.5, .w560))
                                .foregroundColor(on ? .white : UmbraColor.muted)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(Capsule().fill(on ? UmbraColor.orange : UmbraColor.card))
                                .overlay(Capsule().strokeBorder(on ? UmbraColor.orange : UmbraColor.border, lineWidth: UmbraMetric.borderW))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: 时间 + 备注

    private var timeNoteCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("时间").font(UmbraFont.sans(15)).foregroundColor(UmbraColor.text)
                Spacer()
                timeChip(icon: "M3.5,5L20.5,5L20.5,20.5L3.5,20.5ZM3.5,10L20.5,10M8,3.5L8,6.5M16,3.5L16,6.5", label: dateLabel) { showDatePick = true }
                timeChip(icon: UmbraIconPath.clock, label: clockLabel, mono: true) { showTimePick = true }
            }
            .padding(.horizontal, 14).frame(minHeight: 48)
            UmbraRowDivider()
            HStack(spacing: 10) {
                Text("备注").font(UmbraFont.sans(15)).foregroundColor(UmbraColor.text)
                // = 服务端的 merchant（拍板 D1：商家和备注一个字段）
                TextField("可不填", text: $note)
                    .multilineTextAlignment(.trailing)
                    .font(UmbraFont.sans(14.5))
                    .foregroundColor(UmbraColor.text)
            }
            .padding(.horizontal, 14).frame(minHeight: 48)
        }
        .moneyCard()
    }

    private func timeChip(icon: String, label: String, mono: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                UmbraIcon(d: icon, size: 15, strokeWidth: 1.9).foregroundColor(UmbraColor.muted)
                Text(label)
                    .font(mono ? UmbraFont.mono(14, .w560) : UmbraFont.sans(14, .w560))
                    .foregroundColor(UmbraColor.text)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UmbraColor.chip))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW))
        }
        .buttonStyle(.plain)
    }

    private var dateLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(atDate) { return "今天" }
        if cal.isDateInYesterday(atDate) { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: atDate)
    }

    private var clockLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: atDate)
    }

    // MARK: 底栏

    private var bottomBar: some View {
        UmbraBottomBar {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    UmbraButton(title: "再记一笔", kind: .secondary, height: 48) { save(again: true) }
                        .frame(width: 112)
                        .opacity(canSave ? 1 : 0.5)
                        .disabled(!canSave)
                    UmbraButton(title: id == nil ? "记下这笔" : "保存修改",
                                kind: canSave ? .primary : .disabled, height: 48) { save(again: false) }
                }
                Text(id == nil
                     ? "金额可以直接敲算式，例如 32+18。「再记一笔」会留着分类和时间，只清金额和备注。"
                     : "改完点「保存修改」。金额可以直接敲算式，例如 32+18。")
                    .font(UmbraFont.sans(11.5)).foregroundColor(UmbraColor.faint)
                    .lineSpacing(11.5 * 0.55)
            }
        }
    }

    private func save(again: Bool) {
        guard let c = cents else { router.showToast("先填金额"); return }
        guard let slug = cat else { router.showToast("选一个分类"); return }
        guard !busy else { return }
        busy = true
        failed = false
        let e = editing
        Task { @MainActor in
            let ok = await money.save(
                id: e?.id, cents: c, direction: dir, cat: slug, sub: sub,
                merchant: note.trimmingCharacters(in: .whitespacesAndNewlines),
                atMs: atDate.umbraMs,
                src: e?.src,
                ruleId: e?.rule_id ?? "", batchId: e?.batch_id ?? "", orderNo: e?.order_no ?? ""
            )
            busy = false
            guard ok else { failed = true; return }
            if again {
                // 连着记几笔外卖时分类和时间十有八九不变 —— 留着；金额和备注必换 —— 清掉。
                expr = ""
                note = ""
                router.showToast("记下了，接着记")
                amountFocused = true
            } else {
                router.showToast(e == nil ? "已记下 \(MoneyFmt.yuan(c))" : "已保存")
                router.back()
            }
        }
    }
}
