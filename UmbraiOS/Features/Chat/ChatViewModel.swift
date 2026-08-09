import Foundation

// MARK: - Chat ViewModel
//
// 联系人式多会话（与 PC 端一致）：
//   - "assistant"   = 你↔秘书主会话
//   - "device:<id>" = 与某台设备的会话：可直接发消息，服务端会把「目标设备=这台」注入上下文，
//                     端侧任务直接派给它；这台设备的编排流也落在同一个会话里。
//   每个会话各自维护 blocks/分页/未读；服务端给所有推送打了 conversation 标签，据此路由。
@MainActor
class ChatViewModel: ObservableObject {
    static let mainConv = "assistant"

    // 当前会话的消息（驱动列表渲染）
    @Published var blocks: [ChatBlock] = []
    // 会话切换
    @Published var activeConv: String = ChatViewModel.mainConv
    @Published var conversationOrder: [String] = [ChatViewModel.mainConv]
    @Published var unread: Set<String> = []
    // 联系人列表：所有已知设备（含离线）+ 各会话的最后一条消息预览
    @Published var devices: [KnownDevice] = []
    @Published var previews: [String: ConvPreview] = [:]

    struct ConvPreview: Equatable {
        var text: String = ""
        var at: String? = nil
    }

    @Published var draft: String = ""
    /// 对话模式：自动 / 聊天 / 执行。服务端 app.py 读 message 里的 mode 字段（auto / chat / execution）。
    /// 存本地是因为它是「我这台设备当前怎么用秘书」，跨设备各选各的，不该跟着账号走。
    @Published var mode: ChatMode = ChatMode(rawValue: UserDefaults.standard.string(forKey: "umbra.chat.mode") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "umbra.chat.mode") }
    }
    @Published var isThinking: Bool = false
    // showAttachSheet / showVoiceOverlay / showLightbox / lightboxImageURL 四个已删：
    // 它们只被旧的 ChatView 用过，那个文件已经不在了。新的对话页用自己的 @State 管这些瞬时状态。
    @Published var confirmPending: ConfirmRequest?

    let ws = ChatWebSocket()

    // 正在等回复的会话（流式 token / reply 归属它；服务端也会给事件打 conversation 标签，这里是兜底）。
    private var pendingConv: String = ChatViewModel.mainConv

    // 回复超时兜底：发出后一段时间没有任何回复/流式内容，就把「思考中」气泡收尾为错误，
    // 避免连接中途断开时界面永远 loading。
    private var replyTimeout: Task<Void, Never>?
    /// **静默**多久算这一轮没戏了。注意是「一点动静都没有」的时长，不是整轮耗时 ——
    /// 带工具的一轮跑几分钟很正常（服务端日志里单次请求就要 20 秒往上），
    /// 按总耗时判会把正常的长任务全判成超时。
    private static let idleTimeoutNs: UInt64 = 120_000_000_000   // 120s

    private func armReplyTimeout() {
        replyTimeout?.cancel()
        replyTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleTimeoutNs)
            guard let self, !Task.isCancelled else { return }
            self.failPendingTurn()
        }
    }

    /// 这一轮收尾（拿到 reply / 出错）→ 停表并置空。
    /// 置 nil 而不只是 cancel：handleMessage 靠它判断「还在等这一轮吗」，
    /// 不置空的话闲置期间收到别的推送也会白白重起一个计时器。
    private func stopReplyTimeout() {
        replyTimeout?.cancel()
        replyTimeout = nil
    }
    private func failPendingTurn() {
        let conv = pendingConv
        let s = store(conv)
        guard let idx = s.assistantIdx, idx < s.blocks.count else { return }
        if case .assistant(var a) = s.blocks[idx] {
            a.thinking = false
            a.streaming = false
            s.blocks[idx] = .assistant(a)
        }
        s.assistantIdx = nil
        replyTimeout = nil
        s.blocks.append(.error(id: UUID(), text: L("chat.status.timeout")))
        reflect(conv)
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

    func convLabel(_ conv: String) -> String {
        if conv == ChatViewModel.mainConv { return L("chat.conv.secretary") }
        if let d = device(for: conv) { return d.device_name }
        if conv.hasPrefix("device:") { return String(conv.dropFirst("device:".count)) }
        return conv
    }

    func device(for conv: String) -> KnownDevice? {
        guard conv.hasPrefix("device:") else { return nil }
        let id = String(conv.dropFirst("device:".count))
        return devices.first { $0.device_id == id }
    }

    /// 联系人顺序：秘书恒在首位 → 在线设备 → 离线设备（服务端已排好序）。
    var contacts: [String] {
        [ChatViewModel.mainConv] + devices.map(\.conversation)
    }

    init() {
        setupWebSocket()
    }

    // MARK: - Devices（联系人列表）
    func loadDevices() {
        Task { await reloadDevices() }
    }

    /// 下拉刷新用的可等待版本 —— .refreshable 需要 async 才能让刷新圈转到数据回来。
    func reloadDevices() async {
        let list = await HTTPService.shared.fetchAllDevices()
        // 拉失败（nil）保留旧联系人，别把列表清成只剩秘书。
        if let list { await MainActor.run { self.devices = list } }
    }

    func forgetDevice(_ deviceId: String) {
        Task {
            if await HTTPService.shared.forgetDevice(deviceId) {
                await MainActor.run { self.devices.removeAll { $0.device_id == deviceId } }
            }
        }
    }

    private func setPreview(_ conv: String, _ text: String, _ at: String?) {
        guard !text.isEmpty else { return }
        previews[conv] = ConvPreview(text: text, at: at)
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
            if status == .offline, self.store(self.pendingConv).assistantIdx != nil {
                self.stopReplyTimeout()
                self.failPendingTurn()
            }
        }
        ws.connect()
        loadHistory()
        loadConversationsList()
        loadDevices()
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
                for r in rows {
                    _ = self.store(r.conversation)
                    self.setPreview(r.conversation, r.last_content, r.last_at)
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

    /// 当前会话还能往前翻吗。不是 @Published，但它只在 blocks 变化时会变，
    /// 而 blocks 是 @Published —— 读它的视图该刷新的时候都会刷新。
    var canLoadOlder: Bool {
        let s = store(activeConv)
        return s.hasMoreHistory && !s.blocks.isEmpty
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
        activeConv = conv
        unread.remove(conv)
        stickToBottom = true
        let s = store(conv)
        blocks = s.blocks
        if !s.loaded { loadConvHistory(conv) }
    }

    // MARK: - Send
    // 发到**当前会话**：主会话=直接跟秘书说；设备会话=对着这台设备说（秘书按「目标设备=这台」执行）。
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        stickToBottom = true
        let conv = activeConv
        let s = store(conv)
        let now = ISO8601DateFormatter().string(from: Date())
        s.blocks.append(.user(id: UUID(), text: text, ts: now))
        s.blocks.append(.assistant(ChatBlock.AssistantBlock(thinking: true, streaming: true, text: "", trace: [], traceOpen: true, ts: now)))
        s.assistantIdx = s.blocks.count - 1
        setPreview(conv, text, now)
        reflect(conv)
        ws.sendMessage(text, conversation: conv, mode: mode.rawValue)
        pendingConv = conv
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
        previews[conv] = nil
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

    // MARK: - 问答卡
    //
    // 作答状态存在块里（见 QuestionBlock），这里只做「找到那张卡 → 改它 → 反映到 UI」。
    // 每个方法都按 cardId 找，而不是按下标 —— 补拉历史会往前插消息，下标会整体位移。

    private func mutateQuestion(_ cardId: String, _ body: (inout ChatBlock.QuestionBlock) -> Void) {
        for (conv, s) in stores {
            var changed = false
            for i in s.blocks.indices {
                if case .question(var q) = s.blocks[i], q.cardId == cardId {
                    body(&q)
                    s.blocks[i] = .question(q)
                    changed = true
                }
            }
            if changed { reflect(conv) }
        }
    }

    /// 选一个选项。多选=切换；单选=替换（再点一次可以取消，和 PC 端一致）。
    func pickAnswer(cardId: String, questionId: String, option: String, multi: Bool) {
        mutateQuestion(cardId) { q in
            guard !q.done else { return }
            var cur = q.picked[questionId] ?? []
            if multi {
                if let k = cur.firstIndex(of: option) { cur.remove(at: k) } else { cur.append(option) }
            } else {
                cur = cur.contains(option) ? [] : [option]
            }
            q.picked[questionId] = cur
        }
    }

    func setCustomAnswer(cardId: String, questionId: String, text: String) {
        mutateQuestion(cardId) { q in
            guard !q.done else { return }
            q.custom[questionId] = text
        }
    }

    /// 翻题。夹在 0…题数-1，越界就停在边界上（不要环绕，用户会以为提交了）。
    func moveQuestion(cardId: String, by delta: Int) {
        mutateQuestion(cardId) { q in
            guard !q.done else { return }
            q.at = min(max(0, q.at + delta), max(0, q.questions.count - 1))
        }
    }

    /// 提交整张卡。必答题没答完就直接不提交 —— 界面上提交键此时是置灰的，
    /// 这里是第二道闸（多端同时操作、或者题目在提交瞬间被改）。
    func submitAnswers(cardId: String) {
        var payload: [String: [String]] = [:]
        var pairs: [(q: String, v: String)] = []
        var ok = false
        mutateQuestion(cardId) { q in
            guard !q.done, q.allFilled else { return }
            payload.removeAll()
            pairs.removeAll()
            for item in q.questions {
                var vals = q.picked[item.id] ?? []
                let c = (q.custom[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !c.isEmpty { vals.append(c) }   // 自己填的与选项并存
                payload[item.id] = vals
                pairs.append((q: item.text, v: vals.isEmpty ? "（跳过）" : vals.joined(separator: "、")))
            }
            q.done = true
            q.answered = pairs
            ok = true
        }
        guard ok else { return }
        ws.sendAnswers(cardId: cardId, answers: payload)
    }

    /// 别的端答完了：本端标成已完成。没有答案明细可展示，就不编 —— 只显示「已答完」。
    private func resolveQuestion(cardId: String) {
        mutateQuestion(cardId) { q in q.done = true }
    }

    // 总是允许：打开自动批准（“我的”里同步）+ 批准本次。
    func handleConfirmAlways(taskId: String) {
        NetworkConfig.shared.autoApproveOperate = true
        handleConfirm(taskId: taskId, approved: true)
    }

    // ① 箭头指位：nx,ny 为箭头尖端归一化坐标(0-1000)。
    func handleLocate(taskId: String, nx: Int, ny: Int) {
        ws.sendLocate(taskId: taskId, nx: nx, ny: ny)
        resolveLocate(taskId: taskId, status: .located)
    }

    // ② 文字纠偏：把「哪错了」发给 AI，让它自己调整步骤/判断。
    func handleLocateFeedback(taskId: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        ws.sendLocate(taskId: taskId, feedback: t)
        resolveLocate(taskId: taskId, status: .feedbackSent)
    }

    // ③ 暂停我来：任务挂起，用户手动处理；卡片随后出现「继续」。
    func handleLocatePause(taskId: String) {
        ws.sendLocate(taskId: taskId, paused: true)
        resolveLocate(taskId: taskId, status: .paused)
    }

    // 用户手动处理完点「继续」：唤醒任务，AI 重新看屏接着干。
    func handleResume(jobId: String, taskId: String) {
        guard !jobId.isEmpty else { return }
        ws.sendResume(jobId: jobId)
        resolveLocate(taskId: taskId, status: .resumed)
    }

    private func resolveLocate(taskId: String, status: ChatBlock.LocateStatus) {
        let s = mainStore
        for i in s.blocks.indices {
            if case .locate(var l) = s.blocks[i], l.taskId == taskId {
                // paused → resumed 允许再次更新；其它状态定型后不再改。
                if l.resolved == nil || (l.resolved == .paused && status == .resumed) {
                    l.resolved = status
                    s.blocks[i] = .locate(l)
                }
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
        // 流式一类事件归属「服务端标注的会话」，缺省回落到正在等回复的会话。
        let streamConv = msg.conversation ?? pendingConv
        // **收到任何一条服务端消息都重置静默计时**。
        // 原来只有 delta 会重置，可一轮里很可能一个 delta 都没有 ——
        // 模型直接吐工具调用时只有 tool_call / tool_result / node，
        // 问答卡那一轮更是只有 question_card，于是 60 秒一到就误报「连接中断」，
        // 而连接其实好好的（所以点「重新连接」也没用）。用户实测点名。
        if replyTimeout != nil { armReplyTimeout() }
        switch msg.type {
        case "delta":
            if var a = currentAssistant(streamConv) { a.text += msg.deltaText ?? ""; a.thinking = false; updateAssistant(a, streamConv) }

        case "tool_call":
            if var a = currentAssistant(streamConv) {
                if !a.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    a.trace.append("💭 " + a.text.trimmingCharacters(in: .whitespaces))
                    a.text = ""
                }
                var argsStr = ""
                if let args = msg.toolArgs { argsStr = String(String(describing: args).prefix(120)) }
                a.trace.append("🔧 \(msg.toolName ?? "unknown")(\(argsStr))")
                updateAssistant(a, streamConv)
            }

        case "tool_result":
            if var a = currentAssistant(streamConv) {
                let preview = msg.toolResultPreview ?? ""
                let truncated = preview.count > 160 ? preview.prefix(160) + "…" : preview
                a.trace.append("↳ \(msg.toolName ?? "unknown") → \(truncated)")
                updateAssistant(a, streamConv)
            }

        case "reply":
            stopReplyTimeout()
            if var a = currentAssistant(streamConv) { a.text = msg.text ?? a.text; a.thinking = false; a.streaming = false; updateAssistant(a, streamConv) }
            store(streamConv).assistantIdx = nil
            setPreview(streamConv, msg.text ?? "", ISO8601DateFormatter().string(from: Date()))

        case "device_presence":
            loadDevices()  // 设备上下线 → 刷新联系人列表（在线状态 / 能力目录）

        case "inspiration_saved", "inspiration_updated", "inspiration_deleted":
            // 灵感变更（可能来自任意端）→ 通知灵感页刷新。
            NotificationCenter.default.post(name: .inspirationChanged, object: nil)

        case "reminder_updated", "reminder_deleted":
            // 提醒变更（秘书在聊天里建/改/撤，或别的端改的）→ **立刻拉一次**。
            // 不能等下一轮定时同步：用户说「5 分钟后提醒我」，秘书答应了，
            // 这台手机却还不知道有这条，到点什么也不会响。
            // 拉完 ReminderStore 会顺手重排本机的本地通知（applyMerged 里做）。
            ReminderStore.shared.syncNow()

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
            setPreview(conv, msg.chatText ?? "", ts)
            reflect(conv)

        case "confirm_request":
            if let taskId = msg.taskId {
                let conv = msg.conversation ?? ChatViewModel.mainConv
                let s = store(conv)
                let exists = s.blocks.contains { if case .confirm(let c) = $0 { return c.taskId == taskId } else { return false } }
                if !exists {
                    s.blocks.append(.confirm(ChatBlock.ConfirmBlock(taskId: taskId, summary: msg.confirmSummary ?? L("chat.status.confirmRequired"), resolved: nil)))
                    confirmPending = ConfirmRequest(taskId: taskId, summary: msg.confirmSummary ?? "")
                    reflect(conv)
                }
                _ = autoApproveIfEnabled(taskId)
            }

        case "operate_locate_request":
            if let taskId = msg.taskId, let img = msg.locateImageUrl {
                let s = mainStore
                let exists = s.blocks.contains { if case .locate(let l) = $0 { return l.taskId == taskId } else { return false } }
                if !exists {
                    s.blocks.append(.locate(ChatBlock.LocateBlock(
                        taskId: taskId, jobId: msg.jobId ?? "", imageUrl: img,
                        target: msg.locateTarget ?? "",
                        hint: msg.locateHint ?? L("operate.locate.hint"),
                        resolved: nil)))
                    reflect(ChatViewModel.mainConv)
                }
            }

        case "question_card":
            // 问答卡不落 messages 表，只走广播；服务端会在新连接握手时补发未答的卡，
            // 所以这里必须按 card_id 去重，否则重连一次就多出一张一模一样的卡。
            if let cardId = msg.cardId, !cardId.isEmpty {
                let conv = msg.conversation ?? ChatViewModel.mainConv
                let s = store(conv)
                let exists = s.blocks.contains {
                    if case .question(let q) = $0 { return q.cardId == cardId } else { return false }
                }
                let items = (msg.cardQuestions ?? []).compactMap { ChatBlock.QuestionItem(json: $0) }
                if !exists && !items.isEmpty {
                    let title = msg.cardTitle ?? ""
                    s.blocks.append(.question(ChatBlock.QuestionBlock(
                        cardId: cardId, title: title, questions: items)))
                    setPreview(conv, title.isEmpty ? "有几个问题要确认" : title,
                               ISO8601DateFormatter().string(from: Date()))
                    reflect(conv)
                }
            }

        case "question_resolved":
            // 别的端已经答过了 → 本端把卡标成已完成，别重复作答。
            if let cardId = msg.cardId { resolveQuestion(cardId: cardId) }

        case "history_cleared":
            // 别的端清空了某个会话 → 本端同步清空，并留一行说明，
            // 否则用户会以为是自己这边把消息弄丢了。
            let conv = msg.conversation ?? ChatViewModel.mainConv
            let s = store(conv)
            s.blocks.removeAll()
            s.assistantIdx = nil
            s.jobMap.removeAll()
            s.oldestId = nil
            s.hasMoreHistory = false
            s.loaded = true
            previews[conv] = nil
            s.blocks.append(.note(id: UUID(), text: "电脑端清空了这段聊天历史"))
            reflect(conv)

        case "confirm_resolved":
            resolveConfirm(taskId: msg.taskId ?? "", approved: msg.confirmApproved ?? false)

        case "chat_message":
            // 其它端发出的消息（跨端同步），落到它所属的会话。
            let conv = msg.conversation ?? ChatViewModel.mainConv
            let ts = msg.created_at ?? ISO8601DateFormatter().string(from: Date())
            let s = store(conv)
            if msg.chatRole == "user" {
                s.blocks.append(.user(id: UUID(), text: msg.chatText ?? "", ts: ts))
            } else if msg.chatRole == "assistant" {
                s.blocks.append(.assistant(ChatBlock.AssistantBlock(thinking: false, streaming: false, text: msg.chatText ?? "", trace: [], traceOpen: false, ts: ts)))
            }
            setPreview(conv, msg.chatText ?? "", ts)
            reflect(conv)

        case "error":
            stopReplyTimeout()
            let s = store(streamConv)
            if s.assistantIdx != nil {
                if var a = currentAssistant(streamConv) { a.thinking = false; a.streaming = false; updateAssistant(a, streamConv) }
                s.assistantIdx = nil
            }
            s.blocks.append(.error(id: UUID(), text: msg.errorMessage ?? L("chat.status.error")))
            reflect(streamConv)

        default: break
        }
    }

    // 某会话正在流式输出的助手气泡
    private func currentAssistant(_ conv: String) -> ChatBlock.AssistantBlock? {
        let s = store(conv)
        guard let idx = s.assistantIdx, idx < s.blocks.count, case .assistant(let a) = s.blocks[idx] else { return nil }
        return a
    }

    private func updateAssistant(_ a: ChatBlock.AssistantBlock, _ conv: String) {
        let s = store(conv)
        guard let idx = s.assistantIdx, idx < s.blocks.count else { return }
        s.blocks[idx] = .assistant(a)
        reflect(conv)
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
        setPreview(conv, msg.jobMessage ?? msg.jobGoal ?? "", ISO8601DateFormatter().string(from: Date()))
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

// MARK: - 对话模式
//
// 取值是服务端约定的 auto / chat / execution；中文名只用于界面。
enum ChatMode: String, CaseIterable, Hashable {
    case auto, chat, execution

    var label: String {
        switch self {
        case .auto: return "自动"
        case .chat: return "聊天"
        case .execution: return "执行"
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
    case question(QuestionBlock)
    /// 居中的一行系统说明（如「电脑端清空了这段聊天历史」）。不是气泡，不属于任何一方。
    case note(id: UUID, text: String)
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
        case .question(let q): return q.id.uuidString
        case .note(let id, _): return id.uuidString
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

    // operate 人工求助：显示截图；用户可①拖箭头指位 ②文字纠偏 ③暂停我来（之后可继续）。
    struct LocateBlock: Hashable {
        let id = UUID()
        var taskId: String
        var jobId: String
        var imageUrl: String       // 服务端相对路径（如 /files/<id>），显示时拼 baseUrl
        var target: String
        var hint: String
        var resolved: LocateStatus?
    }

    /// 问答卡里的一道题。字段与服务端 questions.normalize() 的输出一一对应。
    struct QuestionItem: Hashable, Identifiable {
        var id: String
        var text: String
        var multi: Bool
        var options: [String]
        var optional: Bool
        /// 服务端**强制**为 true（每题都留一个「自己填」的口子），这里仍然按收到的值走，
        /// 不在客户端写死 —— 写死了协议改动就发现不了。
        var allowCustom: Bool

        init?(json: [String: Any]) {
            guard let id = json["id"] as? String, let text = json["text"] as? String,
                  !id.isEmpty, !text.isEmpty else { return nil }
            self.id = id
            self.text = text
            self.multi = json["multi"] as? Bool ?? false
            self.options = (json["options"] as? [String]) ?? []
            self.optional = json["optional"] as? Bool ?? false
            self.allowCustom = json["allow_custom"] as? Bool ?? true
        }
    }

    /// 问答卡（QuestionCard）：分页式多题，一次性提交。
    /// 作答过程（当前第几题 / 选了什么 / 自己填了什么）就存在这个块里 ——
    /// 放 ViewModel 的全局字段会让两张同时在场的卡互相踩。
    struct QuestionBlock: Hashable {
        let id = UUID()
        var cardId: String
        var title: String
        var questions: [QuestionItem]
        /// 当前题序号。
        var at: Int = 0
        /// 题目 id → 选中的选项文本。
        var picked: [String: [String]] = [:]
        /// 题目 id → 自己填的内容。
        var custom: [String: String] = [:]
        /// 已提交（本端提交，或别的端先答了收到 question_resolved）。
        var done: Bool = false
        /// 提交后展示的「题 → 答」配对，供用户回看自己答了什么。
        var answered: [(q: String, v: String)] = []

        static func == (l: QuestionBlock, r: QuestionBlock) -> Bool {
            l.id == r.id && l.at == r.at && l.picked == r.picked
                && l.custom == r.custom && l.done == r.done
                && l.answered.map(\.v) == r.answered.map(\.v)
        }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }

        /// 某题是否已经答了（可选题永远算答了）。
        func filled(_ q: QuestionItem) -> Bool {
            if q.optional { return true }
            if !(picked[q.id] ?? []).isEmpty { return true }
            return !(custom[q.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        var allFilled: Bool { questions.allSatisfy { filled($0) } }
    }

    enum ConfirmStatus: Hashable { case approved, denied }
    // located=已指位；feedbackSent=已发纠偏；paused=已暂停(可继续)；resumed=已点继续
    enum LocateStatus: Hashable { case located, feedbackSent, paused, resumed }

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
