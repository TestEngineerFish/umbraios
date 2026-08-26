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
    func sendMessage(_ content: String, conversation: String = "assistant", mode: String = "auto") {
        guard let task = webSocketTask, task.state == .running else { return }
        let msg: [String: Any] = [
            "type": "message",
            "content": content,
            "client_id": clientId,
            "auto_approve_operate": NetworkConfig.shared.autoApproveOperate,
            "conversation": conversation,
            "mode": mode
        ]
        sendJSON(msg)
    }

    // B 批改名：确认单号叫 confirm_id，不再冒充任务 id（原 job_confirm_response + task_id）。
    func sendConfirm(confirmId: String, approved: Bool) {
        guard let task = webSocketTask, task.state == .running else { return }
        let msg: [String: Any] = [
            "type": "confirm_response",
            "confirm_id": confirmId,
            "approved": approved
        ]
        sendJSON(msg)
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

    func sendNewSession() {
        sendMessage("/new")
    }

    /// 问答卡一次性提交（多题一起交，和 PC 端同一个协议）。
    /// answers 的形状是「题目 id → 选中项数组」；自己填的内容作为**额外一项**追加进数组，
    /// 而不是替换掉选项 —— 用户总有你没想到的答案，两者并存服务端才拼得出完整上下文。
    func sendAnswers(cardId: String, answers: [String: [String]]) {
        guard let task = webSocketTask, task.state == .running else { return }
        sendJSON(["type": "question_answer", "card_id": cardId, "answers": answers])
    }

    // MARK: - Private
    private func sendJSON(_ json: [String: Any]) {
        // 必须发「文本帧」：服务端 chat_ws 用 receive_text() 只收文本帧；
        // 发 .data（二进制帧）会让服务端解析失败并关闭连接（表现为 Socket not connected / RST）。
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { error in
            if let error {
                print("[ChatWebSocket] Send error: \(error)")
            }
        }
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
}
