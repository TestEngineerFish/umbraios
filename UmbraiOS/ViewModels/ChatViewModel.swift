import Foundation

// MARK: - Chat ViewModel
@MainActor
class ChatViewModel: ObservableObject {
    // Message blocks for rendering
    @Published var blocks: [ChatBlock] = []
    @Published var draft: String = ""
    @Published var isThinking: Bool = false
    @Published var showAttachSheet: Bool = false
    @Published var showVoiceOverlay: Bool = false
    @Published var showLightbox: Bool = false
    @Published var lightboxImageURL: String = ""
    @Published var confirmPending: ConfirmRequest?

    let ws = ChatWebSocket()

    private var assistantIdx: Int?
    private var jobMap: [String: Int] = [:]
    private var oldestId: Int?
    private var hasMoreHistory: Bool = true
    private var isLoadingHistory: Bool = false
    var stickToBottom: Bool = true

    // 公开滚动状态供UI使用
    var shouldScrollToBottom: Bool { stickToBottom }

    func setStickToBottom(_ value: Bool) {
        stickToBottom = value
    }

    init() {
        setupWebSocket()
    }

    private func setupWebSocket() {
        ws.onMessage = { [weak self] msg in
            self?.handleMessage(msg)
        }
        ws.onStatusChange = { [weak self] _ in
            // Status changed, UI will update via @Published
        }
        ws.connect()
        loadHistory()
    }

    func loadHistory() {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true

        Task {
            let messages = await HTTPService.shared.fetchHistory(limit: 40)
            await MainActor.run {
                self.isLoadingHistory = false
                if self.blocks.isEmpty {
                    self.blocks = messages.map { msg in
                        if msg.role == "user" {
                            return ChatBlock.user(id: UUID(), text: msg.content, ts: msg.created_at)
                        } else {
                            return ChatBlock.assistantBlock(text: msg.content, ts: msg.created_at)
                        }
                    }
                }
                if let last = messages.first {
                    self.oldestId = last.id
                    self.hasMoreHistory = messages.count >= 40
                }
            }
        }
    }

