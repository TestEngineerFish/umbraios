// 提醒 · 列表 / 详情（就地编辑）/ 新建。
//
// **数据是跨端同步的**（服务端 /reminders）。本机那份降级成**离线缓存**：
// 断网时照常读写并排队，联网后按 updated_at_ms 逐条合并（规则见 ReminderSync.swift）。
// 提醒是离线属性最强的功能，不能因为拉不到服务端就整个用不了。
//
// **到点触发仍然全靠本机**：服务端只存不调度 —— 没有 APNs 时它算出「到点了」也
// 推不到不在前台的 App。所以每次拿到新数据都要把本地通知整体重排一遍（rescheduleAll）。
//
// v2 变化：
//   列表 = 系统 List + 系统 .swipeActions（老系统方块、iOS 26 自动浮动胶囊）；
//   勾选 = 圈立即变绿画勾 → 停一拍 → 整行淡出收合，完成给带「撤销」的 toast；
//   详情 = **就地编辑**（同页切预览/编辑，导航变 取消/保存，不推新页）；
//   重复规则 = 不重复/每天/每周/每月/工作日/自定义（每 N 小时/天/周/月/年）+ 结束日期，
//   子项行左缩进 32、行高 38、标签 15 灰（同卡白底不换色）；
//   选项类字段 = 系统 Menu（锚定小弹框）；日期/时间 = 滚轮面板（UmbraPickers）。
import SwiftUI
import UIKit
import UserNotifications

// MARK: - 模型与本机存储

struct UmbraReminder: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    /// 触发时间。
    var at: Date
    /// 不重复 / 每天 / 每周 / 每月 / 工作日 / 自定义
    var repeatRule: String
    /// 自定义重复的单位（小时/天/周/月/年）与间隔（每 N）。只在 repeatRule == 自定义 时有意义。
    var customFreq: String
    var customN: Int
    /// 结束重复。nil = 永不。
    var repeatEnd: Date?
    /// 提前提醒：分钟数，0 = 无。
    var aheadMinutes: Int
    var note: String
    var done: Bool
    /// 来源与创建时间（详情页字段）。目前只有手动添加；聊天建提醒等服务端接口。
    var source: String
    var createdAt: Date
    /// 跨端合并的依据（epoch 毫秒）。任何本地改动都要把它推到「现在」，
    /// 服务端与各端按它比大小判胜负 —— 详见 ReminderSync.swift。
    var updatedAtMs: Int64
    /// 本地改过、还没成功推给服务端。联网后补推；拉取合并时「本地 dirty 且更新」则本地赢，
    /// 否则断网期间的修改会被服务端旧值覆盖掉。
    var dirty: Bool

    static let repeatOptions = ["不重复", "每天", "每周", "每月", "工作日", "自定义"]
    static let customFreqOptions = ["小时", "天", "周", "月", "年"]
    static let aheadOptions: [(String, Int)] = [
        ("无", 0), ("5 分钟", 5), ("15 分钟", 15), ("1 小时", 60), ("1 天", 1440)
    ]

    init(id: String, text: String, at: Date, repeatRule: String = "不重复",
         customFreq: String = "天", customN: Int = 1, repeatEnd: Date? = nil,
         aheadMinutes: Int = 0, note: String = "", done: Bool = false,
         source: String = "手动添加", createdAt: Date = Date(),
         updatedAtMs: Int64 = 0, dirty: Bool = true) {
        self.id = id; self.text = text; self.at = at; self.repeatRule = repeatRule
        self.customFreq = customFreq; self.customN = customN; self.repeatEnd = repeatEnd
        self.aheadMinutes = aheadMinutes; self.note = note; self.done = done
        self.source = source; self.createdAt = createdAt
        self.updatedAtMs = updatedAtMs == 0 ? Date.umbraNowMs : updatedAtMs
        self.dirty = dirty
    }

    /// 手写解码：v1 存量数据没有 customFreq / repeatEnd / source 这些键，
    /// 直接加非可选字段会让老数据整批解不出来 —— 缺的键给默认值。
    /// v1 的「每年」规则映射成 自定义·每 1 年。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        at = try c.decode(Date.self, forKey: .at)
        let rule = try c.decode(String.self, forKey: .repeatRule)
        customFreq = try c.decodeIfPresent(String.self, forKey: .customFreq) ?? "天"
        customN = try c.decodeIfPresent(Int.self, forKey: .customN) ?? 1
        if rule == "每年" { repeatRule = "自定义"; customFreq = "年"; customN = 1 }
        else { repeatRule = rule }
        repeatEnd = try c.decodeIfPresent(Date.self, forKey: .repeatEnd)
        aheadMinutes = try c.decodeIfPresent(Int.self, forKey: .aheadMinutes) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "手动添加"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? at
        // 上收之前的存量数据没有这两个键：它们从没推给过服务端，
        // 所以标成 dirty 等着补推。戳用 createdAt 而不是「现在」——
        // 每次读缓存都盖新戳的话，它会永远比服务端新，服务端的修改就再也进不来了。
        updatedAtMs = try c.decodeIfPresent(Int64.self, forKey: .updatedAtMs) ?? createdAt.umbraMs
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? true
    }

    var aheadLabel: String {
        UmbraReminder.aheadOptions.first { $0.1 == aheadMinutes }?.0 ?? "无"
    }

    /// 「每 3 天一次」/「每周」/「不重复」。
    var repeatLabel: String {
        repeatRule == "自定义" ? "每 \(max(1, customN)) \(customFreq)一次" : repeatRule
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

    var createdLabel: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 HH:mm"
        return df.string(from: createdAt)
    }
}

