// 日期 / 时间选择面板 —— 底部玻璃面板：月历网格 + 时/分滚轮（批次 007 答复稿，tokens.dateTimePicker.ios）。
//
// 交接清单第 3 条照旧：**禁止用浏览器原生 date/time picker 的替代品**（文本输入、
// 系统日历弹窗都不行），统一从**字段整行**弹出，不是点图标。
//
// 与 PC 的 dateTimePicker 同一套规则，形态换成移动端：
// - **日期 = 月历网格**（批次 007 把「今天 ±2 年单列滚轮」撤了：触屏上滚 400 行找
//   「明年 3 月」要划十几次，网格两下换月）。恒 6 行 42 格、周一开头、切月不跳高；
//   格高 44（热区达标）、圆角 12、16px tabular；**选中 --orange 实底白字，
//   今天 1px --border 描边 + 650 字重、不用橙** —— 一屏两个橙分不清哪个是你选的；
//   邻月 --faint 可点，点了跟着翻月。
// - **时间 = 时/分滚轮留着**（60 个分钟用惯性滑最快，也是系统习惯），只把选中行换成
//   --orange-text 600、未选中 --faint。稿还要求选中带 --orange-soft —— 系统滚轮的镜片
//   盖在最上层且不开放替换，这里把橙软带垫在滚轮**后面**从镜片下透出来；
//   完全替换镜片要去抠 UIPickerView 的私有子视图，按本工程「不碰系统件私有结构」的
//   铁律不做（已记回流台账，设计看实机效果再定）。
// - **一个值 = 一个字段**：提醒 / 记一笔的「什么时候」是一个瞬间 → when 面板
//   （顶部两段切换，一次「确定」落两段，中途关掉不留半个值）；周期规则的
//   「首次日期 / 时间」是两个值 → 各自单开，date 点选即落值（底条只留全宽「取消」）。
// - **结束日期复用 date 面板 + 下界**：早于 min 的日子直接不可点（--faint + 34% 透明），
//   下方一行 --faint 说明为什么 —— 拦在前面比事后标红省一步；红字只留给
//   「进来时值就已经不对」（前面的日期被改过）。
import SwiftUI

// MARK: - 面板本体

struct UmbraDateTimePanel: View {
    /// 三种变体：只选日期（点选即落）/ 只选时间（确定落）/ 日期+时间（两段一次确定）。
    enum Kind { case date, time, when }

    /// when 面板的两段。Identifiable 是为了直接喂 sheet(item:)（哪段打开面板就落在哪段）。
    enum Tab: String, Identifiable {
        case date, time
        var id: String { rawValue }
    }

    let kind: Kind
    /// 顶条待落值下面那行小字：这是哪个字段（「什么时候」/「结束重复」…）——
    /// 面板高的时候用户会忘了自己在改哪一行。
    let field: String
    /// 初值。确定时把改动合并回同一个 Date 的对应部分（date 只换年月日、time 只换时分）。
    let initial: Date
    /// 结束日期这类字段的下界（含当天）。早于它的日子不可点。
    var minDay: Date? = nil
    /// 下界的一句说明（--faint 常驻）。为什么选不了要说出来，不能只是灰着。
    var minNote: String? = nil
    var initialTab: Tab = .date
    var onCancel: () -> Void
    var onConfirm: (Date) -> Void

    /// 选中的那天（startOfDay）与时分。@State 在 onAppear 灌初值 ——
    /// init 里赋 @State 会被 SwiftUI 的状态恢复盖掉（老坑）。
    @State private var selDay = Calendar.current.startOfDay(for: Date())
    @State private var hour = 9
    @State private var minute = 0
    /// 日历当前显示的月份（每月 1 号）。选邻月的日子会跟着翻过去。
    @State private var shownMonth = Date()
    @State private var tab: Tab = .date
    @State private var seeded = false

