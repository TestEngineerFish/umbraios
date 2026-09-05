import Foundation

// MARK: - WebSocket Chat Connection
@MainActor
class ChatWebSocket: ObservableObject {
    enum ConnectionStatus: String {
        case connecting, online, offline
    }

    @Published private(set) var status: ConnectionStatus = .offline

    private var webSocketTask: URLSessionWebSocketTask?
    // 必须持有 URLSession：局部变量会被 ARC 释放，导致其 WebSocket task 立刻失效（Socket not connected / RST）。
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var backoff: TimeInterval = 1.0
    private let maxBackoff: TimeInterval = 30.0
    private var reconnectTimer: Timer?

    // Handlers
    var onMessage: ((ChatMessage) -> Void)?
    var onStatusChange: ((ConnectionStatus) -> Void)?

    private var wsUrl: String { NetworkConfig.shared.wsUrl }
    private var clientId: String { NetworkConfig.shared.clientId }

    func connect() {
        disconnect()
        setStatus(.connecting)

        guard let url = URL(string: wsUrl) else {
            scheduleReconnect()
            return
        }

        let session = URLSession(configuration: .default)
        self.session = session   // 持有，防止被释放导致连接被拆
        let task = session.webSocketTask(with: url)
        task.resume()
        webSocketTask = task

        // Guard to prevent stale connections
        let currentTask = task

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.webSocketTask === currentTask else { return }
            if currentTask.state == .running {
                self.setStatus(.online)
                self.backoff = 1.0
                self.startReceiving(task: currentTask)
            } else {
                self.setStatus(.offline)
                self.scheduleReconnect()
            }
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    func reconnect() {
        backoff = 1.0
        connect()
    }

    /// conversation：'assistant' 主会话；'device:<id>' = 在某台设备的聊天窗口里说话
    /// （服务端会把「目标设备=这台」注入上下文，端侧任务直接派给它）。
    /// mode：三态 auto / chat / execution，对应输入框左侧的「自动 / 聊天 / 执行」切换。
    /// 服务端 app.py 读的就是这个字段，缺省 auto。
    /// quote：引用注脚（批次 011 ②）。服务端落进这条消息的 meta.quote 并随广播带给各端，
    /// **不进正文** —— 模型看到的引用上下文由端侧自己拼进 content（发出去的是什么，用户看得见）。
    @discardableResult
    func sendMessage(_ content: String, conversation: String = "assistant", mode: String = "auto",
                     quote: ChatQuote? = nil) -> Bool {
        var msg: [String: Any] = [
            "type": "message",
            "content": content,
            "client_id": clientId,
            "auto_approve_operate": NetworkConfig.shared.autoApproveOperate,
            "conversation": conversation,
            "mode": mode
        ]
        if let quote { msg["quote"] = quote.wire }
        return sendJSON(msg)
    }

    /// 停掉正在处理的这次回复（批次 011 ①）。服务端取消该会话在跑的那条 process_message，
    /// 收尾（半截落库 / 系统提示行 / 已执行的工具清单）由服务端做完后以 reply_cancelled 回来 ——
    /// **本端不要自己抢着改气泡**，不然「停了但其实已经答完了」这种时序会两边打架。
    @discardableResult
    func sendCancelReply(conversation: String = "assistant") -> Bool {
        sendJSON(["type": "chat_cancel", "conversation": conversation])
    }

    /// 删一条消息（批次 011 ②）。服务端软删进回收站（30 天），随后广播 message_deleted 给**所有端**
    /// （包括发起端 —— 本端已经删了，重复收到时找不到 id 就当没事）。
    @discardableResult
    func sendDeleteMessage(id: Int) -> Bool {
        sendJSON(["type": "message_delete", "id": id])
    }

    /// 图片消息（批次 011 ③）。文件已先走 POST /files/upload 拿到 file_id，这里只送 id 列表。
    /// 服务端落库 + 跨端广播（回执是 message_saved，带消息 id），**并且从批次 016 起会回复**：
    /// 这一条里的图全部过一遍视觉模型，秘书据此回话。
    /// 所以调用方送完之后要开一轮占位（见 ChatViewModel.beginAssistantTurn）——
    /// 不开的话随后的 delta / reply 找不到落点，会被静默丢掉。
    @discardableResult
    func sendImageMessage(atts: [String], conversation: String = "assistant") -> Bool {
        guard !atts.isEmpty else { return false }
        return sendJSON([
            "type": "message", "kind": "image", "atts": atts,
            "client_id": clientId, "conversation": conversation
        ])
    }

    // B 批改名：确认单号叫 confirm_id，不再冒充任务 id（原 job_confirm_response + task_id）。
    @discardableResult
    func sendConfirm(confirmId: String, approved: Bool) -> Bool {
        let msg: [String: Any] = [
            "type": "confirm_response",
            "confirm_id": confirmId,
            "approved": approved
        ]
        return sendJSON(msg)
    }

    // 不带 runId = 停掉所有正在跑的操控（服务端语义）。
    func sendOperateStop(runId: String? = nil) {
        guard let task = webSocketTask, task.state == .running else { return }
        var msg: [String: Any] = ["type": "operate_stop"]
        if let runId { msg["run_id"] = runId }
        sendJSON(msg)
    }

    // operate 人工求助回传，三选一：
    //   箭头指位 nx,ny(归一化0-1000) / 文字纠偏 feedback / 暂停我来 paused。
    // ask_id 是这次求助的单号（B 批改名，原 task_id）—— 一次操控可能求助多次。
    func sendLocate(askId: String, nx: Int? = nil, ny: Int? = nil,
                    feedback: String? = nil, paused: Bool = false) {
        guard let task = webSocketTask, task.state == .running else { return }
        var msg: [String: Any] = ["type": "operate_locate_response", "ask_id": askId]
        if paused {
            msg["paused"] = true
        } else if let feedback, !feedback.isEmpty {
            msg["feedback"] = feedback
        } else if let nx, let ny {
            msg["nx"] = nx
            msg["ny"] = ny
        }
        sendJSON(msg)
    }

    // operate 暂停后「继续」：让服务端重新看屏、从当前状态接着干。按 run_id 走 ——
    // 服务端等的是「这次运行能接着跑了」，不是某张求助单。
    func sendResume(runId: String) {
        guard let task = webSocketTask, task.state == .running else { return }
        sendJSON(["type": "operate_resume", "run_id": runId])
    }

    /// 开新话题。返回值 = 「/new 交出去了吗」—— 调用方要靠它决定该不该清本地历史。
    @discardableResult
    func sendNewSession() -> Bool {
        sendMessage("/new")
    }

    /// 问答卡一次性提交（多题一起交，和 PC 端同一个协议）。
    /// answers 的形状是「题目 id → 选中项数组」；自己填的内容作为**额外一项**追加进数组，
    /// 而不是替换掉选项 —— 用户总有你没想到的答案，两者并存服务端才拼得出完整上下文。
    @discardableResult
    func sendAnswers(cardId: String, answers: [String: [String]]) -> Bool {
        sendJSON(["type": "question_answer", "card_id": cardId, "answers": answers])
    }

    // MARK: - Private
    /// 返回值 = 「这一帧交出去了吗」。**不是**「服务端收到了吗」—— URLSession 的发送是异步的，
    /// 真正的失败（连接半死）只能靠回调打印。但「离线时压根没发出去」这一种必须让调用方知道：
    /// 不知道的话界面就会摆出一副发出去了的样子，然后干等到超时（批次 011 前的老毛病）。
    @discardableResult
    private func sendJSON(_ json: [String: Any]) -> Bool {
        guard let task = webSocketTask, task.state == .running else { return false }
        // 必须发「文本帧」：服务端 chat_ws 用 receive_text() 只收文本帧；
        // 发 .data（二进制帧）会让服务端解析失败并关闭连接（表现为 Socket not connected / RST）。
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return false }
        task.send(.string(text)) { error in
            if let error {
                print("[ChatWebSocket] Send error: \(error)")
            }
        }
        return true
    }