@MainActor
final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()

    @Published private(set) var items: [UmbraReminder] = []
    /// 通知权限。nil = 还没查。
    @Published private(set) var notifyAuthorized: Bool? = nil

    private init() {
        items = ReminderCache.load()
        // **冷启动就整体重排一遍**。预排式规则（工作日 / 自定义间隔 / 带结束日期）系统
        // 表达不了，只能预排 maxPrescheduled 次；scheduleSeries 的注释一直承诺
        // 「每次打开 App 都会重排一遍」，但一期 init/reload 谁都没真的调 schedule——
        // 于是这类提醒用满 12 次之后就**静默不响了**。这里把承诺补上。
        rescheduleAll()
        refreshBadge()
        // 启动就同步一次小组件快照 —— 原来只在「有改动 / 下拉刷新」时写，
        // 刚装上 App 没碰过提醒的话小组件永远拿不到数据（实机踩过）。
        UmbraWidgetBridge.syncReminders(items)
        Task { await self.sync() }
    }

    /// 下拉刷新入口（非 async 调用点用这个，比如别处主动触发一次同步）。
    func reload() {
        refreshAuthorization()
        Task { await self.sync() }
    }

    /// 下拉刷新的 async 版：`.refreshable` 要 await 到真的拉完，
    /// 否则转圈立刻消失，用户以为没刷新。
    func reloadAsync() async {
        refreshAuthorization()
        await sync()
    }

    // MARK: 服务端同步

    /// 正在同步。只用来防并发重入（下拉刷新连点、启动与首次进页面撞一起）。
    private var syncing = false
    /// 同步进行中又来了新的同步请求。**不能直接丢掉**：秘书在聊天里建提醒时，
    /// 广播往往紧跟在别的同步后面到达，直接丢就等于这条提醒要等下一轮定时同步
    /// ——而「5 分钟后提醒我」根本等不到。这里记一笔，跑完再补一轮。
    private var resyncRequested = false

    /// 拉增量 → 合并 → 补推本地未推送的改动与删除。
    ///
    /// 同步中再调只会记一笔待办并立刻返回，等当前这轮跑完自动补跑（不丢请求）。
    func sync() async {
        guard !syncing else { resyncRequested = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            resyncRequested = false
            await syncOnce()
        } while resyncRequested
    }

    /// 秘书或别的端改了提醒 → 立刻拉一次，别等下一轮定时同步。
    /// 非 async 的调用点（WS 事件回调）用这个。
    func syncNow() {
        Task { await self.sync() }
    }

    /// 一轮实际的同步。
    ///
    /// **任何一步失败都不动本地数据**：断网时提醒必须照常能用，
    /// 把列表清空或回滚成服务端旧值都是不可接受的（比不同步更糟）。
    private func syncOnce() async {
        // ① 先补推：本地的改动要先上去，免得紧接着拉下来的服务端旧值把它盖了。
        await pushPending()

        // ② 拉增量并合并。
        let since = ReminderCache.lastSyncMs
        guard let page = await HTTPService.shared.fetchReminders(since: since) else { return }
        let merged = ReminderMerge.apply(local: items,
                                         serverItems: page.items,
                                         serverTombs: page.deleted)
        ReminderCache.lastSyncMs = page.synced_at_ms
        applyMerged(merged)
    }

    /// 合并结果落地：存缓存 + 整体重排通知 + 刷角标与小组件。
    /// 单独一个方法是因为「拿到新数据之后要做的四件事」谁都不能漏，漏一件就是个隐蔽 bug。
    private func applyMerged(_ merged: [UmbraReminder]) {
        items = merged.sorted { $0.at < $1.at }
        ReminderCache.save(items)
        rescheduleAll()
        refreshBadge()
        UmbraWidgetBridge.syncReminders(items)
    }

    /// 把本地攒下的改动与删除推上去。推成功才清 dirty / 清墓碑 ——
    /// 推失败就留着，下次同步继续试（断网期间改的东西不能丢）。
    private func pushPending() async {
        for (id, ms) in ReminderCache.pendingTombs() {
            if await HTTPService.shared.deleteReminder(id: id, at: ms) {
                ReminderCache.removeTomb(id: id)
            }
        }
        for r in items where r.dirty {
            guard let resp = await HTTPService.shared.putReminder(r.dto) else { continue }
            guard let i = items.firstIndex(where: { $0.id == r.id }) else { continue }
            if resp.applied {
                items[i].dirty = false
            } else {
                // 服务端那份更新（别的端刚改过）→ 用它覆盖本地，别再反复推一个必输的版本。
                items[i] = UmbraReminder(dto: resp.reminder)
            }
        }
        ReminderCache.save(items)
    }

    /// 本地写操作的统一收尾：盖时间戳、标 dirty、落缓存、重排、刷角标，最后异步推。
    /// 所有 save/delete/toggle/snooze 都走它 —— 少做一步就会出现「改了没同步」这类幽灵问题。
    private func commit(_ r: UmbraReminder) {
        var v = r
        v.updatedAtMs = Date.umbraNowMs
        v.dirty = true
        if let i = items.firstIndex(where: { $0.id == v.id }) { items[i] = v } else { items.append(v) }
        items.sort { $0.at < $1.at }
        ReminderCache.save(items)
        if v.done { cancel(id: v.id) } else { schedule(v) }
        refreshBadge()
        UmbraWidgetBridge.syncReminders(items)
        Task { await self.pushPending() }
    }

    func item(_ id: String) -> UmbraReminder? { items.first { $0.id == id } }

    func save(_ r: UmbraReminder) {
        commit(r)
    }

    func delete(id: String) {
        items.removeAll { $0.id == id }
        ReminderCache.save(items)
        // 删除也要留墓碑并推上去：只删本地的话，下次拉取又会把它同步回来。
        ReminderCache.addTomb(id: id, at: Date.umbraNowMs)
        cancel(id: id)
        refreshBadge()
        UmbraWidgetBridge.syncReminders(items)
        Task { await self.pushPending() }
    }

    func toggleDone(id: String) {
        guard var r = item(id) else { return }
        r.done.toggle()
        commit(r)
    }

    /// 「再等 10 分钟」。从**现在**往后推 10 分钟，不是从原时间推 ——
    /// 原时间可能已经过去两小时了，那样推完还是过期的。
    func snooze(id: String, minutes: Int = 10) {
        guard var r = item(id) else { return }
        r.at = Date().addingTimeInterval(TimeInterval(minutes * 60))
        r.done = false
        commit(r)
    }

    /// 「稍后提醒」到指定时刻（长按菜单里的「明早 9 点」这类），其余语义同上。
    func snooze(id: String, until date: Date) {
        guard var r = item(id) else { return }
        r.at = date
        r.done = false
        commit(r)
    }

    // MARK: 本地通知

    /// 未完成且已过期/今天到点的条数 —— 与底栏角标、中号小组件同一口径。
    var pendingCount: Int {
        items.filter { !$0.done && ($0.group == "已过期" || $0.group == "今天") }.count
    }

    /// 刷 App 图标角标。
    ///
    /// 一期申请了 `.badge` 权限却从没设过角标，图标上永远是干净的。
    /// 这里在每次数据变化时设一次真实值。
    /// **已知局限**：App 被系统回收后到点响的那条通知不会顺手把角标加一
    /// （那要么给每条通知硬编一个数字、要么上 APNs，前者会在用户中途完成几条后变成错的）。
    /// 下次打开 App 会立刻校正。
    func refreshBadge() {
        let n = pendingCount
        UNUserNotificationCenter.current().setBadgeCount(n) { _ in }
    }

    /// 把当前所有提醒重排一遍本地通知。
    /// 见 init 里的注释：预排式规则用完 maxPrescheduled 次就不响了，靠这个续上。
    func rescheduleAll() {
        for r in items { schedule(r) }
    }

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

    /// 一条提醒最多占用的通知位。系统给每个 App 的待发通知上限是 64 个，
    /// 预排占位的规则（工作日 / 自定义间隔 / 带结束日期）不能放开了排。
    private let maxPrescheduled = 12

    private func cancel(id: String) {
        // 预排的占位是 id.0 / id.1 / …，一并清。
        var ids = [id, id + ".ahead"]
        for k in 0..<maxPrescheduled { ids.append("\(id).\(k)"); ids.append("\(id).ahead.\(k)") }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func schedule(_ r: UmbraReminder) {
        cancel(id: r.id)
        guard !r.done else { return }

        let content = UNMutableNotificationContent()
        content.title = "提醒"
        content.body = r.text
        if !r.note.isEmpty { content.subtitle = r.note }
        content.sound = .default
        content.categoryIdentifier = UmbraNotificationDelegate.reminderCategory
        content.userInfo = ["reminderId": r.id]

        scheduleSeries(baseId: r.id, content: content, r: r, shiftMinutes: 0)

        // 提前提醒是**另一条**通知，不是把主通知提前 —— 两条都要响。
        // 它的 userInfo 指向主提醒的 id，在提前通知上点「完成」也是完成那条提醒。
        if r.aheadMinutes > 0 {
            let ahead = UNMutableNotificationContent()
            ahead.title = "快到了"
            ahead.body = "提前 \(r.aheadLabel)：\(r.text)"
            ahead.sound = .default
            ahead.categoryIdentifier = UmbraNotificationDelegate.reminderCategory
            ahead.userInfo = ["reminderId": r.id]
            scheduleSeries(baseId: r.id + ".ahead", content: ahead, r: r, shiftMinutes: -r.aheadMinutes)
        }
    }

    /// 按规则排通知。能用系统重复触发器就用（每天/每周/每月且永不结束），
    /// 其余（工作日、自定义间隔、带结束日期）系统表达不了 —— 预排接下来的
    /// maxPrescheduled 次。代价是很远的将来不响，但 12 次对「每天」也够一轮半月，
    /// 而且**每次冷启动和每次同步到新数据都会整体重排**（rescheduleAll），实际用不掉这个上限。
    /// ⚠️ 这句话一期是假的（谁都没调 schedule），排满 12 次后就静默不响了；靠 rescheduleAll 补上。
    private func scheduleSeries(baseId: String, content: UNMutableNotificationContent,
                                r: UmbraReminder, shiftMinutes: Int) {
        let cal = Calendar.current
        let fire = r.at.addingTimeInterval(TimeInterval(shiftMinutes * 60))

        switch r.repeatRule {
        case "不重复":
            guard fire > Date() else { return }   // 过去的时间不排，系统会立刻弹一条像 bug
            add(id: baseId, content: content,
                comps: cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire), repeats: false)
        case "每天" where r.repeatEnd == nil:
            add(id: baseId, content: content,
                comps: cal.dateComponents([.hour, .minute], from: fire), repeats: true)
        case "每周" where r.repeatEnd == nil:
            add(id: baseId, content: content,
                comps: cal.dateComponents([.weekday, .hour, .minute], from: fire), repeats: true)
        case "每月" where r.repeatEnd == nil:
            add(id: baseId, content: content,
                comps: cal.dateComponents([.day, .hour, .minute], from: fire), repeats: true)
        default:
            for (k, date) in occurrences(of: r).prefix(maxPrescheduled).enumerated() {
                let f = date.addingTimeInterval(TimeInterval(shiftMinutes * 60))
                guard f > Date() else { continue }
                add(id: "\(baseId).\(k)", content: content,
                    comps: cal.dateComponents([.year, .month, .day, .hour, .minute], from: f), repeats: false)
            }
        }
    }

    /// 未来的触发时刻序列（含结束日期截断）。
    private func occurrences(of r: UmbraReminder) -> [Date] {
        let cal = Calendar.current
        var out: [Date] = []
        var d = r.at
        // 从未来的第一次开始
        while d <= Date(), let next = step(from: d, r: r, cal: cal) { d = next }
        var guardCount = 0
        while out.count < maxPrescheduled, guardCount < 400 {
            guardCount += 1
            if let end = r.repeatEnd, d > cal.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end { break }
            if d > Date() { out.append(d) }
            guard let next = step(from: d, r: r, cal: cal) else { break }
            d = next
        }
        return out
    }

    private func step(from d: Date, r: UmbraReminder, cal: Calendar) -> Date? {
        switch r.repeatRule {
        case "每天": return cal.date(byAdding: .day, value: 1, to: d)
        case "每周": return cal.date(byAdding: .weekOfYear, value: 1, to: d)
        case "每月": return cal.date(byAdding: .month, value: 1, to: d)
        case "工作日":
            var next = cal.date(byAdding: .day, value: 1, to: d)
            while let n = next, cal.isDateInWeekend(n) { next = cal.date(byAdding: .day, value: 1, to: n) }
            return next
        case "自定义":
            let n = max(1, r.customN)
            switch r.customFreq {
            case "小时": return cal.date(byAdding: .hour, value: n, to: d)
            case "周": return cal.date(byAdding: .weekOfYear, value: n, to: d)
            case "月": return cal.date(byAdding: .month, value: n, to: d)
            case "年": return cal.date(byAdding: .year, value: n, to: d)
            default: return cal.date(byAdding: .day, value: n, to: d)
            }
        default: return nil
        }
    }

    private func add(id: String, content: UNMutableNotificationContent,
                     comps: DateComponents, repeats: Bool) {
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
    /// 勾选动画中的那条：圈已变绿、行还没收走。
    @State private var leavingId: String?

    private static let todoOrder = ["已过期", "今天", "明天", "本周", "更远"]

    var body: some View {
        List {
            // 分段控件放列表首行：跟着内容一起滚，系统大标题的收纳行为不受影响。
            Section {
                UmbraSegmentedControl(items: [
                    .init(value: Seg.todo, label: "待办", count: store.items.filter { !$0.done }.count),
                    .init(value: Seg.done, label: "已完成", count: store.items.filter(\.done).count)
                ], selection: $seg)
                // 与下面的记录卡同宽：insetGrouped 的行已有统一左右缩进，
                // 这里再加 16 就比卡片窄一截（用户点名）。
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: UmbraMetric.sp3, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if store.notifyAuthorized == false && !store.items.isEmpty {
                    permissionBanner
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: UmbraMetric.sp3, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if groups.isEmpty {
                Section {
                    UmbraEmptyState(
                        iconPath: UmbraIconPath.bell,
                        title: seg == .todo ? "还没有提醒" : "还没有完成过的提醒",
                        hint: seg == .todo
                            ? "点右上角加一条。到点会用系统通知叫你，这一版提醒存在这台手机上，还没有跟服务端同步。"
                            : "完成过的提醒会收在这里。",
                        actionTitle: seg == .todo ? "加一条提醒" : nil,
                        action: addAction)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } else {
                ForEach(groups, id: \.0) { name, items in
                    Section {
                        ForEach(items) { r in row(r) }
                    } header: {
                        Text(name)
                            .font(UmbraFont.sans(12, .w600))
                            .tracking(UmbraFont.labelTracking(12))
                            .foregroundColor(name == "已过期" ? UmbraColor.danger : UmbraColor.faint)
                            .textCase(nil)
                    }
                }

            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UmbraColor.bg)
        .navigationTitle("提醒")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.go(.remEdit(id: nil)) } label: {
                    Image(systemName: "plus")
                }
                .tint(UmbraColor.orange)
            }
        }
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .refreshable { await store.reloadAsync() }
        .onAppear { store.refreshAuthorization() }
    }

    private var permissionBanner: some View {
        // 有提醒但没通知权限 = 到点不会响。这必须说出来，否则用户以为设了就万事大吉。
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
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusInput, style: .continuous).fill(UmbraColor.warningSoft))
    }

    /// 空态的主动作。写成显式可选闭包 —— `cond ? {...} : nil` 的闭包字面量推不出类型。
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

    // MARK: 行

    private func row(_ r: UmbraReminder) -> some View {
        let leaving = leavingId == r.id
        return Button {
            router.go(.remDetail(id: r.id))
        } label: {
            HStack(alignment: .top, spacing: UmbraMetric.sp4) {
                // 勾选圈是独立的点击区（点圈=完成，点行=进详情）。
                Button { toggleAnimated(r) } label: {
                    ZStack {
                        Circle().fill((r.done || leaving) ? UmbraColor.success : Color.clear)
                        Circle().strokeBorder((r.done || leaving) ? UmbraColor.success : UmbraColor.border,
                                              lineWidth: 1.8)
                        if r.done || leaving {
                            UmbraIcon(d: UmbraIconPath.check, size: 13, strokeWidth: 3.4)
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 24, height: 24)
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
                        .lineLimit(2)      // 最多 2 行省略，点行进详情看全文
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 7) {
                        Text(r.timeLabel)
                            .font(UmbraFont.sans(13, .w400))
                            .foregroundColor(r.overdue ? UmbraColor.danger : UmbraColor.muted)
                        if r.overdue {
                            Text("已过期")
                                .font(UmbraFont.sans(11, .w600))
                                .foregroundColor(UmbraColor.danger)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(UmbraColor.dangerSoft))
                        }
                        if r.repeatRule != "不重复" {
                            HStack(spacing: 4) {
                                UmbraIcon(d: UmbraIconPath.repeatArrows, size: 10, strokeWidth: 2.4)
                                Text(r.repeatLabel).font(UmbraFont.sans(11, .w600))
                            }
                            .foregroundColor(UmbraColor.muted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(UmbraColor.chip))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(UmbraColor.card)
        // 收合动画：整行淡出 + 轻微缩小。行真正移除交给数据变化 + List 的默认动画。
        .opacity(leaving ? 0.999 : 1)   // 占位，避免编译器把闭包判为常量视图
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 系统左滑。destructive 不直接删 —— 规范：必进确认弹窗。
            // 所以这里用普通 Button 手动弹 alert，不用 role: .destructive
            //（带 role 的按钮系统会先把行划走，取消确认后行回不来）。
            Button {
                router.confirm(UmbraAlert(
                    title: "删除「\(r.text)」？",
                    body: "删除后无法恢复。",
                    confirmLabel: "删除",
                    confirmDestructive: true,
                    onConfirm: {
                        withAnimation { store.delete(id: r.id) }
                        router.showToast("已删除")
                    }))
            } label: {
                Label("删除", systemImage: "trash")
            }
            .tint(UmbraColor.danger)

            Button {
                withAnimation { store.snooze(id: r.id) }
                router.showToast("好，10 分钟后再叫你")
            } label: {
                Label("再等 10 分钟", systemImage: "clock")
            }
            .tint(UmbraColor.warning)
        }
    }

    /// 勾选动画：圈立即变绿画勾 → 停一拍（0.9s）→ 数据真正翻转，行随分组变化收走。
    /// 完成给带「撤销」的 toast —— 手滑点完的成本要能一步撤回。
    private func toggleAnimated(_ r: UmbraReminder) {
        if r.done || leavingId != nil {
            store.toggleDone(id: r.id)
            router.showToast(r.done ? "已标回待办" : "「\(r.text)」已完成")
            return
        }
        leavingId = r.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard leavingId == r.id else { return }
            leavingId = nil
            withAnimation { store.toggleDone(id: r.id) }
            router.showToast("「\(r.text)」已完成", undo: {
                store.toggleDone(id: r.id)
            })
        }
    }
}

// MARK: - 详情（就地编辑）

struct UmbraReminderDetailView: View {
    let id: String

    @EnvironmentObject private var router: UmbraRouter
    @ObservedObject private var store = ReminderStore.shared

    /// 编辑草稿。nil = 预览态。**就地编辑**：同一页切换，不推新页。
    @State private var draft: UmbraReminder?
    @State private var pickDate = false
    @State private var pickTime = false
    @State private var pickEndDate = false

    private var item: UmbraReminder? { store.item(id) }
    private var editing: Bool { draft != nil }

    var body: some View {
        UmbraScreen(content: {
            if let d = draft {
                UmbraReminderForm(draft: Binding(get: { d }, set: { draft = $0 }),
                                  pickDate: $pickDate, pickTime: $pickTime, pickEndDate: $pickEndDate)
            } else if let r = item {
                preview(r)
            } else {
                UmbraEmptyState(iconPath: UmbraIconPath.bell, title: "这条提醒不在了",
                                hint: "可能是刚才删掉了。", actionTitle: "回到提醒列表",
                                action: { router.back() })
            }
        }, bottom: {
            if !editing, let r = item { bottomBar(r) }
        })
        .navigationTitle(editing ? "编辑提醒" : "提醒详情")
        .navigationBarTitleDisplayMode(.inline)
        // 编辑态藏系统返回（会丢改动的出口只留「取消」一个，语义清楚）。
        .navigationBarBackButtonHidden(editing)
        .toolbar {
            if editing {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { draft = nil }
                        .tint(UmbraColor.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { saveEdit() } label: {
                        Text("保存").font(UmbraFont.sans(16, .w600))
                    }
                    .tint(UmbraColor.orange)
                }
            } else if let r = item {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("编辑") { draft = r }
                        .tint(UmbraColor.orange)
                }
            }
        }
        .umbraWheelPicker(isPresented: $pickDate, title: "选择日期", mode: .date,
                          date: Binding(get: { draft?.at ?? Date() }, set: { draft?.at = $0 }))
        .umbraWheelPicker(isPresented: $pickTime, title: "选择时间", mode: .time,
                          date: Binding(get: { draft?.at ?? Date() }, set: { draft?.at = $0 }))
        .umbraWheelPicker(isPresented: $pickEndDate, title: "结束日期", mode: .date,
                          date: Binding(get: { draft?.repeatEnd ?? Date().addingTimeInterval(30 * 86400) },
                                        set: { draft?.repeatEnd = $0 }))
    }

    // 查看态信息层级（v2 重设计）：标题是主角，备注紧跟其下当补充；
    // 时间放大突出；字段卡只留「重复 / 提前提醒」；来源与创建时间降为页底脚注。
    @ViewBuilder
    private func preview(_ r: UmbraReminder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(r.text)
                .font(UmbraFont.sans(26, .w650))
                .tracking(-0.26)                      // -.01em
                .foregroundColor(UmbraColor.text)
                .lineSpacing(26 * 0.3)                // 行高 ≈1.3
            // 备注是标题的补充说明，不再和「重复」这类设置字段同级；没写就整块不出现。
            if !r.note.isEmpty {
                Text(r.note)
                    .font(UmbraFont.sans(15, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(15 * 0.6)
                    .padding(.top, 8)
            }
            HStack(spacing: 8) {
                UmbraIcon(d: UmbraIconPath.bell, size: 18, strokeWidth: 2)
                Text(r.timeLabel)
                    .font(UmbraFont.sans(19, .w600))
                if r.overdue {
                    Text("已过期")
                        .font(UmbraFont.sans(11, .w600))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(UmbraColor.dangerSoft))
                }
            }
            // 过期时铃铛、时间、胶囊一起转警示色 —— 状态不只靠一个小胶囊表达。
            .foregroundColor(r.overdue ? UmbraColor.danger : UmbraColor.text)
            .padding(.top, 14)
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.top, UmbraMetric.sp6)
        .padding(.bottom, 16)

        UmbraSettingSectionView(section: UmbraSettingSection(rows: [
            UmbraSettingRow(label: "重复", value: r.repeatLabel),
            UmbraSettingRow(label: "提前提醒", value: r.aheadLabel)
        ]))

        // 来源与创建时间是「偶尔想确认一下」的信息，从字段卡降为一行脚注。
        Text("来自\(r.source) · 创建于 \(r.createdLabel)")
            .font(UmbraFont.sans(12, .w400))
            .foregroundColor(UmbraColor.faint)
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.top, 12)
    }

    // MARK: 底部操作（吸底玻璃栏，垂直排列）
    //
    // 「完成」升级成滑动完成（主操作，橙）；「再等 10 分钟」升级成「稍后提醒」
    //（次要操作，点=默认 10 分钟，长按换时间）。一屏一个橙实底的规矩不变。
    private func bottomBar(_ r: UmbraReminder) -> some View {
        VStack(spacing: 10) {
            if r.done {
                // 已完成的提醒没有「再完成一次」：给一个把它标回待办的出口就够了。
                UmbraButton(title: "标回待办", kind: .secondary) {
                    store.toggleDone(id: r.id)
                    router.showToast("已标回待办")
                    router.back()
                }
            } else {
                UmbraSlideToComplete {
                    // 时序：滑块吸附+对勾（组件内停 420ms）→ 才落数据、toast、返回。
                    store.toggleDone(id: r.id)
                    router.showToast("已完成「\(r.text)」")
                    router.back()
                }
                snoozeButton(r)
                Text("长按「稍后提醒」可以换时间")
                    .font(UmbraFont.sans(11, .w400))
                    .foregroundColor(UmbraColor.faint)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.top, 10)
        .padding(.bottom, UmbraMetric.sp5)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
        }
    }

    /// 稍后提醒：点一下 = 默认延后 10 分钟；长按 = 系统锚定小弹框换时间。
    /// 用系统 Menu(primaryAction:) 而不是自己叠 LongPressGesture ——
    /// 「长按弹框后抬手不能再触发默认动作」这类互斥，系统帮你处理好了
    ///（原型里要自己用 fired 标志吞 click，Menu 天然没这个问题）。
    private func snoozeButton(_ r: UmbraReminder) -> some View {
        Menu {
            Button("10 分钟后") { doSnooze(r, minutes: 10, say: "10 分钟后") }
            Button("30 分钟后") { doSnooze(r, minutes: 30, say: "30 分钟后") }
            Button("1 小时后") { doSnooze(r, minutes: 60, say: "1 小时后") }
            Button("明早 9 点") { snoozeTomorrowNine(r) }
        } label: {
            Text("稍后提醒 · 10 分钟后")
                .font(UmbraFont.sans(15.5, .w560))
                .foregroundColor(UmbraColor.text)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Capsule().fill(UmbraColor.card))
                .overlay(Capsule().strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW))
                .contentShape(Capsule())
        } primaryAction: {
            doSnooze(r, minutes: 10, say: "10 分钟后")
        }
    }

    private func doSnooze(_ r: UmbraReminder, minutes: Int, say: String) {
        store.snooze(id: r.id, minutes: minutes)
        router.showToast("好，\(say)再叫你")
        router.back()
    }

    /// 明早 9 点。跨天用日历算，不拿 86400 秒硬加 —— 夏令时切换那天会差一小时。
    private func snoozeTomorrowNine(_ r: UmbraReminder) {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))
            ?? Date().addingTimeInterval(86400)
        let nine = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
            ?? tomorrow.addingTimeInterval(9 * 3600)
        store.snooze(id: r.id, until: nine)
        router.showToast("好，明早 9 点再叫你")
        router.back()
    }

    private func saveEdit() {
        guard var d = draft else { return }
        d.text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.text.isEmpty else { router.showToast("提醒内容不能是空的"); return }
        d.note = d.note.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save(d)
        draft = nil
        router.showToast("已保存")
    }
}

