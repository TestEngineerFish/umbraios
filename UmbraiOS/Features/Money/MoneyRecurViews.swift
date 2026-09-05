// 周期记账（二期）：规则列表（money.recur）+ 新建/编辑（money.recur.edit），照稿
// mrVM / mreVM。触发在服务端（拍板 D5）：客户端只管规则的增删改停，
// 到点写流水、停机补记都是服务端看门狗的事 —— 这两页没有任何「生成」逻辑。
//
// 编辑器一期照稿只有 每天/每周/每月/每年 四档（every_n 是服务端备用列，
// 「每 N 个」等设计补稿再放开）。批次 004 补上收入侧：编辑器顶部「记在哪边」
// SegmentedControl（和「多久一次」同一个控件，稿），切了整组换分类芯片、不混排 ——
// 服务端只校 direction 本身合法，「分类属于该方向」这道门就由这个选择器挡。
import SwiftUI

// MARK: - 展示工具

enum MoneyRecurFmt {
    /// "2026-09-05" → "9月5日"。列表「下次」与预览句用。
    static func shortDate(_ s: String) -> String {
        let p = s.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return s }
        return "\(m)月\(d)日"
    }

    /// "2026-09-05" → "2026年9月5日"。结束日期要带年 —— 它常在一年以外。
    static func fullDate(_ s: String) -> String {
        let p = s.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return s }
        return "\(y)年\(m)月\(d)日"
    }

    static let weekNames = ["一", "二", "三", "四", "五", "六", "日"]

    /// 规则的周期一句话："每天 08:30" / "每周一 09:00" / "每月 5 号 09:00" / "每年 3月1日 09:00"。
    /// every_n > 1 的规则界面还建不了，但服务端存在就要显示得出（"每 3 个月 5 号"）。
    static func cycleText(_ r: MoneyRecurDTO) -> String {
        let day = Int(r.first_date.suffix(2)) ?? 1
        let mo = Int(r.first_date.dropFirst(5).prefix(2)) ?? 1
        let n = r.every_n
        switch r.cycle {
        case "day":   return (n > 1 ? "每 \(n) 天" : "每天") + " \(r.time_hhmm)"
        case "week":  return (n > 1 ? "每 \(n) 周的周" : "每周") + weekNames[max(0, min(6, r.week_day))] + " \(r.time_hhmm)"
        case "year":  return (n > 1 ? "每 \(n) 年" : "每年") + " \(mo)月\(day)日 \(r.time_hhmm)"
        default:      return (n > 1 ? "每 \(n) 个月" : "每月") + " \(day) 号 \(r.time_hhmm)"
        }
    }

    /// 首次~结束（含当天）里最后一个应记日期；一笔都没有回 nil。
    /// **必须和服务端 money_recur.last_occur_in_range 算得一样**（服务端是正本，
    /// 这里只为保存前的当场拦截 —— 拦不住的服务端还会再拦一道 400）。
    static func lastOccur(cycle: String, first: Date, end: Date, weekDay: Int) -> Date? {
        let cal = Calendar.current
        guard end >= first else { return nil }
        switch cycle {
        case "day":
            return end
        case "week":
            // Calendar.weekday: 1=周日…7=周六；规则的 0=周一 → 换算。
            let target = weekDay == 6 ? 1 : weekDay + 2
            var d = end
            for _ in 0..<7 {
                if cal.component(.weekday, from: d) == target { return d >= first ? d : nil }
                d = cal.date(byAdding: .day, value: -1, to: d)!
            }
            return nil
        case "year":
            let fd = cal.dateComponents([.month, .day], from: first)
            let ey = cal.component(.year, from: end)
            let fy = cal.component(.year, from: first)
            for y in stride(from: ey, through: fy, by: -1) {
                if let c = monthDay(cal, year: y, month: fd.month!, day: fd.day!),
                   c <= end, c >= first { return c }
            }
            return nil
        default: // month
            let fdDay = cal.component(.day, from: first)
            var y = cal.component(.year, from: end)
            var m = cal.component(.month, from: end)
            for _ in 0..<25 {
                if let c = monthDay(cal, year: y, month: m, day: fdDay), c <= end, c >= first {
                    return c
                }
                m -= 1
                if m == 0 { m = 12; y -= 1 }
            }
            return nil
        }
    }

    /// 某年某月的「d 号」，短月顺延到月底（每月 31 号遇 2 月 → 2/28-29，不跳过）。
    private static func monthDay(_ cal: Calendar, year: Int, month: Int, day: Int) -> Date? {
        var c = DateComponents(year: year, month: month, day: 1)
        guard let firstOfMonth = cal.date(from: c) else { return nil }
        let dim = cal.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 28
        c.day = min(day, dim)
        return cal.date(from: c)
    }

    static func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 规则列表（money.recur）

