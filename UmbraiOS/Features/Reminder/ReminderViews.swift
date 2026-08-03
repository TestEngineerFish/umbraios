// 提醒 · 列表 / 详情 / 编辑。
//
// **重要：这一版提醒是「本机提醒」。** 服务端目前没有提醒接口（PC 端也还只在文档阶段），
// 所以这里不是「先做界面等接口」，而是把它做成一个真能用的东西：
//   · 数据存本机（UserDefaults 里一段 JSON）；
//   · 到点用 iOS 本地通知真的响 —— UNUserNotificationCenter，不是假的；
//   · 界面按设计稿做全（分组、左滑、重复、提前提醒）。
// 服务端有了提醒接口之后，把 ReminderStore 的读写换成 HTTP 即可，界面不用动。
//
// 与设计稿的差异只有一处文案：空态原文写「在聊天里跟秘书说『提醒我明天 10 点开会』就能建一条」——
// 那要服务端支持，现在做不到，所以改成如实的说法。别的取值和文案都照搬。
import SwiftUI
import UIKit
import UserNotifications

// MARK: - 模型与本机存储

struct UmbraReminder: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    /// 触发时间。
    var at: Date
    /// 不重复 / 每天 / 每周 / 每月 / 每年
    var repeatRule: String
    /// 提前提醒：分钟数，0 = 无。
    var aheadMinutes: Int
    var note: String
    var done: Bool

    static let repeatOptions = ["不重复", "每天", "每周", "每月", "每年"]
    static let aheadOptions: [(String, Int)] = [
        ("无", 0), ("提前 5 分钟", 5), ("提前 15 分钟", 15),
        ("提前 30 分钟", 30), ("提前 1 小时", 60), ("提前 1 天", 1440)
    ]

    var aheadLabel: String {
        UmbraReminder.aheadOptions.first { $0.1 == aheadMinutes }?.0 ?? "无"
    }

    var overdue: Bool { !done && at < Date() }

    /// 列表分组。**过期在最前** —— 过期的提醒最需要被看见。
    var group: String {
        if done { return "已完成" }
        let cal = Calendar.current
        if at < Date() { return "已过期" }
        if cal.isDateInToday(at) { return "今天" }
        if cal.isDateInTomorrow(at) { return "明天" }
        if let end = cal.date(byAdding: .day, value: 7, to: Date()), at <= end { return "本周" }
        return "更远"
    }

    /// 「今天 09:30」/「明天 09:30」/「7月31日 09:30」。
    var timeLabel: String {
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "HH:mm"
        let t = df.string(from: at)
        if cal.isDateInToday(at) { return "今天 \(t)" }
        if cal.isDateInTomorrow(at) { return "明天 \(t)" }
        if cal.isDateInYesterday(at) { return "昨天 \(t)" }
        df.dateFormat = cal.component(.year, from: at) == cal.component(.year, from: Date())
            ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
        return df.string(from: at)
    }
}