// MARK: - 新建

struct UmbraReminderEditView: View {
    /// 现在只用于新建（编辑走详情页的就地编辑）。带 id 进来也能编，路由兼容。
    let id: String?

    @EnvironmentObject private var router: UmbraRouter
    @ObservedObject private var store = ReminderStore.shared

    @State private var draft = UmbraReminder(id: UUID().uuidString, text: "",
                                             at: Date().addingTimeInterval(3600))
    @State private var pickDate = false
    @State private var pickTime = false
    @State private var pickEndDate = false
    @State private var loaded = false

    private var canSave: Bool { !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        UmbraScreen {
            UmbraReminderForm(draft: $draft, pickDate: $pickDate,
                              pickTime: $pickTime, pickEndDate: $pickEndDate)

        }
        .navigationTitle(id == nil ? "新建提醒" : "编辑提醒")
        .navigationBarTitleDisplayMode(.inline)
        // 编辑表单的左上角是「取消」不是返回 —— 放弃这次编辑，不是回上一页。
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { router.back() }
                    .tint(UmbraColor.text)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { save() } label: {
                    Text("保存").font(UmbraFont.sans(16, .w600))
                }
                .tint(canSave ? UmbraColor.orange : UmbraColor.faint)
            }
        }
        .umbraWheelPicker(isPresented: $pickDate, title: "选择日期", mode: .date, date: $draft.at)
        .umbraWheelPicker(isPresented: $pickTime, title: "选择时间", mode: .time, date: $draft.at)
        .umbraWheelPicker(isPresented: $pickEndDate, title: "结束日期", mode: .date,
                          date: Binding(get: { draft.repeatEnd ?? Date().addingTimeInterval(30 * 86400) },
                                        set: { draft.repeatEnd = $0 }))
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let rid = id, let r = store.item(rid) { draft = r }
        }
    }

    private func save() {
        // 没写内容点保存 → 用一次性的 toast 说原因，不在页面上常驻一行小字（用户点名删）。
        guard canSave else { router.showToast("提醒内容还是空的，写一句才能存"); return }
        var d = draft
        d.text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        d.note = d.note.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save(d)
        // 第一次建提醒时才要权限 —— 这时候用户正想让它响，是最容易被同意的时机。
        store.requestAuthorizationIfNeeded()
        router.back()
        router.showToast("已保存")
    }
}

