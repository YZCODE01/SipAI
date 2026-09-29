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
// ("model.not_configured: Model not set" — measured, even with a
// `default_model` configured): the model is bound by the FIRST prompt.
// So the first prompt goes through the server, which takes
// `disabled_tools` per prompt, and every later turn is an ordinary
// `--prompt --session` around the policy file.
//
// Measured on kimi-code 2.0.1 over a throwaway `KIMI_CODE_HOME` (the
// harness reproduces each):
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
//   * The server writes the session's `tool-policy/state.json` itself
//     for that prompt, and the file outlives the server — so the caller
//     restores it (`.absent`) when the turn ends.
//   * `GET /sessions/{id}` answers `busy` and `main_turn_active`;
//     `/status` answers `busy` alone. Idle is both false.
//   * Stop: the prompt action route `POST …/prompts/{prompt_id}::abort`
//     is mounted (it reaches kimi's `abortPromptAction`) but on 2.0.1
//     answered "prompt …: not found" for a running prompt, as did the
//     session-level `…/sessions/{id}::abort`; `POST /api/v1/shutdown`
//     certainly ends it — the wire then records `turn.ended reason:
//     cancelled` and `prompt.aborted`, and the server exits within a
//     few seconds. So Stop tries the action route and shuts down
//     whether or not it answered.
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

    // MARK: - Request layer (pure)

    static var sessionsPath: String { apiPrefix + "/sessions" }
    static func sessionPath(_ id: String) -> String { sessionsPath + "/" + id }
    static func promptsPath(_ id: String) -> String { sessionPath(id) + "/prompts" }
    static func abortPath(session: String, prompt: String) -> String {
        promptsPath(session) + "/" + prompt + "::abort"
    }

    /// `{metadata:{cwd}}` — the RESOLVED path (see the header).
    static func createSessionBody(cwd: URL) -> [String: Any] {
        ["metadata": ["cwd": resolvedPath(cwd)]]
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
    /// text), the profile and model the route needs to bind before it
    /// can honour `disabled_tools`, and the names. `thinking` is
    /// deliberately absent — the string the route takes for it is
    /// unmeasured. Images ride this first turn only, the shape kimi's
    /// route takes (`source.kind == "base64"`, `ChatOnlyImages`).
    static func promptBody(text: String, model: String, disabledTools: [String],
                           images: [AgentImage] = []) -> [String: Any] {
        [
            "content": ChatOnlyImages.kimiContentBlocks(text: text, images: images),
            "profile": profileName,
            "model": model,
            "disabled_tools": disabledTools,
        ]
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
    static func createSession(_ session: KimiWebServerCall.Session,
                              cwd: URL) async -> Result<String, Failure> {
        let answer = await session.request(method: "POST", path: sessionsPath,
                                           body: createSessionBody(cwd: cwd),
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
                       disabledTools: [String],
                       images: [AgentImage] = []) async -> Result<String, Failure> {
        let answer = await session.request(method: "POST", path: promptsPath(sessionId),
                                           body: promptBody(text: text, model: model,
                                                            disabledTools: disabledTools,
                                                            images: images),
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

    /// Poll until the session is idle, or `isCancelled` says stop.
    /// Answers true when idle was observed, false when the wait was
    /// abandoned (cancelled, or the server stopped answering).
    static func waitIdle(_ session: KimiWebServerCall.Session, sessionId: String,
                         isCancelled: @Sendable () -> Bool) async -> Bool {
        var misses = 0
        while !isCancelled() {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if isCancelled() { return false }
            let answer = await session.request(method: "GET", path: sessionPath(sessionId))
            switch answer {
            case .success(let data):
                misses = 0
                if isIdle(sessionAnswer: data) == true { return true }
            case .failure:
                // A server that stops answering for a while is a server
                // that is gone; the turn cannot end, so stop waiting.
                misses += 1
                if misses >= 6 { return false }
            }
        }
        return false
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
