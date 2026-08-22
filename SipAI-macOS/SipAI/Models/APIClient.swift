// APIClient.swift
// Makes chat requests against OpenAI-compatible providers and Anthropic.
// The OpenAI-style paths STREAM on the wire and deliver the reply whole:
// a reasoning model thinks for minutes before a non-streaming reply's
// first byte, and middleboxes that drop byte-silent connections (local
// proxies, corporate gateways, provider edges) kill that request long
// before any client timeout. The UI contract is unchanged — one piece.

import Foundation

enum APIError: LocalizedError {
    case noModelConfigured
    case noProvider(String)
    case missingApiKey(String)
    case http(Int, String)
    case decode(String)
    case transport(String)
    /// A 400 on a request that carried an image or a PDF, worded so the
    /// reader knows to change the model rather than the message. The
    /// raw body rides along because the providers disagree about how to
    /// say "this model has no eyes".
    case attachmentRejected(String, String)
    /// A scanned PDF aimed at an API style that takes no native PDF.
    /// Refused before the request, because the alternative is a billed
    /// turn in which the model was shown nothing.
    case pdfNotReadable(String, String)

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
        case .attachmentRejected(let model, let body):
            return String(
                localized: "\(model) rejected the attached file — it may not accept images or PDFs. Pick a model that does, or remove the attachment.\n\n\(body)",
                comment: "Error when a provider refuses a request carrying an image or PDF")
        case .pdfNotReadable(let name, let model):
            return String(
                localized: "\(name) has no text layer, and \(model) cannot read PDFs directly. Use a Claude model or an OpenAI Responses model, or attach the pages as images.",
                comment: "Error when a scanned PDF is sent to a provider that takes no native PDF")
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

    /// Which API styles take a PDF as a native document block. The rest
    /// are sent the extracted text layer instead.
    ///
    /// Chat Completions is deliberately excluded even though OpenAI's
    /// own endpoint accepts a `file` part: nearly every provider in the
    /// catalog speaks that dialect, most of them reject the part, and a
    /// 400 costs the whole turn. Text works on all of them.
    static func acceptsNativePDF(apiStyle: String) -> Bool {
        apiStyle == "anthropic" || apiStyle == "openai-responses"
    }

    /// Send a chat request and return the assistant's reply text, measured
    /// time, and the provider-reported token usage (nil when the provider
    /// omits a usage block).
    ///
    /// `attachments` ride the LAST user message and nothing else. Text
    /// attachments are already part of that message's stored content —
    /// see `ChatAttachment` — so they are ignored here; only images and
    /// PDFs become content blocks, and only on this one request.
    func sendChat(messages: [ChatMessage],
                  modelId: String,
                  systemPrompt: String?,
                  attachments: [ChatAttachment] = []) async throws -> (text: String, time: Double, truncated: Bool, usage: TokenUsage?) {
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

        // Text attachments are already inside the message body; only
        // images and PDFs still need to be turned into content blocks.
        let blocks = attachments.filter { !$0.isText }
        if !Self.acceptsNativePDF(apiStyle: style) {
            // The PDF will be sent as its extracted text. A scan has
            // none, so there is nothing to send and the turn would be
            // billed for a question about a document the model never
            // saw.
            if let scan = blocks.first(where: { $0.kind == .pdf && $0.text == nil }) {
                throw APIError.pdfNotReadable(scan.name, model.name)
            }
        }

        let (text, truncated, usage): (String, Bool, TokenUsage?)
        do {
            switch style {
            case "anthropic":
                (text, truncated, usage) = try await callAnthropic(messages: messages, system: systemPrompt,
                                               modelId: model.id, baseURL: provider.baseURL, apiKey: effectiveKey,
                                               attachments: blocks)
            case "openai-responses":
                (text, truncated, usage) = try await callOpenAIResponses(messages: messages, system: systemPrompt,
                                                     modelId: model.id, baseURL: provider.baseURL,
                                                     apiKey: effectiveKey, header: provider.authHeader, prefix: provider.authPrefix,
                                                     attachments: blocks)
            default:
                (text, truncated, usage) = try await callOpenAIChat(messages: messages, system: systemPrompt,
                                                modelId: model.id, baseURL: provider.baseURL,
                                                apiKey: effectiveKey, header: provider.authHeader, prefix: provider.authPrefix,
                                                attachments: blocks)
            }
        } catch APIError.http(let code, let body)
            where code == 400 && !blocks.isEmpty && Self.readsAsAttachmentRejection(body) {
            // A text-only model handed an image says so in a different
            // sentence per provider. Restate it once, as an instruction.
            throw APIError.attachmentRejected(model.name, String(body.prefix(400)))
        }

        if let usage {
            UsageLog.record(model: model.id, usage: usage)
        }
        return (text, Date().timeIntervalSince(start), truncated, usage)
    }

