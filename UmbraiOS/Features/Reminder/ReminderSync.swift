// 提醒的服务端同步层：线格式(DTO) + 中英枚举映射 + 本地缓存 + 合并规则。
//
// 为什么单独一个文件：ReminderViews.swift 已经很长，而这里的东西**一条界面代码都没有** ——
// 纯数据。而且合并规则是最容易出错的一段（写错了会静默丢用户的提醒），
// 单独放便于一眼看完、也便于以后补测试。
//
// 三条必须记住的约定：
//   1. **出网一律英文枚举**。iOS 界面上仍显示中文（"每天"），但存进服务端的是 daily ——
//      服务端有白名单校验，中文会被 400 挡回来。映射只在这一个文件里做。
//   2. **时刻一律 epoch 毫秒**。服务端刻意用毫秒整数而不是时间字符串（时区上不会翻车），
//      Swift 侧在边界上转成 Date，业务代码照旧用 Date。
//   3. **本地缓存是缓存，不是真相**。断网时读它、写它并排队，联网后按 updated_at_ms 合并。
//      **不能因为断网就让提醒功能整个不能用** —— 提醒是离线属性最强的功能。
import Foundation

// MARK: - 线格式（对齐服务端 /reminders 的 JSON）

/// 服务端的一条提醒。字段名刻意用 snake_case 直接对齐服务端 JSON
/// （跟 Models.swift 里的 Job 一样），省掉一层 CodingKeys，改字段时少一处能漏。
struct ReminderDTO: Codable {
    let id: String
    let text: String
    let note: String
    let at_ms: Int64
    let repeat_rule: String
    let custom_freq: String
    let custom_n: Int
    let repeat_end_ms: Int64?
    let ahead_minutes: Int
    let done: Bool
    let source: String
    let tz: String
    let updated_at_ms: Int64
    let deleted: Bool
}

/// 一条删除墓碑。没有它，这台设备删掉的提醒会被另一台一推又复活。
struct ReminderTombDTO: Codable {
    let id: String
    let deleted_at_ms: Int64
}

/// GET /reminders 的响应。**items 和 deleted 总是一起回**（都按 since 过滤），
/// 所以拉增量时不会漏掉别的端做的删除。
struct ReminderListDTO: Codable {
    let items: [ReminderDTO]
    let deleted: [ReminderTombDTO]
    let synced_at_ms: Int64
}

/// PUT /reminders/{id} 的响应。applied=false 表示「你推的这版更旧，服务端没采纳」，
/// 客户端要拿回来的 reminder 回滚本地。
struct ReminderPutDTO: Codable {
    let applied: Bool
    let reminder: ReminderDTO
}

// MARK: - 中英枚举映射

/// 界面中文 ↔ 服务端英文。**中文只留给 UI，绝不出网。**
/// 认不出的值一律退到最保守的默认（none / day / manual），
/// 而不是原样透传 —— 透传中文会被服务端 400，整条提醒就同步不上去了。
enum ReminderWire {
    private static let rules: [(display: String, wire: String)] = [
        ("不重复", "none"), ("每天", "daily"), ("每周", "weekly"),
        ("每月", "monthly"), ("工作日", "weekday"), ("自定义", "custom"),
    ]
    private static let freqs: [(display: String, wire: String)] = [
        ("小时", "hour"), ("天", "day"), ("周", "week"), ("月", "month"), ("年", "year"),
    ]
    private static let sources: [(display: String, wire: String)] = [
        ("手动添加", "manual"), ("聊天", "chat"), ("任务", "task"),
    ]

    static func ruleToWire(_ display: String) -> String {
        rules.first { $0.display == display }?.wire ?? "none"
    }

    static func ruleToDisplay(_ wire: String) -> String {
        rules.first { $0.wire == wire }?.display ?? "不重复"
    }

    static func freqToWire(_ display: String) -> String {
        freqs.first { $0.display == display }?.wire ?? "day"
    }

    static func freqToDisplay(_ wire: String) -> String {
        freqs.first { $0.wire == wire }?.display ?? "天"
    }

    static func sourceToWire(_ display: String) -> String {
        sources.first { $0.display == display }?.wire ?? "manual"
    }

    static func sourceToDisplay(_ wire: String) -> String {
        sources.first { $0.wire == wire }?.display ?? "手动添加"
    }
}

// MARK: - Date ↔ epoch 毫秒

extension Date {
    /// epoch 毫秒。服务端所有时刻字段都是这个单位。
    var umbraMs: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    /// 当前时刻的 epoch 毫秒。写操作要盖这个戳，合并全靠它比大小。
    static var umbraNowMs: Int64 { Date().umbraMs }

    init(umbraMs: Int64) {
        self.init(timeIntervalSince1970: Double(umbraMs) / 1000.0)
    }
}

// MARK: - UmbraReminder ↔ DTO