    private func startReceiving(task: URLSessionWebSocketTask) {
        receiveTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    await handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        print("[ChatWebSocket] Receive error: \(error)")
                        // 连接中途断开（如 Socket not connected）：标记离线并自动重连，
                        // 否则界面会永远卡在 loading 等一个不会来的回复。
                        if self.webSocketTask === task {
                            self.webSocketTask = nil
                            self.setStatus(.offline)
                            self.scheduleReconnect()
                        }
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        let string: String
        switch message {
        case .string(let s): string = s
        case .data(let d): string = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }

        guard let data = string.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        await MainActor.run {
            let chatMsg = ChatMessage(json: json)
            onMessage?(chatMsg)
        }
    }

    private func setStatus(_ newStatus: ConnectionStatus) {
        status = newStatus
        onStatusChange?(newStatus)
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: backoff, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.connect()
            }
        }
        backoff = min(backoff * 2, maxBackoff)
    }
}

// MARK: - Chat Message
struct ChatMessage {
    let type: String
    let json: [String: Any]

    init(json: [String: Any]) {
        self.type = json["type"] as? String ?? ""
        self.json = json
    }

    // reply
    var text: String? { json["text"] as? String }
    var sessionId: Int? { json["session_id"] as? Int }

    // delta
    var deltaText: String? { json["text"] as? String }

