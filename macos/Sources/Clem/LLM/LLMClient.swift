import Foundation

/// Which model backend powers enrichment, tagging, and chat.
enum LLMProvider: String, CaseIterable, Identifiable {
    case ollama, openai, anthropic, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ollama: return "Local (Ollama)"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    var defaultModel: String? {
        switch self {
        case .openai: return "gpt-4o-mini"
        case .anthropic: return "claude-haiku-4-5"
        case .ollama, .custom: return nil
        }
    }
}

enum LLMError: LocalizedError {
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let detail):
            return detail.isEmpty ? "The model API returned an error." : detail
        }
    }

    /// Pulls a human-readable message out of an API error body, if any.
    static func from(data: Data, status: Int) -> LLMError {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return .badResponse(msg)
        }
        return .badResponse("Model API returned HTTP \(status).")
    }
}

/// Unified interface over the local Ollama server and cloud model APIs.
/// Everything downstream (enrichment, tagging, chat) talks to this.
enum LLMClient {
    case ollama(OllamaClient)
    case openAI(OpenAIChatClient)
    case anthropic(AnthropicClient)

    func isUp() async -> Bool {
        switch self {
        case .ollama(let c): return await c.isUp()
        case .openAI(let c): return await c.isUp()
        case .anthropic(let c): return await c.isUp()
        }
    }

    func completeJSON(system: String, user: String, timeout: TimeInterval) async throws -> Data {
        switch self {
        case .ollama(let c): return try await c.completeJSON(system: system, user: user, timeout: timeout)
        case .openAI(let c): return try await c.completeJSON(system: system, user: user, timeout: timeout)
        case .anthropic(let c): return try await c.completeJSON(system: system, user: user, timeout: timeout)
        }
    }

    func streamChat(messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        switch self {
        case .ollama(let c): return c.streamChat(messages: messages)
        case .openAI(let c): return c.streamChat(messages: messages)
        case .anthropic(let c): return c.streamChat(messages: messages)
        }
    }

    /// Cloud models sometimes wrap JSON in prose or code fences; keep only the object.
    static func extractJSON(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[start...end])
    }
}

/// OpenAI chat-completions API; also serves any OpenAI-compatible endpoint
/// (Groq, OpenRouter, Together, …) via a custom base URL.
struct OpenAIChatClient {
    var baseURL: URL // e.g. https://api.openai.com/v1
    var apiKey: String
    var model: String

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return req
    }

    func isUp() async -> Bool {
        guard !apiKey.isEmpty else { return false }
        var req = request("models")
        req.timeoutInterval = 5
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func completeJSON(system: String, user: String, timeout: TimeInterval) async throws -> Data {
        var req = request("chat/completions")
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LLMError.from(data: data, status: status) }
        struct Resp: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable { let content: String? }
                let message: Msg
            }
            let choices: [Choice]
        }
        let content = try JSONDecoder().decode(Resp.self, from: data).choices.first?.message.content ?? ""
        return Data(LLMClient.extractJSON(content).utf8)
    }

    func streamChat(messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var req = request("chat/completions")
                    req.httpMethod = "POST"
                    req.timeoutInterval = 300
                    let body: [String: Any] = ["model": model, "stream": true, "messages": messages]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var err = Data()
                        for try await byte in bytes { err.append(byte); if err.count > 4096 { break } }
                        throw LLMError.from(data: err, status: status)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let token = delta["content"] as? String, !token.isEmpty else { continue }
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// Anthropic Messages API (native, not an OpenAI shim). System prompts are a
/// top-level field, so incoming "system" messages are hoisted out of the list.
struct AnthropicClient {
    var apiKey: String
    var model: String

    private var baseURL: URL { URL(string: "https://api.anthropic.com/v1")! }

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return req
    }

    func isUp() async -> Bool {
        guard !apiKey.isEmpty else { return false }
        var req = request("models")
        req.timeoutInterval = 5
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func completeJSON(system: String, user: String, timeout: TimeInterval) async throws -> Data {
        var req = request("messages")
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LLMError.from(data: data, status: status) }
        struct Resp: Decodable {
            struct Block: Decodable {
                let type: String
                let text: String?
            }
            let content: [Block]
        }
        let text = try JSONDecoder().decode(Resp.self, from: data).content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
        return Data(LLMClient.extractJSON(text).utf8)
    }

    func streamChat(messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let system = messages.filter { $0["role"] == "system" }.compactMap { $0["content"] }.joined(separator: "\n\n")
                    let turns = messages.filter { $0["role"] != "system" }

                    var req = request("messages")
                    req.httpMethod = "POST"
                    req.timeoutInterval = 300
                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": 4096,
                        "stream": true,
                        "messages": turns,
                    ]
                    if !system.isEmpty { body["system"] = system }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var err = Data()
                        for try await byte in bytes { err.append(byte); if err.count > 4096 { break } }
                        throw LLMError.from(data: err, status: status)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String else { continue }
                        if type == "message_stop" { break }
                        guard type == "content_block_delta",
                              let delta = obj["delta"] as? [String: Any],
                              delta["type"] as? String == "text_delta",
                              let token = delta["text"] as? String, !token.isEmpty else { continue }
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
