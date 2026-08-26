// 主 App 与 Widget 扩展的**共享层**：App Group 常量、快照模型、Live Activity 属性。
//
// ⚠️ Target Membership：这个文件要同时勾 UmbraiOS（主 App）和 UmbraWidgets（扩展）——
// 扩展是独立进程，只共享代码不共享内存，双方靠 App Group 的 UserDefaults 传快照。
// 建 target 的完整步骤见 doc/Widget与AutoFill-接入步骤.md。
//
// 「三处同源同 tick」（规范增补 4.3）：灵动岛 / 锁屏实况 / 小组件显示的任务数据
// 全部出自这里的同一份快照与同一个 ActivityAttributes —— 不允许各算各的。
import Foundation
import ActivityKit

// MARK: - App Group

enum UmbraShared {
    /// App Group 标识。**必须**和 Xcode 里两个 target 勾选的 App Group 一致；
    /// 改这里一处即可（用 bundle id xyz.tingyusha.umbra.ios 派生）。
    static let appGroup = "group.xyz.tingyusha.umbra.ios"

    /// 两个小组件的 kind（刷新时按 kind 指名重载，不全量刷）。
    static let taskWidgetKind = "UmbraTaskWidget"
    static let reminderWidgetKind = "UmbraReminderWidget"

    private static let taskKey = "umbra.widget.task"
    private static let reminderKey = "umbra.widget.reminders"

    /// App Group 还没在 Xcode 里配好时返回 nil —— 所有读写都静默跳过，不崩、不写错地方。
    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// App Group **真的生效了吗**。UserDefaults(suiteName:) 在没配 entitlement 时
    /// 也会给一个能用的实例（只是落在自己沙盒里，扩展看不见）—— 用它判断会误判成正常。
    /// containerURL 才是实话：拿不到共享容器 = entitlement 没配对上。
    static var appGroupReady: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
    }

    // MARK: 快照读写（主 App 写，扩展读）

    static func save(_ snap: UmbraTaskSnapshot) {
        guard let d = defaults, let data = try? JSONEncoder().encode(snap) else { return }
        d.set(data, forKey: taskKey)
    }
    static func loadTaskSnapshot() -> UmbraTaskSnapshot? {
        guard let data = defaults?.data(forKey: taskKey) else { return nil }
        return try? JSONDecoder().decode(UmbraTaskSnapshot.self, from: data)
    }

    static func save(_ snap: UmbraReminderSnapshot) {
        guard let d = defaults, let data = try? JSONEncoder().encode(snap) else { return }
        d.set(data, forKey: reminderKey)
    }
    static func loadReminderSnapshot() -> UmbraReminderSnapshot? {
        guard let data = defaults?.data(forKey: reminderKey) else { return nil }
        return try? JSONDecoder().decode(UmbraReminderSnapshot.self, from: data)
    }
}

// MARK: - 快照模型

/// 任务快照：给小号小组件。执行中任务 + 今天完成数，都是服务端列表算出来的真实值。
struct UmbraTaskSnapshot: Codable {
    /// 执行中任务（没有则为 nil —— 小组件转而显示今天完成数，不画假任务）。
    var runningId: String?
    /// 执行中任务的**短标题**。原来这里存的是 goal（整段需求描述），
    /// 小组件那一小块地方放不下，显示出来是一段被截断的需求文——
    /// 而 PC 上同一个任务显示的是「连连看网页游戏」（用户点名）。
    /// 旧快照没有这个键 → 解出 nil → 小组件退回「今天完成数」那一屏，
    /// 下一次同步（打开 App 即触发）就补上，不用迁移。
    var runningTitle: String?
    var stepsDone: Int
    var stepsTotal: Int
    var todayDone: Int
    /// 写入时刻。超过 10 分钟没更新时小组件要显示「更新于」（规范：数据过期要说）。
    var savedAt: Date

    var percent: Double? {
        stepsTotal > 0 ? Double(stepsDone) / Double(stepsTotal) : nil
    }
}

