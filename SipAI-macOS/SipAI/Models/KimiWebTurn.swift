// KimiWebTurn.swift
// A NEW kimi session's first Chat only turn, through kimi's own local
// server (`kimi web` — part of every kimi install, the same server
// SipAI already starts for sign-in and the usage window; not an API
// key, not a paid route, the same membership as `--prompt`).
//
// Why a server for the first turn only. Kimi binds its tools and its
// persona at SESSION creation and refuses both on resume, so a print-
// mode turn cannot switch tools off from its command line. What every
// `--prompt` turn DOES read is the session's `tool-policy/state.json`
// (`KimiToolPolicy`) — but a session that does not exist yet has no
// directory to put that file in, and a session born through the server
// but never prompted refuses `--prompt --session` outright
// ("model.not_configured: Model not set", even with a `default_model`
// configured): the model is bound by the FIRST prompt.
// So the first prompt goes through the server, which takes
// `disabled_tools` per prompt, and every later turn is an ordinary
// `--prompt --session` around the policy file.
//
// What the server does, each fact reproduced by the harness over a
// throwaway `KIMI_CODE_HOME`:
//
//   * `POST /api/v1/sessions {metadata:{cwd}}` creates the directory
//     (`state.json` with the cwd, `notify/`) before any turn. The cwd
//     MUST be the RESOLVED path — `realpath(3)`, `/private` included:
//     kimi's own `--prompt` computes the bucket from `process.cwd()`,
//     which is the kernel's real path, and a session created under
//     `/tmp/x` (or `/var/…`) while the turn runs in `/private/tmp/x`
//     is refused as "created under a different directory".
//   * `POST /sessions/{id}/prompts` with `disabled_tools` on a never-
//     prompted session is refused — "Cannot set session disabled
//     tools: agent profile is not bound" — unless the SAME request
//     carries `profile: "agent"` (kimi's built-in default profile,
//     read out of the wire's `profile.bind` record) and `model:
//     <alias>`, which the route applies first. With them every listed
//     tool is off (all 26 listed → 0 tools).
//   * A newer kimi binds the profile and the model when the session
//     is CREATED (`agent_config: {profile, model}`): a prompt
//     naming a profile is refused ("choose the agent profile with
//     agent_config.profile when creating the session"). And the tools a
//     prompt's `disabled_tools` names are stored in the policy file and
//     NOT applied to that prompt's turn — every tool is still sent;
//     kimi applies the file when it OPENS the session. So on such a kimi
//     the session is closed once made, its file written by the caller,
//     and a fresh server opens it for the prompt, which carries no list
//     (`Binding`; measured: one tool sent, the web lookup Chat only keeps).
//   * The server writes the session's `tool-policy/state.json` itself
//     for that prompt (a kimi that binds on the first prompt), and the
//     file outlives the server — so the caller restores it (`.absent`)
//     when the turn ends.
//   * `GET /sessions/{id}` answers `busy` and `main_turn_active`;
//     `/status` answers `busy` alone. Idle is both false.
//   * A turn kimi ends as FAILED — the model unreachable after kimi's
//     own retries — answers idle all the same, `last_turn_reason:
//     "failed"` beside `busy`. Why is in the record's `turn.ended`,
//     written before the session first answers idle, and so is each
//     retry while it waits (`turn.step.retrying`). Read as "idle" alone,
//     the turn ends on no row at all — the question with nothing under
//     it — however long kimi spent retrying.
//   * Stop: the prompt action route is `POST …/prompts/{prompt_id}:abort`
//     — ONE colon. Kimi splits the action off the LAST colon, so a
//     doubled one asks for the prompt `<id>:` and is answered "prompt …:
//     not found" while the turn runs on. Answered, the route says
//     `{"aborted": true}`, the session is idle within a second, and the
//     wire records `turn.cancel`, `turn.ended reason: cancelled` and
//     `prompt.aborted`. `POST /api/v1/shutdown` then ends the server
//     (and with it any turn the route did not reach), so Stop sends
//     both, whatever the route answered.
//
// The request layer is pure over bytes and paths; the two async drivers
// run over `KimiWebServerCall.Session` (start on a free port, PTY,
// bearer, app-wide occupancy, shutdown) and are what the harness drives
// against the real kimi. No MainActor: the runner calls in.

import Foundation

enum KimiWebTurn {
    /// Kimi's built-in default profile — the one `profile.bind` records
    /// for every print-mode session. A fact of the binary, not of any
    /// Mac; the harness reads it off a real wire.
    static let profileName = "agent"
    static let apiPrefix = "/api/v1"
    /// How often the session is asked whether its turn is over.
    static let pollInterval: TimeInterval = 0.5
    /// The one-shot ceilings; the WAIT for the turn has none — a turn
    /// takes as long as the model takes, and Stop is the way out, as it
    /// is for a child process.
    static let createCeiling: TimeInterval = 15
    static let promptCeiling: TimeInterval = 15
    static let abortCeiling: TimeInterval = 5