extension UmbraReminder {
    /// 从服务端的一条造出本地模型。服务端来的东西一定是「干净的」，所以 dirty = false。
    init(dto: ReminderDTO) {
        self.init(
            id: dto.id,
            text: dto.text,
            at: Date(umbraMs: dto.at_ms),
            repeatRule: ReminderWire.ruleToDisplay(dto.repeat_rule),
            customFreq: ReminderWire.freqToDisplay(dto.custom_freq),
            customN: max(1, dto.custom_n),
            repeatEnd: dto.repeat_end_ms.map { Date(umbraMs: $0) },
            aheadMinutes: dto.ahead_minutes,
            note: dto.note,
            done: dto.done,
            source: ReminderWire.sourceToDisplay(dto.source),
            createdAt: Date(umbraMs: dto.at_ms),
            updatedAtMs: dto.updated_at_ms,
            dirty: false
        )
    }

    /// 转成上行的线格式。**这里是中文枚举唯一的出口**，务必走 ReminderWire。
    var dto: ReminderDTO {
        ReminderDTO(
            id: id,
            text: text,
            note: note,
            at_ms: at.umbraMs,
            repeat_rule: ReminderWire.ruleToWire(repeatRule),
            custom_freq: ReminderWire.freqToWire(customFreq),
            custom_n: max(1, customN),
            repeat_end_ms: repeatEnd?.umbraMs,
            ahead_minutes: aheadMinutes,
            done: done,
            source: ReminderWire.sourceToWire(source),
            tz: TimeZone.current.identifier,
            updated_at_ms: updatedAtMs,
            deleted: false
        )
    }
}

// MARK: - 合并规则

/// 把服务端拉到的一批并进本地。**纯函数**，不碰存储也不发请求 —— 这段最容易写错
/// （写错了会静默丢用户的提醒），抽出来才好一眼看完、以后也好补测试。
enum ReminderMerge {
    /// 逐条 last-write-wins，但**本地未推送的改动（dirty）且更新时，本地赢**。
    /// 不这么做的话：断网时改了一条，联网拉一次就被服务端旧值覆盖，用户的修改凭空消失。
    static func apply(local: [UmbraReminder],
                      serverItems: [ReminderDTO],
                      serverTombs: [ReminderTombDTO]) -> [UmbraReminder] {
        var byId: [String: UmbraReminder] = [:]
        for r in local { byId[r.id] = r }

        for dto in serverItems {
            if let mine = byId[dto.id], mine.dirty, mine.updatedAtMs > dto.updated_at_ms {
                continue                      // 本地有更新的未推送改动，等推上去再说
            }
            byId[dto.id] = UmbraReminder(dto: dto)
        }

        for tomb in serverTombs {
            if let mine = byId[tomb.id], mine.dirty, mine.updatedAtMs > tomb.deleted_at_ms {
                continue                      // 删除之后本地又改过（更晚），删除作废
            }
            byId.removeValue(forKey: tomb.id)
        }

        return byId.values.sorted { $0.at < $1.at }
    }
}

// MARK: - 本地缓存（App Group）

/// 提醒的本机缓存。**是缓存不是真相**：断网时读它写它，联网后跟服务端合并。
///
/// 放 App Group 而不是 UserDefaults.standard：小组件快照本来就在 App Group，
/// 两份数据分居两地是个隐患（将来做小组件交互式勾选会直接卡在这儿）。
/// 老用户的 standard 存量数据会在第一次读时自动搬过来，不会凭空消失。
enum ReminderCache {
    private static let itemsKey = "umbra.reminders.local"
    private static let syncKey = "umbra.reminders.syncedAtMs"
    private static let tombKey = "umbra.reminders.tombs"

    private static var defaults: UserDefaults { UmbraGroupStore.defaults }

    /// 读缓存。共享域没有就读私有域的老值并**顺手搬过去**（同 UmbraGroupStore.string 的做法）。
    static func load() -> [UmbraReminder] {
        var raw = defaults.data(forKey: itemsKey)
        if raw == nil, defaults != .standard,
           let legacy = UserDefaults.standard.data(forKey: itemsKey) {
            defaults.set(legacy, forKey: itemsKey)
            raw = legacy
        }
        guard let data = raw,
              let list = try? JSONDecoder().decode([UmbraReminder].self, from: data) else { return [] }
        return list.sorted { $0.at < $1.at }
    }

    static func save(_ items: [UmbraReminder]) {
        guard let d = try? JSONEncoder().encode(items) else { return }
        defaults.set(d, forKey: itemsKey)
    }

    /// 上次拉取的水位线（服务端回的 synced_at_ms），下次当 since 用。
    static var lastSyncMs: Int64 {
        get { Int64(defaults.integer(forKey: syncKey)) }
        set { defaults.set(Int(newValue), forKey: syncKey) }
    }

    /// 还没推上去的删除。断网删了一条，联网后要把这个删除也送上去，
    /// 否则别的端永远看得见它（本地删了、云端还在，下次拉取又同步回来）。
    static func pendingTombs() -> [String: Int64] {
        guard let raw = defaults.dictionary(forKey: tombKey) as? [String: Int] else { return [:] }
        var out: [String: Int64] = [:]
        for (k, v) in raw { out[k] = Int64(v) }
        return out
    }

    static func addTomb(id: String, at ms: Int64) {
        var t = pendingTombs()
        t[id] = ms
        defaults.set(t.mapValues { Int($0) }, forKey: tombKey)
    }

    static func removeTomb(id: String) {
        var t = pendingTombs()
        t.removeValue(forKey: id)
        defaults.set(t.mapValues { Int($0) }, forKey: tombKey)
    }
}