/// 提醒快照：给中号小组件。只放「今天 + 已过期」的未完成项，最多 6 条。
struct UmbraReminderSnapshot: Codable {
    struct Row: Codable, Identifiable {
        var id: String
        var text: String
        /// 「18:00」。过期行由小组件配「已过期」文字，这里只给时刻。
        var time: String
        var overdue: Bool
    }
    var rows: [Row]
    var savedAt: Date
}

// MARK: - Live Activity 属性（灵动岛 + 锁屏实况共用）

struct UmbraTaskActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var stepsDone: Int
        var stepsTotal: Int
        /// 一句话事件行：「第 3/5 步」或状态文案。来自任务列表接口，不编。
        var statusLine: String
        /// 收尾态（完成/失败）：结束 Activity 前推的最后一帧。
        var finished: Bool
        var failed: Bool

        var percent: Double? {
            stepsTotal > 0 ? Double(stepsDone) / Double(stepsTotal) : nil
        }
        /// 「40%」。没有步骤数时给 "…"（服务端没给就不编百分比）。
        var percentText: String {
            guard let p = percent else { return "…" }
            return "\(Int((p * 100).rounded()))%"
        }
    }

    /// 固定属性：整个 Activity 生命周期不变。
    var taskId: String
    var goal: String
}

// MARK: - 小工具

extension UmbraShared {
    /// 服务端 ISO 时间串是不是今天。带不带毫秒都认；解析不了一律按「不是今天」。
    /// 解析服务端给的时间字符串。**全 App 只此一份**，别再各写各的。
    ///
    /// 服务端有两种格式，只认其中一种就会静默失效：
    ///   1. `"2026-08-08T14:15:09.123456+00:00"` —— Python 的 `datetime.isoformat()`
    ///      （设备表 last_seen、保险箱 updated_at 走这个）；
    ///   2. `"2026-08-08 14:15:09"` —— SQLite 的 `CURRENT_TIMESTAMP`
    ///      （tasks / inspirations 的 created_at、updated_at 全是这个）。
    ///      **空格分隔、没有 T、没有时区后缀，而它是 UTC。**
    ///
    /// 原来只挂了两个 ISO8601 解析器，格式 2 一律解不出来 —— 于是
    /// 小组件的「今天完成」永远是 0，任务列表的时间直接把原始字符串
    /// 「2026-08-08 14:15:09」打在界面上（两处都是用户点名的现象）。
    ///
    /// ⚠️ 格式 2 必须**按 UTC 解**：本地是 +08:00 的话，UTC 16:00 之后的记录
    /// 按本地时间解会算到前一天去，「今天完成」又会少数。
    /// `locale` 固定 en_US_POSIX：定长格式解析不这么写，会被用户的日历/地区设置带歪。
    static func parseServerDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso1 = ISO8601DateFormatter()
        iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso1.date(from: raw) { return d }
        if let d = ISO8601DateFormatter().date(from: raw) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        // 带**时区偏移**的那两条是给 Python `datetime.isoformat()` 用的：
        // 它吐 6 位小数秒 +「+00:00」（如 2026-08-08T15:32:42.123456+00:00），
        // 而 ISO8601DateFormatter 的 .withFractionalSeconds 只保证认 3 位——
        // 上面两行会双双落空，掉到这里。没有带偏移的格式的话就彻底解不出，
        // 界面上会原样显示一串时间戳（灵感的 research_at 踩过）。
        for fmt in ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss",
                    "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss",
                    "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            df.dateFormat = fmt
            if let d = df.date(from: raw) { return d }
        }
        return nil
    }

    /// 这个时刻是不是「今天」——按**本机时区**判断日界（服务端存的是 UTC）。
    static func isToday(_ raw: String?) -> Bool {
        guard let d = parseServerDate(raw) else { return false }
        return Calendar.current.isDateInToday(d)
    }
}