    // tool_call
    var toolName: String? { json["name"] as? String }
    var toolArgs: [String: Any]? { json["args"] as? [String: Any] }

    // tool_result
    var toolResultPreview: String? { json["preview"] as? String }

    // task_update（引擎里程碑 + 电脑操控共用；B 批起 job_update 已死）
    var taskId: String? { json["task_id"] as? String }
    var taskGoal: String? { json["goal"] as? String }
    var taskStatus: String? { json["status"] as? String }
    var taskMessage: String? { json["message"] as? String }
    var taskOverall: Double? { json["overall"] as? Double }
    var taskResults: [[String: String]]? { json["results"] as? [[String: String]] }
    var taskEvent: String? { json["event"] as? String }
    var taskNeedsConfirm: Bool? { json["needs_confirm"] as? Bool }
    /// 这次操控运行的编号（operate 的 task_update / locate_request 带；停止与继续按它走）。
    var runId: String? { json["run_id"] as? String }

    // confirm_request / confirm_resolved（B 批改名：单号叫 confirm_id，不再冒充任务 id）
    var confirmId: String? { json["confirm_id"] as? String }
    var confirmSummary: String? { json["summary"] as? String }
    var confirmDetail: Any? { json["detail"] }
    var confirmApproved: Bool? { json["approved"] as? Bool }

    // operate_locate_request（人工箭头指位）。ask_id = 这次求助的单号。
    var askId: String? { json["ask_id"] as? String }
    var locateImageUrl: String? { json["image_url"] as? String }
    var locateTarget: String? { json["target"] as? String }
    var locateHint: String? { json["hint"] as? String }

    // chat_message (cross-end sync)
    var chatRole: String? { json["role"] as? String }
    var chatText: String? { json["text"] as? String }
    var created_at: String? { json["created_at"] as? String }

    // question_card（问答卡：秘书在派活之前把歧义问清楚）
    var cardId: String? { json["card_id"] as? String }
    var cardTitle: String? { json["title"] as? String }
    /// 服务端已经把题目规整过（补齐 id / options / optional / allow_custom），这里只做类型转换，
    /// **不再补默认值** —— 客户端自己猜默认值会和服务端的规整规则慢慢分叉。
    var cardQuestions: [[String: Any]]? { json["questions"] as? [[String: Any]] }

    // 会话归属（task_update 带 'device:<id>'；无则视为主会话 'assistant'）
    var conversation: String? { json["conversation"] as? String }

