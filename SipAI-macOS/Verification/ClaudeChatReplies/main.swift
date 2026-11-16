// Headless check of a chat with a Claude model: what the Messages API is
// sent, and what SipAI reads back.
//
// Compiles the REAL APIClient.swift against stand-ins for the config
// layer and drives `APIClient.sendChat` against anthropic_server.py, a
// local stand-in that answers in the shapes Anthropic documents. It never
// touches ~/Library/Application Support/SipAI and never leaves 127.0.0.1.
//
// The failures this guards are quiet ones: current Claude models think
// before they answer, and a reader that takes the first content block as
// the reply turns every such answer into a decode error; a cap the
// thinking counts toward cuts the answer off before it starts.

import Foundation

var failures = 0
var checks = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        let why = detail()
        print("  FAIL \(label)" + (why.isEmpty ? "" : " — \(why)"))
    }
}

func section(_ title: String) { print("\n\(title)") }

/// The Messages API version SipAI speaks: Anthropic's newest
/// (https://platform.claude.com/docs/en/api/versioning). It refuses
/// `temperature`, `top_p` and `top_k`, a `document` block in an
/// `assistant` message, and a user `text` block with citations, each with
/// a 400 — the checks below hold SipAI's requests to that. Moving the
/// version means reading its migration notes against them again.
let anthropicVersion = "2026-10-21"

/// The stand-in: started, its port read, stopped by closing its stdin.
/// nil when python3 or the script is missing.
func startStandIn() -> (port: Int, stop: () -> Void)? {
    guard let script = ProcessInfo.processInfo.environment["ANTHROPIC_STANDIN"],
          FileManager.default.fileExists(atPath: script),
          FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [script]
    let stdin = Pipe(), stdout = Pipe()
    p.standardInput = stdin
    p.standardOutput = stdout
    guard (try? p.run()) != nil else { return nil }
    var line = Data()
    while true {
        let byte = stdout.fileHandleForReading.readData(ofLength: 1)
        if byte.isEmpty || byte == Data("\n".utf8) { break }
        line.append(byte)
    }
    guard let port = Int(String(decoding: line, as: UTF8.self)) else { p.terminate(); return nil }
    return (port, { try? stdin.fileHandleForWriting.close(); p.waitUntilExit() })
}

typealias Reply = (text: String, time: Double, truncated: Bool, usage: TokenUsage?)

@MainActor
func send(_ client: APIClient, _ model: String) async -> Result<Reply, Error> {
    do {
        let reply = try await client.sendChat(
            messages: [ChatMessage(role: "user", content: "What is six times seven?")],
            modelId: model,
            systemPrompt: "Answer briefly.")
        return .success(reply)
    } catch {
        return .failure(error)
    }
}

