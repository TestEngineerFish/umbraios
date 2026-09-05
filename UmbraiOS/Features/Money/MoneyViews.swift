// 记账的两个主屏：统计（money 首屏）+ 流水列表。记一笔和分类管理各自单独一个文件。
//
// 一期范围（doc/记账-实现方案.md §4）：统计 / 流水 / 记一笔 / 分类管理。
// 稿里统计屏还有「待确认」横幅（四期）、「周期记账」卡（二期）、「预算」卡（三期），
// 这一版都不画 —— 放一个点了没反应的入口比不放更糟。
import SwiftUI

// MARK: - 统计屏（记账首屏，me.money）

struct UmbraMoneyHomeView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var money: MoneyStore

    /// 分类占比 / 趋势的「以表格查看」开关。纯视图状态，退出页面就复位，不进 store。
    @State private var catTable = false
    @State private var trendTable = false
    @State private var trend12 = false

    var body: some View {
        UmbraScreen {
            switch money.phase {
            case .idle, .loading:
                // 原来是三个 card 底的大圆角矩形 + `.redacted(.placeholder)`，
                // 尺寸 150/300/200 —— 那是「三张卡的影子」，不是骨架。
                // 骨架的取值（三组、每组两条、62/84 · 48/72 · 55/66、条高 14/11、
                // `--track` 底、不呼吸）现在归 UmbraSkeleton。
                UmbraSkeleton()
            case .error:
                // 原来这一档借的是**空态**的壳 —— 空态和错误画得一模一样，
                // 正是骨架 `states.iconBoxTone` 点名的那个毛病。整屏拿不到数据是
                // 错误卡的 card 形（`states.errorCard`）。
                UmbraErrorCard(variant: .card,
                               title: "暂时连不上服务端",
                               reason: "统计和流水都在服务端。检查网络或服务端状态，然后重试。",
                               actionTitle: "重试",
                               action: { Task { await money.reload() } },
                               // 第二颗把人送到能解决问题的地方去，和聊天失败行同一条口径。
                               // 用 jump 不是 go：连接设置在「我」那个 tab 里。
                               secondaryTitle: "检查服务端",
                               secondaryAction: { router.jump(.setConn) })
            case .ready:
                if isEmpty {
                    UmbraEmptyState(iconPath: UmbraIconPath.wallet,
                                    title: "这个月还没有记账",
                                    hint: "记一笔，这里就会出现分类占比和月度趋势。",
                                    actionTitle: "记一笔") { router.go(.moneyAdd(id: nil)) }
                } else if let st = money.stats {
                    content(st)
                }
            }
        }
        .navigationTitle("记账")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.go(.moneyAdd(id: nil)) } label: { Image(systemName: "plus") }
                    .tint(UmbraColor.orange)
            }
        }
        .refreshable { await money.reload(silent: true) }
        .onAppear { money.loadIfNeeded() }
    }

    /// 「这个月一笔都没有」才算空 —— 统计为 0 但有收入（或反过来）都不算。
    private var isEmpty: Bool {
        money.entries.isEmpty && (money.stats.map { $0.expense == 0 && $0.income == 0 } ?? true)
    }

    // MARK: 有数据

    private func content(_ st: MoneyStatsDTO) -> some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp4) {
            monthRow
            summaryCard(st)
            recurCard
            catShareCard(st)
            trendCard(st)
            topCard
            UmbraButton(title: "全部流水", kind: .secondary, height: 46) {
                money.listDir = "all"
                money.listCat = nil
                router.go(.moneyList)
            }
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.top, UmbraMetric.sp2)
    }

    /// 月份行。一期只做本月（拍板 D3），箭头按稿保留但点了只给一句话 ——
    /// 光把箭头藏掉，用户会以为翻月功能坏了；说出来才知道是「还没有」。
    private var monthRow: some View {
        HStack(spacing: 14) {
            Spacer()
            monthArrow(back: true) { router.showToast("这一版只做本月的数据") }
            Text(MoneyFmt.ymLabel(money.ym))
                .font(UmbraFont.sans(16, .w600))
                .foregroundColor(UmbraColor.text)
            monthArrow(back: false) { router.showToast("已经是最新的月份") }
            Spacer()
        }
    }

    private func monthArrow(back: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            UmbraIcon(d: UmbraIconPath.chevronRight, size: 16, strokeWidth: 2.2)
                .rotationEffect(back ? .degrees(180) : .zero)
                .foregroundColor(UmbraColor.faint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(UmbraColor.card))
                .overlay(Circle().strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW))
                // 圆钮画 32、点 44（规范：热区用透明外框撑，不把控件画大）。
                .frame(width: UmbraMetric.tapMin, height: UmbraMetric.tapMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 周期记账入口卡（二期，照稿 mnVM 的 goRecur / recHint / recNext）：
    /// 「N 条在跑」+ 最近要记的两条预览。没有规则时也显示 —— 入口藏起来，
    /// 「房租不用手记」这个功能就永远没人发现。
    private var recurCard: some View {
        let live = money.recurRules.filter { !$0.paused && $0.next_at_ms > 0 }
        let next2 = live.sorted { $0.next_at_ms < $1.next_at_ms }.prefix(2)
        return Button { router.go(.moneyRecur) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    UmbraIcon(d: MoneySrc.badge("recur")!.icon, size: 15, strokeWidth: 1.9)
                        .foregroundColor(UmbraColor.orangeText)
                    Text("周期记账").font(UmbraFont.sans(14.5, .w600)).foregroundColor(UmbraColor.text)
                    Spacer()
                    Text(live.isEmpty ? "还没有" : "\(live.count) 条在跑")
                        .font(UmbraFont.sans(12)).foregroundColor(UmbraColor.muted)
                    UmbraIcon(d: UmbraIconPath.chevronRight, size: 14, strokeWidth: 2.2)
                        .foregroundColor(UmbraColor.faint)
                }
                if next2.isEmpty {
                    Text("房租、订阅这类固定账，建一条规则到点自动记，不用再手记。")
                        .font(UmbraFont.sans(12)).foregroundColor(UmbraColor.faint)
                } else {
                    ForEach(Array(next2), id: \.id) { r in
                        HStack(spacing: 8) {
                            Text(r.name).font(UmbraFont.sans(13)).foregroundColor(UmbraColor.text)
                                .lineLimit(1)
                            Spacer()
                            Text(MoneyFmt.yuan(r.cents))
                                .font(UmbraFont.mono(12.5, .w560)).foregroundColor(UmbraColor.muted)
                            Text("下次 \(MoneyRecurFmt.shortDate(r.next_date))")
                                .font(UmbraFont.sans(11.5)).foregroundColor(UmbraColor.orangeText)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .moneyCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 本月支出大卡：大数 + 环比 + 收入/结余两小格。
    private func summaryCard(_ st: MoneyStatsDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("本月支出").font(UmbraFont.sans(12.5)).foregroundColor(UmbraColor.muted)
                Text(MoneyFmt.yuan(st.expense))
                    .font(UmbraFont.sans(34, .w650))
                    .foregroundColor(UmbraColor.text)
            }
            momRow(st)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本月收入").font(UmbraFont.sans(12)).foregroundColor(UmbraColor.muted)
                    Text(MoneyFmt.yuan(st.income))
                        .font(UmbraFont.sans(17, .w600))
                        .foregroundColor(UmbraColor.success)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text("结余").font(UmbraFont.sans(12)).foregroundColor(UmbraColor.muted)
                    Text(MoneyFmt.yuan(st.balance))
                        .font(UmbraFont.sans(17, .w600))
                        .foregroundColor(UmbraColor.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 11)
            .overlay(moneyRowSeparator(pad: 16), alignment: .top)
        }
        .padding(16)
        .moneyCard()
    }

    /// 环比行。prev_expense 三态：nil = 上月没记录（不画箭头）；0 = 记过但支出 0
    /// （百分比会除零，直说「上月支出 ¥0.00」）；正数 = 正常算百分比。
    private func momRow(_ st: MoneyStatsDTO) -> some View {
        HStack(spacing: 6) {
            if let prev = st.prev_expense, prev > 0 {
                let up = st.expense > prev
                let pct = Int((Double(abs(st.expense - prev)) / Double(prev) * 100).rounded())
                UmbraIcon(d: up ? "M12,19L12,5M6,11L12,5L18,11" : "M12,5L12,19M6,13L12,19L18,13", size: 14, strokeWidth: 2.2)
                    .foregroundColor(up ? UmbraColor.danger : UmbraColor.success)
                Text("比上月\(up ? "多" : "少") \(pct)%")
                    .font(UmbraFont.sans(13, .w560))
                    .foregroundColor(up ? UmbraColor.danger : UmbraColor.success)
            } else if st.prev_expense == 0 {
                Text("上月支出 ¥0.00").font(UmbraFont.sans(13)).foregroundColor(UmbraColor.muted)
            } else {
                Text("上月没有记录，无法对比").font(UmbraFont.sans(13)).foregroundColor(UmbraColor.muted)
            }
            // 本月还没过完的话补一句剩余天数 ——「比上月少 40%」在月中是个假象，这句是拆穿它用的。
            if daysLeft > 0 {
                Text("本月还剩 \(daysLeft) 天").font(UmbraFont.sans(12)).foregroundColor(UmbraColor.faint)
            }
            Spacer(minLength: 0)
        }
    }

    private var daysLeft: Int {
        let cal = Calendar.current
        let now = Date()
        guard let range = cal.range(of: .day, in: .month, for: now) else { return 0 }
        return range.count - cal.component(.day, from: now)
    }

    // MARK: 分类占比

    private func catShareCard(_ st: MoneyStatsDTO) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Text("分类占比").font(UmbraFont.sans(15.5, .w600)).foregroundColor(UmbraColor.text)
                Spacer()
                // 没数时不出切换钮：图和表都是空的，点它只会让自己的字来回变，
                // 卡里什么都不动 —— 一颗看着能点、点了没反应的钮。
                if !st.by_cat.isEmpty {
                    togglePill(catTable ? "看图" : "以表格查看") { catTable.toggle() }
                }
            }
            if st.by_cat.isEmpty {
                // 卡内无数据走 compact 档（`states.cardNoData`），**不用整屏态** ——
                // 屏上别的卡还有数，人不是无事可做，所以这一档不给正文也不给按钮。
                // 原来这里画的是「只剩 chip 灰圈的环 + 中心 ¥0.00 + 零行排行 + 那句脚注」，
                // 看上去像画好了，其实什么也没说。
                UmbraCardNoData(iconPath: UmbraIconPath.columns, title: "本月还没有支出分类")
            } else if catTable {
                catTableView(st)
            } else {
                donut(st)
                VStack(spacing: 0) {
                    ForEach(Array(st.by_cat.enumerated()), id: \.element.cat) { idx, row in
                        catRow(row, total: st.expense, first: idx == 0)
                    }
                }
                Text("环形只画金额前 5 的分类，其余合并成一块灰色；下面的排行是本月有支出的全部分类。")
                    .font(UmbraFont.sans(11.5)).foregroundColor(UmbraColor.faint)
                    .lineSpacing(11.5 * 0.6)
            }
        }
        .padding(15)
        .moneyCard()
    }

    /// 环形图：Circle().trim 逐段描边。稿的取值：170×170、内环占比≈70%（r60/宽26）。
    /// 只画金额前 5，其余合并成灰色一段（稿明写）。
    private func donut(_ st: MoneyStatsDTO) -> some View {
        let total = max(st.expense, 1)
        var segs: [(color: Color, cents: Int)] = st.by_cat.prefix(5).map {
            (MoneyCatArt.slotColor(money.catSlot($0.cat)), $0.cents)
        }
        let rest = st.by_cat.dropFirst(5).reduce(0) { $0 + $1.cents }
        if rest > 0 { segs.append((MoneyCatArt.slotColor(0), rest)) }
        // 先把每段的起止算好再画 —— 在 ForEach 里累加状态是 SwiftUI 的经典坑。
        var acc = 0
        let arcs: [(id: Int, from: Double, to: Double, color: Color)] = segs.enumerated().map { i, s in
            let from = Double(acc) / Double(total)
            acc += s.cents
            return (i, from, Double(acc) / Double(total), s.color)
        }
        return HStack {
            Spacer()
            ZStack {
                Circle().stroke(UmbraColor.chip, lineWidth: 26)
                ForEach(arcs, id: \.id) { a in
                    Circle()
                        .trim(from: a.from, to: a.to)
                        .stroke(a.color, lineWidth: 26)
                }
            }
            .frame(width: 144, height: 144)   // 170 外径 − 26 描边 = 中线 144
            .rotationEffect(.degrees(-90))    // trim 从 3 点方向起，转到 12 点方向
            .padding(13)
            // 中心文字放在旋转**之外**的 overlay 上 —— 放进 ZStack 会跟着转 90°。
            .overlay(
                VStack(spacing: 2) {
                    Text(MoneyFmt.yuan(st.expense))
                        .font(UmbraFont.sans(17, .w650))
                        .foregroundColor(UmbraColor.text)
                    Text("本月支出").font(UmbraFont.sans(11)).foregroundColor(UmbraColor.muted)
                }
            )
            Spacer()
        }
    }

    private func catRow(_ row: MoneyCatStatDTO, total: Int, first: Bool) -> some View {
        Button {
            money.listDir = "expense"
            money.listCat = row.cat
            router.go(.moneyList)
        } label: {
            HStack(spacing: 9) {
                Circle().fill(MoneyCatArt.slotColor(money.catSlot(row.cat))).frame(width: 8, height: 8)
                // 分类色块（批次 003）：排行的图标进同色 tint 块，色点保留当图例锚。
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(MoneyCatArt.tint(money.catSlot(row.cat)))
                    .frame(width: 22, height: 22)
                    .overlay(UmbraIcon(d: money.catArt(row.cat), size: 14, strokeWidth: 1.9)
                        .foregroundColor(MoneyCatArt.slotColor(money.catSlot(row.cat))))
                Text(money.catName(row.cat))
                    .font(UmbraFont.sans(14.5)).foregroundColor(UmbraColor.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(MoneyFmt.yuan(row.cents))
                    .font(UmbraFont.mono(14, .w560)).foregroundColor(UmbraColor.text)
                Text(pct(row.cents, total))
                    .font(UmbraFont.mono(12.5)).foregroundColor(UmbraColor.muted)
                    .frame(width: 48, alignment: .trailing)
            }
            .padding(.vertical, 7)
            .frame(minHeight: 44)
            .overlay(alignment: .top) {
                if !first { moneyRowSeparator(pad: 15) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func catTableView(_ st: MoneyStatsDTO) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("分类").frame(maxWidth: .infinity, alignment: .leading)
                Text("金额").frame(width: 78, alignment: .trailing)
                Text("占比").frame(width: 46, alignment: .trailing)
                Text("笔数").frame(width: 34, alignment: .trailing)
            }
            .font(UmbraFont.sans(11, .w600))
            .foregroundColor(UmbraColor.faint)
            .padding(.bottom, 7)
            ForEach(st.by_cat, id: \.cat) { row in
                HStack(spacing: 8) {
                    Text(money.catName(row.cat)).font(UmbraFont.sans(13)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(MoneyFmt.yuan(row.cents)).font(UmbraFont.mono(13))
                        .frame(width: 78, alignment: .trailing)
                    Text(pct(row.cents, st.expense)).font(UmbraFont.mono(13)).foregroundColor(UmbraColor.muted)
                        .frame(width: 46, alignment: .trailing)
                    Text("\(row.count)").font(UmbraFont.mono(13)).foregroundColor(UmbraColor.muted)
                        .frame(width: 34, alignment: .trailing)
                }
                .foregroundColor(UmbraColor.text)
                .frame(minHeight: 36)
                // 这张表第一行**要**画线：它上面是表头行，这条线分的是表头和数据，
                // 不是「第一行的行间线」。
                .overlay(alignment: .top) { moneyRowSeparator(pad: 15) }
            }
            // 合计行：占比恒 100%，笔数 = 支出笔数合计。
            HStack(spacing: 8) {
                Text("合计").frame(maxWidth: .infinity, alignment: .leading)
                Text(MoneyFmt.yuan(st.expense)).font(UmbraFont.mono(13, .w600)).frame(width: 78, alignment: .trailing)
                Text("100%").font(UmbraFont.mono(13, .w600)).frame(width: 46, alignment: .trailing)
                Text("\(st.by_cat.reduce(0) { $0 + $1.count })").font(UmbraFont.mono(13, .w600)).frame(width: 34, alignment: .trailing)
            }
            .font(UmbraFont.sans(13, .w600))
            .foregroundColor(UmbraColor.text)
            .frame(minHeight: 36)
            // 合计行上面这条**故意用 border 而不是 borderSoft**：它分的是「明细」和「合计」
            // 两段内容，不是行与行，深一档才读得出「上面结束了」。
            .overlay(alignment: .top) { moneyRowSeparator(pad: 15, tint: UmbraColor.border) }
        }
    }

    // MARK: 月度趋势

    private func trendCard(_ st: MoneyStatsDTO) -> some View {
        // 一次拉的就是 12 个月，近 6 月是它的切片 —— 切档位不再打接口。
        let pts = trend12 ? st.trend : Array(st.trend.suffix(6))
        let maxCents = max(pts.map { $0.cents }.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Text("月度趋势").font(UmbraFont.sans(15.5, .w600)).foregroundColor(UmbraColor.text)
                Spacer()
                // 同分类占比：没数时三颗钮全不出（近 6 月 / 近 12 月 / 以表格查看）。
                if !pts.isEmpty {
                    rangePill("近 6 月", on: !trend12) { trend12 = false }
                    rangePill("近 12 月", on: trend12) { trend12 = true }
                }
            }
            if pts.isEmpty {
                // 原来这一档画的是一个空的 150 高柱状区 + 一颗「以表格查看」胶囊，
                // 看着像图没加载出来。卡内 compact 档（`states.cardNoData`）。
                UmbraCardNoData(iconPath: UmbraIconPath.sortLines, title: "还没有可比较的月份")
            } else if trendTable {
                VStack(spacing: 0) {
                    ForEach(pts, id: \.ym) { p in
                        HStack(spacing: 8) {
                            Text(MoneyFmt.ymLabel(p.ym)).font(UmbraFont.sans(13)).foregroundColor(UmbraColor.text)
                            Spacer()
                            Text(MoneyFmt.yuan(p.cents))
                                .font(UmbraFont.mono(13))
                                .foregroundColor(p.ym == st.ym ? UmbraColor.orangeText : UmbraColor.muted)
                        }
                        .frame(minHeight: 36)
                        // 第一行不画线（`iosShell.list.separator`）。这张表上面没有表头，
                        // 第一行再画一条就成了「月度趋势」标题下面的一条横杠。
                        //（下面分类表格的第一行**要**画 —— 那张表上面有表头行，
                        // 那条线分的是表头和数据。）
                        .overlay(alignment: .top) {
                            if p.ym != pts.first?.ym { moneyRowSeparator(pad: 15) }
                        }
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(pts, id: \.ym) { p in
                        let cur = p.ym == st.ym
                        VStack(spacing: 6) {
                            // 柱顶只标当前月，其余的看下面的表格（稿的规则；手机上没有悬停）。
                            Text(cur ? MoneyFmt.yuan(p.cents) : " ")
                                .font(UmbraFont.mono(10.5, .w600))
                                .foregroundColor(UmbraColor.orangeText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                                .fill(cur ? UmbraColor.orange : UmbraColor.track)
                                .frame(height: max(4, CGFloat(p.cents) / CGFloat(maxCents) * 104))
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 4)
                            Text(MoneyFmt.monthShort(p.ym))
                                .font(UmbraFont.sans(11))
                                .foregroundColor(cur ? UmbraColor.text : UmbraColor.faint)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 150, alignment: .bottom)
            }
            if !pts.isEmpty {
                togglePill(trendTable ? "看图" : "以表格查看") { trendTable.toggle() }
            }
        }
        .padding(15)
        .moneyCard()
    }

    // MARK: 大额支出

    private var topCard: some View {
        let top = money.entries.filter { $0.direction == "expense" }
            .sorted { $0.cents > $1.cents }.prefix(5)
        return VStack(alignment: .leading, spacing: 4) {
            Text("大额支出").font(UmbraFont.sans(15.5, .w600)).foregroundColor(UmbraColor.text)
                .padding(.bottom, 5)
            // 本月没有支出时，这张卡原来只剩一行标题、底下一片空 ——
            // 像是内容没渲染出来。卡内 compact 档（`states.cardNoData`）。
            if top.isEmpty {
                UmbraCardNoData(iconPath: UmbraIconPath.wallet, title: "本月还没有支出")
            }
            ForEach(Array(top.enumerated()), id: \.element.id) { idx, e in
                Button {
                    money.listDir = "expense"
                    money.listCat = nil
                    router.go(.moneyList)
                } label: {
                    HStack(spacing: 10) {
                        // 分类色块（批次 003）：同色 tint 底 + 色槽色描边图标。
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(MoneyCatArt.tint(money.catSlot(e.cat)))
                            .frame(width: 30, height: 30)
                            .overlay(UmbraIcon(d: money.catArt(e.cat), size: 15, strokeWidth: 1.9)
                                .foregroundColor(MoneyCatArt.slotColor(money.catSlot(e.cat))))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.merchant.isEmpty ? money.catName(e.cat) : e.merchant)
                                .font(UmbraFont.sans(14.5)).foregroundColor(UmbraColor.text).lineLimit(1)
                            Text(topSub(e)).font(UmbraFont.sans(11.5)).foregroundColor(UmbraColor.faint)
                        }
                        Spacer(minLength: 6)
                        Text(MoneyFmt.yuan(e.cents))
                            .font(UmbraFont.mono(15, .w560)).foregroundColor(UmbraColor.text)
                    }
                    .padding(.vertical, 6)
                    .frame(minHeight: 46)
                    .overlay(alignment: .top) {
                        if idx > 0 { moneyRowSeparator(pad: 15) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(15)
        .moneyCard()
    }

    private func topSub(_ e: MoneyEntryDTO) -> String {
        let d = Date(umbraMs: e.at_ms)
        let c = Calendar.current
        let sub = e.sub.isEmpty ? "" : " · \(e.sub)"
        return "\(money.catName(e.cat))\(sub) · \(c.component(.month, from: d))月\(c.component(.day, from: d))日"
    }

    // MARK: 小件

    private func togglePill(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(UmbraFont.sans(12, .w560)).foregroundColor(UmbraColor.muted)
                .padding(.horizontal, 11).frame(height: 28)
                .background(Capsule().fill(UmbraColor.bg))
                .overlay(Capsule().strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW))
        }
        .buttonStyle(.plain)
    }

    private func rangePill(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(UmbraFont.sans(12, .w560))
                .foregroundColor(on ? UmbraColor.orangeText : UmbraColor.muted)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Capsule().fill(on ? UmbraColor.orangeSoft : UmbraColor.bg))
                .overlay(Capsule().strokeBorder(on ? UmbraColor.orange : UmbraColor.border, lineWidth: UmbraMetric.borderW))
        }
        .buttonStyle(.plain)
    }

    private func pct(_ cents: Int, _ total: Int) -> String {
        guard total > 0 else { return "0%" }
        return String(format: "%.1f%%", Double(cents) / Double(total) * 100)
    }

}

// MARK: - 流水屏（money.list）

struct UmbraMoneyListView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var money: MoneyStore

    // 列表 = 系统 List + 系统 .swipeActions（提醒列表是模板，CLAUDE.md 有铁律）。
    // 上一版用自绘 UmbraSwipeRow，三宗罪一次全犯（用户验收点名）：
    // 划开一行后整页卡住不能上下滚、几行能同时划开、行上的拖拽手势抢掉边缘返回。
    // 系统 swipeActions 这三件事全是 UIKit 替你协调的，不自己造轮子。
    var body: some View {
        List {
            Section {
                UmbraSegmentedControl(items: [
                    .init(value: "all", label: "全部"),
                    .init(value: "expense", label: "支出"),
                    .init(value: "income", label: "收入"),
                ], selection: $money.listDir)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: UmbraMetric.sp2, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // 分类胶囊只列**当前方向下真的出现过**的分类（稿就是这么派生的）——
                // 列全量的话大多数点了都是空结果。
                UmbraFilterChips(items: catChips, selection: $money.listCat, edgeInset: 0)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: UmbraMetric.sp2, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // ⚠️ 这一屏原来**完全不看 `money.phase`**，只判 `filtered.isEmpty` ——
            // 而它是能**冷进**的（聊天里记完一笔，卡片上的「看流水」直接 jump 过来，
            // 此时 store 还是 .idle）。于是：
            //   · 请求还在飞 → 画「这个月还没有记录」，是假空态；
            //   · 请求失败   → 一直停在「这个月还没有记录」，把「连不上」说成「你没记账」。
            // 后者正是这一批刚在统计屏修掉的毛病（见本文件顶部那段注释），只是搬到了隔壁屏。
            if money.phase == .idle || money.phase == .loading {
                Section {
                    UmbraSkeleton()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
            } else if money.phase == .error && money.entries.isEmpty {
                // 有旧数据就别拿错误卡把它盖掉（下拉刷新失败是这种情况）——
                // 只有「一条都没有 + 拿不到」才是真的没东西可看。
                Section {
                    UmbraErrorCard(variant: .card,
                                   title: "暂时连不上服务端",
                                   reason: "流水在服务端。检查网络或服务端状态，然后重试。",
                                   actionTitle: "重试",
                                   action: { Task { await money.reload() } },
                                   secondaryTitle: "检查服务端",
                                   secondaryAction: { router.jump(.setConn) })
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
            } else if filtered.isEmpty {
                Section {
                    // 「空」和「无结果」是**两件不同的事**（`states.emptyVsNoResult`）：
                    // 空态说「怎么开始」并给主动作，无结果说「改什么条件」并给「清掉筛选」。
                    // 原来挤在一次调用里用三元分档，无结果那一档连 hint 都是 nil ——
                    // 等于只说了「没有」，没说该改什么。拆成两次调用。
                    if money.entries.isEmpty {
                        UmbraEmptyState(iconPath: UmbraIconPath.wallet,
                                        title: "这个月还没有记录",
                                        hint: "记一笔，流水会按天分组出现在这里。",
                                        actionTitle: "记一笔") { router.go(.moneyAdd(id: nil)) }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        UmbraEmptyState(iconPath: UmbraIconPath.filter,
                                        title: "这个筛选条件下没有记录",
                                        hint: "这个月是有记录的，只是不符合当前的方向或分类。放宽条件再看看。",
                                        actionTitle: "清掉筛选") {
                            money.listDir = "all"
                            money.listCat = nil
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            } else {
                ForEach(groups, id: \.day) { g in
                    Section {
                        ForEach(g.items) { e in entryRow(e) }
                    } header: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(g.day).font(UmbraFont.sans(12.5, .w600)).foregroundColor(UmbraColor.muted)
                            Spacer()
                            Text(g.spend > 0 ? "支出 \(MoneyFmt.yuan(g.spend))" : "仅收入")
                                .font(UmbraFont.mono(12)).foregroundColor(UmbraColor.faint)
                        }
                        .textCase(nil)
                    }
                }
                Section {
                    // 合计条撑满整行（稿的样式：通栏一条，不是居中小卡）——
                    // List 会把行按内容收窄，这里把行内衬清零、让它吃满分组宽度。
                    footChip
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    Text("左滑一行可以编辑或删除。")
                        .font(UmbraFont.sans(11.5)).foregroundColor(UmbraColor.faint)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UmbraColor.bg)
        .navigationTitle("流水")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.go(.moneyAdd(id: nil)) } label: { Image(systemName: "plus") }
                    .tint(UmbraColor.orange)
            }
        }
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .refreshable { await money.reload(silent: true) }
        .onAppear { money.loadIfNeeded() }
    }

    // MARK: 筛选

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp3) {
            UmbraSegmentedControl(items: [
                .init(value: "all", label: "全部"),
                .init(value: "expense", label: "支出"),
                .init(value: "income", label: "收入"),
            ], selection: $money.listDir)
            .padding(.horizontal, UmbraMetric.pagePadX)
            // 分类胶囊只列**当前方向下真的出现过**的分类（稿就是这么派生的）——
            // 列全量的话大多数点了都是空结果。
            UmbraFilterChips(items: catChips, selection: $money.listCat)
        }
    }

    private var catChips: [UmbraFilterChips<String?>.Item] {
        var seen: [String] = []
        for e in money.entries where money.listDir == "all" || e.direction == money.listDir {
            if !seen.contains(e.cat) { seen.append(e.cat) }
        }
        return [.init(value: nil, label: "全部分类")]
            + seen.map { .init(value: $0, label: money.catName($0)) }
    }

    private var filtered: [MoneyEntryDTO] {
        money.entries.filter { e in
            if money.listDir != "all", e.direction != money.listDir { return false }
            if let cat = money.listCat, e.cat != cat { return false }
            return true
        }
    }

    // MARK: 日分组

    private struct DayGroup {
        let day: String        // "8月19日 周三"
        let items: [MoneyEntryDTO]
        let spend: Int
    }

    private var groups: [DayGroup] {
        // 服务端已按 at_ms 降序排好，这里只分组不重排 —— 排序两处做迟早对不上。
        var out: [(key: String, items: [MoneyEntryDTO])] = []
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        for e in filtered {
            let label = f.string(from: Date(umbraMs: e.at_ms))
            if out.last?.key == label {
                out[out.count - 1].items.append(e)
            } else {
                out.append((label, [e]))
            }
        }
        return out.map { g in
            DayGroup(day: g.key, items: g.items,
                     spend: g.items.filter { $0.direction == "expense" }.reduce(0) { $0 + $1.cents })
        }
    }

    private func entryRow(_ e: MoneyEntryDTO) -> some View {
        let income = e.direction == "income"
        return Group {
            HStack(spacing: 11) {
                // 分类色块（批次 003）：流水行统一走同色 tint + 色槽色，
                // 不再按收支分绿/灰 —— 方向已经由右侧的 +/− 金额颜色表达，
                // 图标块的职责回归「这是哪个分类」。
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MoneyCatArt.tint(money.catSlot(e.cat)))
                    .frame(width: 32, height: 32)
                    .overlay(UmbraIcon(d: money.catArt(e.cat), size: 16, strokeWidth: 1.9)
                        .foregroundColor(MoneyCatArt.slotColor(money.catSlot(e.cat))))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(money.catName(e.cat) + (e.sub.isEmpty ? "" : " · \(e.sub)"))
                            .font(UmbraFont.sans(14.5)).foregroundColor(UmbraColor.text).lineLimit(1)
                        // 来源徽章只是标记，不给点击 —— 手机上 14px 高的命中区必然误触，
                        // 而且它嵌在本身可左滑的行里，两个目标会叠（稿的原话）。
                        if let badge = MoneySrc.badge(e.src) {
                            HStack(spacing: 3) {
                                UmbraIcon(d: badge.icon, size: 10, strokeWidth: 2.4)
                                Text(badge.label).font(UmbraFont.sans(10.5, .w600))
                            }
                            .foregroundColor(e.src == "recur" ? UmbraColor.orangeText : UmbraColor.faint)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(e.src == "recur" ? UmbraColor.orangeSoft : UmbraColor.chip))
                        }
                    }
                    if !e.merchant.isEmpty {
                        Text(e.merchant).font(UmbraFont.sans(12)).foregroundColor(UmbraColor.faint).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Text(MoneyFmt.signed(e.cents, income: income))
                    .font(UmbraFont.mono(15.5, .w560))
                    .foregroundColor(income ? UmbraColor.success : UmbraColor.text)
            }
            .padding(.vertical, 6)
            // 原来这里写死 48 —— 和骨架 `iosShell.list.row` 的取值一样，但写死就是「碰巧对」，
            // 下次调 token 它不会跟着动。换成 token。
            .frame(minHeight: UmbraMetric.rowMinH)
        }
        .listRowBackground(UmbraColor.card)
        .umbraRowSeparatorFullWidth()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 删除放第一个（最靠边）。不用 role: .destructive —— 带 role 系统会先把行
            // 划走，确认弹窗点取消行就回不来了（提醒列表同一条注释）。
            Button { confirmDelete(e) } label: { Label("删除", systemImage: "trash") }
                .tint(UmbraColor.danger)
            Button { router.go(.moneyAdd(id: e.id)) } label: { Label("编辑", systemImage: "pencil") }
                .tint(UmbraColor.warning)
        }
    }

    /// 删除确认。文案与其它类别对齐：「移入回收站，保留 30 天」+ 跨端后果说在前面
    /// （回流台账已记：稿上这条还是「删除后统计会跟着变」的老话，要补稿）。
    private func confirmDelete(_ e: MoneyEntryDTO) {
        let name = e.merchant.isEmpty ? money.catName(e.cat) : e.merchant
        router.confirm(UmbraAlert(
            title: "删除「\(name) · \(MoneyFmt.yuan(e.cents))」这一笔？",
            body: "删除后移入回收站，保留 30 天，随时可以恢复。其它设备上的这条也会一并删掉。",
            confirmLabel: "删除",
            confirmDestructive: true,
            onConfirm: {
                Task { @MainActor in
                    let ok = await money.delete(id: e.id)
                    router.showToast(ok ? "已移入回收站" : "没删掉，稍后再试")
                }
            }
        ))
    }

    private var footChip: some View {
        let exp = filtered.filter { $0.direction == "expense" }.reduce(0) { $0 + $1.cents }
        let inc = filtered.filter { $0.direction == "income" }.reduce(0) { $0 + $1.cents }
        return HStack(spacing: 10) {
            Text("共 \(filtered.count) 笔").font(UmbraFont.sans(12.5)).foregroundColor(UmbraColor.muted)
            Spacer()
            Text("支出 \(MoneyFmt.yuan(exp)) · 收入 \(MoneyFmt.yuan(inc))")
                .font(UmbraFont.mono(12.5, .w560)).foregroundColor(UmbraColor.text)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UmbraColor.chip))
    }
}

