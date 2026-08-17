// APIClient.swift
// Makes chat completion requests against OpenAI-compatible providers and
// Anthropic. Non-streaming: a chat reply lands in one piece.

import Foundation

enum APIError: LocalizedError {
    case noModelConfigured
    case noProvider(String)
    case missingApiKey(String)
    case http(Int, String)
    case decode(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .noModelConfigured:
            return String(localized: "No model configured. Add one in Settings.", comment: "Error: no models in config")
        case .noProvider(let p):
            return String(localized: "Provider \(p) is not configured.", comment: "Error: missing provider")
        case .missingApiKey(let p):
            return String(localized: "Missing API key for \(p).", comment: "Error: missing API key")
        case .http(let code, let body):
            return "HTTP \(code): \(body)"
        case .decode(let m):
            return "Decode error: \(m)"
        case .transport(let m):
            return "Network error: \(m)"
        }
    }
}

/// Token counts one API reply reported for itself.
struct TokenUsage {
    let input: Int
    let output: Int
}

/// Persistent per-request token log in the app's own data dir —
/// usage.json, one JSON object per line ({"ts","model","in","out"}).
/// Records older than a year are pruned on write. All access is behind
/// one lock so concurrent requests can't interleave the
/// read-modify-write.
enum UsageLog {
    private static let lock = NSLock()

    private static var fileURL: URL {
        SipaiPaths.dataDir.appendingPathComponent("usage.json")
    }

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func record(model: String, usage: TokenUsage) {
        guard usage.input > 0 || usage.output > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let cutoff = tsFormatter.string(
            from: Date().addingTimeInterval(-365 * 24 * 3600))
        var lines: [String] = []
        if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
            for ln in content.components(separatedBy: "\n") {
                let t = ln.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty,
                      let data = t.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let ts = obj["ts"] as? String, ts >= cutoff
                else { continue }
                lines.append(t)
            }
        }
        let rec: [String: Any] = ["ts": tsFormatter.string(from: Date()),
                                  "model": model,
                                  "in": usage.input,
                                  "out": usage.output]
        if let data = try? JSONSerialization.data(withJSONObject: rec),
           let line = String(data: data, encoding: .utf8) {
            lines.append(line)
        }
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

@MainActor
final class APIClient {
    let config: ConfigManager
    init(config: ConfigManager) { self.config = config }

    /// Send a chat request and return the assistant's reply text, measured
    /// time, and the provider-reported token usage (nil when the provider
    /// omits a usage block).
    func sendChat(messages: [ChatMessage],
                  modelId: String,
                  systemPrompt: String?) async throws -> (text: String, time: Double, truncated: Bool, usage: TokenUsage?) {
        guard let model = config.model(for: modelId) else { throw APIError.noModelConfigured }
        guard let provider = config.provider(for: model.providerKey)
                ?? Self.fallbackProvider(for: model.providerKey)
        else { throw APIError.noProvider(model.providerKey) }

        let localProviderKeys: Set<String> = ["ollama", "lmstudio", "vllm", "sglang"]
        let isLocal = localProviderKeys.contains(provider.key)
        let rawKey = config.apiKey(for: provider.key) ?? ""
        guard !rawKey.isEmpty || isLocal else {
            throw APIError.missingApiKey(provider.name)
        }
        let effectiveKey = isLocal && rawKey.isEmpty ? "local" : rawKey

        let style = model.apiStyle ?? provider.apiStyle
        let start = Date()

        let (text, truncated, usage): (String, Bool, TokenUsage?)
        switch style {
        case "anthropic":
            (text, truncated, usage) = try await callAnthropic(messages: messages, system: systemPrompt,
                                           modelId: model.id, baseURL: provider.baseURL, apiKey: effectiveKey)
        case "openai-responses":
            (text, truncated, usage) = try await callOpenAIResponses(messages: messages, system: systemPrompt,
                                                 modelId: model.id, baseURL: provider.baseURL,
                                                 apiKey: effectiveKey, header: provider.authHeader, prefix: provider.authPrefix)
        default:
            (text, truncated, usage) = try await callOpenAIChat(messages: messages, system: systemPrompt,
                                            modelId: model.id, baseURL: provider.baseURL,
                                            apiKey: effectiveKey, header: provider.authHeader, prefix: provider.authPrefix)
        }

        if let usage {
            UsageLog.record(model: model.id, usage: usage)
        }
        return (text, Date().timeIntervalSince(start), truncated, usage)
    }

