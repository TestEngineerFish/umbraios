import Foundation

// MARK: - Chat ViewModel
//
// 多会话（与 PC / Web 端一致）：
//   - "assistant"   = 你↔秘书主会话（可发送）
//   - "device:<id>" = 服务端↔某设备的编排流（默认只读，设置里可开启发送）
//   每个会话各自维护 blocks/分页/未读；服务端推送按 msg.conversation 路由。
@MainActor
class ChatViewModel: ObservableObject {
    static let mainConv = "assistant"

    // 当前会话的消息（驱动列表渲染）
    @Published var blocks: [ChatBlock] = []
    // 会话切换
    @Published var activeConv: String = ChatViewModel.mainConv
    @Published var conversationOrder: [String] = [ChatViewModel.mainConv]
    @Published var unread: Set<String> = []

    @Published var draft: String = ""
    @Published var isThinking: Bool = false
    @Published var showAttachSheet: Bool = false
    @Published var showVoiceOverlay: Bool = false
    @Published var showLightbox: Bool = false
    @Published var lightboxImageURL: String = ""
    @Published var confirmPending: ConfirmRequest?

    let ws = ChatWebSocket()

    // 回复超时兜底：发出后一段时间没有任何回复/流式内容，就把「思考中」气泡收尾为错误，
    // 避免连接中途断开时界面永远 loading。
    private var replyTimeout: Task<Void, Never>?
    private func armReplyTimeout() {
        replyTimeout?.cancel()
        replyTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)  // 60s 无响应
            guard let self, !Task.isCancelled else { return }
            self.failPendingTurn()
        }
    }
    private func failPendingTurn() {
        let s = mainStore
        guard let idx = s.assistantIdx, idx < s.blocks.count else { return }
        if case .assistant(var a) = s.blocks[idx] {
            a.thinking = false
            a.streaming = false
            s.blocks[idx] = .assistant(a)
        }
        s.assistantIdx = nil
        s.blocks.append(.error(id: UUID(), text: L("chat.status.timeout")))
        reflect(ChatViewModel.mainConv)
    }

    // 每个会话的独立状态
    private final class ConvStore {
        var blocks: [ChatBlock] = []
        var assistantIdx: Int?
        var jobMap: [String: Int] = [:]
        var oldestId: Int?
        var hasMoreHistory = true
        var loaded = false
    }
    private var stores: [String: ConvStore] = [:]

    private var isLoadingHistory = false
    var stickToBottom: Bool = true
    var shouldScrollToBottom: Bool { stickToBottom }
    func setStickToBottom(_ value: Bool) { stickToBottom = value }

    func isReadonly(_ conv: String) -> Bool {
        conv != ChatViewModel.mainConv && !NetworkConfig.shared.allowDeviceSend
    }

    func convLabel(_ conv: String) -> String {
        if conv == ChatViewModel.mainConv { return L("chat.conv.secretary") }
        if conv.hasPrefix("device:") { return String(conv.dropFirst("device:".count)).uppercased() }
        return conv
    }

    init() {
        setupWebSocket()
    }

    // MARK: - Store helpers
    private func store(_ conv: String) -> ConvStore {
        if let s = stores[conv] { return s }
        let s = ConvStore()
        stores[conv] = s
        if !conversationOrder.contains(conv) { conversationOrder.append(conv) }
        return s
    }
    private var mainStore: ConvStore { store(ChatViewModel.mainConv) }

    // 把某会话的变更反映到 UI：active → 更新 blocks；否则标未读。
    private func reflect(_ conv: String) {
        if conv == activeConv {
            blocks = store(conv).blocks
        } else {
            unread.insert(conv)
        }
    }

    // MARK: - Setup / history
    private func setupWebSocket() {
        ws.onMessage = { [weak self] msg in self?.handleMessage(msg) }
        ws.onStatusChange = { [weak self] status in
            // 连接掉线且此时有「思考中」的回合在等 → 立即收尾为错误，不用干等超时。
            guard let self else { return }
            if status == .offline, self.mainStore.assistantIdx != nil {
                self.replyTimeout?.cancel()
                self.failPendingTurn()
            }
        }
        ws.connect()
        loadHistory()
        loadConversationsList()
    }

    func loadHistory() {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        Task {
            let messages = await HTTPService.shared.fetchHistory(limit: 40, conversation: ChatViewModel.mainConv)
            await MainActor.run {
                self.isLoadingHistory = false
                let s = self.mainStore
                s.loaded = true
                if s.blocks.isEmpty {
                    s.blocks = messages.map { self.historyToBlock($0) }
                }
                if let last = messages.first {
                    s.oldestId = last.id
                    s.hasMoreHistory = messages.count >= 40
                }
                self.reflect(ChatViewModel.mainConv)
            }
        }
    }

    private func loadConvHistory(_ conv: String) {
        let s = store(conv)
        guard !s.loaded else { return }
        s.loaded = true
        Task {
            let messages = await HTTPService.shared.fetchHistory(limit: 40, conversation: conv)
            await MainActor.run {
                if s.blocks.isEmpty {
                    s.blocks = messages.map { self.historyToBlock($0) }
                }
                if let last = messages.first {
                    s.oldestId = last.id
                    s.hasMoreHistory = messages.count >= 40
                }
                self.reflect(conv)
            }
        }
    }

    private func loadConversationsList() {
        Task {
            let rows = await HTTPService.shared.fetchConversations()
            await MainActor.run {
                for r in rows where r.conversation != ChatViewModel.mainConv {
                    _ = self.store(r.conversation)
                }
            }
        }
    }

    private func historyToBlock(_ msg: HistoryMessage) -> ChatBlock {
        switch msg.role {
        case "user": return .user(id: UUID(), text: msg.content, ts: msg.created_at)
        case "device": return .device(id: UUID(), text: msg.content, ts: msg.created_at)
        default: return .assistantBlock(text: msg.content, ts: msg.created_at)
        }
    }

    func loadOlderHistory() async {
        let s = store(activeConv)
        guard !isLoadingHistory, s.hasMoreHistory, let beforeId = s.oldestId else { return }
        isLoadingHistory = true
        let conv = activeConv
        let messages = await HTTPService.shared.fetchHistory(limit: 40, beforeId: beforeId, conversation: conv)
        await MainActor.run {
            isLoadingHistory = false
            if messages.isEmpty { s.hasMoreHistory = false; return }
            if messages.count < 40 { s.hasMoreHistory = false }
            s.oldestId = messages.first?.id
            let newBlocks = messages.map { self.historyToBlock($0) }
            s.blocks.insert(contentsOf: newBlocks, at: 0)
            let shift = newBlocks.count
            for key in s.jobMap.keys { s.jobMap[key]? += shift }
            s.assistantIdx? += shift
            reflect(conv)
        }
    }

    // MARK: - Conversation switching
    func switchConversation(_ conv: String) {
        guard conv != activeConv else { return }
        activeConv = conv
        unread.remove(conv)
        stickToBottom = true
        let s = store(conv)
        blocks = s.blocks
        if !s.loaded { loadConvHistory(conv) }
    }

    // MARK: - Send
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        stickToBottom = true
        // 发送始终由秘书处理 → 落主会话；若当前在设备会话，切回主会话。
        if activeConv != ChatViewModel.mainConv { switchConversation(ChatViewModel.mainConv) }
        let s = mainStore
        let now = ISO8601DateFormatter().string(from: Date())
        s.blocks.append(.user(id: UUID(), text: text, ts: now))
        s.blocks.append(.assistant(ChatBlock.AssistantBlock(thinking: true, streaming: true, text: "", trace: [], traceOpen: true, ts: now)))
        s.assistantIdx = s.blocks.count - 1
        reflect(ChatViewModel.mainConv)
        ws.sendMessage(text)
        armReplyTimeout()
    }

    // 清空【当前会话】历史：本地立即清 + 服务端删除。
    func clearActiveHistory() {
        let conv = activeConv
        let s = store(conv)
        s.blocks.removeAll()
        s.assistantIdx = nil
        s.jobMap.removeAll()
        s.oldestId = nil
        s.hasMoreHistory = false
        s.loaded = true
        reflect(conv)
        Task { await HTTPService.shared.clearHistory(conversation: conv) }
    }

    func newSession() {
        let s = mainStore
        s.blocks.removeAll()
        s.assistantIdx = nil
        s.jobMap.removeAll()
        s.oldestId = nil
        s.hasMoreHistory = true
        ws.sendNewSession()
        stickToBottom = true
        if activeConv != ChatViewModel.mainConv { switchConversation(ChatViewModel.mainConv) }
        else { reflect(ChatViewModel.mainConv) }
    }

    func toggleTrace(at index: Int) {
        let s = store(activeConv)
        guard index < s.blocks.count, case .assistant(var a) = s.blocks[index] else { return }
        a.traceOpen.toggle()
        s.blocks[index] = .assistant(a)
        reflect(activeConv)
    }

    func handleConfirm(taskId: String, approved: Bool) {
        ws.sendConfirm(taskId: taskId, approved: approved)
        resolveConfirm(taskId: taskId, approved: approved)
        confirmPending = nil
    }

    // 总是允许：打开自动批准（“我的”里同步）+ 批准本次。
    func handleConfirmAlways(taskId: String) {
        NetworkConfig.shared.autoApproveOperate = true
        handleConfirm(taskId: taskId, approved: true)
    }

    // 用户在截图上拖箭头指了目标：nx,ny 为箭头尖端归一化坐标(0-1000)。
    func handleLocate(taskId: String, nx: Int, ny: Int) {
        ws.sendLocate(taskId: taskId, nx: nx, ny: ny)
        resolveLocate(taskId: taskId, status: .located)
    }

    // 用户选择自己手动处理。
    func handleLocateCancel(taskId: String) {
        ws.sendLocate(taskId: taskId, cancelled: true)
        resolveLocate(taskId: taskId, status: .cancelled)
    }

    private func resolveLocate(taskId: String, status: ChatBlock.LocateStatus) {
        let s = mainStore
        for i in s.blocks.indices {
            if case .locate(var l) = s.blocks[i], l.taskId == taskId, l.resolved == nil {
                l.resolved = status
                s.blocks[i] = .locate(l)
            }
        }
        reflect(ChatViewModel.mainConv)
    }

    private var autoApprovedTasks: Set<String> = []
    // 满足自动批准就直接批准；返回是否已自动处理。
    private func autoApproveIfEnabled(_ taskId: String) -> Bool {
        guard NetworkConfig.shared.autoApproveOperate, !autoApprovedTasks.contains(taskId) else { return false }
        autoApprovedTasks.insert(taskId)
        ws.sendConfirm(taskId: taskId, approved: true)
        resolveConfirm(taskId: taskId, approved: true)
        return true
    }

    // MARK: - Message Handler
    private func handleMessage(_ msg: ChatMessage) {
        switch msg.type {
        case "delta":
            if var a = currentAssistant { a.text += msg.deltaText ?? ""; a.thinking = false; updateAssistant(a) }
            armReplyTimeout()  // 有流式内容 → 重置超时（避免长回复被误判超时）

        case "tool_call":
            if var a = currentAssistant {
                if !a.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    a.trace.append("💭 " + a.text.trimmingCharacters(in: .whitespaces))
                    a.text = ""
                }
                var argsStr = ""
                if let args = msg.toolArgs { argsStr = String(String(describing: args).prefix(120)) }
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
            replyTimeout?.cancel()
            if var a = currentAssistant { a.text = msg.text ?? a.text; a.thinking = false; a.streaming = false; updateAssistant(a) }
            mainStore.assistantIdx = nil

        case "inspiration_saved", "inspiration_updated", "inspiration_deleted":
            // 灵感变更（可能来自任意端）→ 通知灵感页刷新。
            NotificationCenter.default.post(name: .inspirationChanged, object: nil)

        case "job_update":
            handleJobUpdate(msg)

        case "device_message":
            let conv = msg.conversation ?? ChatViewModel.mainConv
            let s = store(conv)
            let ts = msg.created_at ?? ISO8601DateFormatter().string(from: Date())
            if msg.chatRole == "device" {
                s.blocks.append(.device(id: UUID(), text: msg.chatText ?? "", ts: ts))
            } else {
                s.blocks.append(.assistant(ChatBlock.AssistantBlock(thinking: false, streaming: false, text: msg.chatText ?? "", trace: [], traceOpen: false, ts: ts)))
            }
            reflect(conv)

        case "confirm_request":
            if let taskId = msg.taskId {
                let s = mainStore
                let exists = s.blocks.contains { if case .confirm(let c) = $0 { return c.taskId == taskId } else { return false } }
                if !exists {
                    s.blocks.append(.confirm(ChatBlock.ConfirmBlock(taskId: taskId, summary: msg.confirmSummary ?? L("chat.status.confirmRequired"), resolved: nil)))
                    confirmPending = ConfirmRequest(taskId: taskId, summary: msg.confirmSummary ?? "")
                    reflect(ChatViewModel.mainConv)
                }
                _ = autoApproveIfEnabled(taskId)
            }

        case "operate_locate_request":
            if let taskId = msg.taskId, let img = msg.locateImageUrl {
                let s = mainStore
                let exists = s.blocks.contains { if case .locate(let l) = $0 { return l.taskId == taskId } else { return false } }
                if !exists {
                    s.blocks.append(.locate(ChatBlock.LocateBlock(
                        taskId: taskId, imageUrl: img,
                        target: msg.locateTarget ?? "",
                        hint: msg.locateHint ?? L("operate.locate.hint"),
                        resolved: nil)))
                    reflect(ChatViewModel.mainConv)
                }
            }

        case "confirm_resolved":
            resolveConfirm(taskId: msg.taskId ?? "", approved: msg.confirmApproved ?? false)

        case "chat_message":
            let ts = msg.created_at ?? ISO8601DateFormatter().string(from: Date())
            let s = mainStore
            if msg.chatRole == "user" {
                s.blocks.append(.user(id: UUID(), text: msg.chatText ?? "", ts: ts))
            } else if msg.chatRole == "assistant" {
                s.blocks.append(.assistant(ChatBlock.AssistantBlock(thinking: false, streaming: false, text: msg.chatText ?? "", trace: [], traceOpen: false, ts: ts)))
            }
            reflect(ChatViewModel.mainConv)

        case "error":
            replyTimeout?.cancel()
            let s = mainStore
            if s.assistantIdx != nil {
                if var a = currentAssistant { a.thinking = false; a.streaming = false; updateAssistant(a) }
                s.assistantIdx = nil
            }
            s.blocks.append(.error(id: UUID(), text: msg.errorMessage ?? L("chat.status.error")))
            reflect(ChatViewModel.mainConv)

        default: break
        }
    }

    // 流式回合始终属于主会话
    private var currentAssistant: ChatBlock.AssistantBlock? {
        let s = mainStore
        guard let idx = s.assistantIdx, idx < s.blocks.count, case .assistant(let a) = s.blocks[idx] else { return nil }
        return a
    }

    private func updateAssistant(_ a: ChatBlock.AssistantBlock) {
        let s = mainStore
        guard let idx = s.assistantIdx, idx < s.blocks.count else { return }
        s.blocks[idx] = .assistant(a)
        reflect(ChatViewModel.mainConv)
    }

    private func handleJobUpdate(_ msg: ChatMessage) {
        guard let id = msg.jobId else { return }
        let conv = msg.conversation ?? ChatViewModel.mainConv
        let s = store(conv)
        let overall = msg.jobOverall ?? (msg.jobStatus == "done" ? 1.0 : 0.0)
        let pct = min(100, max(0, Int(overall * 100)))

        if let idx = s.jobMap[id] {
            if case .job(var j) = s.blocks[idx] {
                j.pct = pct
                j.status = msg.jobStatus ?? j.status
                j.message = msg.jobMessage ?? j.message
                if let goal = msg.jobGoal { j.goal = goal }
                if let confirmId = msg.jobConfirmTaskId, msg.jobNeedsConfirm == true {
                    j.confirmTaskId = confirmId
                    if autoApproveIfEnabled(confirmId) { j.confirmTaskId = nil }
                }
                if let results = msg.jobResults { j.results = results }
                s.blocks[idx] = .job(j)
                if msg.jobStatus == "done" {
                    s.blocks.append(.done(id: UUID(), goal: j.goal, results: j.results ?? []))
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
            s.jobMap[id] = s.blocks.count
            s.blocks.append(block)
        }
        reflect(conv)
    }

    // 跨所有会话统一更新某确认的状态
    private func resolveConfirm(taskId: String, approved: Bool) {
        for (conv, s) in stores {
            var changed = false
            for i in s.blocks.indices {
                if case .job(var j) = s.blocks[i], j.confirmTaskId == taskId {
                    j.confirmTaskId = nil
                    j.message = approved ? L("chat.status.approved") : L("chat.status.denied")
                    s.blocks[i] = .job(j)
                    changed = true
                }
                if case .confirm(var c) = s.blocks[i], c.taskId == taskId {
                    c.resolved = approved ? .approved : .denied
                    s.blocks[i] = .confirm(c)
                    changed = true
                }
            }
            if changed && conv == activeConv { blocks = s.blocks }
        }
    }
}

// MARK: - Chat Blocks
enum ChatBlock: Identifiable {
    case user(id: UUID, text: String, ts: String?)
    case assistant(AssistantBlock)
    case device(id: UUID, text: String, ts: String?)
    case job(JobBlock)
    case done(id: UUID, goal: String, results: [[String: String]])
    case confirm(ConfirmBlock)
    case locate(LocateBlock)
    case error(id: UUID, text: String)

    // 稳定 id：每个块创建时就固定，供 SwiftUI 做行身份识别。
    var id: String {
        switch self {
        case .user(let id, _, _): return id.uuidString
        case .assistant(let a): return a.id.uuidString
        case .device(let id, _, _): return id.uuidString
        case .job(let j): return j.id.uuidString
        case .done(let id, _, _): return id.uuidString
        case .confirm(let c): return c.id.uuidString
        case .locate(let l): return l.id.uuidString
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

    // operate 人工箭头指位：显示截图，用户拖箭头指目标，tip 坐标回传。
    struct LocateBlock: Hashable {
        let id = UUID()
        var taskId: String
        var imageUrl: String       // 服务端相对路径（如 /files/<id>），显示时拼 baseUrl
        var target: String
        var hint: String
        var resolved: LocateStatus?
    }

    enum ConfirmStatus: Hashable { case approved, denied }
    enum LocateStatus: Hashable { case located, cancelled }

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
