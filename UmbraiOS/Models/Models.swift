import Foundation

// MARK: - Data Models (Network)
struct HistoryMessage: Codable, Identifiable {
    let id: Int
    let role: String
    let content: String
    let created_at: String?
    let conversation: String?
    /// text / image（atts 是文件 id）/ system（取消提示这类系统行）。老服务端不带 → 当 text。
    let kind: String?
    /// 附件的 file_id 列表（图片消息；批次 013 起带附件的文字消息也有）。
    let atts: [String]?
    /// 附加信息：引用注脚 quote、取消收尾的 interrupted / cancelled、已执行工具 tools。
    /// 结构随服务端走，端上只挑认识的字段读，所以用 [String: AnyCodableValue] 而不是强类型。
    let meta: HistoryMeta?
}

/// 历史行的 meta。只解码端上真的会用的那几个键 —— 服务端以后往里加东西不会把这一条解码搞崩。
struct HistoryMeta: Codable {
    let interrupted: Bool?
    let cancelled: Bool?
    let quote: HistoryQuote?
    let tools: [HistoryTool]?
}

struct HistoryQuote: Codable {
    let id: Int?
    let role: String?
    let text: String?
}

struct HistoryTool: Codable {
    let name: String?
    let args: String?
}

// 会话列表项：'assistant'=你↔秘书；'device:<id>'=服务端↔某设备（只读）。
struct ConversationRow: Codable {
    let conversation: String
    let last_role: String
    let last_content: String
    let last_at: String?
    let count: Int
}

/// 任务行（GET /tasks）。B 批改名：原来叫 Job —— 那是已删除的旧流水线的名字，
/// 现在服务端从表到接口都叫任务（tasks），端上跟着改，别让两套名字打架。
/// 不叫 `Task` 是因为会撞 Swift 并发的 `Task`，全项目都在用。
struct TaskItem: Codable, Identifiable {
    let id: String
    /// 短标题（服务端 tasks.name，≤15 字，列表主展示）。
    /// **一期漏了这个字段**，于是列表、详情、小组件一律拿 goal 顶替标题位 ——
    /// PC 端显示的是「连连看网页游戏」，iOS 上却是整段需求描述（用户点名）。
    /// 历史数据可能没有 name，所以是可选，用 title 统一兜底。
    let name: String?
    /// 详细描述（执行/验收/汇报都以它为准）。标题位不该放它。
    let goal: String
    let status: String
    let result_summary: String?
    let channel: String?
    let created_at: String?
    let updated_at: String?
    // 步骤统计（列表接口附带）：用于任务列表按真实完成步数显示进度。
    var steps_total: Int? = nil
    var steps_done: Int? = nil

    /// 显示用标题：有短标题就用短标题，没有才退回描述。
    /// **凡是「标题位」一律用它**，别再直接写 goal。
    var title: String {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? goal : n
    }
}

/// 一步失败时的结构化错误。kind: step_error(执行轮异常)/device_error(设备报错)/timeout(疑似卡住)。
struct StepError: Codable, Hashable {
    let kind: String?
    let message: String?
    let detail: String?
}

/// 任务的一步（详情里的 steps；原 Subtask）。
/// 字段跟着服务端 _step_row 走：provider/skill/result_json 已随统一执行轮模型
/// 从接口里消失，error 从自由文本变成了结构化对象 —— 旧声明 `error: String?`
/// 会让**任何带失败步骤的任务**整个详情解码失败，界面上表现为详情永远转圈。
struct TaskStep: Codable, Identifiable {
    let id: String
    let seq: Int
    let title: String?
    let status: String
    /// 这一步实际干了什么（引擎写的人话说明，如「设备不在线，挂起等待」）。
    let detail: String?
    let device_id: String?
    let elapsed_ms: Int?
    let error: StepError?
    /// 结构化结果 {summary, artifacts, device_results}（JSON 文本，原样透传）。
    /// 步骤产出的可点链接（截图 url 等）藏在 device_results 里 —— 详情页的
    /// 内联截图靠它。解析放界面：脏数据只该影响那一块，不该让整个详情解码失败。
    let result_json: String?
}

struct TaskEvent: Codable, Identifiable {
    let id: Int
    let type: String
    let message: String?
    /// 事件挂在哪一步上（可空：任务级事件不挂步）。原来声明成 subtask_id，
    /// 服务端实际给的键一直是 step_id —— 那一列因此永远解出 nil。
    let step_id: String?
    let created_at: String?
}

/// GET /tasks/{id} 的响应。键名跟服务端一致（B 批改名，原 {job, subtasks, events}），
/// 字段名即 JSON 键，不用 CodingKeys —— 改字段时少一处能漏。
struct TaskDetail: Codable {
    let task: TaskItem
    let steps: [TaskStep]
    let events: [TaskEvent]
}

struct Capability: Codable {
    let device_id: String
    let device_name: String
    let platform: String
    let providers: [ProviderInfo]
}

// 已知设备（含离线）：聊天页「联系人列表」的数据源（GET /devices/all）。
// 离线设备带的是最近一次上线时的能力目录快照，所以详情页离线也能看它「会什么」。
struct KnownDevice: Codable, Identifiable {
    let device_id: String
    let device_name: String
    let platform: String
    let online: Bool
    let last_seen: String?
    let providers: [ProviderInfo]

