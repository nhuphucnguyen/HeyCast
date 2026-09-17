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
        // A screenshot on the clipboard rides along automatically — the
        // "screenshot → @glm extract the text" flow.
        let image = ClipboardService.clipboardImagePNG()
        guard let id = store.insert(agent: agent.name, request: trimmed, imageData: image) else { return nil }
        dispatch(agent: agent, id: id, text: trimmed, imageData: image)
        onUpdated?()
        return id
    }

    func retry(message: AssistantMessage, agent: AgentConfig?) {
        // Prefer the current config for the alias, so a fixed URL/key applies.
        let resolved = agent ?? AgentConfig(name: message.agent, alias: "", type: "openai", baseURL: "")
        store.reset(id: message.id)
        dispatch(agent: resolved, id: message.id, text: message.request, imageData: message.imageData)
        onUpdated?()
    }

    private func dispatch(agent: AgentConfig, id: Int64, text: String, imageData: Data?) {
        inFlight.insert(id)
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await Self.perform(agent: agent, question: text, imageData: imageData) { [weak self] delta in
                    self?.streamDelta(id: id, delta: delta)
                }
                self.store.updateResponse(id: id, response: response)
                self.streamBuffers[id] = nil
                self.lastStreamFlush[id] = nil
                NotificationService.shared.post(title: "\(agent.name) responded",
                                                body: String(response.prefix(120)), messageID: id)
            } catch {
                self.store.updateError(id: id, error: error.localizedDescription)
                self.streamBuffers[id] = nil
                self.lastStreamFlush[id] = nil
                NotificationService.shared.post(title: "\(agent.name) failed",
                                                body: String(error.localizedDescription.prefix(120)),
                                                messageID: id)
            }
            self.inFlight.remove(id)
            self.onUpdated?()
        }
    }

    // MARK: - streaming

    private var streamBuffers: [Int64: String] = [:]
    private var lastStreamFlush: [Int64: Date] = [:]

    /// Called for every streamed chunk. UI/store writes are throttled —
    /// providers emit far faster than anyone needs to re-render.
    private func streamDelta(id: Int64, delta: String) {
        let now = Date()
        streamBuffers[id, default: ""] += delta
        if let last = lastStreamFlush[id], now.timeIntervalSince(last) < 0.12 { return }
        lastStreamFlush[id] = now
        store.updatePartial(id: id, response: streamBuffers[id] ?? "")
        onUpdated?()
    }

    // MARK: - agents

    static func perform(agent: AgentConfig, question: String, imageData: Data?,
                        onDelta: @escaping (String) -> Void) async throws -> String {
        switch agent.type.lowercased() {
        case "anthropic": return try await callAnthropic(agent: agent, question: question, imageData: imageData, onDelta: onDelta)
        case "mcp": return try await callMCP(agent: agent, question: question)
        default: return try await callOpenAI(agent: agent, question: question, imageData: imageData, onDelta: onDelta)
        }
    }

    /// OpenAI-compatible chat endpoint (OpenAI, Groq, Ollama, OpenRouter,
    /// z.ai, most self-hosted agents). baseURL includes the version path,
    /// e.g. https://api.openai.com/v1. Streams SSE deltas as they arrive;
    /// falls back to parsing a plain JSON body if the provider ignores
    /// stream:true.
    private static func callOpenAI(agent: AgentConfig, question: String,
                                   imageData: Data?, onDelta: @escaping (String) -> Void) async throws -> String {
        // Image requests may target a vision-specific model/endpoint (e.g.
        // z.ai's coding endpoint is text-only; vision lives on the general
        // endpoint with a vision model like glm-4.6v).
        var endpoint = agent.baseURL
        var model = agent.model ?? "gpt-4o-mini"
        if imageData != nil {
            if let visionBase = agent.visionBaseURL, !visionBase.isEmpty { endpoint = visionBase }
            if let visionModel = agent.visionModel, !visionModel.isEmpty { model = visionModel }
        }
        var request = URLRequest(url: URL(string: endpoint + "/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = agent.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        var userContent: Any = question
        if let imageData {
            // Multimodal: text + image part (base64 data URI).
            userContent = [
                ["type": "text", "text": question],
                ["type": "image_url", "image_url":
                    ["url": "data:image/png;base64,\(imageData.base64EncodedString())"]],
            ]
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": userContent]],
            "stream": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        var full = ""
        var sawStream = false
        var rawBody = ""

        for try await line in bytes.lines {
            rawBody += line + "\n"
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                throw NSError(domain: "assistant", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            if let choices = json["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let piece = delta["content"] as? String, !piece.isEmpty {
                sawStream = true
                full += piece
                // The loop runs off the main actor; stream buffers live on it.
                await MainActor.run { onDelta(piece) }
            }
        }
        if sawStream { return full }

        // Fallback: the provider ignored stream:true and answered in one body.
        if let json = try? JSONSerialization.jsonObject(with: Data(rawBody.utf8)) as? [String: Any] {
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String, !content.isEmpty {
                return content
            }
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                throw NSError(domain: "assistant", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        throw NSError(domain: "assistant", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Unexpected response from \(endpoint)"])
    }

    /// Anthropic Messages API. baseURL defaults to https://api.anthropic.com.
    /// Streams content_block_delta text events.
    private static func callAnthropic(agent: AgentConfig, question: String,
                                      imageData: Data?, onDelta: @escaping (String) -> Void) async throws -> String {
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
        var userContent: Any = question
        if let imageData {
            userContent = [
                ["type": "image", "source": [
                    "type": "base64", "media_type": "image/png",
                    "data": imageData.base64EncodedString()]],
                ["type": "text", "text": question],
            ]
        }
        let body: [String: Any] = [
            "model": agent.model ?? "claude-sonnet-4-5",
            "max_tokens": 2048,
            "messages": [["role": "user", "content": userContent]],
            "stream": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        var full = ""
        var sawStream = false
        var rawBody = ""

        for try await line in bytes.lines {
            rawBody += line + "\n"
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if json["type"] as? String == "content_block_delta" {
                if let delta = json["delta"] as? [String: Any],
                   let piece = delta["text"] as? String, !piece.isEmpty {
                    sawStream = true
                    full += piece
                    // The loop runs off the main actor; stream buffers live on it.
                    await MainActor.run { onDelta(piece) }
                }
            } else if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                throw NSError(domain: "assistant", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        if sawStream { return full }

        // Fallback: plain JSON body.
        if let json = try? JSONSerialization.jsonObject(with: Data(rawBody.utf8)) as? [String: Any] {
            if let content = json["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { return text }
            }
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                throw NSError(domain: "assistant", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
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