    func loadOlderHistory() async {
        guard !isLoadingHistory, hasMoreHistory, let beforeId = oldestId else { return }
        isLoadingHistory = true

        let messages = await HTTPService.shared.fetchHistory(limit: 40, beforeId: beforeId)

        await MainActor.run {
            isLoadingHistory = false
            if messages.isEmpty {
                hasMoreHistory = false
                return
            }
            if messages.count < 40 { hasMoreHistory = false }
            oldestId = messages.first?.id

            let newBlocks: [ChatBlock] = messages.map { msg in
                if msg.role == "user" {
                    return ChatBlock.user(id: UUID(), text: msg.content, ts: msg.created_at)
                } else {
                    return ChatBlock.assistantBlock(text: msg.content, ts: msg.created_at)
                }
            }
            blocks.insert(contentsOf: newBlocks, at: 0)

            // Adjust indices
            let shift = newBlocks.count
            for key in jobMap.keys { jobMap[key]? += shift }
            assistantIdx? += shift
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        stickToBottom = true

        let now = ISO8601DateFormatter().string(from: Date())
        blocks.append(.user(id: UUID(), text: text, ts: now))

        let assistantBlockIdx = blocks.count
        blocks.append(.assistant(ChatBlock.AssistantBlock(thinking: true, streaming: true, text: "", trace: [], traceOpen: true, ts: now)))
        assistantIdx = assistantBlockIdx

        ws.sendMessage(text)
    }

    func newSession() {
        blocks.removeAll()
        assistantIdx = nil
        jobMap.removeAll()
        ws.sendNewSession()
        stickToBottom = true
    }

    func toggleTrace(at index: Int) {
        guard index < blocks.count, case .assistant(var a) = blocks[index] else { return }
        a.traceOpen.toggle()
        blocks[index] = .assistant(a)
    }

    func handleConfirm(taskId: String, approved: Bool) {
        ws.sendConfirm(taskId: taskId, approved: approved)
        // Update UI
        for i in blocks.indices {
            if case .job(var j) = blocks[i], j.confirmTaskId == taskId {
                j.confirmTaskId = nil
                j.message = approved ? L("chat.status.approved") : L("chat.status.denied")
                blocks[i] = .job(j)
            }
        }
        confirmPending = nil
    }

    // MARK: - Message Handler
    private func handleMessage(_ msg: ChatMessage) {
        switch msg.type {
        case "delta":
            if var a = currentAssistant {
                a.text += msg.deltaText ?? ""
                a.thinking = false
                updateAssistant(a)
            }

        case "tool_call":
            if var a = currentAssistant {
                if !a.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    a.trace.append("💭 " + a.text.trimmingCharacters(in: .whitespaces))
                    a.text = ""
                }
                var argsStr = ""
                if let args = msg.toolArgs {
                    let truncated = String(describing: args).prefix(120)
                    argsStr = String(truncated)
                }
                a.trace.append("🔧 \(msg.toolName ?? "unknown")(\(argsStr))")
                updateAssistant(a)
            }

        case "tool_result":
            if var a = currentAssistant {
                let preview = msg.toolResultPreview ?? ""
                let truncated = preview.count > 160 ? preview.prefix(160) + "…" : preview
                a.trace.append("↳ \(msg.toolName ?? "unknown") → \(truncated)")
                updateAssistant(a)
            }

        case "reply":
            if var a = currentAssistant {
                a.text = msg.text ?? a.text
                a.thinking = false
                a.streaming = false
                updateAssistant(a)
            }
            assistantIdx = nil

        case "job_update":
            handleJobUpdate(msg)

        case "confirm_request":
            if let taskId = msg.taskId,
               !blocks.contains(where: { if case .confirm(let c) = $0 { return c.taskId == taskId } else { return false } }) {
                blocks.append(.confirm(ChatBlock.ConfirmBlock(taskId: taskId, summary: msg.confirmSummary ?? L("chat.status.confirmRequired"), resolved: nil)))
                confirmPending = ConfirmRequest(taskId: taskId, summary: msg.confirmSummary ?? "")
            }

        case "confirm_resolved":
            resolveConfirm(taskId: msg.taskId ?? "", approved: msg.confirmApproved ?? false)

        case "chat_message":
            let ts = msg.created_at ?? ISO8601DateFormatter().string(from: Date())
            if msg.chatRole == "user" {
                blocks.append(.user(id: UUID(), text: msg.chatText ?? "", ts: ts))
            } else if msg.chatRole == "assistant" {
                blocks.append(.assistant(ChatBlock.AssistantBlock(thinking: false, streaming: false, text: msg.chatText ?? "", trace: [], traceOpen: false, ts: ts)))
            }

        case "error":
            if assistantIdx != nil {
                if var a = currentAssistant {
                    a.thinking = false
                    a.streaming = false
                    updateAssistant(a)
                }
                assistantIdx = nil
            }
            blocks.append(.error(id: UUID(), text: msg.errorMessage ?? L("chat.status.error")))

        default: break
        }
    }

    private var currentAssistant: ChatBlock.AssistantBlock? {
        guard let idx = assistantIdx, idx < blocks.count,
              case .assistant(let a) = blocks[idx] else { return nil }
        return a
    }

    private func updateAssistant(_ a: ChatBlock.AssistantBlock) {
        guard let idx = assistantIdx, idx < blocks.count else { return }
        blocks[idx] = .assistant(a)
    }