struct UmbraMoneyRecurListView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var money: MoneyStore

    @State private var busy = false

    var body: some View {
        List {
            if money.recurRules.isEmpty {
                Section {
                    Text("还没有周期记账。房租、保险、宽带这类固定账建一条规则，到点自动记进流水 —— 不手动停就一直跑。")
                        .font(UmbraFont.sans(13)).foregroundColor(UmbraColor.faint)
                        .lineSpacing(13 * 0.6)
                        .listRowBackground(UmbraColor.card)
                }
            } else {
                Section {
                    ForEach(money.recurRules) { r in ruleRow(r) }
                }
            }
            Section {
                Text(footText)
                    .font(UmbraFont.sans(12)).foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UmbraColor.bg)
        .navigationTitle("周期记账")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.go(.moneyRecurEdit(id: nil)) } label: { Image(systemName: "plus") }
                    .tint(UmbraColor.orange)
            }
        }
        .refreshable { await money.reloadRecur() }
        .task { await money.reloadRecur() }
    }

    /// 稿的页脚原话（「不推通知」「带周期标记」都是拍板过的行为，写出来省一次疑惑）。
    private var footText: String {
        let live = money.recurRules.filter { !$0.paused && $0.next_at_ms > 0 }.count
        return "共 \(money.recurRules.count) 条 · \(live) 条在跑。自动记入不推通知，在流水里带「周期」标记；左滑可以停掉或删除。"
    }

    private func ruleRow(_ r: MoneyRecurDTO) -> some View {
        Button { router.go(.moneyRecurEdit(id: r.id)) } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(r.paused ? UmbraColor.chip : UmbraColor.orangeSoft)
                    .frame(width: 34, height: 34)
                    .overlay(UmbraIcon(d: money.catArt(r.cat), size: 17, strokeWidth: 1.9)
                        .foregroundColor(r.paused ? UmbraColor.faint : UmbraColor.orangeText))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(r.name).font(UmbraFont.sans(15, .w560)).foregroundColor(UmbraColor.text)
                            .lineLimit(1)
                        Text(money.catName(r.cat))
                            .font(UmbraFont.sans(10.5)).foregroundColor(UmbraColor.muted)
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Capsule().fill(UmbraColor.chip))
                    }
                    Text("\(MoneyRecurFmt.cycleText(r)) · \(history(r))")
                        .font(UmbraFont.sans(11.5)).foregroundColor(UmbraColor.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(MoneyFmt.yuan(r.cents))
                        .font(UmbraFont.mono(14.5, .w560)).foregroundColor(UmbraColor.text)
                    // 停用时给一句完整的说明，别和名称旁的态重复（稿原话）。
                    Text(nextText(r))
                        .font(UmbraFont.sans(11)).foregroundColor(r.paused || r.next_at_ms == 0
                                                                  ? UmbraColor.faint : UmbraColor.orangeText)
                }
            }
            .padding(.vertical, 6)
            .opacity(r.paused ? 0.62 : 1)
            // 带两行副文，走「独立卡带第二行 60 起」那一档（`iosShell.list.row`）。
            .frame(minHeight: UmbraMetric.rowMinHSub)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(UmbraColor.card)
        .umbraRowSeparatorFullWidth()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { confirmDelete(r) } label: { Label("删除", systemImage: "trash") }
                .tint(UmbraColor.danger)
            Button { toggle(r) } label: {
                Label(r.paused ? "开始" : "停止", systemImage: r.paused ? "play" : "pause")
            }
            .tint(UmbraColor.warning)
        }
    }

    /// 「已自动记 N 笔 · 最近 M月d日」—— 两个值都是服务端从流水现算的**真值**
    /// （稿 demo 里「最近 8月5日」写死，那处已发回设计）。
    private func history(_ r: MoneyRecurDTO) -> String {
        guard r.done_count > 0 else { return "还没记过" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return "已自动记 \(r.done_count) 笔 · 最近 \(f.string(from: Date(umbraMs: r.last_done_ms)))"
    }

    private func nextText(_ r: MoneyRecurDTO) -> String {
        if r.paused { return "已停，不再自动记" }
        if r.next_at_ms == 0 { return "已到结束日期" }
        return "下次 \(MoneyRecurFmt.shortDate(r.next_date))"
    }

    private func toggle(_ r: MoneyRecurDTO) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            let ok = await money.pauseRecur(id: r.id, paused: !r.paused)
            busy = false
            router.showToast(ok ? (r.paused ? "已重新开始" : "已停，不再自动记")
                                : "没存上，检查网络后再试")
        }
    }

    /// 删除确认照稿逐句：已生成的流水**留着不动**（那些是真花过的钱），
    /// 只是想停一停就用「停止」。
    private func confirmDelete(_ r: MoneyRecurDTO) {
        let bodyText = r.done_count > 0
            ? "以后不再自动记这一笔。已经记进流水的 \(r.done_count) 条留着不动 —— 那些是真花过的钱。只想暂时停一停就用「停止」。"
            : "以后不再自动记这一笔。只想暂时停一停就用「停止」。"
        router.confirm(UmbraAlert(
            title: "删除「\(r.name)」这条周期记账？",
            body: bodyText,
            confirmLabel: "删除规则",
            confirmDestructive: true,
            onConfirm: {
                Task { @MainActor in
                    let ok = await money.deleteRecur(id: r.id)
                    router.showToast(ok ? "已删除规则" : "没删掉，检查网络后再试")
                }
            }))
    }
}

