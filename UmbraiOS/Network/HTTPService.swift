import Foundation

// MARK: - HTTP Service
@MainActor
class HTTPService {
    static let shared = HTTPService()

    private var baseUrl: String { NetworkConfig.shared.serverUrl }
    private var token: String { NetworkConfig.shared.token }

    private var headers: [String: String] {
        var h: [String: String] = ["Content-Type": "application/json"]
        if !token.isEmpty { h["X-Umbra-Token"] = token }
        return h
    }

    // MARK: - History
    func fetchHistory(limit: Int = 20, beforeId: Int? = nil, conversation: String = "assistant") async -> [HistoryMessage] {
        var components = URLComponents(string: "\(baseUrl)/history")
        var items = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "conversation", value: conversation)
        ]
        if let beforeId { items.append(URLQueryItem(name: "before_id", value: String(beforeId))) }
        components?.queryItems = items

        return await request(components?.url)
    }

    // MARK: - Conversations
    func fetchConversations() async -> [ConversationRow] {
        guard let url = URL(string: "\(baseUrl)/conversations") else { return [] }
        return await request(url)
    }

    // 清空指定会话历史（默认主会话；传 device:<id> 清某设备房间）。
    func clearHistory(conversation: String = "assistant") async {
        guard let url = URL(string: "\(baseUrl)/history/clear") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Umbra-Token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["conversation": conversation])
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Jobs
    func fetchJobs(limit: Int = 30, status: String? = nil) async -> [Job] {
        var components = URLComponents(string: "\(baseUrl)/jobs")
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let status { items.append(URLQueryItem(name: "status", value: status)) }
        components?.queryItems = items

        return await request(components?.url)
    }

    func fetchJobDetail(id: String) async -> JobDetail? {
        guard let url = URL(string: "\(baseUrl)/jobs/\(id)") else { return nil }
        return await request(url)
    }

    // 强制结束一个正在跑/暂停中的 operate 任务（任务列表「结束任务」）。
    @discardableResult
    func stopJob(id: String) async -> Bool {
        guard let url = URL(string: "\(baseUrl)/jobs/\(id)/stop") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse).map { $0.statusCode < 400 } ?? false
        } catch {
            return false
        }
    }

    // MARK: - Inspirations（灵感速记）
    func fetchInspirations(status: String? = nil) async -> [Inspiration] {
        var components = URLComponents(string: "\(baseUrl)/inspirations")
        if let status, !status.isEmpty {
            components?.queryItems = [URLQueryItem(name: "status", value: status)]
        }
        guard let url = components?.url else { return [] }
        do {
            var req = URLRequest(url: url)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            let (data, _) = try await URLSession.shared.data(for: req)
            return (try? JSONDecoder().decode([Inspiration].self, from: data)) ?? []
        } catch {
            return []
        }
    }

    @discardableResult
    func createInspiration(raw: String, title: String, summary: String, tags: [String]) async -> Bool {
        guard let url = URL(string: "\(baseUrl)/inspirations") else { return false }
        let body: [String: Any] = ["raw": raw, "title": title, "summary": summary, "tags": tags]
        return await sendJSON(url, method: "POST", body: body)
    }

    @discardableResult
    func updateInspiration(id: Int, patch: [String: Any]) async -> Bool {
        guard let url = URL(string: "\(baseUrl)/inspirations/\(id)") else { return false }
        return await sendJSON(url, method: "PATCH", body: patch)
    }

    @discardableResult
    func deleteInspiration(id: Int) async -> Bool {
        guard let url = URL(string: "\(baseUrl)/inspirations/\(id)") else { return false }
        return await sendJSON(url, method: "DELETE", body: nil)
    }

    // 通用 JSON 请求（灵感增改删共用）。返回是否成功（<400）。
    private func sendJSON(_ url: URL, method: String, body: [String: Any]?) async -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse).map { $0.statusCode < 400 } ?? false
        } catch {
            return false
        }
    }

    // MARK: - Capabilities
    func fetchCapabilities() async -> [Capability] {
        guard let url = URL(string: "\(baseUrl)/capabilities") else { return [] }
        return await request(url)
    }

    // MARK: - Devices
    func fetchDevices() async -> [[String: Any]] {
        guard let url = URL(string: "\(baseUrl)/devices") else { return [] }
        return await requestAny(url)
    }

    /// 所有已知设备（含离线），聊天页的联系人列表。
    func fetchAllDevices() async -> [KnownDevice] {
        guard let url = URL(string: "\(baseUrl)/devices/all") else { return [] }
        return await request(url)
    }

    /// 把某台（离线的）设备从联系人列表移除。
    @discardableResult
    func forgetDevice(_ deviceId: String) async -> Bool {
        let encoded = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceId
        guard let url = URL(string: "\(baseUrl)/devices/\(encoded)") else { return false }
        return await sendJSON(url, method: "DELETE", body: nil)
    }

    // MARK: - File Upload
    func uploadFile(name: String, data: Data) async throws -> UploadResponse {
        guard let url = URL(string: "\(baseUrl)/files/upload") else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-Umbra-Token") }

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n")
        body.append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode < 400 else {
            throw NetworkError.serverError
        }
        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }

    // MARK: - Assist endpoints (LLM, image generation)
    func llmComplete(messages: [[String: String]]) async throws -> String {
        guard let url = URL(string: "\(baseUrl)/llm/complete") else { throw NetworkError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-Umbra-Token") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["messages": messages])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode < 400 else {
            throw NetworkError.serverError
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["text"] as? String ?? ""
    }

    func replySuggest(imageBase64: String, hint: String? = nil) async throws -> String {
        guard let url = URL(string: "\(baseUrl)/assist/reply-suggest") else { throw NetworkError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-Umbra-Token") }
        var body: [String: Any] = ["image_base64": imageBase64]
        if let hint { body["hint"] = hint }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode < 400 else {
            throw NetworkError.serverError
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["text"] as? String ?? ""
    }

    // MARK: - Generic
    private func request<T: Decodable>(_ url: URL?) async -> T {
        guard let url else {
            // Return empty for array types
            if T.self == [HistoryMessage].self { return [] as! T }
            if T.self == [Job].self { return [] as! T }
            if T.self == [Capability].self { return [] as! T }
            if T.self == [ConversationRow].self { return [] as! T }
            fatalError("Unexpected type")
        }
        do {
            var urlRequest = URLRequest(url: url)
            for (key, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
            let (data, _) = try await URLSession.shared.data(for: urlRequest)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            if T.self == [HistoryMessage].self { return [] as! T }
            if T.self == [Job].self { return [] as! T }
            if T.self == [Capability].self { return [] as! T }
            if T.self == [ConversationRow].self { return [] as! T }
            return try! JSONDecoder().decode(T.self, from: Data())
        }
    }

    private func requestAny(_ url: URL?) async -> [[String: Any]] {
        guard let url else { return [] }
        do {
            var urlRequest = URLRequest(url: url)
            for (key, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
            let (data, _) = try await URLSession.shared.data(for: urlRequest)
            return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        } catch {
            return []
        }
    }
}

enum NetworkError: Error {
    case invalidURL
    case serverError
    case decodingError
}

extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { self.append(data) }
    }
}