    /// Where a new session's profile and model are bound.
    enum Binding: Equatable {
        /// On the first prompt, beside `disabled_tools`: a kimi before
        /// `atCreationFloor`.
        case onFirstPrompt
        /// In `agent_config` when the session is created: the kimi that
        /// refuses a prompt naming a profile, and applies the tools a
        /// session's policy file names only when it opens the session.
        case atCreation

        static let atCreationFloor = "2.6.1"

        /// The binding the installed kimi takes. A version not read yet
        /// answers the older one; Chat only is not offered before kimi's
        /// version is read.
        static func of(kimiVersion: String?) -> Binding {
            ChatOnlyAvailability.versionAtLeast(kimiVersion, atCreationFloor) ? .atCreation : .onFirstPrompt
        }
    }

    // MARK: - Request layer (pure)

    static var sessionsPath: String { apiPrefix + "/sessions" }
    static func sessionPath(_ id: String) -> String { sessionsPath + "/" + id }
    static func promptsPath(_ id: String) -> String { sessionPath(id) + "/prompts" }
    static func abortPath(session: String, prompt: String) -> String {
        promptsPath(session) + "/" + prompt + ":abort"
    }

    /// `{metadata:{cwd}}` — the RESOLVED path (see the header) — and, for
    /// a kimi that binds at creation, the profile and the model.
    static func createSessionBody(cwd: URL, model: String, binding: Binding) -> [String: Any] {
        var body: [String: Any] = ["metadata": ["cwd": resolvedPath(cwd)]]
        if binding == .atCreation {
            body["agent_config"] = ["profile": profileName, "model": model]
        }
        return body
    }