@MainActor
final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()

    @Published private(set) var items: [UmbraReminder] = []
    /// 通知权限。nil = 还没查。
    @Published private(set) var notifyAuthorized: Bool? = nil

    private let key = "umbra.reminders.local"

    private init() { load() }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([UmbraReminder].self, from: d) else { return }
        items = list.sorted { $0.at < $1.at }
    }

    private func persist() {
        items.sort { $0.at < $1.at }
        if let d = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    func item(_ id: String) -> UmbraReminder? { items.first { $0.id == id } }

    func save(_ r: UmbraReminder) {
        if let i = items.firstIndex(where: { $0.id == r.id }) { items[i] = r } else { items.append(r) }
        persist()
        schedule(r)
    }

    func delete(id: String) {
        items.removeAll { $0.id == id }
        persist()
        cancel(id: id)
    }

    func toggleDone(id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done.toggle()
        persist()
        if items[i].done { cancel(id: items[i].id) } else { schedule(items[i]) }
    }

    /// 「再等 10 分钟」。从**现在**往后推 10 分钟，不是从原时间推 ——
    /// 原时间可能已经过去两小时了，那样推完还是过期的。
    func snooze(id: String, minutes: Int = 10) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].at = Date().addingTimeInterval(TimeInterval(minutes * 60))
        items[i].done = false
        persist()
        schedule(items[i])
    }

    // MARK: 本地通知

    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            Task { @MainActor in
                self.notifyAuthorized = (s.authorizationStatus == .authorized || s.authorizationStatus == .provisional)
            }
        }
    }

    /// 请求权限。**只在用户真的建了一条提醒时问**——一进应用就弹权限框是最容易被拒的时机。
    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in self.notifyAuthorized = granted }
        }
    }

    private func cancel(id: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id, id + ".ahead"])
    }

    private func schedule(_ r: UmbraReminder) {
        cancel(id: r.id)
        guard !r.done else { return }

        let content = UNMutableNotificationContent()
        content.title = "提醒"
        content.body = r.text
        if !r.note.isEmpty { content.subtitle = r.note }
        content.sound = .default
        // 分类决定锁屏上有没有「完成 / 再等 10 分钟」两个按钮；userInfo 让动作和点击知道是哪条。
        content.categoryIdentifier = UmbraNotificationDelegate.reminderCategory
        content.userInfo = ["reminderId": r.id]

        add(id: r.id, content: content, at: r.at, rule: r.repeatRule)

        // 提前提醒是**另一条**通知，不是把主通知提前 —— 两条都要响。
        // 它的 userInfo 指向**主提醒**的 id，这样在提前通知上点「完成」也是完成那条提醒。
        if r.aheadMinutes > 0 {
            let ahead = UNMutableNotificationContent()
            ahead.title = "快到了"
            ahead.body = "\(r.aheadLabel)：\(r.text)"
            ahead.sound = .default
            ahead.categoryIdentifier = UmbraNotificationDelegate.reminderCategory
            ahead.userInfo = ["reminderId": r.id]
            add(id: r.id + ".ahead", content: ahead,
                at: r.at.addingTimeInterval(TimeInterval(-r.aheadMinutes * 60)), rule: r.repeatRule)
        }
    }

    private func add(id: String, content: UNMutableNotificationContent, at date: Date, rule: String) {
        let cal = Calendar.current
        var comps: DateComponents
        var repeats = true
        switch rule {
        case "每天": comps = cal.dateComponents([.hour, .minute], from: date)
        case "每周": comps = cal.dateComponents([.weekday, .hour, .minute], from: date)
        case "每月": comps = cal.dateComponents([.day, .hour, .minute], from: date)
        case "每年": comps = cal.dateComponents([.month, .day, .hour, .minute], from: date)
        default:
            // 不重复：过去的时间不排 —— 系统会立刻弹一条，看起来像 bug。
            guard date > Date() else { return }
            comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            repeats = false
        }
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: repeats)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

// MARK: - 列表

struct UmbraReminderListView: View {
    @EnvironmentObject private var router: UmbraRouter
    @ObservedObject private var store = ReminderStore.shared

    enum Seg: Hashable { case todo, done }
    @State private var seg: Seg = .todo

    private static let todoOrder = ["已过期", "今天", "明天", "本周", "更远"]