// MARK: - 表单（详情就地编辑与新建共用）
//
// 重复规则的子项（频率 / 间隔 / 结束日期）：同卡白底、左缩进 32、行高 38、
// 标签 15 灰 —— 不换底色，靠缩进表达从属。选项字段用系统 Menu（锚定小弹框）。
struct UmbraReminderForm: View {
    @Binding var draft: UmbraReminder
    @Binding var pickDate: Bool
    @Binding var pickTime: Bool
    @Binding var pickEndDate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp6) {
            field("提醒内容") {
                TextField("要提醒你做什么", text: $draft.text, axis: .vertical)
                    .font(UmbraFont.sans(16, .w400))
                    .lineSpacing(16 * 0.55)
                    .lineLimit(3...6)      // 多行要有上限，超过内滚（交接清单）
                    .textFieldStyle(.plain)
                    .padding(12)
                    .frame(minHeight: 88, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusInput, style: .continuous).fill(UmbraColor.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: UmbraMetric.radiusInput, style: .continuous)
                            .strokeBorder(UmbraColor.borderSoft, lineWidth: UmbraMetric.borderW)
                    )
            }

            // 备注紧跟内容：它是内容的补充说明，层级要贴着内容走，
            // 不该压在页面最底下和「重复」这类设置字段抢位置（v2 详情重设计同步改；
            // 详情页就地编辑和新建页共用这个表单，两处一起生效）。
            field("备注（可选）") {
                TextField("要不要带什么、找谁", text: $draft.note, axis: .vertical)
                    .font(UmbraFont.sans(15.5, .w400))
                    .lineSpacing(15.5 * 0.55)
                    .lineLimit(2...5)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .frame(minHeight: 64, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusInput, style: .continuous).fill(UmbraColor.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: UmbraMetric.radiusInput, style: .continuous)
                            .strokeBorder(UmbraColor.borderSoft, lineWidth: UmbraMetric.borderW)
                    )
            }

            // 日期 / 时间：点击**整个字段区域**弹滚轮面板，不是点图标。
            field("时间") {
                VStack(spacing: 0) {
                    pickerRow(label: "日期", value: UmbraWheelPanel.dayLabel(offset: dayOffset)) { pickDate = true }
                    divider(inset: 14)
                    pickerRow(label: "时间", value: timeText) { pickTime = true }
                }
                .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
                .overlay(
                    RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                        .strokeBorder(UmbraColor.borderSoft, lineWidth: UmbraMetric.borderW)
                )
            }

            field("重复与提前") {
                VStack(spacing: 0) {
                    menuRow(label: "重复", value: draft.repeatLabel,
                            options: UmbraReminder.repeatOptions,
                            current: draft.repeatRule) { draft.repeatRule = $0 }

                    if draft.repeatRule == "自定义" {
                        divider(inset: 32)
                        menuRow(label: "频率", value: draft.customFreq, sub: true,
                                options: UmbraReminder.customFreqOptions,
                                current: draft.customFreq) { draft.customFreq = $0 }
                        divider(inset: 32)
                        numberRow(label: "间隔（每）", suffix: draft.customFreq)
                    }
                    if draft.repeatRule != "不重复" {
                        divider(inset: 32)
                        menuRow(label: "结束重复", value: draft.repeatEnd == nil ? "永不" : "指定日期", sub: true,
                                options: ["永不", "指定日期"],
                                current: draft.repeatEnd == nil ? "永不" : "指定日期") { v in
                            if v == "永不" { draft.repeatEnd = nil }
                            else if draft.repeatEnd == nil { draft.repeatEnd = Date().addingTimeInterval(30 * 86400) }
                        }
                        if draft.repeatEnd != nil {
                            divider(inset: 32)
                            pickerRow(label: "结束日期", value: endDateText, sub: true) { pickEndDate = true }
                        }
                    }

                    divider(inset: 14)
                    menuRow(label: "提前提醒", value: draft.aheadLabel,
                            options: UmbraReminder.aheadOptions.map(\.0),
                            current: draft.aheadLabel) { v in
                        draft.aheadMinutes = UmbraReminder.aheadOptions.first { $0.0 == v }?.1 ?? 0
                    }
                }
                .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
                .overlay(
                    RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                        .strokeBorder(UmbraColor.borderSoft, lineWidth: UmbraMetric.borderW)
                )
            }

        }
        .padding(UmbraMetric.pagePadX)
    }

    // MARK: 行构件

    @ViewBuilder
    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
            UmbraFieldLabel(text: label)
            content()
        }
    }

    private func divider(inset: CGFloat) -> some View {
        Rectangle().fill(UmbraColor.borderSoft)
            .frame(height: UmbraMetric.borderW)
            .padding(.leading, inset)
    }

    /// 点击弹滚轮的行。
    ///
    /// **先收键盘再弹面板**：不收的话，滚轮面板关掉时系统会把焦点还给刚才那个输入框，
    /// 键盘又自己蹦出来 —— 表现就是「选完日期还得再关一次键盘」（用户点名）。
    private func pickerRow(label: String, value: String, sub: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button {
            UmbraKeyboard.dismiss()
            action()
        } label: {
            HStack {
                Text(label)
                    .font(UmbraFont.sans(sub ? 15 : 16, .w400))
                    .foregroundColor(sub ? UmbraColor.muted : UmbraColor.text)
                Spacer(minLength: 0)
                Text(value)
                    .font(UmbraFont.sans(15, .w400))
                    .foregroundColor(UmbraColor.muted)
                UmbraIcon(d: UmbraIconPath.chevronRight, size: 14, strokeWidth: 2.2)
                    .foregroundColor(UmbraColor.faint)
            }
            .padding(.leading, sub ? 32 : 14)
            .padding(.trailing, 14)
            .frame(minHeight: sub ? 38 : 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 选项行：系统 Menu 锚定展开（≤6 项纯选择不该用全宽底部弹层 —— 交接清单第 4 条）。
    private func menuRow(label: String, value: String, sub: Bool = false,
                         options: [String], current: String,
                         choose: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.self) { o in
                Button {
                    choose(o)
                } label: {
                    if o == current { Label(o, systemImage: "checkmark") } else { Text(o) }
                }
            }
        } label: {
            HStack {
                Text(label)
                    .font(UmbraFont.sans(sub ? 15 : 16, .w400))
                    .foregroundColor(sub ? UmbraColor.muted : UmbraColor.text)
                Spacer(minLength: 0)
                Text(value)
                    .font(UmbraFont.sans(15, .w400))
                    .foregroundColor(UmbraColor.muted)
                UmbraIcon(d: UmbraIconPath.chevronDown, size: 14, strokeWidth: 2.2)
                    .foregroundColor(UmbraColor.faint)
            }
            .padding(.leading, sub ? 32 : 14)
            .padding(.trailing, 14)
            .frame(minHeight: sub ? 38 : 48)
            .contentShape(Rectangle())
        }
    }

    /// 「间隔（每）」：只许数字，空/0 落回 1（交接清单第 36 条）。
    private func numberRow(label: String, suffix: String) -> some View {
        HStack {
            Text(label)
                .font(UmbraFont.sans(15, .w400))
                .foregroundColor(UmbraColor.muted)
            Spacer(minLength: 0)
            TextField("1", text: Binding(
                get: { String(draft.customN) },
                set: { s in
                    let digits = s.filter(\.isNumber)
                    draft.customN = max(1, Int(digits) ?? 1)
                }
            ))
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .font(UmbraFont.mono(15))
            .frame(width: 56)
            Text(suffix)
                .font(UmbraFont.sans(15, .w400))
                .foregroundColor(UmbraColor.muted)
        }
        .padding(.leading, 32)
        .padding(.trailing, 14)
        .frame(minHeight: 38)
    }

    // MARK: 展示值

    private var dayOffset: Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                  to: cal.startOfDay(for: draft.at)).day ?? 0
    }
    private var timeText: String {
        let df = DateFormatter(); df.dateFormat = "HH:mm"
        return df.string(from: draft.at)
    }
    private var endDateText: String {
        guard let e = draft.repeatEnd else { return "—" }
        let cal = Calendar.current
        let off = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                     to: cal.startOfDay(for: e)).day ?? 0
        return UmbraWheelPanel.dayLabel(offset: off)
    }
}

