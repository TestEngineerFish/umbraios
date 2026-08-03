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

        return await request(components?.url) ?? []
    }

    // MARK: - Conversations
    func fetchConversations() async -> [ConversationRow] {
        guard let url = URL(string: "\(baseUrl)/conversations") else { return [] }
        return await request(url) ?? []
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

        return await request(components?.url) ?? []
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
        return await request(url) ?? []
    }

    // MARK: - Devices
    func fetchDevices() async -> [[String: Any]] {
        guard let url = URL(string: "\(baseUrl)/devices") else { return [] }
        return await requestAny(url)
    }

    /// 所有已知设备（含离线），聊天页的联系人列表。
    func fetchAllDevices() async -> [KnownDevice] {
        guard let url = URL(string: "\(baseUrl)/devices/all") else { return [] }
        return await request(url) ?? []
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

    // MARK: - Workspaces（工作区，手机上只读）
    func fetchWorkspaces() async -> [Workspace] {
        guard let url = URL(string: "\(baseUrl)/workspaces") else { return [] }
        return await request(url) ?? []
    }

    // MARK: - Profile（用户画像）
    func fetchProfile() async -> String {
        guard let url = URL(string: "\(baseUrl)/profile") else { return "" }
        let r: ProfileBody? = await request(url)
        return r?.markdown ?? ""
    }

    /// 整篇覆盖保存。返回服务端回存后的内容（失败返回 nil，调用方据此提示）。
    func saveProfile(_ markdown: String) async -> String? {
        guard let url = URL(string: "\(baseUrl)/profile") else { return nil }
        return await sendJSONReturning(url, method: "PUT", body: ["markdown": markdown], as: ProfileBody.self)?.markdown
    }

    /// 重置为空白模板。
    func resetProfile() async -> String? {
        guard let url = URL(string: "\(baseUrl)/profile") else { return nil }
        return await sendJSONReturning(url, method: "DELETE", body: nil, as: ProfileBody.self)?.markdown
    }

    // MARK: - Phrases（常用语，双向同步）
    func fetchPhrases() async -> PhraseBundle? {
        guard let url = URL(string: "\(baseUrl)/phrases") else { return nil }
        return await request(url)
    }

    /// 推本地全量（含墓碑）上去，服务端逐条 last-write-wins 合并后回全量。
    /// 一次往返完成、没有冲突弹窗 —— 常用语条数少，这样最省心（和 PC 端同一套约定）。
    func syncPhrases(items: [Phrase], deleted: [PhraseTomb]) async -> PhraseBundle? {
        guard let url = URL(string: "\(baseUrl)/phrases/sync") else { return nil }
        let body: [String: Any] = [
            "items": items.map { $0.wire },
            "deleted": deleted.map { ["id": $0.id, "deletedAt": $0.deletedAt] }
        ]
        return await sendJSONReturning(url, method: "POST", body: body, as: PhraseBundle.self)
    }

    /// 带返回值的 JSON 请求。原来的 sendJSON 只回一个 Bool，
    /// 而画像保存和常用语同步都需要**服务端合并后的结果**（不是本地那份）。
    private func sendJSONReturning<T: Decodable>(_ url: URL, method: String,
                                                 body: [String: Any]?, as: T.Type) async -> T? {
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                print("[HTTPService] \(url.path) 返回 HTTP \(http.statusCode)")
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("[HTTPService] \(url.path) 失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Generic
    //
    // 返回 T? 而不是 T。原来的签名是 `-> T`（不抛、不可空），于是请求失败时它没有任何
    // 合法的 T 可以返回，只能靠一张写死的类型白名单硬凑一个空数组，落到白名单之外就
    // `try! JSONDecoder().decode(T.self, from: Data())` —— 空 Data 解码**必然抛**，
    // try! 把它变成 fatalError，整个 App 当场崩。
    //
    // 实际炸的是 fetchAllDevices（[KnownDevice] 不在白名单里）：首次启动连不上服务端就崩。
    // 但这跟网络权限只是巧合关系 —— 超时、500、JSON 格式变了、切了 VPN，任何一种失败都会
    // 走到同一行。而且那张白名单是「按构造就会过期」的东西：以后每加一个模型类型，
    // 就多一颗只在网络不好时才引爆的雷。
    //
    // 现在：失败一律返回 nil，由调用方决定兜底值（数组给 []，详情给 nil）。
    // 顺带把失败原因打出来 —— 原来是静默吞掉的，线上只能看到「列表是空的」，查不出为什么。
    private func request<T: Decodable>(_ url: URL?) async -> T? {
        guard let url else {
            print("[HTTPService] 请求地址拼不出来（检查设置里的服务端地址）")
            return nil
        }
        do {
            var urlRequest = URLRequest(url: url)
            for (key, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                // 4xx/5xx 的响应体多半不是目标结构，硬解只会得到一个更难懂的解码错误。
                print("[HTTPService] \(url.path) 返回 HTTP \(http.statusCode)")
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("[HTTPService] \(url.path) 失败：\(error.localizedDescription)")
            return nil
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