    var body: some View {
        UmbraPage(navBar: { EmptyView() }, content: {
            UmbraTitleHeader(title: "提醒") {
                UmbraRoundPlusButton { router.go(.remEdit(id: nil)) }
            }

            UmbraSegmentedControl(items: [
                .init(value: Seg.todo, label: "待办", count: store.items.filter { !$0.done }.count),
                .init(value: Seg.done, label: "已完成", count: store.items.filter(\.done).count)
            ], selection: $seg)
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.bottom, UmbraMetric.sp5)

            if store.notifyAuthorized == false && !store.items.isEmpty {
                // 有提醒但没通知权限 = 到点不会响。这必须说出来，否则用户以为设了就万事大吉。
                permissionBanner
            }

            if groups.isEmpty {
                UmbraEmptyState(
                    iconPath: UmbraIconPath.bell,
                    title: seg == .todo ? "还没有提醒" : "还没有完成过的提醒",
                    hint: seg == .todo
                        ? "点右上角加一条。到点会用系统通知叫你，这一版提醒存在这台手机上，还没有跟服务端同步。"
                        : "完成过的提醒会收在这里。",
                    actionTitle: seg == .todo ? "加一条提醒" : nil,
                    action: addAction)
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                    let name = g.0
                    let items = g.1
                    VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
                        UmbraSectionLabel(text: name,
                                          color: name == "已过期" ? UmbraColor.danger : UmbraColor.faint)
                            .padding(.horizontal, UmbraMetric.pagePadX)
                        VStack(spacing: 8) {
                            ForEach(items) { r in row(r) }
                        }
                        .padding(.horizontal, UmbraMetric.pagePadX)
                    }
                    .padding(.bottom, 16)
                }

                Text("左滑一行可以再等 10 分钟或删除。提醒目前只存在这台手机上，服务端有接口后会自动改成多端同步。")
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)
                    .padding(.horizontal, UmbraMetric.pagePadX)
            }
        })
        .onAppear { store.refreshAuthorization() }
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: UmbraMetric.sp3) {
            UmbraIcon(d: UmbraIconPath.alertTriangle, size: 15, strokeWidth: 2).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("没有通知权限，到点不会响")
                    .font(UmbraFont.sans(12.5, .w560))
                Text("去系统设置 › 通知 › Umbra 打开就行。")
                    .font(UmbraFont.sans(12, .w400))
            }
            Spacer(minLength: 0)
            Button {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            } label: {
                Text("去开").font(UmbraFont.sans(13, .w600))
                    .frame(minHeight: UmbraMetric.tapMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(UmbraColor.warning)
        .padding(.horizontal, UmbraMetric.sp4)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(UmbraColor.warningSoft))
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.bottom, UmbraMetric.sp5)
    }

    /// 空态的主动作。写成一个显式的可选闭包，而不是在参数位置写三元 ——
    /// `cond ? { ... } : nil` 里闭包字面量的类型推不出来，编译器会直接拒绝。
    private var addAction: (() -> Void)? {
        guard seg == .todo else { return nil }
        return { router.go(.remEdit(id: nil)) }
    }

    private var groups: [(String, [UmbraReminder])] {
        let pool = store.items.filter { seg == .todo ? !$0.done : $0.done }
        let order = seg == .todo ? Self.todoOrder : ["已完成"]
        return order.compactMap { name in
            let items = pool.filter { $0.group == name }
            return items.isEmpty ? nil : (name, items)
        }
    }

    private func row(_ r: UmbraReminder) -> some View {
        UmbraSwipeRow(actions: [
            UmbraSwipeAction(label: "再等\n10 分钟", width: 88, background: UmbraColor.warning) {
                store.snooze(id: r.id)
                router.showToast("好，10 分钟后再叫你")
            },
            UmbraSwipeAction(label: "删除", width: 80, background: UmbraColor.danger) {
                store.delete(id: r.id)
                router.showToast("已删除")
            }
        ]) {
            Button {
                router.go(.remDetail(id: r.id))
            } label: {
                HStack(alignment: .top, spacing: UmbraMetric.sp4) {
                    // 勾选圈是独立的点击区（点圈=完成，点行=进详情）。
                    Button { store.toggleDone(id: r.id) } label: {
                        ZStack {
                            Circle()
                                .fill(r.done ? UmbraColor.success : Color.clear)
                            Circle()
                                .strokeBorder(r.done ? UmbraColor.success : UmbraColor.border, lineWidth: 1.8)
                            if r.done {
                                UmbraIcon(d: UmbraIconPath.check, size: 13, strokeWidth: 3.4)
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(width: 24, height: 24)
                        // 圈只有 24，靠 10 的内边距把触达区撑到 44；外面再用 -10 抵消，
                        // 视觉上仍是 24，不会把旁边的文字挤开。
                        .padding(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-10)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(r.text)
                            .font(UmbraFont.sans(16, .w400))
                            .foregroundColor(r.done ? UmbraColor.faint : UmbraColor.text)
                            .strikethrough(r.done)
                            .lineSpacing(16 * 0.4)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 7) {
                            Text(r.timeLabel)
                                .font(UmbraFont.sans(13, .w400))
                                .foregroundColor(r.overdue ? UmbraColor.danger : UmbraColor.muted)
                            if r.overdue { pill("已过期", UmbraColor.dangerSoft, UmbraColor.danger) }
                            if r.repeatRule != "不重复" {
                                HStack(spacing: 4) {
                                    UmbraIcon(d: UmbraIconPath.repeatArrows, size: 10, strokeWidth: 2.4)
                                    Text(r.repeatRule).font(UmbraFont.sans(11, .w600))
                                }
                                .foregroundColor(UmbraColor.muted)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(UmbraColor.chip))
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    UmbraIcon(d: UmbraIconPath.chevronRight, size: 16, strokeWidth: 2.2)
                        .foregroundColor(UmbraColor.faint)
                        .padding(.top, 5)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, UmbraMetric.sp4)
                .frame(minHeight: UmbraMetric.tapMin)
                .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous).fill(UmbraColor.card))
                .overlay(
                    RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                        .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func pill(_ t: String, _ bg: Color, _ fg: Color) -> some View {
        Text(t)
            .font(UmbraFont.sans(11, .w600))
            .foregroundColor(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
    }
}

// MARK: - 详情

struct UmbraReminderDetailView: View {
    let id: String

    @EnvironmentObject private var router: UmbraRouter
    @ObservedObject private var store = ReminderStore.shared

    private var item: UmbraReminder? { store.item(id) }

    var body: some View {
        UmbraPage(navBar: {
            UmbraNavBar(backLabel: "提醒", title: "", onBack: { router.back() }) {
                if item != nil {
                    UmbraNavAction(title: "编辑") { router.go(.remEdit(id: id)) }
                }
            }
        }, content: {
            if let r = item { content(r) } else { missing }
        }, bottom: {
            if let r = item { bottomBar(r) }
        })
    }

    private var missing: some View {
        UmbraEmptyState(iconPath: UmbraIconPath.bell, title: "这条提醒不在了",
                        hint: "可能是刚才删掉了。", actionTitle: "回到提醒列表",
                        action: { router.back() })
    }

    @ViewBuilder
    private func content(_ r: UmbraReminder) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(r.text)
                .font(UmbraFont.sans(24, .w600))
                .foregroundColor(UmbraColor.text)
                .lineSpacing(24 * 0.35)
            HStack(spacing: 8) {
                Text(r.timeLabel)
                    .font(UmbraFont.sans(16, .w560))
                    .foregroundColor(r.overdue ? UmbraColor.danger : UmbraColor.text)
                if r.overdue {
                    Text("已过期")
                        .font(UmbraFont.sans(11, .w600))
                        .foregroundColor(UmbraColor.danger)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(UmbraColor.dangerSoft))
                }
            }
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.top, UmbraMetric.sp6)
        .padding(.bottom, 16)

        UmbraSettingSectionView(section: UmbraSettingSection(rows: [
            UmbraSettingRow(label: "重复", value: r.repeatRule),
            UmbraSettingRow(label: "提前提醒", value: r.aheadLabel),
            UmbraSettingRow(label: "状态", value: r.done ? "已完成" : "待办"),
            UmbraSettingRow(label: "备注", value: r.note.isEmpty ? "—" : r.note)
        ]))

        Text("这一版提醒只存在这台手机上，到点用系统通知叫你。服务端有提醒接口后会改成多端同步。")
            .font(UmbraFont.sans(12, .w400))
            .foregroundColor(UmbraColor.faint)
            .lineSpacing(12 * 0.65)
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.top, 16)
    }

    private func bottomBar(_ r: UmbraReminder) -> some View {
        UmbraBottomBar {
            UmbraButton(title: r.done ? "标回待办" : "完成", kind: .primary) {
                store.toggleDone(id: r.id)
                router.showToast(r.done ? "已标回待办" : "已完成")
            }
            UmbraButton(title: "再等 10 分钟", kind: .secondary) {
                store.snooze(id: r.id)
                router.showToast("好，10 分钟后再叫你")
            }
        }
    }
}

// MARK: - 编辑

struct UmbraReminderEditView: View {
    /// nil = 新建
    let id: String?

    @EnvironmentObject private var router: UmbraRouter
    @ObservedObject private var store = ReminderStore.shared

    @State private var text = ""
    @State private var at = Date().addingTimeInterval(3600)
    @State private var repeatRule = "不重复"
    @State private var ahead = 0
    @State private var note = ""
    @State private var loaded = false

    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        UmbraPage(navBar: {
            UmbraNavBar(backLabel: "取消", title: id == nil ? "新建提醒" : "编辑提醒",
                        onBack: { router.back() }, backChevron: false) {
                UmbraNavAction(title: "存下", weight: .w600, enabled: canSave, action: save)
            }
        }, content: {
            VStack(alignment: .leading, spacing: UmbraMetric.sp6) {
                field("提醒内容") {
                    TextField("要提醒你做什么", text: $text, axis: .vertical)
                        .font(UmbraFont.sans(16, .w400))
                        .lineSpacing(16 * 0.55)
                        .lineLimit(3...)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .frame(minHeight: 88, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(UmbraColor.card))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                        )
                }

                field("时间") {
                    // 用系统 DatePicker：日期时间选择器是用户最熟的控件，
                    // 自绘一个只会更难用，而且设计稿这里用的就是原生 date/time input。
                    DatePicker("", selection: $at, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                }

                UmbraSettingSectionView(section: UmbraSettingSection(rows: [
                    UmbraSettingRow(label: "重复", value: repeatRule, chevron: true) {
                        router.present(UmbraSheet(title: "重复", items: UmbraReminder.repeatOptions.map { o in
                            UmbraSheetItem(label: o, checked: repeatRule == o) { repeatRule = o }
                        }))
                    },
                    UmbraSettingRow(label: "提前提醒", value: aheadLabel, chevron: true) {
                        router.present(UmbraSheet(title: "提前提醒", items: UmbraReminder.aheadOptions.map { o in
                            UmbraSheetItem(label: o.0, checked: ahead == o.1) { ahead = o.1 }
                        }))
                    }
                ]))
                // SettingSectionView 自带左右 16，这里外面已经有 16 了，抵消掉
                .padding(.horizontal, -UmbraMetric.pagePadX)

                field("备注（可选）") {
                    TextField("要不要带什么、找谁", text: $note, axis: .vertical)
                        .font(UmbraFont.sans(15.5, .w400))
                        .lineSpacing(15.5 * 0.55)
                        .lineLimit(2...)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .frame(minHeight: 64, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(UmbraColor.card))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                        )
                }

                Text("到点用系统通知叫你。这一版提醒存在这台手机上，卸载应用会一起没掉。")
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)

                if !canSave {
                    Text("提醒内容还是空的，写一句才能存。")
                        .font(UmbraFont.sans(12, .w400))
                        .foregroundColor(UmbraColor.faint)
                }

                if let rid = id, store.item(rid) != nil {
                    UmbraButton(title: "删除这条提醒", kind: .dangerOutline) {
                        router.confirm(UmbraAlert(
                            title: "删除这条提醒？",
                            body: "删除后不会再提醒你，也无法恢复。",
                            confirmLabel: "删除",
                            confirmDestructive: true,
                            onConfirm: {
                                store.delete(id: rid)
                                router.back()
                                router.showToast("已删除")
                            }))
                    }
                }
            }
            .padding(UmbraMetric.pagePadX)
        })
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let rid = id, let r = store.item(rid) {
                text = r.text; at = r.at; repeatRule = r.repeatRule
                ahead = r.aheadMinutes; note = r.note
            }
        }
    }

    private var aheadLabel: String {
        UmbraReminder.aheadOptions.first { $0.1 == ahead }?.0 ?? "无"
    }

    @ViewBuilder
    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
            UmbraFieldLabel(text: label)
            content()
        }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let existing = id.flatMap { store.item($0) }
        let r = UmbraReminder(id: existing?.id ?? UUID().uuidString,
                              text: t, at: at, repeatRule: repeatRule,
                              aheadMinutes: ahead, note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                              done: existing?.done ?? false)
        store.save(r)
        // 第一次建提醒时才要权限 —— 这时候用户正想让它响，是最容易被同意的时机。
        store.requestAuthorizationIfNeeded()
        router.back()
        router.showToast("已存下")
    }
}