    // MARK: - OpenAI Chat Completions (most providers)

    /// Chat models that reject the legacy `max_tokens` parameter on
    /// /chat/completions. OpenAI's o-series and the gpt-5 era onward
    /// accept only `max_completion_tokens`. This is just the first
    /// guess — a 400 naming either parameter swaps and retries once,
    /// so an unlisted model corrects itself at the cost of one call.
    static func prefersMaxCompletionTokens(_ modelId: String) -> Bool {
        let m = modelId.lowercased()
        return m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
            || m.hasPrefix("gpt-5") || m.hasPrefix("gpt-6")
            || m.hasPrefix("chat-latest")
    }

    private func callOpenAIChat(messages: [ChatMessage], system: String?,
                                modelId: String, baseURL: String,
                                apiKey: String, header: String, prefix: String) async throws -> (String, Bool, TokenUsage?) {
        var msgs: [[String: Any]] = []
        if let s = system, !s.isEmpty { msgs.append(["role": "system", "content": s]) }
        for m in messages where m.role == "user" || m.role == "assistant" {
            msgs.append(["role": m.role, "content": m.content])
        }
        var body: [String: Any] = ["model": modelId, "messages": msgs, "stream": false]
        var tokenParam = Self.prefersMaxCompletionTokens(modelId)
            ? "max_completion_tokens" : "max_tokens"
        body[tokenParam] = 16384
        let url = try Self.endpointURL(base: baseURL, path: "/chat/completions")
        let headers = [
            header: prefix + apiKey,
            "Content-Type": "application/json",
        ]

        let json: [String: Any]
        do {
            json = try await postJSON(url: url, body: body, headers: headers)
        } catch APIError.http(let code, let errBody)
            where code == 400
                && (errBody.contains("max_completion_tokens")
                    || errBody.contains("max_tokens")) {
            // The server wants the other spelling of the token limit —
            // OpenAI's newer models refuse max_tokens, while many
            // OpenAI-compatible servers only know max_tokens.
            body.removeValue(forKey: tokenParam)
            tokenParam = tokenParam == "max_tokens"
                ? "max_completion_tokens" : "max_tokens"
            body[tokenParam] = 16384
            json = try await postJSON(url: url, body: body, headers: headers)
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw APIError.decode("missing choices[0].message.content")
        }
        let truncated = (first["finish_reason"] as? String) == "length"
        return (content, truncated, Self.parseUsage(json))
    }

    // MARK: - OpenAI Responses API

    private func callOpenAIResponses(messages: [ChatMessage], system: String?,
                                     modelId: String, baseURL: String,
                                     apiKey: String, header: String, prefix: String) async throws -> (String, Bool, TokenUsage?) {
        var input: [[String: Any]] = []
        for m in messages where m.role == "user" || m.role == "assistant" {
            input.append(["role": m.role, "content": m.content])
        }
        var body: [String: Any] = ["model": modelId, "input": input, "max_output_tokens": 16384]
        if let s = system, !s.isEmpty { body["instructions"] = s }
        let url = try Self.endpointURL(base: baseURL, path: "/responses")
        let json = try await postJSON(url: url, body: body, headers: [
            header: prefix + apiKey,
            "Content-Type": "application/json",
        ])
        let truncated = (json["status"] as? String) == "incomplete"
        let usage = Self.parseUsage(json)
        // The Responses API returns output_text directly when supported, otherwise output[].content[].text
        if let s = json["output_text"] as? String { return (s, truncated, usage) }
        if let outputs = json["output"] as? [[String: Any]] {
            for o in outputs {
                if let content = o["content"] as? [[String: Any]] {
                    for c in content {
                        if let t = c["text"] as? String { return (t, truncated, usage) }
                    }
                }
            }
        }
        throw APIError.decode("Responses API: no output_text")
    }