    /// `realpath(3)` of a directory — what `process.cwd()` answers the
    /// kimi that later resumes the session. NOT `URL
    /// .resolvingSymlinksInPath()`, which deliberately strips the
    /// `/private` prefix macOS puts on `/var` and `/tmp` (measured: it
    /// answers `/var/folders/…` where the kernel says `/private/var/…`),
    /// so a session created from it is refused as "created under a
    /// different directory".
    static func resolvedPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        if let resolved = realpath(url.path, &buffer) {
            return String(cString: resolved)
        }
        return url.standardizedFileURL.path
    }

    /// The first prompt's body: the content (image blocks, then the
    /// text) and, for a kimi that binds on the first prompt, the profile
    /// and model the route needs to bind before it can honour
    /// `disabled_tools`, and the names. A kimi that binds at creation
    /// gets the content alone: its session's policy file names the tools
    /// (see the header). `thinking` is deliberately absent — the string
    /// the route takes for it is unmeasured. Images ride this first turn
    /// only, the shape kimi's route takes (`source.kind == "base64"`,
    /// `ChatOnlyImages`).
    static func promptBody(text: String, model: String, disabledTools: [String],
                           binding: Binding, images: [AgentImage] = []) -> [String: Any] {
        var body: [String: Any] = ["content": ChatOnlyImages.kimiContentBlocks(text: text, images: images)]
        if binding == .onFirstPrompt {
            body["profile"] = profileName
            body["model"] = model
            body["disabled_tools"] = disabledTools
        }
        return body
    }

    /// `data.id` of a created session.
    static func sessionId(fromCreateAnswer data: Data) -> String? {
        guard let obj = envelopeData(data), let id = obj["id"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    /// `data.prompt_id` of a submitted prompt.
    static func promptId(fromPromptAnswer data: Data) -> String? {
        guard let obj = envelopeData(data), let id = obj["prompt_id"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    /// Whether a session answer says the turn is over: `busy` false and
    /// `main_turn_active` not true (absent counts as false — `/status`
    /// omits it). nil when the answer is not a session object at all.
    static func isIdle(sessionAnswer data: Data) -> Bool? {
        guard let obj = envelopeData(data), let busy = obj["busy"] as? Bool else { return nil }
        let mainTurn = (obj["main_turn_active"] as? Bool) ?? false
        return !busy && !mainTurn
    }

    /// How a session answer says its last turn ended
    /// (`last_turn_reason`: "failed" for a turn whose model never
    /// answered), or nil where it does not say.
    static func lastTurnReason(sessionAnswer data: Data) -> String? {
        guard let obj = envelopeData(data), let reason = obj["last_turn_reason"] as? String,
              !reason.isEmpty
        else { return nil }
        return reason
    }

    /// Why the turn failed, as its row says it, or nil for a turn that
    /// did not fail. A failed turn answers idle like any other, so
    /// "idle" is never "answered": kimi's words are the record's (the
    /// reader's `.error` row — `KimiSessionScanner.failedTurnReason`),
    /// and a server saying the turn failed while the record holds no
    /// such row still ends it, on `wordless`.
    ///
    /// - Parameter items: the turn's rows, as the reader drew them.
    static func failure(in items: [AgentSessionHistoryItem], lastTurnReason: String?,
                        wordless: String) -> String? {
        for item in items {
            if case .error(let message) = item.kind { return message }
        }
        return lastTurnReason == "failed" ? wordless : nil
    }

    /// Kimi's own sentence out of an error envelope (`msg` beside a
    /// non-zero `code`), or nil when the bytes are not one.
    static func refusal(from data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = (obj["code"] as? NSNumber)?.intValue, code != 0,
              let msg = obj["msg"] as? String, !msg.isEmpty
        else { return nil }
        return msg
    }

    /// The `data` object of a success envelope.
    private static func envelopeData(_ data: Data) -> [String: Any]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if let inner = obj["data"] as? [String: Any] { return inner }
        // A bare object (no envelope) is accepted for the same keys.
        return obj["code"] == nil ? obj : nil
    }

    // MARK: - Drivers over the server session

    enum Failure: Error, Equatable {
        /// The server did not answer, or answered with something that is
        /// not the measured shape. Carries the transport's or kimi's own
        /// words.
        case unavailable(String)
        /// Kimi refused, in its own words.
        case refused(String)
    }

    /// Create the session. Answers its id.
    static func createSession(_ session: KimiWebServerCall.Session, cwd: URL, model: String,
                              binding: Binding) async -> Result<String, Failure> {
        let body = createSessionBody(cwd: cwd, model: model, binding: binding)
        let answer = await session.request(method: "POST", path: sessionsPath, body: body,
                                           ceiling: createCeiling)
        switch answer {
        case .failure(let error):
            return .failure(.unavailable(error.localizedDescription))
        case .success(let data):
            guard let id = sessionId(fromCreateAnswer: data) else {
                return .failure(.unavailable(refusal(from: data)
                                             ?? "the server's answer named no session"))
            }
            return .success(id)
        }
    }

    /// Submit the first prompt. Answers the prompt id.
    static func prompt(_ session: KimiWebServerCall.Session, sessionId: String,
                       text: String, model: String,
                       disabledTools: [String], binding: Binding,
                       images: [AgentImage] = []) async -> Result<String, Failure> {
        let body = promptBody(text: text, model: model, disabledTools: disabledTools,
                              binding: binding, images: images)
        let answer = await session.request(method: "POST", path: promptsPath(sessionId), body: body,
                                           ceiling: promptCeiling)
        switch answer {
        case .failure(let error):
            return .failure(.refused(error.localizedDescription))
        case .success(let data):
            if let why = refusal(from: data) { return .failure(.refused(why)) }
            guard let id = promptId(fromPromptAnswer: data) else {
                return .failure(.unavailable("the server's answer named no prompt"))
            }
            return .success(id)
        }
    }

    /// What the session said once it was idle.
    struct Idle: Equatable {
        /// `lastTurnReason(sessionAnswer:)` of the idle answer.
        let lastTurnReason: String?
    }

    /// Poll until the session is idle, or `isCancelled` says stop.
    /// Answers what the idle session said, nil when the wait was
    /// abandoned (cancelled, or the server stopped answering).
    static func waitIdle(_ session: KimiWebServerCall.Session, sessionId: String,
                         isCancelled: @Sendable () -> Bool) async -> Idle? {
        var misses = 0
        while !isCancelled() {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if isCancelled() { return nil }
            let answer = await session.request(method: "GET", path: sessionPath(sessionId))
            switch answer {
            case .success(let data):
                misses = 0
                if isIdle(sessionAnswer: data) == true {
                    return Idle(lastTurnReason: lastTurnReason(sessionAnswer: data))
                }
            case .failure:
                // A server that stops answering for a while is a server
                // that is gone; the turn cannot end, so stop waiting.
                misses += 1
                if misses >= 6 { return nil }
            }
        }
        return nil
    }

    /// Stop a running prompt: the action route, then the shutdown that
    /// certainly ends it (`Session.shutdown` is idempotent and releases
    /// the occupancy).
    static func abort(_ session: KimiWebServerCall.Session, sessionId: String,
                      promptId: String) async {
        _ = await session.request(method: "POST",
                                  path: abortPath(session: sessionId, prompt: promptId),
                                  ceiling: abortCeiling)
        await session.shutdown()
    }
}
