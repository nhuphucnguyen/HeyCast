import AppKit
import Foundation

/// Fire-and-forget agent requests: the launcher sends and dismisses, this
/// service runs the call in the background, persists the outcome to the
/// inbox store and posts a notification when it lands.
@MainActor
final class AssistantService {
    let store = AssistantStore()

    /// Called whenever a message row changed (response landed, failed, sent).
    var onUpdated: (() -> Void)?

    private var inFlight: Set<Int64> = []

    @discardableResult
    func send(agent: AgentConfig, text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let id = store.insert(agent: agent.name, request: trimmed) else { return nil }
        dispatch(agent: agent, id: id, text: trimmed)
        onUpdated?()
        return id
    }

    func retry(message: AssistantMessage, agent: AgentConfig?) {
        // Prefer the current config for the alias, so a fixed URL/key applies.
        let resolved = agent ?? AgentConfig(name: message.agent, alias: "", type: "openai", baseURL: "")
        store.reset(id: message.id)
        dispatch(agent: resolved, id: message.id, text: message.request)
        onUpdated?()
    }

    private func dispatch(agent: AgentConfig, id: Int64, text: String) {
        inFlight.insert(id)
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await Self.perform(agent: agent, question: text)
                self.store.updateResponse(id: id, response: response)
                NotificationService.shared.post(title: "\(agent.name) responded",
                                                body: String(response.prefix(120)), messageID: id)
            } catch {
                self.store.updateError(id: id, error: error.localizedDescription)
                NotificationService.shared.post(title: "\(agent.name) failed",
                                                body: String(error.localizedDescription.prefix(120)),
                                                messageID: id)
            }
            self.inFlight.remove(id)
            self.onUpdated?()
        }
    }

    // MARK: - agents

    static func perform(agent: AgentConfig, question: String) async throws -> String {
        switch agent.type.lowercased() {
        case "anthropic": return try await callAnthropic(agent: agent, question: question)
        case "mcp": return try await callMCP(agent: agent, question: question)
        default: return try await callOpenAI(agent: agent, question: question)
        }
    }

    /// OpenAI-compatible chat endpoint (OpenAI, Groq, Ollama, OpenRouter,
    /// most self-hosted agents). baseURL includes the version path, e.g.
    /// https://api.openai.com/v1.
    private static func callOpenAI(agent: AgentConfig, question: String) async throws -> String {
        var request = URLRequest(url: URL(string: agent.baseURL + "/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = agent.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": agent.model ?? "gpt-4o-mini",
            "messages": [["role": "user", "content": question]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String, !content.isEmpty {
            return content
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw NSError(domain: "assistant", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        throw NSError(domain: "assistant", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Unexpected response from \(agent.baseURL)"])
    }

    /// Anthropic Messages API. baseURL defaults to https://api.anthropic.com.
    private static func callAnthropic(agent: AgentConfig, question: String) async throws -> String {
        var base = agent.baseURL
        if base.isEmpty { base = "https://api.anthropic.com" }
        var request = URLRequest(url: URL(string: base + "/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = agent.apiKey, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": agent.model ?? "claude-sonnet-4-5",
            "max_tokens": 2048,
            "messages": [["role": "user", "content": question]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let content = json["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw NSError(domain: "assistant", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        throw NSError(domain: "assistant", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Unexpected response from \(base)"])
    }

    /// MCP streamable-HTTP client: initialize → tools/list → tools/call with
    /// the question as the tool's single required argument. Auth is a Bearer
    /// key for now (OAuth is a planned follow-up).
    private static func callMCP(agent: AgentConfig, question: String) async throws -> String {
        var sessionID: String?
        var nextID = 1

        func rpc(_ method: String, params: [String: Any]? = nil, notification: Bool = false) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: agent.baseURL)!)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let key = agent.apiKey, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            if let sessionID {
                request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            }
            var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
            if !notification {
                body["id"] = nextID
                nextID += 1
            }
            if let params { body["params"] = params }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            if let sid = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id") {
                sessionID = sid
            }
            return try Self.parseJSONRPCResponse(data: data, id: notification ? nil : nextID - 1)
        }

        _ = try await rpc("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "HeyCast", "version": "1.0"],
        ])
        _ = try await rpc("notifications/initialized", notification: true)

        let toolsResult = try await rpc("tools/list")
        let tools = (toolsResult["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        guard !tools.isEmpty else {
            throw NSError(domain: "assistant", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "\(agent.name) exposes no MCP tools"])
        }
        let toolName: String
        var argumentKey = "query"
        if let preferred = agent.tool, tools.contains(where: { $0["name"] as? String == preferred }) {
            toolName = preferred
        } else {
            toolName = tools[0]["name"] as? String ?? "ask"
        }
        if let chosen = tools.first(where: { $0["name"] as? String == toolName }),
           let schema = chosen["inputSchema"] as? [String: Any],
           let required = schema["required"] as? [String], let first = required.first {
            argumentKey = first
        }

        let callResult = try await rpc("tools/call", params: [
            "name": toolName,
            "arguments": [argumentKey: question],
        ])
        if let result = callResult["result"] as? [String: Any] {
            let content = result["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if result["isError"] as? Bool == true {
                throw NSError(domain: "assistant", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? "Tool error" : text])
            }
            if !text.isEmpty { return text }
        }
        if let error = callResult["error"] as? [String: Any], let message = error["message"] as? String {
            throw NSError(domain: "assistant", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        return "(empty response)"
    }

    /// JSON-RPC replies arrive as a plain JSON body or wrapped in an SSE
    /// stream ("data: {...}" lines); handle both.
    private static func parseJSONRPCResponse(data: Data, id: Int?) throws -> [String: Any] {
        func decode(_ jsonData: Data) throws -> [String: Any] {
            guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                throw NSError(domain: "assistant", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Malformed agent response"])
            }
            return json
        }
        // Fast path: plain JSON body with a matching (or any) id.
        if let json = try? decode(data) {
            if id == nil { return json }
            if json["id"] as? Int == id || json["result"] != nil || json["error"] != nil {
                return json
            }
        }
        // SSE path: prefer the last data line whose id matches the request,
        // falling back to the last reply-looking line.
        if let text = String(data: data, encoding: .utf8) {
            var lastMatch: [String: Any]?
            var lastReply: [String: Any]?
            for line in text.split(separator: "\n") {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let json = try? decode(Data(payload.utf8)) else { continue }
                if id != nil, json["id"] as? Int == id { lastMatch = json }
                if json["result"] != nil || json["error"] != nil { lastReply = json }
            }
            if let lastMatch { return lastMatch }
            if let lastReply { return lastReply }
        }
        throw NSError(domain: "assistant", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "No JSON-RPC reply from agent"])
    }
}
