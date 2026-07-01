import Foundation

// MARK: - Data Models (Network)
struct HistoryMessage: Codable, Identifiable {
    let id: Int
    let role: String
    let content: String
    let created_at: String?
}

struct Job: Codable, Identifiable {
    let id: String
    let goal: String
    let status: String
    let result_summary: String?
    let channel: String?
    let created_at: String?
    let updated_at: String?
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