    private func handleJobUpdate(_ msg: ChatMessage) {
        guard let id = msg.jobId else { return }
        let overall = msg.jobOverall ?? (msg.jobStatus == "done" ? 1.0 : 0.0)
        let pct = min(100, max(0, Int(overall * 100)))

        if let idx = jobMap[id] {
            if case .job(var j) = blocks[idx] {
                j.pct = pct
                j.status = msg.jobStatus ?? j.status
                j.message = msg.jobMessage ?? j.message
                if let goal = msg.jobGoal { j.goal = goal }
                if let confirmId = msg.jobConfirmTaskId, msg.jobNeedsConfirm == true {
                    j.confirmTaskId = confirmId
                }
                if let results = msg.jobResults { j.results = results }
                blocks[idx] = .job(j)

                if msg.jobStatus == "done" {
                    blocks.append(.done(id: UUID(), goal: j.goal, results: j.results ?? []))
                }
            }
        } else {
            let goal = msg.jobGoal ?? L("chat.status.task")
            let block = ChatBlock.jobBlock(
                jobId: id, goal: goal, pct: pct,
                status: msg.jobStatus ?? "running",
                message: msg.jobMessage ?? "",
                confirmTaskId: msg.jobConfirmTaskId,
                results: msg.jobResults
            )
            jobMap[id] = blocks.count
            blocks.append(block)
        }
    }

    private func resolveConfirm(taskId: String, approved: Bool) {
        for i in blocks.indices {
            if case .job(var j) = blocks[i], j.confirmTaskId == taskId {
                j.confirmTaskId = nil
                j.message = approved ? L("chat.status.approved") : L("chat.status.denied")
                blocks[i] = .job(j)
            }
            if case .confirm(var c) = blocks[i], c.taskId == taskId {
                c.resolved = approved ? .approved : .denied
                blocks[i] = .confirm(c)
            }
        }
    }
}

// MARK: - Chat Blocks
enum ChatBlock: Identifiable {
    case user(id: UUID, text: String, ts: String?)
    case assistant(AssistantBlock)
    case job(JobBlock)
    case done(id: UUID, goal: String, results: [[String: String]])
    case confirm(ConfirmBlock)
    case error(id: UUID, text: String)

    // 稳定 id：每个块创建时就固定，供 SwiftUI 做行身份识别（此前每次访问都新建 UUID，导致整列反复重建、卡顿）。
    var id: String {
        switch self {
        case .user(let id, _, _): return id.uuidString
        case .assistant(let a): return a.id.uuidString
        case .job(let j): return j.id.uuidString
        case .done(let id, _, _): return id.uuidString
        case .confirm(let c): return c.id.uuidString
        case .error(let id, _): return id.uuidString
        }
    }
}

extension ChatBlock {
    struct AssistantBlock: Hashable {
        let id = UUID()
        var thinking: Bool
        var streaming: Bool
        var text: String
        var trace: [String]
        var traceOpen: Bool
        var ts: String?
    }

    struct JobBlock: Hashable {
        let id = UUID()
        var jobId: String
        var goal: String
        var pct: Int
        var status: String
        var message: String
        var confirmTaskId: String?
        var results: [[String: String]]?
    }

    struct ConfirmBlock: Hashable {
        let id = UUID()
        var taskId: String
        var summary: String
        var resolved: ConfirmStatus?
    }

    enum ConfirmStatus: Hashable { case approved, denied }

    // Helper factory methods (enums don't provide these automatically with labels)
    static func assistantBlock(text: String, ts: String?) -> ChatBlock {
        .assistant(AssistantBlock(thinking: false, streaming: false, text: text, trace: [], traceOpen: false, ts: ts))
    }

    static func assistantBlock(thinking: Bool, streaming: Bool, text: String, trace: [String] = [], traceOpen: Bool = true, ts: String?) -> ChatBlock {
        .assistant(AssistantBlock(thinking: thinking, streaming: streaming, text: text, trace: trace, traceOpen: traceOpen, ts: ts))
    }

    static func assistantBlock(_ data: AssistantBlock) -> ChatBlock {
        .assistant(data)
    }

    static func jobBlock(jobId: String, goal: String, pct: Int, status: String, message: String, confirmTaskId: String?, results: [[String: String]]?) -> ChatBlock {
        .job(JobBlock(jobId: jobId, goal: goal, pct: pct, status: status, message: message, confirmTaskId: confirmTaskId, results: results))
    }
}

// MARK: - Confirm Request
struct ConfirmRequest: Identifiable {
    let id: String
    let summary: String

    init(taskId: String, summary: String) {
        self.id = taskId
        self.summary = summary
    }
}
