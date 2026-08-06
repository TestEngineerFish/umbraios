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
    var runningGoal: String?
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
    var jobId: String
    var goal: String
}

// MARK: - 小工具

extension UmbraShared {
    /// 服务端 ISO 时间串是不是今天。带不带毫秒都认；解析不了一律按「不是今天」。
    static func isToday(_ iso: String?) -> Bool {
        guard let iso else { return false }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter()
        guard let d = f1.date(from: iso) ?? f2.date(from: iso) else { return false }
        return Calendar.current.isDateInToday(d)
    }
}