func describe(_ result: Result<Reply, Error>) -> String {
    switch result {
    case .success(let reply):
        return "text \(reply.text.debugDescription), truncated \(reply.truncated)"
    case .failure(let error):
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

/// What the stand-in received, oldest first.
func readLog(port: Int) async -> [[String: Any]] {
    guard let url = URL(string: "http://127.0.0.1:\(port)/harness/log"),
          let (data, _) = try? await URLSession(configuration: .ephemeral).data(from: url),
          let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return entries
}

func posts(_ log: [[String: Any]], model: String) -> [[String: Any]] {
    log.filter {
        ($0["method"] as? String) == "POST"
            && (($0["body"] as? [String: Any])?["model"] as? String) == model
    }
}

func body(_ entry: [String: Any]?) -> [String: Any] {
    (entry?["body"] as? [String: Any]) ?? [:]
}

Task { @MainActor in
    section("1. A Claude reply through the real sendChat (local stand-in)")

    if let standIn = startStandIn() {
        let config = ConfigManager()
        config.providers["anthropic"] = ProviderConfig(
            key: "anthropic", name: "Anthropic",
            baseURL: "http://127.0.0.1:\(standIn.port)/v1",
            apiStyle: "anthropic", apiKey: nil, envVar: nil,
            authHeader: "x-api-key", authPrefix: "")
        config.keys["anthropic"] = "sk-harness-key"
        for id in ["claude-thinks", "claude-thinks-cut", "claude-no-stream",
                   "claude-null-max", "claude-unlisted", "claude-overloaded",
                   "claude-slow-lookup"] {
            config.models[id] = ModelConfig(id: id, name: id, providerKey: "anthropic", apiStyle: nil)
        }
        let client = APIClient(config: config)

        let thinks = await send(client, "claude-thinks")
        check("a reply that starts with a thinking block is read",
              (try? thinks.get().text) == "The answer is 42.", describe(thinks))
        let usage = (try? thinks.get())?.usage
        check("its usage is the reply's own (25 in, 15 out)",
              usage?.input == 25 && usage?.output == 15,
              "got \(String(describing: usage.map { ($0.input, $0.output) }))")

        var log = await readLog(port: standIn.port)
        let thinkPost = posts(log, model: "claude-thinks").last
        check("the request streams", body(thinkPost)["stream"] as? Bool == true,
              "stream = \(String(describing: body(thinkPost)["stream"]))")
        check("its cap is the model's published maximum (64,000)",
              body(thinkPost)["max_tokens"] as? Int == 64000,
              "max_tokens = \(String(describing: body(thinkPost)["max_tokens"]))")
        check("the key and the API version ride the request",
              thinkPost?["x-api-key"] as? String == "sk-harness-key"
                && thinkPost?["anthropic-version"] as? String == anthropicVersion,
              "anthropic-version = \(String(describing: thinkPost?["anthropic-version"]))")
        check("…and none of the parameters that version refuses (temperature, top_p, top_k)",
              ["temperature", "top_p", "top_k"].allSatisfy { body(thinkPost)[$0] == nil })

        let again = await send(client, "claude-thinks")
        log = await readLog(port: standIn.port)
        let lookups = log.filter {
            ($0["method"] as? String) == "GET" && ($0["path"] as? String) == "/v1/models/claude-thinks"
        }
        check("the maximum is asked for once per model, not per message",
              lookups.count == 1 && (try? again.get().text) == "The answer is 42.",
              "\(lookups.count) lookups; \(describe(again))")
        check("the lookup carries the key and the API version",
              lookups.first?["x-api-key"] as? String == "sk-harness-key"
                && lookups.first?["anthropic-version"] as? String == anthropicVersion)

        let cut = await send(client, "claude-thinks-cut")
        if case .success(let reply) = cut {
            check("a reply cut off while thinking is a cut-off reply, not a decode error",
                  reply.truncated && reply.text.isEmpty, describe(cut))
        } else {
            check("a reply cut off while thinking is a cut-off reply, not a decode error",
                  false, describe(cut))
        }

        let noStream = await send(client, "claude-no-stream")
        check("a server that refuses to stream gets the plain request, its text blocks joined",
              (try? noStream.get().text) == "Part one. Part two.", describe(noStream))
        log = await readLog(port: standIn.port)
        let plainPost = posts(log, model: "claude-no-stream").last { body($0)["stream"] as? Bool != true }
        check("the plain request carries the same cap (8,192)",
              body(plainPost)["max_tokens"] as? Int == 8192,
              "max_tokens = \(String(describing: body(plainPost)["max_tokens"]))")

        let nullMax = await send(client, "claude-null-max")
        log = await readLog(port: standIn.port)
        check("a model that publishes no maximum keeps 16,384",
              (try? nullMax.get().text) == "Plain reply."
                && body(posts(log, model: "claude-null-max").last)["max_tokens"] as? Int == 16384,
              describe(nullMax))

        let unlisted = await send(client, "claude-unlisted")
        log = await readLog(port: standIn.port)
        check("a model the list does not know keeps 16,384, and the chat still works",
              (try? unlisted.get().text) == "Plain reply."
                && body(posts(log, model: "claude-unlisted").last)["max_tokens"] as? Int == 16384,
              describe(unlisted))

        let overloaded = await send(client, "claude-overloaded")
        if case .failure = overloaded {
            check("an error the stream reports is said in Anthropic's words",
                  describe(overloaded).contains("Overloaded"), describe(overloaded))
        } else {
            check("an error the stream reports is said in Anthropic's words", false, describe(overloaded))
        }

        // Stop while the first lookup of a model's maximum is still on
        // its way: the lookup is cut short with the turn, and must not be
        // remembered as "this model publishes none" — that would hold the
        // fallback cap for ten minutes on a model that publishes one.
        let stopped = Task { @MainActor in await send(client, "claude-slow-lookup") }
        try? await Task.sleep(nanoseconds: 250_000_000)
        stopped.cancel()
        let stoppedResult = await stopped.value
        var stoppedAsStop = false
        if case .failure(let error) = stoppedResult { stoppedAsStop = error is CancellationError }
        check("a Stop during the cap lookup ends the turn as a Stop", stoppedAsStop, describe(stoppedResult))
        let afterStop = await send(client, "claude-slow-lookup")
        log = await readLog(port: standIn.port)
        let slowLookups = log.filter {
            ($0["method"] as? String) == "GET" && ($0["path"] as? String) == "/v1/models/claude-slow-lookup"
        }
        let afterStopCap = body(posts(log, model: "claude-slow-lookup").last)["max_tokens"] as? Int
        check("the maximum is asked again after a Stop cut its first lookup short",
              slowLookups.count == 2 && afterStopCap == 64000
                && (try? afterStop.get().text) == "Plain reply.",
              "\(slowLookups.count) lookups; max_tokens = \(String(describing: afterStopCap)); \(describe(afterStop))")
        standIn.stop()
    } else {
        print("  SKIP  no python3 or no anthropic_server.py — the stand-in could not start")
    }

    section("2. The stream reader and the plain reader, line by line")

    func fold(_ payloads: [String]) -> APIClient.SSEAssembly {
        var acc = APIClient.SSEAssembly()
        for p in payloads { APIClient.foldAnthropicLine(p, into: &acc) }
        return acc
    }
    // Summarized thinking: the thinking deltas carry words, and none of
    // them is the reply.
    let summarized = fold([
        #"{"type":"message_start","message":{"usage":{"input_tokens":40,"output_tokens":1}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Six sevens are forty-two."}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQB"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"ping"}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"42"}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":30}}"#,
        #"{"type":"message_stop"}"#,
    ])
    check("thinking words never reach the reply", summarized.text == "42", summarized.text.debugDescription)
    check("usage is input from message_start, output from message_delta",
          summarized.usage?.input == 40 && summarized.usage?.output == 30)
    check("an end_turn stop is not a cut-off", summarized.finishReason == "end_turn")
    check("an event type nobody has seen yet is passed over",
          fold([#"{"type":"harness_new_event","delta":{"type":"text_delta","text":"no"}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"yes"}}"#])
              .text == "yes")
    check("a malformed line is passed over",
          fold(["not json", #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}"#])
              .text == "ok")
    check("an error event is captured in Anthropic's words",
          fold([#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#])
              .errorMessage == "Overloaded")
    check("a max_tokens stop is kept as sent",
          fold([#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":9}}"#])
              .finishReason == "max_tokens")

    func plain(_ json: String) -> Result<(String, Bool, TokenUsage?), Error> {
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return Result { try APIClient.parseAnthropicJSON(obj) }
    }
    let joined = plain(#"{"content":[{"type":"thinking","thinking":"","signature":"x"},{"type":"text","text":"A"},{"type":"text","text":"B"}],"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":3}}"#)
    check("plain reply: thinking passed over, text blocks joined in order",
          (try? joined.get().0) == "AB")
    let cutPlain = plain(#"{"content":[{"type":"thinking","thinking":"","signature":"x"}],"stop_reason":"max_tokens"}"#)
    check("plain reply: no text at the cap is a cut-off reply",
          (try? cutPlain.get().0) == "" && (try? cutPlain.get().1) == true)
    // Anthropic's other cut-off: the reply filled the model's context
    // window before it reached the cap ("Treat the response as
    // truncated"). A cap set to the model's own maximum is exactly the
    // request that can end this way.
    let windowPlain = plain(#"{"content":[{"type":"text","text":"Partial"}],"stop_reason":"model_context_window_exceeded"}"#)
    check("plain reply: a stop at the context window is a cut-off reply",
          (try? windowPlain.get().0) == "Partial" && (try? windowPlain.get().1) == true,
          String(describing: try? windowPlain.get()))
    if case .failure(let error) = plain(#"{"content":[],"stop_reason":"refusal"}"#) {
        let words = (error as? LocalizedError)?.errorDescription ?? ""
        check("plain reply: no text otherwise is a failure that names the stop reason",
              words.contains("refusal"), words)
    } else {
        check("plain reply: no text otherwise is a failure that names the stop reason", false)
    }

    section("3. What the version refuses, held to every request's messages")

    // A conversation with answers in it, and a PDF and an image on its
    // newest question: the attachments ride the USER message alone, and
    // no text block carries citations.
    let history = [
        ChatMessage(role: "user", content: "First question"),
        ChatMessage(role: "assistant", content: "First answer"),
        ChatMessage(role: "user", content: "What is in these?"),
    ]
    let pdf = ChatAttachment(url: URL(fileURLWithPath: "/dev/null"), name: "a.pdf", kind: .pdf,
                             byteCount: 4, base64: "JVBERg==", text: nil, textTruncated: false)
    let png = ChatAttachment(url: URL(fileURLWithPath: "/dev/null"), name: "b.png",
                             kind: .image(mediaType: "image/png"), byteCount: 4,
                             base64: "iVBORw==", text: nil, textTruncated: false)
    let sent = APIClient.anthropicMessages(history, attachments: [pdf, png])
    let blocks: [(role: String, block: [String: Any])] = sent.flatMap { message -> [(String, [String: Any])] in
        let role = message["role"] as? String ?? ""
        return ((message["content"] as? [[String: Any]]) ?? []).map { (role, $0) }
    }
    check("the PDF rides a user message as a document block",
          blocks.contains { $0.role == "user" && $0.block["type"] as? String == "document" })
    check("no assistant message carries a block of any kind (a document there is refused)",
          sent.filter { $0["role"] as? String == "assistant" }.allSatisfy { $0["content"] is String })
    check("no block carries citations (refused in a user text block)",
          blocks.allSatisfy { $0.block["citations"] == nil })

    print("\n\(checks - failures) of \(checks) checks passed")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