    /// history_cleared：发起这次清空的客户端 id（服务端把 /history/clear 收到的
    /// client_id 原样回填）。广播是发给**所有**在线端的，本端也会收到自己那一条 ——
    /// 拿它跟 NetworkConfig.shared.clientId 比一下，才知道该不该插「别的端清空了」那行提示。
    /// 老服务端不带这个字段，取到 nil，此时一律当成别人清的（宁可多一行提示）。
    var clearedBy: String? { json["by"] as? String }

    // error
    var errorMessage: String? { json["message"] as? String }

    // ── 批次 011 消息层：id / kind / atts / meta ────────────────────────────
    // 服务端的一条消息现在有身份（id）和类型（kind），还能带附件与元信息。
    // 端上的引用、删除、图片消息全指着这几个取值器 —— 老服务端不带就取到 nil，各处按「没有」处理。

    /// 消息 id（chat_message 广播 / message_saved 回执 / message_deleted 都带）。
    /// 服务端给的是整数；JSON 里可能被解析成 NSNumber，用 as? Int 取不到时兜一层。
    var messageId: Int? {
        if let n = json["id"] as? Int { return n }
        if let n = json["id"] as? NSNumber { return n.intValue }
        return nil
    }
    /// text / image / system。老服务端不带 → nil，调用方当 text。
    var kind: String? { json["kind"] as? String }
    /// 附件的 file_id 列表（kind=image；批次 013 起 kind=text 也可能带）。
    var atts: [String]? { (json["atts"] as? [Any])?.compactMap { $0 as? String } }
    /// 附加信息（quote / interrupted / cancelled / tools）。
    var meta: [String: Any]? { json["meta"] as? [String: Any] }
    /// 引用注脚：气泡顶部那块「引用 X」靠它渲染。
    var metaQuote: ChatQuote? { ChatQuote(json: meta?["quote"] as? [String: Any]) }
    /// 这条是「停在半截」的回复（reply_cancelled 的第一种收尾）：时间戳后缀「只写到这里」。
    var metaInterrupted: Bool { (meta?["interrupted"] as? Bool) ?? false }
    /// 这条是「一个字都没流出来就停了」的系统提示行（第二种收尾）。
    var metaCancelled: Bool { (meta?["cancelled"] as? Bool) ?? false }
    /// 停之前已经执行掉的工具（琥珀行「已经动过 X」靠它说得具体）。
    var metaTools: [ChatToolRun] {
        ((meta?["tools"] as? [[String: Any]]) ?? []).compactMap { ChatToolRun(json: $0) }
    }
    /// message_saved 的回执里也带 content（发起端拿它对齐乐观气泡）。
    var savedContent: String? { json["content"] as? String }
}

// MARK: - 引用与工具留痕（批次 011）

/// 消息的引用注脚。**只有三个字段**：被引消息的 id、谁说的、摘要 —— meta 是要进库的，
/// 不给客户端塞任意结构的口子（服务端 app.py 也是这么收的，text 截 200）。
struct ChatQuote: Equatable, Hashable {
    var id: Int?
    /// "user" / "assistant"：决定气泡顶部写「引用 我」还是「引用 秘书」。
    var role: String
    var text: String

    init(id: Int?, role: String, text: String) {
        self.id = id
        self.role = role
        self.text = String(text.prefix(200))
    }

    init?(json: [String: Any]?) {
        guard let json, let text = json["text"] as? String, !text.isEmpty else { return nil }
        self.id = (json["id"] as? Int) ?? (json["id"] as? NSNumber)?.intValue
        self.role = (json["role"] as? String) ?? "user"
        self.text = String(text.prefix(200))
    }

    var wire: [String: Any] {
        var d: [String: Any] = ["role": role, "text": text]
        if let id { d["id"] = id }
        return d
    }
}

/// 取消收尾里「已经跑掉的那些工具」。name 是工具名，args 是参数摘要（服务端已截到 200）。
struct ChatToolRun: Equatable, Hashable {
    let name: String
    let args: String

    init(name: String, args: String) {
        self.name = name
        self.args = args
    }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        self.name = name
        self.args = (json["args"] as? String) ?? ""
    }
}
