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
    let goal: String
    let status: String
    let result_summary: String?
    let channel: String?
    let created_at: String?
    let updated_at: String?
    // 步骤统计（列表接口附带）：用于任务列表按真实完成步数显示进度。
    var steps_total: Int? = nil
    var steps_done: Int? = nil
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
}