// MARK: - 滑动完成
//
// 「完成」是把一件事画上句号的动作，值得一个有分量的确认 —— 滑到头才算，
// 比一个一点就没的按钮更难误触，也更有仪式感（v2 提醒详情重设计）。
// 交互取值照设计稿：轨道 54 胶囊（orange-soft 底 + orange 描边）、滑块 46 橙圆（左起 4）、
// 拖过 82% 吸附成对勾、停 420ms 再回调；不到就 .28s cubic-bezier(.2,.8,.3,1) 回弹；
// 中央「滑动完成」提示随进度 1-(x/90) 淡出，带 2.4s 循环的扫光 + 双箭头同步右移 5pt。
struct UmbraSlideToComplete: View {
    /// 吸附 + 对勾亮出 420ms 之后才调用 —— 先给视觉反馈，再做数据操作和返回。
    var onComplete: () -> Void

    /// 滑块当前位移（0 … 可滑行程）。拖动中直接赋值不加动画，回弹/吸附才加。
    @State private var x: CGFloat = 0
    /// 已吸附。之后手势失效、提示隐藏、图标换对勾 —— 不给「完成一半再拖回来」的余地。
    @State private var done = false
    @State private var shimmer = false
    @State private var pulse = false

    private let knob: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            // 可滑行程用布局宽度算（宽 - 滑块 46 - 两端各 4）。
            let travel = max(1, geo.size.width - knob - 8)
            ZStack(alignment: .leading) {
                hint
                    .frame(maxWidth: .infinity)
                    // 先在 CGFloat 里把 1-(x/90) 算完再转 Double：三元一边是 Double 字面量
                    // 一边是 CGFloat 表达式时，编译器会在「-」上犹豫（实机报过歧义）。
                    .opacity(done ? 0 : Double(max(0, 1 - x / 90)))

                Circle()
                    .fill(UmbraColor.orange)
                    .frame(width: knob, height: knob)
                    .overlay(
                        UmbraIcon(d: done ? UmbraIconPath.check : UmbraIconPath.arrowRight,
                                  size: 20, strokeWidth: 2.4)
                            .foregroundColor(.white)
                    )
                    .shadow(color: UmbraColor.orange.opacity(0.38), radius: 8, x: 0, y: 3)
                    .offset(x: 4 + x)
                    .gesture(
                        DragGesture()
                            .onChanged { g in
                                guard !done else { return }
                                x = min(max(0, g.translation.width), travel)
                            }
                            .onEnded { _ in
                                guard !done else { return }
                                if x >= travel * 0.82 {
                                    // 吸附到最右、换对勾，停一拍再回调 —— 不瞬间跳走。
                                    withAnimation(UmbraMotion.slider) { x = travel; done = true }
                                    Task { @MainActor in
                                        try? await Task.sleep(nanoseconds: 420_000_000)
                                        onComplete()
                                    }
                                } else {
                                    withAnimation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.28)) { x = 0 }
                                }
                            }
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 54)
        .background(Capsule().fill(UmbraColor.orangeSoft))
        .overlay(Capsule().strokeBorder(UmbraColor.orange, lineWidth: UmbraMetric.borderW))
        .onAppear {
            // 扫光 2.4s 直线循环；双箭头 1.2s 往返（= 同一个 2.4s 周期），两个引导同拍。
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { shimmer = true }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    /// 中央提示：「滑动完成」扫光文字 + 双箭头。
    private var hint: some View {
        HStack(spacing: 5) {
            shimmerLabel
            HStack(spacing: -5) {
                UmbraIcon(d: UmbraIconPath.chevronRight, size: 13, strokeWidth: 2.4)
                UmbraIcon(d: UmbraIconPath.chevronRight, size: 13, strokeWidth: 2.4)
            }
            .foregroundColor(UmbraColor.orangeText.opacity(0.65))
            .offset(x: pulse ? 5 : 0)
        }
    }

    /// 扫光：一条 46pt 宽的白色渐变从文字左边扫到右边，用文字本身当遮罩 ——
    /// 渐变在 ZStack 里动、遮罩不动，所以光是「掠过」文字而不是跟着文字跑。
    private var shimmerLabel: some View {
        Text("滑动完成")
            .font(UmbraFont.sans(15.5, .w600))
            .foregroundColor(UmbraColor.orangeText)
            .overlay(
                ZStack {
                    LinearGradient(
                        gradient: Gradient(colors: [Color.white.opacity(0),
                                                    Color.white.opacity(0.75),
                                                    Color.white.opacity(0)]),
                        startPoint: .leading, endPoint: .trailing)
                        .frame(width: 46)
                        .offset(x: shimmer ? 72 : -72)
                }
                .mask(Text("滑动完成").font(UmbraFont.sans(15.5, .w600)))
            )
    }
}