    /// Whether a 400 is about the attachment rather than the prompt.
    /// Matched on the BODY, not on a list of model ids: a hardcoded
    /// "these models have vision" table is wrong the week any provider
    /// ships a model, and the provider's own refusal is the only current
    /// source of that fact.
    static func readsAsAttachmentRejection(_ body: String) -> Bool {
        let b = body.lowercased()
        let needles = [
            "image", "vision", "multimodal", "image_url", "input_image",
            "file_data", "input_file", "document", "media_type",
            "content type", "unsupported content",
        ]
        return needles.contains { b.contains($0) }
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

    /// Streaming-first. The request goes out with `stream: true` and the
    /// reply is assembled and delivered WHOLE, so `sendChat`'s contract
    /// does not move — the point is the WIRE, not the UI. A reasoning
    /// model legitimately thinks for minutes before the first byte of a
    /// non-streaming reply, and a middlebox that drops byte-silent
    /// connections (a local proxy, a corporate gateway, a provider's
    /// edge) kills that request long before the app's own 3600 s
    /// timeout — measured on a real path: the identical non-streaming
    /// request died at 126 s with zero bytes, the streamed one
    /// completed. Streaming shrinks the silent window from the WHOLE
    /// response time to the time-to-first-token.
    ///
    /// Not every OpenAI-compatible server implements streaming or
    /// `stream_options`, so a 400 naming either drops that piece and
    /// retries — ending, at worst, in the plain non-streaming call this
    /// path used to be. Each retry costs an instant 400, never a
    /// generation.
    private func callOpenAIChat(messages: [ChatMessage], system: String?,
                                modelId: String, baseURL: String,
                                apiKey: String, header: String, prefix: String,
                                attachments: [ChatAttachment] = []) async throws -> (String, Bool, TokenUsage?) {
        let msgs = Self.openAIChatMessages(messages, system: system, attachments: attachments)
        var body: [String: Any] = [
            "model": modelId, "messages": msgs,
            "stream": true,
            // Without this the final chunk carries no usage block and
            // the token counter under the composer goes dark.
            "stream_options": ["include_usage": true],
        ]
        var tokenParam = Self.prefersMaxCompletionTokens(modelId)
            ? "max_completion_tokens" : "max_tokens"
        body[tokenParam] = 16384
        let url = try Self.endpointURL(base: baseURL, path: "/chat/completions")
        let headers = [
            header: prefix + apiKey,
            "Content-Type": "application/json",
        ]

        var swappedToken = false
        var attempts = 0
        while true {
            attempts += 1
            do {
                let acc = try await postSSE(url: url, body: body, headers: headers,
                                            fold: Self.foldChatCompletionsLine)
                if let message = acc.errorMessage {
                    throw APIError.transport(message)
                }
                guard !acc.text.isEmpty || acc.finishReason != nil else {
                    throw APIError.decode("stream carried no reply")
                }
                return (acc.text, acc.finishReason == "length", acc.usage)
            } catch APIError.http(let code, let errBody) where code == 400 && attempts < 4 {
                if !swappedToken,
                   errBody.contains("max_completion_tokens") || errBody.contains("max_tokens") {
                    // The server wants the other spelling of the token
                    // limit — OpenAI's newer models refuse max_tokens,
                    // while many OpenAI-compatible servers only know
                    // max_tokens.
                    body.removeValue(forKey: tokenParam)
                    tokenParam = tokenParam == "max_tokens"
                        ? "max_completion_tokens" : "max_tokens"
                    body[tokenParam] = 16384
                    swappedToken = true
                    continue
                }
                if errBody.contains("stream_options"), body["stream_options"] != nil {
                    body.removeValue(forKey: "stream_options")
                    continue
                }
                if errBody.contains("stream") {
                    // No streaming at all on this server. The legacy
                    // call still carries its own token-param dance.
                    return try await callOpenAIChatUnstreamed(
                        msgs: msgs, modelId: modelId, url: url, headers: headers)
                }
                throw APIError.http(code, errBody)
            }
        }
    }

    /// The pre-streaming request, kept whole as the fallback for
    /// servers that reject `stream`. Same wire shape this path always
    /// had.
    private func callOpenAIChatUnstreamed(msgs: [[String: Any]], modelId: String,
                                          url: URL, headers: [String: String]) async throws -> (String, Bool, TokenUsage?) {
        var body: [String: Any] = ["model": modelId, "messages": msgs, "stream": false]
        var tokenParam = Self.prefersMaxCompletionTokens(modelId)
            ? "max_completion_tokens" : "max_tokens"
        body[tokenParam] = 16384

        let json: [String: Any]
        do {
            json = try await postJSON(url: url, body: body, headers: headers)
        } catch APIError.http(let code, let errBody)
            where code == 400
                && (errBody.contains("max_completion_tokens")
                    || errBody.contains("max_tokens")) {
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

    /// Streaming-first for the same reason as `callOpenAIChat` — the
    /// Responses API sits in front of the same reasoning models, and a
    /// non-streaming call is byte-silent for the whole think. Falls
    /// back to the plain call on a server that rejects `stream`.
    private func callOpenAIResponses(messages: [ChatMessage], system: String?,
                                     modelId: String, baseURL: String,
                                     apiKey: String, header: String, prefix: String,
                                     attachments: [ChatAttachment] = []) async throws -> (String, Bool, TokenUsage?) {
        let input = Self.openAIResponsesInput(messages, attachments: attachments)
        var body: [String: Any] = ["model": modelId, "input": input,
                                   "max_output_tokens": 16384, "stream": true]
        if let s = system, !s.isEmpty { body["instructions"] = s }
        let url = try Self.endpointURL(base: baseURL, path: "/responses")
        let headers = [
            header: prefix + apiKey,
            "Content-Type": "application/json",
        ]
        do {
            let acc = try await postSSE(url: url, body: body, headers: headers,
                                        fold: Self.foldResponsesLine)
            if let message = acc.errorMessage {
                throw APIError.transport(message)
            }
            guard !acc.text.isEmpty else {
                throw APIError.decode("Responses API: no output_text")
            }
            return (acc.text, acc.finishReason == "incomplete", acc.usage)
        } catch APIError.http(let code, let errBody)
            where code == 400 && errBody.contains("stream") {
            body["stream"] = false
            let json = try await postJSON(url: url, body: body, headers: headers)
            return try Self.parseResponsesJSON(json)
        }
    }

    /// The pre-streaming reply shape, used by the fallback.
    nonisolated private static func parseResponsesJSON(_ json: [String: Any]) throws -> (String, Bool, TokenUsage?) {
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
                               modelId: String, baseURL: String, apiKey: String,
                               attachments: [ChatAttachment] = []) async throws -> (String, Bool, TokenUsage?) {
        let msgs = Self.anthropicMessages(messages, attachments: attachments)
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

    // MARK: - Request bodies
    //
    // Pure functions of (history, attachments) so the wire shape can be
    // asserted headlessly. Each one attaches to the LAST user message
    // and leaves every earlier turn as the plain string it was stored
    // as — replaying an image on every turn would bill for it again on
    // every turn.
    //
    // When there is nothing to attach the content stays a STRING, byte
    // for byte what it was before this existed. The array-of-parts form
    // is universal on paper and is not universally implemented, so the
    // 99% case must not travel through it.

    /// `messages` for OpenAI-style /chat/completions.
    static func openAIChatMessages(_ messages: [ChatMessage],
                                   system: String?,
                                   attachments: [ChatAttachment]) -> [[String: Any]] {
        var msgs: [[String: Any]] = []
        if let s = system, !s.isEmpty { msgs.append(["role": "system", "content": s]) }
        let convo = messages.filter { $0.role == "user" || $0.role == "assistant" }
        let target = convo.lastIndex { $0.role == "user" }
        for (i, m) in convo.enumerated() {
            if i == target,
               let parts = openAIChatParts(text: m.content, attachments: attachments) {
                msgs.append(["role": m.role, "content": parts])
            } else {
                msgs.append(["role": m.role, "content": m.content])
            }
        }
        return msgs
    }

    private static func openAIChatParts(text: String,
                                        attachments: [ChatAttachment]) -> [[String: Any]]? {
        var parts: [[String: Any]] = []
        for a in attachments {
            switch a.kind {
            case .image(let media):
                guard let b64 = a.base64 else { continue }
                parts.append(["type": "image_url",
                              "image_url": ["url": "data:\(media);base64,\(b64)"]])
            case .pdf:
                guard let t = a.text else { continue }
                parts.append(["type": "text",
                              "text": ChatAttachment.inlineBlock(name: a.name, text: t,
                                                                 truncated: a.textTruncated)])
            case .text:
                continue
            }
        }
        guard !parts.isEmpty else { return nil }
        if !text.isEmpty { parts.append(["type": "text", "text": text]) }
        return parts
    }

    /// `input` for the OpenAI Responses API.
    static func openAIResponsesInput(_ messages: [ChatMessage],
                                     attachments: [ChatAttachment]) -> [[String: Any]] {
        var input: [[String: Any]] = []
        let convo = messages.filter { $0.role == "user" || $0.role == "assistant" }
        let target = convo.lastIndex { $0.role == "user" }
        for (i, m) in convo.enumerated() {
            if i == target,
               let parts = openAIResponsesParts(text: m.content, attachments: attachments) {
                input.append(["role": m.role, "content": parts])
            } else {
                input.append(["role": m.role, "content": m.content])
            }
        }
        return input
    }

    private static func openAIResponsesParts(text: String,
                                             attachments: [ChatAttachment]) -> [[String: Any]]? {
        var parts: [[String: Any]] = []
        for a in attachments {
            guard let b64 = a.base64 else { continue }
            switch a.kind {
            case .image(let media):
                parts.append(["type": "input_image",
                              "image_url": "data:\(media);base64,\(b64)"])
            case .pdf:
                parts.append(["type": "input_file",
                              "filename": a.name,
                              "file_data": "data:application/pdf;base64,\(b64)"])
            case .text:
                continue
            }
        }
        guard !parts.isEmpty else { return nil }
        if !text.isEmpty { parts.append(["type": "input_text", "text": text]) }
        return parts
    }

    /// `messages` for the Anthropic Messages API. Images and documents
    /// go BEFORE the text block: the question reads as being about the
    /// thing above it, which is the order Anthropic documents.
    static func anthropicMessages(_ messages: [ChatMessage],
                                  attachments: [ChatAttachment]) -> [[String: Any]] {
        var msgs: [[String: Any]] = []
        let convo = messages.filter { $0.role == "user" || $0.role == "assistant" }
        let target = convo.lastIndex { $0.role == "user" }
        for (i, m) in convo.enumerated() {
            if i == target,
               let parts = anthropicParts(text: m.content, attachments: attachments) {
                msgs.append(["role": m.role, "content": parts])
            } else {
                msgs.append(["role": m.role, "content": m.content])
            }
        }
        return msgs
    }

    private static func anthropicParts(text: String,
                                       attachments: [ChatAttachment]) -> [[String: Any]]? {
        var parts: [[String: Any]] = []
        for a in attachments {
            guard let b64 = a.base64 else { continue }
            switch a.kind {
            case .image(let media):
                parts.append(["type": "image",
                              "source": ["type": "base64", "media_type": media, "data": b64]])
            case .pdf:
                parts.append(["type": "document",
                              "source": ["type": "base64",
                                         "media_type": "application/pdf",
                                         "data": b64]])
            case .text:
                continue
            }
        }
        guard !parts.isEmpty else { return nil }
        if !text.isEmpty { parts.append(["type": "text", "text": text]) }
        return parts
    }

    /// Pull the reply's own token accounting out of the response body.
    /// Handles both spellings: input_tokens/output_tokens (Anthropic,
    /// Responses API) and prompt_tokens/completion_tokens (Chat
    /// Completions).
    nonisolated private static func parseUsage(_ json: [String: Any]) -> TokenUsage? {
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

    // MARK: - SSE plumbing

    /// What a server-sent stream has said so far. Built up one `data:`
    /// payload at a time by the fold functions below, which are pure
    /// and `static` so the harness can drive them with captured
    /// streams — no server, no network.
    struct SSEAssembly {
        var text = ""
        /// "length" (chat completions) or "incomplete" (Responses)
        /// marks a reply cut by the token ceiling.
        var finishReason: String?
        var usage: TokenUsage?
        /// A failure the stream itself reported. Checked by the caller
        /// before the text is trusted.
        var errorMessage: String?
    }

    /// One chat-completions `data:` payload. The final chunk under
    /// `stream_options.include_usage` carries an EMPTY `choices` array
    /// and only the usage block — indexing `choices[0]` there is a
    /// crash, which is why everything here is conditional. Deltas that
    /// are not `content` (`reasoning_content`, tool calls) are
    /// deliberately ignored: the reply is the content.
    nonisolated static func foldChatCompletionsLine(_ payload: String, into acc: inout SSEAssembly) {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let err = json["error"] as? [String: Any] {
            acc.errorMessage = (err["message"] as? String) ?? "stream error"
            return
        }
        if let usage = parseUsage(json) { acc.usage = usage }
        guard let first = (json["choices"] as? [[String: Any]])?.first else { return }
        if let delta = first["delta"] as? [String: Any],
           let piece = delta["content"] as? String {
            acc.text += piece
        }
        if let finish = first["finish_reason"] as? String {
            acc.finishReason = finish
        }
    }

    /// One Responses-API `data:` payload. Each carries its own `type`,
    /// so the `event:` lines never need to be tracked. Only the text
    /// deltas and the terminal events matter; everything else
    /// (reasoning summaries, item bookkeeping) is stream furniture.
    nonisolated static func foldResponsesLine(_ payload: String, into acc: inout SSEAssembly) {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }
        switch type {
        case "response.output_text.delta":
            if let piece = json["delta"] as? String { acc.text += piece }
        case "response.completed", "response.incomplete":
            guard let response = json["response"] as? [String: Any] else { return }
            if let usage = parseUsage(response) { acc.usage = usage }
            if (response["status"] as? String) == "incomplete" {
                acc.finishReason = "incomplete"
            }
            // Belt: a server that never emitted deltas still ends with
            // the whole reply inside the terminal event.
            if acc.text.isEmpty, let whole = try? parseResponsesJSON(response) {
                acc.text = whole.0
            }
        case "response.failed", "error":
            let err = (json["response"] as? [String: Any])?["error"] as? [String: Any]
                ?? json["error"] as? [String: Any]
            acc.errorMessage = (err?["message"] as? String)
                ?? (json["message"] as? String)
                ?? "stream error"
        default:
            break
        }
    }

    /// POST `body` and assemble the SSE reply with `fold`. Streaming on
    /// the wire, delivered whole. An error status still arrives as
    /// ordinary JSON, so it is read out and thrown as the same
    /// `APIError.http` the non-streaming path produces — which is what
    /// keeps the 400-shaped retries (token param, stream support,
    /// attachment rejection) working unchanged on top of this.
    private func postSSE(url: URL, body: [String: Any],
                         headers: [String: String],
                         fold: (String, inout SSEAssembly) -> Void) async throws -> SSEAssembly {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Generous for the same reason as postJSON: this now only has
        // to outlast the THINK, not the whole reply.
        req.timeoutInterval = 3600
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        do {
            let (bytes, resp) = try await ProviderHTTP.session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw APIError.transport("non-HTTP response")
            }
            if http.statusCode >= 400 {
                var data = Data()
                for try await b in bytes {
                    data.append(b)
                    if data.count > 262_144 { break }
                }
                throw APIError.http(http.statusCode,
                                    String(data: data, encoding: .utf8) ?? "<no body>")
            }
            var acc = SSEAssembly()
            for try await rawLine in bytes.lines {
                let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                fold(payload, &acc)
            }
            return acc
        } catch let e as APIError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            // Same rule as postJSON: Stop must read as Stop, not as a
            // "Network error: cancelled" banner.
            throw CancellationError()
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
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