    private var cal: Calendar { Calendar.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if kind == .when { tabs }
            if kind == .date || (kind == .when && tab == .date) { calendarGrid }
            if kind == .time || (kind == .when && tab == .time) { wheels }
            if let note = hintText { hintLine(note) }
            footer
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.top, 14)
        .padding(.bottom, UmbraMetric.sp3)
        .onAppear(perform: seed)
    }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        selDay = cal.startOfDay(for: initial)
        hour = cal.component(.hour, from: initial)
        minute = cal.component(.minute, from: initial)
        shownMonth = cal.date(from: cal.dateComponents([.year, .month], from: initial)) ?? initial
        tab = initialTab
    }

    // MARK: 顶条：待落值 + 字段名 + 「今天 / 现在」快捷

    /// 顶条待落值：`8月4日 周二 18:00` 这类，17/600 tabular（稿定值）。
    private var pendingText: String {
        switch kind {
        case .date: return Self.dayText(selDay)
        case .time: return String(format: "%02d:%02d", hour, minute)
        case .when: return "\(Self.dayText(selDay)) \(String(format: "%02d:%02d", hour, minute))"
        }
    }

    /// 「今天 / 现在」是一步落完整值，点了直接落值关掉。
    /// date 面板遇到「今天早于下界」时不给（点了也是非法值）。
    private var quickLabel: String? {
        if kind == .date {
            if let min = minDay, cal.startOfDay(for: Date()) < cal.startOfDay(for: min) { return nil }
            return "今天"
        }
        return "现在"
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pendingText)
                    .font(UmbraFont.sans(17, .w600))
                    .monospacedDigit()
                    .foregroundColor(UmbraColor.text)
                    .lineLimit(1)
                Text(field)
                    .font(UmbraFont.sans(11.5, .w400))
                    .foregroundColor(UmbraColor.faint)
            }
            Spacer(minLength: 0)
            if let q = quickLabel {
                Button {
                    let now = Date()
                    switch kind {
                    case .date: onConfirm(compose(day: cal.startOfDay(for: now)))
                    case .time: onConfirm(composeTime(from: now))
                    case .when: onConfirm(now.umbraTrimSeconds)
                    }
                } label: {
                    Text(q)
                        .font(UmbraFont.sans(15, .w560))
                        .foregroundColor(UmbraColor.orangeText)
                        .frame(minHeight: UmbraMetric.tapMin)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: when 面板的两段（段标签直接写两段的当前值）

    private var tabs: some View {
        HStack(spacing: 3) {
            tabButton(.date, label: Self.dayText(selDay))
            tabButton(.time, label: String(format: "%02d:%02d", hour, minute))
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UmbraColor.chip))
    }

    private func tabButton(_ t: Tab, label: String) -> some View {
        let on = tab == t
        return Button { tab = t } label: {
            Text(label)
                .font(UmbraFont.sans(14, on ? .w600 : .w400))
                .monospacedDigit()
                .foregroundColor(on ? UmbraColor.text : UmbraColor.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(on ? UmbraColor.card : Color.clear)
                        .shadow(color: on ? Color.black.opacity(0.12) : .clear, radius: 3, x: 0, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 月历网格

    /// 恒 6 行 42 格的月历数据。切月不跳高靠的就是「恒 42 格」。
    private struct DayCell: Identifiable {
        let id: String        // 'YYYY-MM-DD'
        let day: Date         // startOfDay
        let label: String
        let otherMonth: Bool
    }

    private var cells: [DayCell] {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: shownMonth)) ?? shownMonth
        // 周一开头：getDay 周日=1…挪成周一=0。
        let firstDow = (cal.component(.weekday, from: first) + 5) % 7
        guard let gridStart = cal.date(byAdding: .day, value: -firstDow, to: first) else { return [] }
        return (0..<42).compactMap { i in
            guard let d = cal.date(byAdding: .day, value: i, to: gridStart) else { return nil }
            let comps = cal.dateComponents([.year, .month, .day], from: d)
            return DayCell(
                id: "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)",
                day: d,
                label: "\(comps.day ?? 0)",
                otherMonth: !cal.isDate(d, equalTo: first, toGranularity: .month))
        }
    }

    private var monthTitle: String {
        let c = cal.dateComponents([.year, .month], from: shownMonth)
        return "\(c.year ?? 0)年\(c.month ?? 0)月"
    }

    private var calendarGrid: some View {
        VStack(spacing: 5) {
            // 月头：44×44 箭头（热区达标）+ 居中年月。
            HStack(spacing: 2) {
                monthArrow(-1, path: UmbraIconPath.chevronLeft, label: "上一个月")
                Text(monthTitle)
                    .font(UmbraFont.sans(15.5, .w600))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                monthArrow(1, path: UmbraIconPath.chevronRight, label: "下一个月")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { w in
                    Text(w).font(UmbraFont.sans(11.5)).foregroundColor(UmbraColor.faint).frame(height: 18)
                }
                ForEach(cells) { c in dayButton(c) }
            }
        }
    }

    private func monthArrow(_ delta: Int, path: String, label: String) -> some View {
        Button {
            shownMonth = cal.date(byAdding: .month, value: delta, to: shownMonth) ?? shownMonth
        } label: {
            UmbraIcon(d: path, size: 19, strokeWidth: 2.1)
                .foregroundColor(UmbraColor.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func dayButton(_ c: DayCell) -> some View {
        let on = cal.isDate(c.day, inSameDayAs: selDay)
        let isToday = cal.isDateInToday(c.day)
        // 早于下界的日子直接不可点（拦在前面比事后标红省一步）。
        let disabled = minDay.map { c.day < cal.startOfDay(for: $0) } ?? false
        return Button {
            guard !disabled else { return }
            selDay = c.day
            // 邻月的点了跟着翻月（稿）。
            if c.otherMonth {
                shownMonth = cal.date(from: cal.dateComponents([.year, .month], from: c.day)) ?? shownMonth
            }
            // date 变体是完整的一个值：点一下即落值关闭；when 只改草稿，等「确定」。
            if kind == .date { onConfirm(compose(day: c.day)) }
        } label: {
            Text(c.label)
                .font(UmbraFont.sans(16, on ? .w600 : (isToday && !on ? .w650 : .w400)))
                .monospacedDigit()
                .foregroundColor(disabled ? UmbraColor.faint
                                 : on ? .white
                                 : c.otherMonth ? UmbraColor.faint : UmbraColor.text)
                .opacity(disabled ? 0.34 : 1)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(on ? UmbraColor.orange : Color.clear)
                )
                // 今天 = 描边加粗、不用橙 —— 一屏两个橙分不清哪个是你选的。
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isToday && !on ? UmbraColor.border : Color.clear,
                                      lineWidth: UmbraMetric.borderW)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 下界说明 / 非法初值

    /// 常态给 minNote（--faint）；「进来时值就已经不对」（前面的日期被改过）才转红字。
    private var hintText: String? {
        guard kind != .time, minNote != nil || badIncoming else { return nil }
        if badIncoming, let min = minDay {
            return "现在这个日子早于 \(Self.dayText(cal.startOfDay(for: min)))，这条一次都不会执行。往后挑一天，或者先改前面的日期。"
        }
        return minNote
    }

    private var badIncoming: Bool {
        guard let min = minDay else { return false }
        return selDay < cal.startOfDay(for: min)
    }

    private func hintLine(_ text: String) -> some View {
        Text(text)
            .font(UmbraFont.sans(12, .w400))
            .foregroundColor(badIncoming ? UmbraColor.danger : UmbraColor.faint)
            .lineSpacing(12 * 0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 时 / 分滚轮

    private var wheels: some View {
        ZStack {
            // 橙软选中带垫在滚轮后面（文件头注释：系统镜片不开放替换，从镜片下透色）。
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(UmbraColor.orangeSoft)
                .frame(height: 40)
                .padding(.horizontal, 8)
            HStack(spacing: 0) {
                Picker("时", selection: $hour) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(String(format: "%02d 时", h))
                            .font(UmbraFont.sans(15.5, h == hour ? .w600 : .w400))
                            .monospacedDigit()
                            .foregroundColor(h == hour ? UmbraColor.orangeText : UmbraColor.faint)
                            .tag(h)
                    }
                }
                .pickerStyle(.wheel)
                Picker("分", selection: $minute) {
                    ForEach(0..<60, id: \.self) { m in
                        Text(String(format: "%02d 分", m))
                            .font(UmbraFont.sans(15.5, m == minute ? .w600 : .w400))
                            .monospacedDigit()
                            .foregroundColor(m == minute ? UmbraColor.orangeText : UmbraColor.faint)
                            .tag(m)
                    }
                }
                .pickerStyle(.wheel)
            }
        }
        .frame(height: 200)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(UmbraColor.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 底条

    /// date 点选即落值，底条只留一个全宽「取消」（给面板一个出口）；
    /// time / when 要点「确定」（两列 / 两段，中途关掉不该留半个值）。
    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Text("取消")
                    .font(UmbraFont.sans(16, .w560))
                    .foregroundColor(UmbraColor.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Capsule().fill(UmbraColor.chip))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            if kind != .date {
                Button {
                    onConfirm(kind == .time ? composeTime() : composeWhen())
                } label: {
                    Text("确定")
                        .font(UmbraFont.sans(16, .w600))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Capsule().fill(UmbraColor.orange))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    // MARK: 合成回 Date（各变体只动自己那部分，谁也不覆盖谁）

    private func compose(day: Date) -> Date {
        let hm = cal.dateComponents([.hour, .minute], from: initial)
        return cal.date(bySettingHour: hm.hour ?? 9, minute: hm.minute ?? 0, second: 0, of: day) ?? initial
    }

    /// time 变体只换时分、**年月日保持绑定值的** —— 周期规则的 timeDate 是一个只承载
    /// HH:mm 的合成 Date，动了它的日期部分等于悄悄改了别的字段。
    /// from 给「现在」快捷用：取 now 的时分，日期部分照旧不动。
    private func composeTime(from date: Date? = nil) -> Date {
        let h = date.map { cal.component(.hour, from: $0) } ?? hour
        let m = date.map { cal.component(.minute, from: $0) } ?? minute
        return cal.date(bySettingHour: h, minute: m, second: 0, of: initial) ?? initial
    }

    private func composeWhen() -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: selDay) ?? initial
    }

    // MARK: 文案

    /// 「今天」/「明天」/「8月5日 周三」（跨年带年份）。相对词只给最近两天 ——
    /// 再远的相对词读起来要换算，不如直接给日期。
    static func dayText(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "今天" }
        if cal.isDateInTomorrow(day) { return "明天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = cal.component(.year, from: day) == cal.component(.year, from: Date())
            ? "M月d日 EEE" : "yyyy年M月d日 EEE"
        return f.string(from: day)
    }

    /// 「今天 / 明天 / 8月5日 周三」按天数偏移取（提醒表单行上的显示还在用这个口径）。
    static func dayLabel(offset: Int) -> String {
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date())) ?? Date()
        return dayText(d)
    }
}

private extension Date {
    /// 秒归零：面板落值都是分钟精度，留着秒会让「现在」和滚轮选出来的值差几十秒。
    var umbraTrimSeconds: Date {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: self)
        return cal.date(from: c) ?? self
    }
}

// MARK: - 挂载扩展
//
// 玻璃底、圆角 26、固定高度 detent 统一在这里给，各页不用重复。
// 三个入口对应三种变体；when 用 sheet(item:) 直接吃 Tab —— 点哪段面板就开在哪段。
extension View {
    /// 「什么时候」（日期+时间，一个瞬间一个值）。tab 非 nil 即打开，落在那一段上。
    func umbraWhenPicker(tab: Binding<UmbraDateTimePanel.Tab?>,
                         field: String,
                         date: Binding<Date>) -> some View {
        sheet(item: tab) { t in
            UmbraDateTimePanel(
                kind: .when, field: field, initial: date.wrappedValue, initialTab: t,
                onCancel: { tab.wrappedValue = nil },
                onConfirm: { new in date.wrappedValue = new; tab.wrappedValue = nil })
            .presentationDetents([.height(560)])
            .presentationCornerRadius(UmbraMetric.radiusSheet)
            .presentationBackground(.ultraThinMaterial)
            .presentationDragIndicator(.hidden)
        }
    }

    /// 只选日期（点选即落值）。结束日期这类传 minDay / minNote：早于下界的日子不可点。
    func umbraDatePicker(isPresented: Binding<Bool>,
                         field: String,
                         date: Binding<Date>,
                         minDay: Date? = nil,
                         minNote: String? = nil) -> some View {
        sheet(isPresented: isPresented) {
            UmbraDateTimePanel(
                kind: .date, field: field, initial: date.wrappedValue,
                minDay: minDay, minNote: minNote,
                onCancel: { isPresented.wrappedValue = false },
                onConfirm: { new in date.wrappedValue = new; isPresented.wrappedValue = false })
            .presentationDetents([.height(minNote == nil ? 500 : 540)])
            .presentationCornerRadius(UmbraMetric.radiusSheet)
            .presentationBackground(.ultraThinMaterial)
            .presentationDragIndicator(.hidden)
        }
    }

    /// 只选时间（时/分滚轮 + 确定）。
    func umbraTimePicker(isPresented: Binding<Bool>,
                         field: String,
                         date: Binding<Date>) -> some View {
        sheet(isPresented: isPresented) {
            UmbraDateTimePanel(
                kind: .time, field: field, initial: date.wrappedValue,
                onCancel: { isPresented.wrappedValue = false },
                onConfirm: { new in date.wrappedValue = new; isPresented.wrappedValue = false })
            .presentationDetents([.height(340)])
            .presentationCornerRadius(UmbraMetric.radiusSheet)
            .presentationBackground(.ultraThinMaterial)
            .presentationDragIndicator(.hidden)
        }
    }
}
