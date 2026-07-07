import Foundation

// MARK: - WebSocket Chat Connection
@MainActor
class ChatWebSocket: ObservableObject {
    enum ConnectionStatus: String {
        case connecting, online, offline
    }

    @Published private(set) var status: ConnectionStatus = .offline

    private var webSocketTask: URLSessionWebSocketTask?
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

    func sendMessage(_ content: String) {
        guard let task = webSocketTask, task.state == .running else { return }
        let msg: [String: Any] = [
            "type": "message",
            "content": content,
            "client_id": clientId
        ]
        sendJSON(msg)
    }

    func sendConfirm(taskId: String, approved: Bool) {
        guard let task = webSocketTask, task.state == .running else { return }
        let msg: [String: Any] = [
            "type": "job_confirm_response",
            "task_id": taskId,
            "approved": approved
        ]
        sendJSON(msg)
    }

    func sendOperateStop(jobId: String? = nil) {
        guard let task = webSocketTask, task.state == .running else { return }
        var msg: [String: Any] = ["type": "operate_stop"]
        if let jobId { msg["job_id"] = jobId }
        sendJSON(msg)
    }

    func sendNewSession() {
        sendMessage("/new")
    }

    // MARK: - Private
    private func sendJSON(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        webSocketTask?.send(.data(data)) { [weak self] error in
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

    // job_update
    var jobId: String? { json["job_id"] as? String }
    var jobGoal: String? { json["goal"] as? String }
    var jobStatus: String? { json["status"] as? String }
    var jobMessage: String? { json["message"] as? String }
    var jobOverall: Double? { json["overall"] as? Double }
    var jobResults: [[String: String]]? { json["results"] as? [[String: String]] }
    var jobEvent: String? { json["event"] as? String }
    var jobNeedsConfirm: Bool? { json["needs_confirm"] as? Bool }
    var jobConfirmTaskId: String? { json["confirm_task_id"] as? String }

    // confirm
    var taskId: String? { json["task_id"] as? String }
    var confirmSummary: String? { json["summary"] as? String }
    var confirmDetail: Any? { json["detail"] }
    var confirmApproved: Bool? { json["approved"] as? Bool }

    // chat_message (cross-end sync)
    var chatRole: String? { json["role"] as? String }
    var chatText: String? { json["text"] as? String }
    var created_at: String? { json["created_at"] as? String }

    // 会话归属（job_update 带 'device:<id>'；无则视为主会话 'assistant'）
    var conversation: String? { json["conversation"] as? String }

    // error
    var errorMessage: String? { json["message"] as? String }
}