    var id: String { device_id }
    var conversation: String { "device:\(device_id)" }
    // 平台 → SF Symbol
    var icon: String {
        switch platform.lowercased() {
        case "ios", "android": return "iphone"
        case "macos": return "laptopcomputer"
        case "windows", "linux": return "desktopcomputer"
        default: return "display"
        }
    }
}

struct ProviderInfo: Codable {
    let provider: String
    let display_name: String
    let kind: String
    let available: Bool
    let unavailable_reason: String
    let version: String?
    let skills: [SkillInfo]
}

struct SkillInfo: Codable {
    let name: String
    let description: String
}

struct UploadResponse: Codable {
    let file_id: String
    let filename: String
    let url: String
}

// 灵感速记：raw 原文一字不改；title/summary/tags 是秘书的轻整理。
struct Inspiration: Codable, Identifiable {
    let id: Int
    let raw: String
    let title: String
    let summary: String
    let tags: [String]
    let status: String          // open/done/archived
    let source_channel: String?
    let created_at: String?
    let updated_at: String?

    // 下面四个都是 **optional**：服务端现在一定会给，但连到旧版服务端时字段是缺的，
    // 非 optional 会让 JSONDecoder 整条解码失败 —— 整个灵感列表变空白，
    // 而用户只会看到「没有灵感」，完全看不出是版本不匹配。宁可这几栏不显示。
    /// pending 待补整理 / done 已整理 / failed 整理失败
    let organize_status: String?
    /// 轻调研纪要（Markdown）。没查过是空串。
    let research: String?
    /// idle / queued / running / done / failed
    let research_status: String?
    let research_at: String?

    var organizeState: String { organize_status ?? "done" }
    var researchState: String { research_status ?? "idle" }
    var researchText: String { research ?? "" }
    /// 排队中或正在跑 —— 详情页据此决定要不要开轮询盯进度。
    var researchInFlight: Bool { researchState == "queued" || researchState == "running" }

    /// 列表/详情显示用的标题。秘书的整理是异步补的，补上之前 title 是空的，
    /// 这时候拿原文前 20 字顶着，比显示「（还没有标题）」有用得多 ——
    /// 用户刚记完就看到自己写的东西，才知道确实记下了。
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return body.count <= 20 ? body : String(body.prefix(20)) + "…"
    }
}

// Workspace 模型已删：工作区整屏随稿在 iOS 下线（2026-08-22，PC 端保留）。

/// GET/PUT/DELETE /profile 的响应体。
struct ProfileBody: Codable {
    let markdown: String
}

/// 一条常用语。updatedAt 是**毫秒**时间戳，合并时靠它比大小（和服务端 PhraseItem 一一对应）。
struct Phrase: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var content: String
    var keyword: String?
    var order: Int
    var updatedAt: Int

    /// 发给服务端的形状。keyword 为 nil 时不带这个键，避免服务端把 null 当成「清空关键字」。
    var wire: [String: Any] {
        var d: [String: Any] = ["id": id, "name": name, "content": content,
                                "order": order, "updatedAt": updatedAt]
        if let k = keyword, !k.isEmpty { d["keyword"] = k }
        return d
    }
}

/// 删除墓碑。没有它，A 端删掉的条目会被 B 端一推又复活。
struct PhraseTomb: Codable, Identifiable, Equatable {
    var id: String
    var deletedAt: Int
}

/// /phrases 与 /phrases/sync 的响应体：合并后的全量 + 墓碑。
struct PhraseBundle: Codable {
    var items: [Phrase]
    var deleted: [PhraseTomb]
}

// MARK: - 回收站（通用区）

/// 回收站里的一条。**id 有两种类型**：灵感是自增整数，任务/提醒是 uuid 字符串。
/// Swift 的 Codable 不认联合类型，所以这里自己解一层，两种都收进 String ——
/// 回传给服务端时原样发回去即可（服务端按 kind 决定怎么用）。
struct TrashItem: Codable, Identifiable {
    let kind: String            // idea / task / reminder（操控记录在服务端就并进 task 了）
    let rawId: String
    let title: String
    let deleted_at_ms: Double
    let left_days: Int

    var id: String { "\(kind):\(rawId)" }

    private enum K: String, CodingKey { case kind, id, title, deleted_at_ms, left_days }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        // 先按字符串试，不成再按整数 —— 反过来会把 uuid 判成解码失败。
        if let s = try? c.decode(String.self, forKey: .id) { rawId = s }
        else if let n = try? c.decode(Int.self, forKey: .id) { rawId = String(n) }
        else { rawId = "" }
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        deleted_at_ms = (try? c.decode(Double.self, forKey: .deleted_at_ms)) ?? 0
        left_days = (try? c.decode(Int.self, forKey: .left_days)) ?? 0
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(kind, forKey: .kind); try c.encode(rawId, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(deleted_at_ms, forKey: .deleted_at_ms); try c.encode(left_days, forKey: .left_days)
    }

    /// 发回服务端时的形状。灵感那一路要还原成整数，别把 "12" 发过去。
    var entry: [String: Any] {
        ["kind": kind, "id": kind == "idea" ? (Int(rawId) ?? 0) as Any : rawId as Any]
    }
}

/// GET /trash 的响应体。
///
/// counts / keep_days 都是 **optional**：连到旧版服务端时字段是缺的，
/// 非 optional 会让整条解码失败 —— 回收站变空白，而用户只会以为「没东西」，
/// 完全看不出是版本不匹配（这个坑 Inspiration 那边已经踩过一次）。
struct TrashListDTO: Codable {
    let items: [TrashItem]
    let counts: [String: Int]?
    let keep_days: Int?
}
