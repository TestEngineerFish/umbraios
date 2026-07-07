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