// MARK: - 新建 / 编辑规则（money.recur.edit）

struct UmbraMoneyRecurEditView: View {
    /// nil = 新建。
    let id: String?

    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var money: MoneyStore

    @State private var name = ""
    @State private var amount = ""
    @State private var merchant = ""
    /// 记在哪边（批次 004）。切方向时分类跳到那一侧第一个、sub 清空 ——
    /// sub 挂在旧分类名下，跟着过去就是脏数据。
    @State private var dir = "expense"
    @State private var cat = "housing"
    /// 编辑时保住原规则的 sub（编辑器没画 sub，不该因为没画就抹掉）；切方向清空。
    @State private var sub = ""
    @State private var cycle = "month"
    @State private var weekDay = 0
    @State private var firstDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var timeDate = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var endsOnDate = false
    @State private var endDate = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var showFirstPick = false
    @State private var showTimePick = false
    @State private var showEndPick = false
    @State private var busy = false
    @State private var seeded = false

    private var editing: MoneyRecurDTO? { id.flatMap { rid in money.recurRules.first { $0.id == rid } } }
    private var cents: Int? { MoneyAmount.cents(amount) }

    var body: some View {
        UmbraScreen {
            VStack(alignment: .leading, spacing: 13) {
                basicCard
                cycleCard
                endCard
                previewRow
            }
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.top, UmbraMetric.sp2)
        } bottom: {
            bottomBar
        }
        .navigationTitle(id == nil ? "新建周期记账" : "编辑周期记账")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { router.back() }.tint(UmbraColor.muted)
            }
            // ⋯ 贴最右，只装破坏性动作（`iosShell.toolbar`）。新建态没有可删的东西，不出这颗。
            // 列表页左滑本来也能删 —— 但已经点进来编辑的人再退出去左滑是多绕一圈，
            // 规矩允许 ⋯ / 长按 / 左滑三条路，这里两条都留着。
            if editing != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) { askDelete() } label: {
                            Label("删除这条规则", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .tint(UmbraColor.muted)
                }
            }
        }
        .onAppear { seed() }
        // 首次日期 / 时间是两个值（改时间不动日期），各自单开（批次 007：一个值 = 一个字段）。
        .umbraDatePicker(isPresented: $showFirstPick, field: "首次日期", date: $firstDate)
        .umbraTimePicker(isPresented: $showTimePick, field: "时间", date: $timeDate)
        // 结束日期带下界：早于首次日期的日子在面板里就点不动，比事后标红省一步。
        .umbraDatePicker(isPresented: $showEndPick, field: "结束重复", date: $endDate,
                         minDay: firstDate,
                         minNote: "早于首次日期 \(MoneyRecurFmt.fullDate(MoneyRecurFmt.dateString(firstDate))) 的日子选不了。含当天：当天该记的那笔照记。")
    }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        guard let r = editing else { return }
        name = r.name
        amount = String(format: "%.2f", Double(r.cents) / 100)
        merchant = r.merchant
        dir = r.direction
        cat = r.cat
        sub = r.sub
        cycle = r.cycle
        weekDay = r.week_day
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        if let d = df.date(from: "\(r.first_date) \(r.time_hhmm)") {
            firstDate = d
            timeDate = d
        }
        endsOnDate = r.end_kind == "date"
        if endsOnDate {
            df.dateFormat = "yyyy-MM-dd"
            if let d = df.date(from: r.end_date) { endDate = d }
        }
    }

    // MARK: 名字 / 金额 / 备注 / 分类

    private var basicCard: some View {
        VStack(spacing: 0) {
            // 记在哪边（批次 004）：SegmentedControl 与「多久一次」同一个控件（稿）。
            // 标签「记在哪边」是词表定稿（记一笔、周期记账、新增分类三处同词）。
            // 收入侧默认选「工资」（服务端顺序第一个），并给一行说明这是干什么的。
            UmbraFieldLabel(text: "记在哪边")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.top, 12)
            UmbraSegmentedControl(items: [
                .init(value: "expense", label: "支出"),
                .init(value: "income", label: "收入"),
            ], selection: $dir)
            .padding(.horizontal, 14).padding(.top, 7)
            .padding(.bottom, dir == "income" ? 7 : 12)
            .onChange(of: dir) { d in
                cat = money.enabledCats(d).first?.slug ?? (d == "income" ? "other_in" : "other")
                sub = ""
            }
            if dir == "income" {
                Text("收入侧的周期规则，比如工资每月 10 号自动入账。")
                    .font(UmbraFont.sans(11.5)).foregroundColor(UmbraColor.faint)
                    .lineSpacing(11.5 * 0.55)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
            UmbraRowDivider()
            HStack(spacing: 10) {
                Text("名字").font(UmbraFont.sans(15)).foregroundColor(UmbraColor.text)
                TextField("例如「房租」", text: $name)
                    .multilineTextAlignment(.trailing)
                    .font(UmbraFont.sans(14.5)).foregroundColor(UmbraColor.text)
            }
            .padding(.horizontal, 14).frame(minHeight: 48)
            UmbraRowDivider()
            HStack(spacing: 10) {
                Text("金额").font(UmbraFont.sans(15)).foregroundColor(UmbraColor.text)
                Spacer()
                Text("¥").font(UmbraFont.sans(14)).foregroundColor(UmbraColor.muted)
                TextField("0.00", text: $amount)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(UmbraFont.mono(15.5, .w560))
                    .foregroundColor(cents != nil ? UmbraColor.text : UmbraColor.faint)
                    .frame(maxWidth: 140)
            }
            .padding(.horizontal, 14).frame(minHeight: 48)
            UmbraRowDivider()
            HStack(spacing: 10) {
                Text("备注").font(UmbraFont.sans(15)).foregroundColor(UmbraColor.text)
                TextField("可不填", text: $merchant)
                    .multilineTextAlignment(.trailing)
                    .font(UmbraFont.sans(14.5)).foregroundColor(UmbraColor.text)
            }
            .padding(.horizontal, 14).frame(minHeight: 48)
            UmbraRowDivider()
            // 分类芯片跟着「记在哪边」整组换（批次 004）：数据驱动，含兜底分类 ——
            // 记一笔的选择器就是这个口径，周期编辑器没有理由更窄。
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(money.enabledCats(dir)) { c in
                        let on = cat == c.slug
                        Button { cat = c.slug } label: {
                            HStack(spacing: 5) {
                                UmbraIcon(d: MoneyCatArt.icon(c.slug, stored: c.icon), size: 13, strokeWidth: 1.9)
                                    .foregroundColor(on ? UmbraColor.orangeText : MoneyCatArt.slotColor(c.slot))
                                Text(c.name).font(UmbraFont.sans(13, .w560))
                                    .foregroundColor(on ? UmbraColor.orangeText : UmbraColor.muted)
                            }
                            .padding(.horizontal, 12).frame(height: 34)
                            .background(Capsule().fill(on ? UmbraColor.orangeSoft : UmbraColor.card))
                            .overlay(Capsule().strokeBorder(on ? UmbraColor.orange : UmbraColor.border,
                                                            lineWidth: UmbraMetric.borderW))
                            .frame(minHeight: UmbraMetric.tapMin)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.vertical, 7)
        }
        .moneyCard()
    }

    // MARK: 周期

    private var cycleCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            UmbraSegmentedControl(items: [
                .init(value: "day", label: "每天"),
                .init(value: "week", label: "每周"),
                .init(value: "month", label: "每月"),
                .init(value: "year", label: "每年"),
            ], selection: $cycle)
            .padding(.horizontal, 14).padding(.vertical, 12)
            if cycle == "week" {
                UmbraRowDivider()
                chipRow(label: "每周几") {
                    chip(label: "周\(MoneyRecurFmt.weekNames[weekDay])") { pickWeek() }
                }
            }
            if cycle == "month" || cycle == "year" {
                UmbraRowDivider()
                chipRow(label: "从哪天开始") {
                    chip(label: MoneyRecurFmt.fullDate(MoneyRecurFmt.dateString(firstDate))) {
                        showFirstPick = true
                    }
                }
            }
            UmbraRowDivider()
            chipRow(label: cycle == "day" ? "每天几点" : "时间") {
                chip(label: MoneyRecurFmt.timeString(timeDate), mono: true) { showTimePick = true }
            }
            // 只有落在 29/30/31 号才解释顺延，别在别的日期上唠叨（稿原话）。
            if cycle == "month", dayOfFirst >= 29 {
                Text("碰到没有 \(dayOfFirst) 号的月份（比如 2 月），顺延到当月最后一天记，不跳过。")
                    .font(UmbraFont.sans(11.5)).foregroundColor(UmbraColor.faint)
                    .padding(.horizontal, 14).padding(.bottom, 11)
            }
        }
        .moneyCard()
    }

    private var dayOfFirst: Int {
        Calendar.current.component(.day, from: firstDate)
    }

    private func pickWeek() {
        router.present(UmbraSheet(title: "每周几", items: MoneyRecurFmt.weekNames.enumerated().map { i, w in
            UmbraSheetItem(label: "周\(w)", checked: weekDay == i) { weekDay = i }
        }))
    }

    // MARK: 结束

    private var endCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            chipRow(label: "结束") {
                chip(label: endsOnDate ? "到某天结束" : "不设结束") { pickEnd() }
            }
            if endsOnDate {
                UmbraRowDivider()
                chipRow(label: "结束日期") {
                    chip(label: MoneyRecurFmt.fullDate(MoneyRecurFmt.dateString(endDate))) {
                        showEndPick = true
                    }
                }
                if let bad = endBadText {
                    Text(bad)
                        .font(UmbraFont.sans(11.5, .w560)).foregroundColor(UmbraColor.danger)
                        .padding(.horizontal, 14).padding(.bottom, 11)
                } else {
                    Text("结束日期含当天：当天该记的那笔照记，之后不再记。")
                        .font(UmbraFont.sans(11.5)).foregroundColor(UmbraColor.faint)
                        .padding(.horizontal, 14).padding(.bottom, 11)
                }
            }
        }
        .moneyCard()
    }

    private func pickEnd() {
        router.present(UmbraSheet(title: "结束", items: [
            UmbraSheetItem(label: "不设结束", checked: !endsOnDate) { endsOnDate = false },
            UmbraSheetItem(label: "到某天结束", checked: endsOnDate) { endsOnDate = true },
        ]))
    }

    /// 「一笔都记不到」当场拦（稿的两句原话）。服务端还有一道同款 400 兜底。
    private var endBadText: String? {
        guard endsOnDate else { return nil }
        let first = Calendar.current.startOfDay(for: firstDate)
        let end = Calendar.current.startOfDay(for: endDate)
        if MoneyRecurFmt.lastOccur(cycle: cycle, first: first, end: end, weekDay: weekDay) != nil {
            return nil
        }
        if end < first {
            return "结束日期早于首次日期（\(MoneyRecurFmt.fullDate(MoneyRecurFmt.dateString(firstDate)))），这样一笔都不会记。"
        }
        return "从 \(MoneyRecurFmt.fullDate(MoneyRecurFmt.dateString(firstDate))) 到 \(MoneyRecurFmt.fullDate(MoneyRecurFmt.dateString(endDate))) 之间没有符合这个周期的日子，一笔都不会记。把结束日期往后挪，或者换个周期。"
    }

    // MARK: 预览 + 保存

    /// 预览句照稿 mreVM：只排得到一笔时别说「之后每年一笔」——
    /// 那句承诺了循环，跟「最后一笔」自相矛盾。
    private var previewText: String {
        let t = MoneyRecurFmt.timeString(timeDate)
        let cal = Calendar.current
        let first = cal.startOfDay(for: firstDate)
        let end = cal.startOfDay(for: endDate)
        let lastAt = endsOnDate ? MoneyRecurFmt.lastOccur(cycle: cycle, first: first, end: end, weekDay: weekDay) : nil
        let tail: String
        if endsOnDate {
            if let lastAt {
                if cal.isDate(lastAt, inSameDayAs: first) {
                    return "只在 \(MoneyRecurFmt.fullDate(MoneyRecurFmt.dateString(first))) \(t) 记这一笔，之后不再记。"
                }
                tail = "最后一笔记在 \(MoneyRecurFmt.fullDate(MoneyRecurFmt.dateString(lastAt))) \(t)，之后不再记。"
            } else {
                tail = "这个区间里一笔都记不到。"
            }
        } else {
            tail = "直到你停掉。"
        }
        let mo = cal.component(.month, from: firstDate)
        let d = cal.component(.day, from: firstDate)
        switch cycle {
        case "day":  return "每天 \(t) 自动记一笔，\(tail)"
        case "week": return "每周\(MoneyRecurFmt.weekNames[weekDay]) \(t) 自动记一笔，\(tail)"
        case "year": return "首次 \(mo)月\(d)日 \(t)，之后每年这一天一笔，\(tail)"
        default:     return "首次 \(mo)月\(d)日 \(t)，之后每月 \(d) 号一笔，\(tail)"
        }
    }

    private var previewRow: some View {
        HStack(alignment: .top, spacing: 8) {
            UmbraIcon(d: MoneySrc.badge("recur")!.icon, size: 13, strokeWidth: 1.9)
                .foregroundColor(UmbraColor.orangeText)
                .padding(.top, 2)
            Text(previewText)
                .font(UmbraFont.sans(12.5)).foregroundColor(UmbraColor.muted)
                .lineSpacing(12.5 * 0.55)
        }
        .padding(.horizontal, 3)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && cents != nil && endBadText == nil && !busy
    }

    /// 底部只留「保存」这一颗。「删除」原来占着这里的左半边，被骨架
    /// `iosShell.toolbar.noDestructiveAtBottom` 挪进了右上角 ⋯。
    private var bottomBar: some View {
        UmbraBottomBar {
            VStack(alignment: .leading, spacing: 8) {
                UmbraButton(title: id == nil ? "建好，到点自动记" : "保存修改",
                            kind: canSave ? .primary : .disabled, height: 48) { save() }
                if editing != nil {
                    Text("改动只影响以后的 —— 已经自动记进流水的不变。")
                        .font(UmbraFont.sans(11.5)).foregroundColor(UmbraColor.faint)
                }
            }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { router.showToast("先给这条规则起个名字"); return }
        guard let c = cents else { router.showToast("金额要大于 0"); return }
        if let bad = endBadText { router.showToast(bad.hasPrefix("结束日期早于") ? "结束日期要晚于首次日期" : "这个区间里一笔都记不到"); return }
        guard !busy else { return }
        busy = true
        let body: [String: Any] = [
            "name": n,
            "cents": c,
            "direction": dir,
            "cat": cat,
            "sub": sub,
            "merchant": merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            "cycle": cycle,
            "every_n": editing?.every_n ?? 1,
            "week_day": weekDay,
            "first_date": MoneyRecurFmt.dateString(firstDate),
            "time_hhmm": MoneyRecurFmt.timeString(timeDate),
            "tz_offset_min": MoneyFmt.tzOffsetMin,
            "end_kind": endsOnDate ? "date" : "never",
            "end_date": endsOnDate ? MoneyRecurFmt.dateString(endDate) : "",
        ]
        Task { @MainActor in
            let ok = await money.saveRecur(id: editing?.id, body: body)
            busy = false
            guard ok else { router.showToast("没存上，检查网络后再试"); return }
            router.showToast(id == nil ? "已建好，到点自动记" : "已保存，改动只影响以后的")
            router.back()
        }
    }

    private func askDelete() {
        guard let r = editing else { return }
        let bodyText = r.done_count > 0
            ? "以后不再自动记这一笔。已经记进流水的留着不动 —— 那些是真花过的钱。只想暂时停一停就用列表里的「停止」。"
            : "以后不再自动记这一笔。只想暂时停一停就用列表里的「停止」。"
        router.confirm(UmbraAlert(
            title: "删除「\(r.name)」这条周期记账？",
            body: bodyText,
            confirmLabel: "删除规则",
            confirmDestructive: true,
            onConfirm: {
                Task { @MainActor in
                    let ok = await money.deleteRecur(id: r.id)
                    router.showToast(ok ? "已删除规则" : "没删掉，检查网络后再试")
                    if ok { router.back() }
                }
            }))
    }

    // MARK: 小件

    private func chipRow<C: View>(label: String, @ViewBuilder chips: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(label).font(UmbraFont.sans(15)).foregroundColor(UmbraColor.text)
            Spacer()
            chips()
        }
        .padding(.horizontal, 14).frame(minHeight: 48)
    }

    private func chip(label: String, mono: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(mono ? UmbraFont.mono(14, .w560) : UmbraFont.sans(14, .w560))
                .foregroundColor(UmbraColor.text)
                .padding(.horizontal, 12).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UmbraColor.chip))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW))
        }
        .buttonStyle(.plain)
    }
}
