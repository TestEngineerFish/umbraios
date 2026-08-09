import Foundation

// MARK: - Data Models (Network)
struct HistoryMessage: Codable, Identifiable {
    let id: Int
    let role: String
    let content: String
    let created_at: String?
    let conversation: String?
}

// 会话列表项：'assistant'=你↔秘书；'device:<id>'=服务端↔某设备（只读）。
struct ConversationRow: Codable {
    let conversation: String
    let last_role: String
    let last_content: String
    let last_at: String?
    let count: Int
}

struct Job: Codable, Identifiable {
    let id: String
    /// 短标题（服务端 tasks.name，≤15 字，列表主展示）。
    /// **一期漏了这个字段**，于是列表、详情、小组件一律拿 goal 顶替标题位 ——
    /// PC 端显示的是「连连看网页游戏」，iOS 上却是整段需求描述（用户点名）。
    /// 旧 Job（operate 流水线）没有 name，所以是可选，用 title 统一兜底。
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

    /// 显示用标题：有短标题就用短标题，没有（旧 Job）才退回描述。
    /// **凡是「标题位」一律用它**，别再直接写 goal。
    var title: String {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? goal : n
    }
}

struct Subtask: Codable, Identifiable {
    let id: String
    let seq: Int
    let title: String?
    let provider: String?
    let skill: String?
    let status: String
    let result_json: String?
    let error: String?
}

struct JobEvent: Codable, Identifiable {
    let id: Int
    let type: String
    let message: String?
    let subtask_id: String?
    let created_at: String?
}

struct JobDetail: Codable {
    let job: Job
    let subtasks: [Subtask]
    let events: [JobEvent]
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

// 工作区：AI 写文件的落地目录。手机上**只读**（新增/删除/打开位置都在电脑上做）。
// 字段对应服务端 workspaces 表 + list_all 附带的两个统计列。
struct Workspace: Codable, Identifiable {
    let id: String
    let name: String
    let device_id: String
    let dir: String?
    let description: String?
    /// auto = 任务自动建 | manual = 手动新增
    let origin: String
    let created_at: String?
    let last_active_at: String?
    var task_count: Int? = nil
    var last_goal: String? = nil
}

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