// MARK: - 共用的卡片外观

private struct MoneyCardMod: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
            .overlay(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                .strokeBorder(UmbraColor.borderSoft, lineWidth: UmbraMetric.borderW))
    }
}

extension View {
    /// 记账页的卡：18 圆角 + card 底 + border-soft 描边（稿的取值）。
    func moneyCard() -> some View { modifier(MoneyCardMod()) }
}

/// 统计屏卡内的行间分隔线，**满宽**（骨架 `iosShell.list.separator`）。
///
/// 这些线是画在**行**上的（`.overlay(alignment: .top)`），而行外面套着卡的内衬
/// （概览卡 16、其余 15），所以照原样画出来左右各短一截 —— 规矩明说不许，
/// 理由是「卡片已经内缩 16，再缩一级会读成『这几行是子项』」。
/// 用负横向内边距把线顶到卡边。
///
/// ⚠️ 和 `minTapTarget.negativeMarginAxis` 那条**不是一回事**：那条管的是「撑点击热区的
/// 负边距」，这里是一条纯装饰的出血线，身上没有任何手势，偷不到谁的点击。
/// - Parameter pad: 这张卡的内衬。传错了线会短一截或探出卡外，改卡内衬时记得同步。
private func moneyRowSeparator(pad: CGFloat, tint: Color = UmbraColor.borderSoft) -> some View {
    Rectangle()
        .fill(tint)
        .frame(height: UmbraMetric.borderW)
        .padding(.horizontal, -pad)
}