    // MARK: - Anthropic

    private func callAnthropic(messages: [ChatMessage], system: String?,
                               modelId: String, baseURL: String, apiKey: String) async throws -> (String, Bool, TokenUsage?) {
        var msgs: [[String: Any]] = []
        for m in messages where m.role == "user" || m.role == "assistant" {
            msgs.append(["role": m.role, "content": m.content])
        }
        var body: [String: Any] = [
            "model": modelId,
            "max_tokens": 16384,
            "messages": msgs,
        ]
        if let s = system, !s.isEmpty { body["system"] = s }
        let url = try Self.endpointURL(base: baseURL, path: "/messages")
        let json = try await postJSON(url: url, body: body, headers: [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json",
        ])
        guard let content = json["content"] as? [[String: Any]],
              let first = content.first, let text = first["text"] as? String else {
            throw APIError.decode("Anthropic: missing content[0].text")
        }
        let truncated = (json["stop_reason"] as? String) == "max_tokens"
        return (text, truncated, Self.parseUsage(json))
    }

    /// Pull the reply's own token accounting out of the response body.
    /// Handles both spellings: input_tokens/output_tokens (Anthropic,
    /// Responses API) and prompt_tokens/completion_tokens (Chat
    /// Completions).
    private static func parseUsage(_ json: [String: Any]) -> TokenUsage? {
        guard let u = json["usage"] as? [String: Any] else { return nil }
        let input = (u["input_tokens"] as? Int) ?? (u["prompt_tokens"] as? Int) ?? 0
        let output = (u["output_tokens"] as? Int) ?? (u["completion_tokens"] as? Int) ?? 0
        guard input > 0 || output > 0 else { return nil }
        return TokenUsage(input: input, output: output)
    }

    // MARK: - HTTP plumbing

    /// Build an endpoint URL from a user-typed provider base URL.
    /// Never force-unwrap here: custom providers accept arbitrary text
    /// (the setup sheets deliberately allow "Add anyway" on failed
    /// verification), so a malformed base URL must surface as a
    /// readable error on send, not a crash.
    private static func endpointURL(base: String, path: String) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed + path) else {
            throw APIError.transport(
                "Invalid provider base URL \"\(trimmed)\" — fix it in Settings → Models.")
        }
        return url
    }

    private func postJSON(url: URL, body: [String: Any], headers: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Reasoning models can legitimately think for many minutes
        // before the first byte of the reply, and URLRequest's default
        // 60 s would cut them off. Generous, not infinite.
        req.timeoutInterval = 3600
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        do {
            let (data, resp) = try await ProviderHTTP.session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw APIError.transport("non-HTTP response")
            }
            if http.statusCode >= 400 {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                throw APIError.http(http.statusCode, body)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw APIError.decode("not a JSON object")
            }
            return json
        } catch let e as APIError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            // A cancelled Task surfaces from URLSession as
            // URLError(.cancelled), not CancellationError — wrapped
            // into APIError.transport it would paint a "Network error:
            // cancelled" banner on every Stop press. Rethrow it as the
            // cancellation it is so callers can treat Stop as Stop.
            throw CancellationError()
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    /// If a model points at a built-in provider that the user hasn't customized, fabricate a ProviderConfig
    /// from the static built-in table so the request can still go through.
    static func fallbackProvider(for key: String) -> ProviderConfig? {
        guard let b = ConfigManager.builtInProviders[key] else { return nil }
        return ProviderConfig(
            key: key,
            name: b.name,
            baseURL: b.baseURL,
            apiStyle: b.apiStyle,
            apiKey: nil,
            envVar: b.env.isEmpty ? nil : b.env,
            authHeader: b.authHeader,
            authPrefix: b.authPrefix
        )
    }
}
