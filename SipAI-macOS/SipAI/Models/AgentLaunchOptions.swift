// AgentLaunchOptions.swift
// Per-send launch options for a Claude Code subprocess, plus the
// catalogs behind the composer's mode / model / effort pickers.
//
// The scraped lists come from `claude --help` so a mode/level Anthropic
// adds shows up without a SipAI release; the hardcoded tuples are only
// the fallback for when the binary is missing or the help shape changes.

import Foundation

/// The three optional flags a send can attach to `claude`.
/// `nil` means "claude's own default" and emits no flag at all.
struct AgentLaunchOptions: Equatable, Hashable {
    var permissionMode: String? = nil
    var model: String? = nil
    var effort: String? = nil
    /// Full model id the session actually ran on ("claude-opus-5"),
    /// from the JSONL's assistant records or a live system.init event.
    /// Display-only: it feeds the chip's hover ("last ran as …") while
    /// `model` stays the picker alias. Never emitted as a flag; saved
    /// with the session's picks as `model_full_id` and dropped on read
    /// when it contradicts the alias beside it; cleared when the user
    /// picks a model so a stale id can't shadow their choice.
    var modelFullId: String? = nil
    /// Claude's "fast mode" — the same model with faster output, drawn
    /// from usage credits at a higher rate. Print mode refuses it
    /// without an explicit opt-in on the FLAG layer (`--settings
    /// {"fastMode":true}`), and only the models claude's own catalog
    /// marks `fast_mode` take it (`ClaudeModelCatalog
    /// .fastModeSupported`). The switch is the REQUEST; whether a call
    /// actually ran fast is claude's to say, per call
    /// (`ClaudeFastModeReport`).
    ///
    /// On a codex session this is only ever a value saved before codex
    /// had a speed choice of its own, read as "the model's Fast tier"
    /// while `serviceTier` is nil. Kimi has no such mode.
    var fastMode: Bool = false
    /// Codex's speed, as a pick among the service tiers the model's
    /// catalog entry advertises: nil follows codex's own default (the
    /// `service_tier` in its config.toml, else the model's
    /// `default_service_tier`), `CodexSpeed.standard` ("default", codex's
    /// own spelling of an explicit standard) turns every tier off, and
    /// anything else is a tier id ("priority" is the one codex names
    /// Fast). Persisted as `service_tier`; claude and kimi ignore it.
    var serviceTier: String? = nil
    /// The exact value a codex SEND passes as `-c service_tier=`, nil to
    /// pass nothing — resolved per send from `serviceTier` by
    /// `CodexCatalog.serviceTierOverride(for:)` for a composer send, and
    /// taken verbatim from the task's own pick for a scheduled run
    /// (`scheduledRun`). Never persisted. A turn that sets nothing — a
    /// scheduled run left on Default — runs at whatever `codex exec`
    /// itself resolves.
    var codexServiceTierOverride: String? = nil
    /// "Chat only" — a turn whose only tools look things up on the web
    /// (no file or command tools, no MCP servers) and (where the agent
    /// lets a turn carry one) a plain-assistant persona, in the
    /// SAME session store, so the next turn in another row simply
    /// continues the conversation. Its OWN field, never a
    /// `permissionMode` value: `AgentSessionView.seedLaunchOptions`
    /// overlays the transcript's newest recorded `permissionMode` onto
    /// the chips, claude records `default` for a Chat only turn, and a
    /// mode spelled as a permission-mode string would therefore snap
    /// back to Default on every reopen. Persisted as `chat_only` in both
    /// prefs maps (absent = false). Picking it clears `permissionMode`;
    /// picking any mode row clears it (`ChatOnlyMode.select`). The argv
    /// it adds lives in `ChatOnlyArgv`; whether the row is offered at
    /// all in `ChatOnlyAvailability`.
    var chatOnly: Bool = false

    /// Flag list for an agent invocation. Blank values are skipped.
    /// Branches per agent: the three CLIs spell all three options
    /// differently.
    func flags(for agentKey: String = "claude_code") -> [String] {
        if agentKey == "codex" { return codexFlags() }
        if agentKey == "kimi" { return kimiFlags() }
        var argv: [String] = []
        // A Chat only turn keeps only its pre-approved web lookups, so
        // there is nothing a permission mode could decide; the flag is
        // dropped even if a stale value rode in from a saved slot (the
        // chip clears it).
        if let mode = permissionMode, !mode.isEmpty, !chatOnly {
            argv += ["--permission-mode", mode]
        }
        if let model = model, !model.isEmpty {
            argv += ["--model", model]
        }
        if let effort = effort, !effort.isEmpty {
            argv += ["--effort", effort]
        }
        if fastMode {
            // The SDK opt-in. Print mode answers `sdk_opt_in_required`
            // for fast mode unless the setting arrives on the FLAG
            // layer — the same key in `settings.json` does not count.
            argv += ["--settings", Self.claudeFastModeSettings]
        }
        return argv
    }

    /// Exactly the JSON claude's flag-settings layer takes for the fast
    /// mode opt-in. Compact, one key: the flag accepts a file path or a
    /// JSON string, and this is the whole of what it needs to say.
    static let claudeFastModeSettings = "{\"fastMode\":true}"

    /// Codex spelling of the same three choices.
    ///
    /// An unrecognized mode emits NOTHING rather than guessing. A
    /// session carrying a claude mode string ("bypassPermissions") is
    /// ordinary — the picker is shared, and `seedLaunchOptions` can
    /// restore a value saved before the session's agent was known — and
    /// passing it through would be a hard argv error that kills the
    /// turn. Falling back to codex's own default is the safe read.
    private func codexFlags() -> [String] {
        var argv: [String] = []
        // Chat only carries its own `sandbox_mode="read-only"` and
        // `approval_policy="never"` (`ChatOnlyArgv.codex`); a preset on
        // top would contradict it, and "full-access" would lift the
        // sandbox that keeps `apply_patch` refused.
        if let mode = permissionMode, !mode.isEmpty, !chatOnly,
           let preset = CodexCapabilities.sandboxArgv(for: mode) {
            argv += preset
        }
        if let model = model, !model.isEmpty {
            argv += ["-m", model]
        }
        if let effort = effort, !effort.isEmpty {
            // Codex has no dedicated effort flag; it travels as a
            // config override.
            argv += ["-c", "model_reasoning_effort=\(effort)"]
        }
        if let tier = codexServiceTierOverride, !tier.isEmpty {
            // Already resolved against the model's advertised tiers and
            // against what `codex exec` would send by itself — see
            // `CodexSpeed.override`. Nothing here is guessed: a tier the
            // model does not advertise is dropped by codex with an
            // `error` item, and `default` is codex's own explicit
            // standard.
            argv += ["-c", "service_tier=\(tier)"]
        }
        return argv
    }

    /// Kimi Code's spelling — one flag out of the three, on purpose.
    ///
    /// The two omissions are omissions for DIFFERENT reasons, and only
    /// one of them means "kimi cannot do this":
    ///
    ///  * `permissionMode` emits NOTHING, and must keep emitting
    ///    nothing. Kimi rejects the combination at startup, one
    ///    message per flag — "error: Cannot combine --prompt with
    ///    --yolo." / "…--auto." / "…--plan." — because print mode
    ///    approves every tool call itself. SipAI drives kimi only
    ///    through `--prompt`, so any mode flag here exits before a
    ///    single event, killing every turn. (The composer therefore
    ///    shows kimi a fixed auto-approve chip rather than a picker, and
    ///    a value saved from another agent's sticky slot lands here
    ///    harmlessly.)
    ///  * `effort` emits nothing here because kimi has no effort FLAG —
    ///    not because it has no effort. It grades thinking low → max
    ///    and takes the per-run override through the ENVIRONMENT
    ///    (`KIMI_MODEL_THINKING_EFFORT`), which `AgentRunner` overlays
    ///    onto the child. See `KimiCapabilities.effortLevels`.
    private func kimiFlags() -> [String] {
        guard let model = model, !model.isEmpty else { return [] }
        return ["--model", model]
    }

    /// What a scheduled task's run launches with: the task file's own
    /// picks, each on the agent that has it. Built here rather than in
    /// the scheduler so the rule compiles headless.
    ///
    /// Speed follows the task, never the composer. Claude's fast mode
    /// travels as the task says; claude refuses it on a model or a
    /// provider without it, at no cost. A codex pick travels VERBATIM as
    /// `-c service_tier=` — a picked speed always does, as it does from
    /// the composer — and no pick passes nothing, so the run gets what
    /// `codex exec` resolves by itself: the config's tier for the task's
    /// folder, never a model's catalog default. Default must stay that
    /// rule: under the composer's picker rule, every task on a model
    /// whose catalog starts it on Fast would run Fast without anyone
    /// choosing it. The task card names what Default resolves to
    /// (`CodexSpeed.scheduled`).
    static func scheduledRun(agent: String, mode: String?, model: String?,
                             effort: String?, fastMode: Bool,
                             serviceTier: String?) -> AgentLaunchOptions {
        var options = AgentLaunchOptions()
        options.permissionMode = mode
        options.model = model
        options.effort = effort
        switch agent {
        case "codex":
            if let tier = CodexSpeed.normalized(serviceTier) {
                options.serviceTier = tier
                options.codexServiceTierOverride = tier
            }
        case "kimi":
            break
        default:
            options.fastMode = fastMode
        }
        return options
    }
}

// MARK: - Claude fast mode: what a turn actually got

/// What claude said about fast mode on a session's turns — the OUTCOME,
/// where `AgentLaunchOptions.fastMode` is the request. Claude spreads it
/// over four channels, and none of the first three is enough alone:
///
///  * `state` — `fast_mode_state` on `system.init` and `result` ("on",
///    "off", "cooldown"). It stays "on" while every call of the turn is
///    being refused, because claude keeps ASKING for fast mode.
///  * `disabledReason` — `fast_mode_disabled_reason` beside it, when
///    something blocks fast mode for the whole session.
///  * `refusal` — claude's own sentence when the API refused a call's
///    fast mode for want of usage credits (a `system` notification,
///    key `ClaudeFastMode.refusalKey`, once per turn). The call is then
///    re-sent at standard speed, and so is every later call.
///  * `lastSpeed` — `usage.speed` of the newest main-loop call this
///    runner saw, "fast" or "standard": the ground truth.
///
/// `seededSpeed` is the same field read off the transcript when the
/// session opens — HISTORY, possibly from before the account's credits
/// changed, so it ranks below everything live and below claude's cached
/// credits verdict. The runner never sets it; the view does.
struct ClaudeFastModeReport: Equatable {
    var state: String? = nil
    var disabledReason: String? = nil
    var refusal: String? = nil
    var lastSpeed: String? = nil
    var seededSpeed: String? = nil
}

/// The rules around claude's fast mode that do not depend on a view.
enum ClaudeFastMode {
    /// The key of the notification claude emits when a call's fast mode
    /// was refused for want of usage credits.
    static let refusalKey = "fast-mode-overage-rejected"

    enum Verdict: Equatable {
        /// Not requested.
        case off
        /// Requested, and nothing has said anything yet.
        case requested
        /// The newest call ran fast.
        case running
        /// Requested, and not what the calls get.
        case notServing(Why)
    }

    enum Why: Equatable {
        /// Claude's own sentence for a refused call.
        case refused(String)
        /// Paused after a rate limit; claude resumes it by itself.
        case cooldown
        /// Blocked for the session, with claude's reason code.
        case disabled(String)
        /// Claude reports it off and gives no reason — a model it does
        /// not take fast mode on.
        case reportedOff
        /// The account's usage credits are unavailable, as claude last
        /// cached it — known before any call is made.
        case credits(String)
        /// The newest call ran at standard speed and nothing said why.
        case ranStandard
    }

    /// One verdict from the four channels, the cached credits state and
    /// the transcript, freshest first: what this runner's own calls said,
    /// then claude's cached credits verdict (set from the overage header
    /// whenever a response carries one), then what the transcript last
    /// recorded. A live call
    /// that ran fast wins over everything before it; the runner marks a
    /// refused call standard the moment the refusal arrives, so an older
    /// fast call cannot outrank the refusal that followed it.
    static func verdict(requested: Bool, report: ClaudeFastModeReport,
                        creditsBlock: String?) -> Verdict {
        guard requested else { return .off }
        if report.lastSpeed == "fast" { return .running }
        if let text = report.refusal, !text.isEmpty { return .notServing(.refused(text)) }
        if report.state == "cooldown" { return .notServing(.cooldown) }
        if let reason = report.disabledReason, !reason.isEmpty {
            return .notServing(.disabled(reason))
        }
        if report.state == "off" { return .notServing(.reportedOff) }
        if let block = creditsBlock, !block.isEmpty { return .notServing(.credits(block)) }
        if report.lastSpeed == "standard" { return .notServing(.ranStandard) }
        switch report.seededSpeed {
        case "fast"?: return .running
        case "standard"?: return .notServing(.ranStandard)
        default: return .requested
        }
    }

    /// The switch a session with no saved picks opens with, given the
    /// sticky prefs (`base`) and the speed of the transcript's newest
    /// main-loop call. The transcript records what a call RAN at, never
    /// what was asked for: a fast call proves the switch was on, but a
    /// standard one proves nothing — it is also what every refused call
    /// records. Read as "off", it would switch every such session off
    /// while usage credits are out; its sends would then carry no
    /// opt-in, record standard again, and keep the session off after the
    /// credits come back. So a fast record may turn the switch on, and
    /// nothing in the transcript turns it off.
    static func seededSwitch(base: Bool, newestCallRanFast: Bool?) -> Bool {
        newestCallRanFast == true || base
    }

    /// Why usage credits are unavailable, as claude caches it:
    /// `cachedExtraUsageDisabledReason` in `~/.claude.json`, which claude
    /// sets from the `anthropic-ratelimit-unified-overage-disabled
    /// -reason` header whenever a response carries one — null while
    /// credits are available, and left as it was by a response without
    /// the header (an API-key run never writes it). On a Claude plan
    /// fast mode is paid from usage credits, so any reason here means
    /// its calls are refused. nil for null, an absent key, another
    /// shape, or no file.
    static func creditsBlock(claudeJSON data: Data?) -> String? {
        guard let data,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let reason = root["cachedExtraUsageDisabledReason"] as? String
        else { return nil }
        let trimmed = reason.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Chat only

/// The mode chip's spelling of Chat only, and the one rule that keeps
/// it and `permissionMode` from both being set.
///
/// The chip's rows carry a `String?` value — nil for Default, a mode
/// name for the agent's own rows — so Chat only rides a sentinel that
/// no CLI could take as a mode. It is never written into config or an
/// argv: `AgentLaunchOptions.chatOnly` is the persisted state, and
/// `select` is the only writer of both fields from a pick.
enum ChatOnlyMode {
    static let rowValue = "__chat_only__"

    /// The row the chip should show as selected.
    static func selectedValue(_ options: AgentLaunchOptions) -> String? {
        options.chatOnly ? rowValue : options.permissionMode
    }

    /// Apply a picked row. Chat only clears the permission mode; any
    /// other row — Default included — clears Chat only.
    static func select(_ value: String?, into options: inout AgentLaunchOptions) {
        if value == rowValue {
            options.chatOnly = true
            options.permissionMode = nil
        } else {
            options.chatOnly = false
            options.permissionMode = value
        }
    }
}

/// The plain-assistant persona a Chat only turn carries where the agent
/// lets a turn carry one — claude on `--system-prompt`, codex through a
/// file SipAI keeps in its data directory (`SipaiPaths
/// .chatOnlyInstructionsFile`); kimi never (its persona binds per
/// session, and its own prompt is left alone).
///
/// One English constant, not a catalog key: it is sent to the model and
/// never shown, and the model answers in the user's language regardless.
/// Names no agent and no mode row of any one CLI — the same text goes
/// to two of them.
enum ChatOnlyPersona {
    /// Looking things up on the web is the one tool use a chat keeps —
    /// the one every chat app makes to answer a question about now —
    /// so the persona names it, and names everything else as off.
    static let text = """
You are a helpful, knowledgeable assistant. Answer conversationally and \
clearly, in the user's language. Use markdown when it helps. Ask a \
clarifying question when a request is ambiguous. When a question needs \
current or specific information, look it up on the web and cite the \
pages you used. You have no other tools in this mode: you cannot read, \
search or change files or run commands. If the user asks for that, say \
so and suggest switching the mode chip out of Chat only.
"""

    /// Codex reads the persona from a file (`-c model_instructions_file`
    /// takes a path, and `""` is refused as "not a file"). Written
    /// atomically, only when the file differs, and never into codex's
    /// own store.
    static func ensureFile(at url: URL) throws {
        let data = Data(text.utf8)
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// The argv each CLI needs for a Chat only turn, over the launch options
/// and the two facts only the caller knows. Pure, nonisolated: the
/// harness compiles it alone, the way it compiles
/// `ScheduledTaskScheduler.decide`.
///
/// Every list here is APPENDED to `AgentLaunchOptions.flags(for:)` by the
/// runner, before the positional / `--resume` arguments.
enum ChatOnlyArgv {

    // MARK: Claude

    /// The built-ins a Chat only turn KEEPS: web search and page fetch,
    /// what any chat uses to answer a question about now. Nothing that
    /// touches files or runs commands.
    static let claudeWebTools = ["WebSearch", "WebFetch"]
    /// `--tools` is VARIADIC (`<tools...>`) and takes the list as ONE
    /// comma-joined value. Measured: the request carries exactly these
    /// two, inline — the tool-search tool is not in the list, so claude
    /// defers neither behind it — and `system.init` reports them. The
    /// flag swallows every following token that is not a flag, so it
    /// must be followed by another `-`-prefixed argument or be last.
    static let claudeToolsWebOnly = ["--tools", claudeWebTools.joined(separator: ",")]
    /// Both web tools ask permission, and a Chat only turn carries no
    /// approver, so they are pre-approved for the turn. Measured: without
    /// this a web search comes back "Claude requested permissions to use
    /// WebSearch, but you haven't granted it yet." and never runs. A deny
    /// rule in the user's own settings still wins — measured: claude then
    /// drops the tool from the turn altogether. Variadic, same rule.
    static let claudeWebPreapproved = ["--allowedTools", claudeWebTools.joined(separator: ",")]
    /// MCP tools are NOT built-ins, so `--tools` alone leaves every MCP
    /// server the user configured callable — SipAI's approver included.
    /// `--mcp-config` is variadic too (the same rule), and the empty
    /// strict config is the usage probe's spelling.
    static let claudeNoMCP = ["--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"]
    /// The persona replaces claude's own ~28 KB system prompt (measured:
    /// the request's system field is 2.1 KB with it — the persona plus
    /// claude's own billing-header line). CLAUDE.md is unaffected: it
    /// travels in the MESSAGES, not the system prompt.
    static let claudePersona = ["--system-prompt", ChatOnlyPersona.text]
    /// Claude's help documents system-prompt RECORDING: rendered on the
    /// conversation's first request, sent and recorded, and "every later
    /// request and resume sends the record as-is, even when a later
    /// launch passes different text". Off means rendered fresh every
    /// request — without which a persona would pin at whichever launch
    /// came first, in BOTH directions. Not yet active on any measured
    /// install ("No effect where system-prompt recording is not yet
    /// enabled"), accepted today, and therefore sent on EVERY claude
    /// turn, Chat only or not — but only when the installed `--help`
    /// lists it, since an unknown flag is a startup error.
    static let claudeSnapshotOff = ["--system-prompt-snapshot", "off"]
    /// Readable thinking for a Chat only turn. Without it `claude -p`
    /// asks the API to leave thinking text OUT — every thinking block
    /// arrives empty — and the turn's activity line has no thoughts to
    /// show (`ChatOnlyActivity`). Visibility only: thinking is billed the
    /// same under every display. Not listed by `--help`, so it rides only
    /// behind the positive probe (`ChatOnlyAvailability
    /// .acceptsThinkingDisplay`) — an unknown flag is a startup error.
    /// Never on an agent turn, whose transcript draws no thoughts.
    static let claudeThinkingSummaries = ["--thinking-display", "summarized"]

    /// The claude list, in THIS order: each variadic flag is followed by
    /// another `-`-prefixed flag, and the runner appends `--resume <id>`
    /// after the whole list, so no variadic can swallow a value.
    static func claude(options: AgentLaunchOptions, snapshotFlagListed: Bool,
                       thinkingDisplayAccepted: Bool = false) -> [String] {
        var argv: [String] = []
        if options.chatOnly {
            argv += claudeToolsWebOnly
            argv += claudeWebPreapproved
            argv += claudeNoMCP
            argv += claudePersona
            if thinkingDisplayAccepted {
                argv += claudeThinkingSummaries
            }
        }
        if snapshotFlagListed {
            argv += claudeSnapshotOff
        }
        return argv
    }

    /// True when every variadic flag in `argv` is followed by a
    /// `-`-prefixed token (or a value the flag itself consumes). The
    /// harness checks the emitted list with this; the runner's positional
    /// `--resume` comes after, which the caller checks separately.
    static func variadicFlagsAreClosed(_ argv: [String]) -> Bool {
        let variadic: Set<String> = ["--tools", "--allowedTools", "--mcp-config"]
        var i = 0
        while i < argv.count {
            if variadic.contains(argv[i]) {
                // One value, then the next token must be a flag or the end.
                let next = i + 2
                if next < argv.count, !argv[next].hasPrefix("-") { return false }
                i += 2
            } else {
                i += 1
            }
        }
        return true
    }

    // MARK: Codex

    /// Every switch as `-c`, because `exec resume` takes `-c` and not
    /// every long flag, and every send after the first resumes. Measured
    /// under a clean home: this set leaves ONE local tool, `apply_patch`,
    /// which no flag removes — and which `sandbox_mode="read-only"` +
    /// `approval_policy="never"` REFUSE ("patch rejected: writing is
    /// blocked by read-only sandbox", nothing written).
    ///
    /// Web search stays ON, as `"live"`: codex's hosted search tool,
    /// run by the provider, never on this Mac — the request carries
    /// `{"type":"web_search","external_web_access":true}` (measured;
    /// `"cached"` sends `false` and answers from a pre-built index,
    /// which is codex's own default whatever the sandbox, and
    /// `"disabled"` drops the tool). `web_search` is a TOP-LEVEL key:
    /// `tools.web_search=…` does nothing. A managed install whose
    /// requirements forbid `"live"` keeps its allowed value instead
    /// (the binary's own log line: "keeping constrained value")
    /// rather than failing the turn.
    ///
    /// Codex ignores an unknown `-c` key SILENTLY (measured: three
    /// unknown keys, three ordinary turns, nothing on stderr), which is
    /// why the row is gated on the installed codex NAMING the switches
    /// (`ChatOnlyAvailability`) rather than on "no error".
    static let codexToolSwitches: [String] = [
        "-c", "features.shell_tool=false",
        "-c", "features.unified_exec=false",
        "-c", "features.view_image=false",
        "-c", "features.multi_agent=false",
        "-c", "features.apps=false",
        "-c", "features.browser_use=false",
        "-c", "features.computer_use=false",
        "-c", "features.image_generation=false",
        "-c", "features.sleep_tool=false",
        "-c", "features.plugins=false",
        "-c", "features.skill_search=false",
        "-c", "features.tool_suggest=false",
        "-c", "features.goals=false",
        "-c", "features.memories=false",
        "-c", "web_search=\"live\"",
        "-c", "tools.experimental_request_user_input.enabled=false",
        "-c", "sandbox_mode=\"read-only\"",
        "-c", "approval_policy=\"never\"",
    ]

    /// The developer preamble, dropped. `include_environment_context`
    /// is KEPT: it carries `<current_date>`, and a chat that does not
    /// know the date is a worse chat (~130 tokens).
    static let codexLeanSwitches: [String] = [
        "-c", "include_permissions_instructions=false",
        "-c", "include_collaboration_mode_instructions=false",
        "-c", "include_apps_instructions=false",
        "-c", "skills.include_instructions=false",
    ]

    /// The codex list. `bornPlain` means "this is not the thread's first
    /// turn" — the BIRTH RULE: the rollout's `session_meta
    /// .base_instructions` records the instructions at thread creation
    /// and a plain resume reuses them, so a thread born with the persona
    /// runs every later AGENT turn as a chat assistant (measured: a
    /// silent downgrade), while a thread born normal is safe to override
    /// per turn (measured: the third, plain, turn got the full
    /// instructions back and the record still reads `provenance:
    /// model`). The persona file therefore rides RESUMED turns only, and
    /// this is the one place that rule is enforced.
    /// Readable reasoning summaries for a Chat only turn — the thoughts
    /// its activity line shows. Codex requests none by default (every
    /// catalog model defaults to `none`), and a request for `auto` has
    /// come back empty; `detailed` returns them (measured). An agent
    /// turn draws no thoughts and is left on the model's own default.
    static let codexThinkingSummaries = ["-c", "model_reasoning_summary=\"detailed\""]

    static func codex(options: AgentLaunchOptions, bornPlain: Bool,
                      personaFile: String) -> [String] {
        guard options.chatOnly else { return [] }
        var argv = codexToolSwitches + codexLeanSwitches + codexThinkingSummaries
        if bornPlain {
            argv += ["-c", "model_instructions_file=\"\(personaFile)\""]
        }
        return argv
    }

    // MARK: Kimi

    /// Nothing. Kimi has no per-run tool control on its command line;
    /// the shape is the session's `tool-policy/state.json`
    /// (`KimiToolPolicy`) around an ordinary `--prompt` turn, and the
    /// local server for a new session's first turn (`KimiWebTurn`).
    static func kimi(options: AgentLaunchOptions) -> [String] { [] }
}

/// An image staged for the next agent message, resolved to the payload
/// the wire needs. Text attachments are inlined into the message
/// (`AttachmentInline.block`); an image cannot be, so it travels each
/// CLI's own image channel (`ChatOnlyImages` below) and only its NAME
/// rides the message text, through `AttachmentInline.imageMarker` — so
/// a bubble and a reopened transcript name it the way a text attachment
/// is named, and base64 never reaches a transcript record. Declared
/// here, beside the only code that reads it headlessly, so a harness
/// compiling this file needs nothing else to know the type.
struct AgentImage: Equatable {
    let name: String
    /// Base64 of the bytes actually sent — already resized and
    /// re-encoded to a provider-safe type by `ChatAttachment`.
    let base64: String
    /// One of the media types every provider accepts (`image/png`,
    /// `image/jpeg`, `image/gif`, `image/webp`).
    let mediaType: String
}

/// The per-agent image channel for a Chat only message. Text rides the
/// message body (`AttachmentInline.block`); an image cannot, so each
/// CLI's own documented image input carries it — and each is a
/// different shape, all pure over `[AgentImage]` so the harness can
/// pin them:
///
///  * claude `-p --input-format stream-json`: one user record on
///    stdin, image blocks before the text (base64).
///  * codex `exec [resume] -i <file>`: a temp file per image; the
///    caller writes the bytes and passes the paths.
///  * kimi's local server (a NEW session's first turn only): content
///    blocks in the prompt body. A RESUMED kimi turn is `--prompt
///    --session`, which has no image input — so images are refused on
///    one, up front (`ChatOnlyImages.kimiResumeAcceptsImages`).
enum ChatOnlyImages {

    /// Whether a resumed kimi turn can carry images. It cannot: only a
    /// new session's first turn goes through the server. A single false
    /// keyed here so the composer's stage-time refusal and any later
    /// reader read one rule.
    static let kimiResumeAcceptsImages = false

    /// The stream-json user record claude reads from stdin: the image
    /// blocks first (each `{"type":"image","source":{base64}}`), then
    /// the text. `text` is the WIRE text — the image name markers
    /// included, so the recorded transcript names the files exactly as
    /// a text attachment's record does.
    static func claudeMessage(text: String, images: [AgentImage]) -> [String: Any] {
        var content: [[String: Any]] = images.map { image in
            ["type": "image",
             "source": ["type": "base64",
                        "media_type": image.mediaType,
                        "data": image.base64]]
        }
        content.append(["type": "text", "text": text])
        return ["type": "user", "message": ["role": "user", "content": content]]
    }

    /// The same, serialised to the single JSON line the runner writes to
    /// claude's stdin (newline-terminated, then EOF). Sorted keys so the
    /// harness can assert a stable shape.
    static func claudeStdinLine(text: String, images: [AgentImage]) -> String {
        let message = claudeMessage(text: text, images: images)
        guard let data = try? JSONSerialization.data(
            withJSONObject: message, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// The content array for kimi's server prompt: image blocks in the
    /// shape kimi's `/prompts` route takes (`source.kind == "base64"`),
    /// then the text block. `name` rides each image block so kimi can
    /// refer to it.
    static func kimiContentBlocks(text: String, images: [AgentImage]) -> [[String: Any]] {
        var blocks: [[String: Any]] = images.map { image in
            ["type": "image",
             "source": ["kind": "base64",
                        "media_type": image.mediaType,
                        "data": image.base64],
             "name": image.name]
        }
        blocks.append(["type": "text", "text": text])
        return blocks
    }

    /// The file extension a codex `-i` temp file should carry for a
    /// media type — codex reads the format from the extension, so an
    /// `image/png` payload must land at `*.png`. Defaults to `png`,
    /// which is what `ChatAttachment` re-encodes an alpha image to.
    static func codexFileExtension(mediaType: String) -> String {
        switch mediaType {
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "png"
        }
    }

    /// The TRAILING arguments of a `codex exec [resume]` turn, in the one
    /// order that works: the session id (resume only), the positional
    /// prompt, THEN `-i <file>` per image — last.
    ///
    /// The order is load-bearing and measured: `-i` / `--image` on
    /// `codex exec` is VARIADIC (`<FILE>...`), so a `-i <file>` placed
    /// before the positional prompt swallows the prompt as a second
    /// image path. codex then finds no prompt, reads stdin (SipAI hands
    /// it `/dev/null`) and dies with "No prompt provided via stdin".
    /// Appended after the prompt, `-i` consumes only the files. This is
    /// the same variadic-flag trap `ChatOnlyArgv.variadicFlagsAreClosed`
    /// guards on the claude side.
    static func codexTrailingArgs(resuming: Bool, sessionId: String?,
                                  text: String, imageFiles: [String]) -> [String] {
        var args: [String] = []
        if resuming, let id = sessionId, !id.isEmpty { args.append(id) }
        args.append(text)
        for file in imageFiles {
            args.append("-i")
            args.append(file)
        }
        return args
    }
}

/// Whether the Chat only row is OFFERED, per agent, over what the app's
/// scrapers already hold about the INSTALLED CLI. Every flag above is
/// version-specific, and one CLI accepts an unknown switch silently
/// (codex), so the rule is positive: the installed binary must NAME what
/// the turn relies on. Below the gate the row is absent and a saved
/// `chat_only` pick is ignored for that send. Newer versions than the
/// floors are accepted; the harness's live section after every upgrade
/// is what keeps that honest.
enum ChatOnlyAvailability {
    /// The version the codex switches and the `apply_patch` refusal were
    /// measured on. Older codex may take `-c features.*` and change
    /// nothing.
    static let codexVersionFloor = "0.155.1"
    /// The version the tool-policy file and the server routes were
    /// measured on.
    static let kimiVersionFloor = "2.0.1"
    /// The two features whose switches carry the whole shape; a `codex
    /// features list` that does not name them is a codex that does not
    /// have them.
    static let codexRequiredFeatures: Set<String> = ["shell_tool", "unified_exec"]

    /// What `claude --help` says about the two flags this mode needs.
    struct ClaudeHelp: Equatable {
        /// `--tools` is listed — the row is offered.
        let listsTools: Bool
        /// `--system-prompt-snapshot` is listed — the flag is emitted.
        let listsSnapshot: Bool
    }

    /// Scrape the two flags off the help text. A flag is "listed" when
    /// it opens a line as an option — `  --tools <tools...>` — not when
    /// another option's description merely mentions it.
    static func claudeHelp(fromHelpText text: String) -> ClaudeHelp {
        func listed(_ flag: String) -> Bool {
            text.split(separator: "\n").contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix(flag + " ") || trimmed == flag
                    || trimmed.hasPrefix(flag + ",")
            }
        }
        return ClaudeHelp(listsTools: listed("--tools"),
                          listsSnapshot: listed("--system-prompt-snapshot"))
    }

    /// `--thinking-display` is not in `--help`, so it is probed: handed a
    /// value no claude accepts, a claude that knows the flag refuses the
    /// value by NAMING the flag and its choices ("Allowed choices are
    /// summarized, …"). One that does not know it either ignores it
    /// (`--version` still prints) or refuses it as an unknown option —
    /// neither names a choice. Local and instant: the refusal happens
    /// while the arguments are parsed.
    static let thinkingDisplayProbeArguments = ["--thinking-display", "sipai-probe", "--version"]

    static func acceptsThinkingDisplay(probeOutput text: String) -> Bool {
        text.contains("--thinking-display") && text.contains("summarized")
    }

    /// The feature names out of `codex features list` — one per line,
    /// the name first, then its stage and default. Only the name is read.
    static func codexFeatures(fromListing text: String) -> Set<String> {
        var names: Set<String> = []
        for line in text.split(separator: "\n") {
            guard let first = line.split(separator: " ", omittingEmptySubsequences: true).first
            else { continue }
            let name = String(first)
            // A name is a lowercase identifier; anything else on the
            // line's head is a log line or a warning.
            guard !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }),
                  name.first?.isLetter == true
            else { continue }
            names.insert(name)
        }
        return names
    }

    /// `text` ≥ `floor`, comparing dotted numeric components padded with
    /// zeros (the `CLIVersion` rule, restated here so the reader
    /// harnesses, which do not compile `AgentCLIUpdates.swift`, can
    /// still build this file). A version that does not parse is below
    /// every floor: an unreadable version is an unmeasured CLI.
    static func versionAtLeast(_ text: String?, _ floor: String) -> Bool {
        guard let text else { return false }
        func components(_ s: String) -> [Int]? {
            let token = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ").first.map(String.init) ?? ""
            let parts = token.split(separator: ".").map(String.init)
            let ints = parts.compactMap { Int($0.prefix { $0.isNumber }) }
            guard !ints.isEmpty, ints.count == parts.count else { return nil }
            return ints
        }
        guard let a = components(text), let b = components(floor) else { return false }
        let depth = max(a.count, b.count)
        for i in 0..<depth {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// The verdict. nil inputs mean "not read yet" and answer false —
    /// the row appears once the scrape lands, never before.
    static func offered(agent: String,
                        claudeHelp: ClaudeHelp?,
                        codexVersion: String?,
                        codexFeatures: Set<String>?,
                        kimiVersion: String?) -> Bool {
        switch agent {
        case "claude_code":
            return claudeHelp?.listsTools == true
        case "codex":
            guard versionAtLeast(codexVersion, codexVersionFloor),
                  let features = codexFeatures else { return false }
            return codexRequiredFeatures.isSubset(of: features)
        case "kimi":
            return versionAtLeast(kimiVersion, kimiVersionFloor)
        default:
            return false
        }
    }

    /// Whether every input `offered` needs has been read. Until then its
    /// false means "not known yet", not "not offered" — and a saved Chat
    /// only pick sent in that window would run as an agent turn, with the
    /// agent's tools, on a message meant as a chat. So the composer holds
    /// such a send until this answers true. A codex below the floor needs
    /// no feature list to be judged.
    static func isSettled(agent: String,
                          claudeHelp: ClaudeHelp?,
                          codexVersion: String?,
                          codexFeatures: Set<String>?,
                          kimiVersion: String?) -> Bool {
        switch agent {
        case "claude_code":
            return claudeHelp != nil
        case "codex":
            guard codexVersion != nil else { return false }
            return codexFeatures != nil || !versionAtLeast(codexVersion, codexVersionFloor)
        case "kimi":
            return kimiVersion != nil
        default:
            return true
        }
    }
}

/// One `key = "value"` line of a TOML file's top level.
///
/// Shared by the codex and kimi catalogs, which both read a
/// hand-editable `config.toml` for the user's declared default model.
/// One parser rather than two: the prefix check below is what stops
/// `model_reasoning_effort` from answering a request for `model`, and
/// a second copy is how that subtlety gets lost.
enum TomlScalar {
    /// One `key = "value"` line: a TOML basic string (`\"` and `\\`
    /// unescaped) or a literal one (`'value'`), with nothing after it but
    /// a `# comment`. Anything else — a multi-line string, two values, an
    /// unterminated quote — answers nil, never a guess.
    static func string(_ line: String, key: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        let rest = line.dropFirst(key.count)
            .trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { return nil }   // not `model_x = …`
        let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let quote = value.first, quote == "\"" || quote == "'" else { return nil }
        var out = ""
        var escaped = false
        var index = value.index(after: value.startIndex)
        while index < value.endIndex {
            let ch = value[index]
            if escaped {
                if ch != "\"" && ch != "\\" { out.append("\\") }
                out.append(ch)
                escaped = false
            } else if quote == "\"" && ch == "\\" {
                escaped = true
            } else if ch == quote {
                let tail = value[value.index(after: index)...]
                    .trimmingCharacters(in: .whitespaces)
                return tail.isEmpty || tail.hasPrefix("#") ? out : nil
            } else {
                out.append(ch)
            }
            index = value.index(after: index)
        }
        return nil
    }

    /// The name of the table a `[name]` header line opens — `[[name]]`
    /// read the same way — with a trailing `# comment` allowed. nil for
    /// a line that is not a header.
    static func tableName(_ line: String) -> String? {
        guard line.hasPrefix("[") else { return nil }
        let body = line.hasPrefix("[[") ? line.dropFirst(2) : line.dropFirst()
        guard let close = body.firstIndex(of: "]") else { return nil }
        return body[..<close].trimmingCharacters(in: .whitespaces)
    }

    /// One `key = [ "a", "b" ]` line — a single-line array of strings,
    /// which is how kimi writes `support_efforts` and `capabilities`.
    ///
    /// Single-line only, deliberately: a multi-line array would need
    /// this scanner to carry state across lines, and nothing kimi's own
    /// writer produces needs it. An unrecognised shape returns nil, and
    /// the caller falls back — never a partial list, which would read
    /// as "this model supports exactly one effort".
    static func stringArray(_ line: String, key: String) -> [String]? {
        guard line.hasPrefix(key) else { return nil }
        let rest = line.dropFirst(key.count)
            .trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { return nil }
        let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
        return value.dropFirst().dropLast()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("\"") && $0.hasSuffix("\"") && $0.count >= 2 }
            .map { String($0.dropFirst().dropLast()) }
            .filter { !$0.isEmpty }
    }

    /// One `key = true` / `key = false` line — a bare TOML boolean, the
    /// shape codex's `[features]` and `[notice]` flags take. Anything
    /// else answers nil, which callers read as "the file does not say".
    static func bool(_ line: String, key: String) -> Bool? {
        guard line.hasPrefix(key) else { return nil }
        let rest = line.dropFirst(key.count)
            .trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { return nil }
        let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        let head = value.split(separator: "#", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        switch head {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// One `key = 262144` line — a bare TOML integer, which is how kimi
    /// writes `max_context_size`. TOML allows `1_048_576`, so the
    /// underscores are stripped before the digits are read; anything
    /// else non-numeric (a float, a quoted string) answers nil and the
    /// caller falls back rather than storing a mangled number.
    static func integer(_ line: String, key: String) -> Int? {
        guard line.hasPrefix(key) else { return nil }
        let rest = line.dropFirst(key.count)
            .trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { return nil }
        // A trailing `# comment` is TOML too (the string and bool
        // readers allow one); a digit run never contains `#`.
        var raw = String(rest.dropFirst())
        if let hash = raw.firstIndex(of: "#") { raw = String(raw[..<hash]) }
        let value = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "_", with: "")
        guard !value.isEmpty, value.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return Int(value)
    }
}

/// Display casing for a reasoning-effort level, shared by every
/// surface that shows one — a per-surface copy would print two
/// spellings of one level two panes apart (`xhigh` vs `XHigh`).
enum AgentEffort {
    static func displayName(_ level: String) -> String {
        level == "xhigh" ? "XHigh" : level.capitalized
    }
}

/// Whether a leading `/` means anything to the CLI we are about to
/// spawn, and whether a token looks like a command at all.
///
/// Pure and free of view state on purpose, so the rule can be compiled
/// against a driver — same reason `ScheduledTaskScheduler.decide` is a
/// plain function. `Verification/SlashCommandOutput/run.sh` drives it.
enum AgentSlashCommands {
    /// True when the agent resolves slash commands ITSELF in headless
    /// mode, false when the text just becomes a prompt, nil when
    /// nobody has measured it.
    ///
    /// Claude does: `claude -p "/mcp"` answers it and records the
    /// answer. Codex and kimi do not — `codex exec` has no command
    /// layer, and kimi's own documentation says an unmatched
    /// `/`-prefixed input "is sent to the Agent as a regular message".
    /// Either way the text reaches the model and comes back as a
    /// billed turn.
    ///
    /// Keyed on the AGENT, never on a list of command NAMES: a list
    /// would have to track three CLIs' release notes and would be
    /// wrong the week any of them shipped a new command — the same
    /// reason models and effort levels are read from each CLI instead
    /// of being hardcoded.
    ///
    /// A fourth agent answers `nil` until someone runs the probe, and
    /// the composer stays SILENT on nil. The hint states a fact about
    /// the CLI, and guessing that fact is still stating it.
    static func resolvesLocally(agentKey: String) -> Bool? {
        switch agentKey {
        case "claude_code": return true
        case "codex", "kimi": return false
        default: return nil
        }
    }

    /// The draft's leading token when it reads as a command name.
    ///
    /// `/mcp`, `/skill:name` and `/code-style.review` qualify.
    /// `/Users/me/notes.md` does NOT — a pasted path is ordinary prose
    /// and flagging one would turn the hint into noise. The
    /// discriminator is the second slash: a command name has none.
    static func leadingCommand(in draft: some StringProtocol) -> String? {
        guard let first = draft
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .first,
              first.hasPrefix("/"), first.count > 1
        else { return nil }
        let name = first.dropFirst()
        guard let head = name.first, head.isLetter,
              name.allSatisfy({
                  $0.isLetter || $0.isNumber || "_-.:".contains($0)
              })
        else { return nil }
        return String(first)
    }
}

/// Codex's counterparts to the claude mode / effort catalogs.
///
/// The sandbox policy travels as `-c` CONFIG OVERRIDES rather than as
/// `--sandbox` / `-a` flags:
///
///  * `-a` / `--ask-for-approval` does not exist on `codex exec` at all
///    — it errors "unexpected argument '-a'" and exits 2 before running
///    anything.
///  * `--sandbox` works on `codex exec` but NOT on `codex exec resume`,
///    which accepts neither it nor `-a`. Since every send after the
///    first is a resume, flag-form presets would make the first turn
///    of a session work and every later one die.
///
/// `-c sandbox_mode=… -c approval_policy=…` is accepted by BOTH
/// subcommands — and enforced, not merely accepted — so one spelling
/// covers the whole session.
enum CodexCapabilities {
    /// (mode value, argv, one-line hint) — the sandbox presets the
    /// composer offers for a codex session.
    static let modePresets: [(value: String, argv: [String], hint: String)] = [
        ("workspace-write",
         ["-c", "sandbox_mode=workspace-write", "-c", "approval_policy=never"],
         "edit files in the workspace; never asks"),
        ("read-only",
         ["-c", "sandbox_mode=read-only", "-c", "approval_policy=never"],
         "look but don't touch"),
        ("full-access",
         // The one FLAG both `exec` and `exec resume` take verbatim.
         ["--dangerously-bypass-approvals-and-sandbox"],
         "no sandbox, no approvals"),
    ]

    // NB: no `effortLevels` here. A hardcoded list goes stale in both
    // directions — codex publishes `xhigh` and `ultra` that a fixed
    // list would not offer, and levels it never mentions would be
    // offered anyway. Effort is harvested instead; see `CodexCatalog`.

    /// Mode the unattended surfaces (scheduled runs) open with.
    static let unattendedDefaultMode = "workspace-write"

    static func sandboxArgv(for mode: String) -> [String]? {
        modePresets.first { $0.value == mode }?.argv
    }

    /// Friendly label + SF Symbol for a codex stdout item type, so a
    /// codex tool row reads like a claude one instead of showing the
    /// raw `command_execution` with a generic wrench.
    /// Returns nil for anything unknown — the caller then keeps its own
    /// default rather than inventing a name for a type we've not seen.
    static func toolDisplay(for itemType: String)
    -> (title: String, symbol: String)? {
        switch itemType {
        case "command_execution":
            return ("Shell", "terminal")
        case "file_change", "patch_apply":
            return ("Update", "pencil")
        case "web_search", "web_search_call":
            return ("Search", "globe")
        case "mcp_tool_call":
            return ("MCP", "puzzlepiece.extension")
        case "todo_list":
            return ("Todo", "checklist")
        default:
            return nil
        }
    }

    /// Chip label for a codex sandbox mode, the counterpart of
    /// `AgentPermissionMode.title`.
    static func title(for mode: String) -> String {
        switch mode {
        case "workspace-write":
            return String(localized: "Workspace Write",
                          comment: "Codex sandbox chip label for workspace-write")
        case "read-only":
            return String(localized: "Read Only",
                          comment: "Codex sandbox chip label for read-only")
        case "full-access":
            return String(localized: "Full Access",
                          comment: "Codex sandbox chip label for full-access")
        default:
            return mode
        }
    }
}

/// Facts about running `claude` HEADLESSLY (`claude -p`), as opposed to
/// the choices a send makes. Nothing here is offered to the user: these
/// are constraints of the harness, and the composer has no chip for a
/// thing that cannot be decided.
enum ClaudePrintMode {

    /// Claude Code's own switch for its background-task feature. It is
    /// read once, at startup, into a single predicate that gates every
    /// surface of the feature at the SCHEMA level: `run_in_background`
    /// is omitted from the Bash tool's input schema (and PowerShell's,
    /// and the `Agent` tool's), the tool-description paragraph that
    /// advertises the parameter returns nil, the matching system-prompt
    /// guidance is dropped, MCP auto-backgrounding is switched off, and
    /// the `Monitor` tool's description flips to recommending the
    /// foreground.
    static let disableBackgroundTasksEnvVar = "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"

    /// Environment a claude child needs on top of the ordinary one.
    ///
    /// **Background tasks do not survive `claude -p`, and they fail
    /// silently.** Print mode begins winding down the moment stdin is
    /// at EOF — which for a SipAI child is the first instant, since it
    /// is handed `/dev/null` — and a still-running background task is
    /// TERMINATED five seconds after the turn's `result`. Measured
    /// repeatedly at 5.05-5.10 s. What the app is told is three
    /// `system` records (`background_tasks_changed` with an empty list,
    /// `task_updated` with `status: "killed"`, `task_notification` with
    /// `status: "stopped"`), none of which any reader renders; the
    /// child then exits with code 0 and an empty stderr, and the
    /// transcript on disk records nothing at all. So the user asks for
    /// something long, is told it started, and is never told anything
    /// again — on the live feed or on reopen.
    ///
    /// Disabling the feature is therefore strictly better than leaving
    /// it: the agent works the constraint out from the schema and runs
    /// the command in the foreground instead, where the turn clock
    /// keeps counting and the result actually lands. Measured, with a
    /// prompt explicitly demanding `run_in_background=true`: "This Bash
    /// tool has no `run_in_background` parameter, so I ran it in the
    /// foreground instead."
    ///
    /// **This must OVERRIDE rather than default.** Unlike
    /// `AgentRunner.overlayProxyVars`, which only fills in names the
    /// process environment lacks, a value inherited from the user's
    /// shell has to lose: a `…=0` exported there would re-enable a
    /// mechanism that cannot work here, and the failure leaves no
    /// evidence anywhere.
    ///
    /// **Claude only, and the other two must be left alone** — not
    /// merely because this is where the bug is:
    ///
    ///  * `codex exec` has no background-execution parameter to
    ///    disable. Asked to background something it improvises
    ///    `nohup … &`, which its own process reaping kills at turn end
    ///    in every sandbox mode. There is nothing to switch.
    ///  * Kimi already does the right thing. Its print mode defaults to
    ///    `steer` — the run stays alive while tasks are pending and
    ///    each completion drives a new main turn — and a 40 s
    ///    backgrounded command was measured running to completion and
    ///    being reported. Do NOT reach for
    ///    `KIMI_CODE_BACKGROUND_KEEP_ALIVE_ON_EXIT` here: it reads like
    ///    the same fix and is a downgrade, mapping to `drain`, which
    ///    waits for the task and can no longer steer a turn to report
    ///    it.
    ///
    /// The cost, accepted: background SUBAGENTS become synchronous, since
    /// the same predicate omits the parameter from the `Agent` tool.
    /// Under `-p` the wall clock is unchanged (a background subagent
    /// already held the turn open for its whole life), and parallel
    /// fan-out is untouched — several `Agent` blocks in one assistant
    /// message still run at once, a path that never used the parameter.
    static func environmentOverlay(agentKey: String) -> [String: String] {
        guard agentKey == "claude_code" else { return [:] }
        return [disableBackgroundTasksEnvVar: "1"]
    }
}

/// Kimi Code's counterpart to the claude / codex capability tables.
///
/// Of the composer's three per-send controls, kimi's headless mode
/// takes the model as a FLAG, the effort through the ENVIRONMENT, and
/// the permission mode not at all. See `AgentLaunchOptions.kimiFlags`
/// for the argv rules.
enum KimiCapabilities {
    /// Chip label for the permission state a SipAI-driven kimi turn
    /// actually runs in. Not a choice — a statement, which is why the
    /// composer renders it as a readout instead of a picker:
    /// `--prompt` refuses `--yolo` / `--auto` / `--plan` outright, so
    /// print mode's own auto-approval is the only mode there is.
    static var autoApproveTitle: String {
        String(localized: "Auto-approve",
               comment: "Composer chip on a Kimi session — print mode approves every tool call")
    }

    static func autoApproveHint(agentName: String) -> String {
        String(localized: "\(agentName) runs non-interactively here, so it approves its own tool calls. Its CLI rejects a permission mode on a headless run, so there is nothing to choose.",
               comment: "Hover hint on the Kimi auto-approve chip; placeholder is the agent label")
    }

    /// The environment variable kimi reads a per-run thinking effort
    /// from. This is the whole reason kimi can have an effort chip at
    /// all: there is no `--effort` flag, and writing the level into the
    /// user's own `config.toml` is not something a composer picker gets
    /// to do — an env var is scoped to the one child we spawn.
    static let effortEnvVar = "KIMI_MODEL_THINKING_EFFORT"

    /// Thinking levels, ordered fast → deep like the other two agents'.
    ///
    /// Kimi groups the levels into per-model-family profiles:
    /// `BUDGET_THINKING_EFFORTS` is low/medium/high,
    /// `ADAPTIVE_MAX_EFFORTS` adds `max`, and
    /// `LATEST_OPUS_THINKING_EFFORTS` adds `xhigh` as well. This is
    /// their UNION, which is safe HERE and would not be for codex: the
    /// env override "intentionally bypasses `support_efforts`", so a
    /// level the selected model does not list is clamped by kimi rather
    /// than rejected as a bad argument. Contrast
    /// `CodexCatalog.effortLevels(forModel:)`, where an unsupported
    /// level reaches the command line and has to be filtered per model.
    ///
    /// `off` and `on` are deliberately NOT offered. Kimi treats both as
    /// "not a level" internally, and the override "cannot turn Thinking
    /// on after the user disabled it" — so a chip reading "Off" could
    /// not honestly promise either direction. Turning thinking off stays
    /// where the user set it, in kimi's own `[thinking]` config.
    static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    /// The env overlay one send contributes, or nothing.
    ///
    /// Empty for every agent but kimi, and empty for kimi when the chip
    /// is on Default — an unset variable is what lets kimi's own
    /// model-aware effort stand, which is a different outcome from
    /// forcing a level that happens to match today's default.
    static func environmentOverlay(agentKey: String,
                                   effort: String?) -> [String: String] {
        guard agentKey == "kimi",
              let effort = effort?.trimmingCharacters(in: .whitespaces),
              !effort.isEmpty
        else { return [:] }
        return [effortEnvVar: effort]
    }
}

/// Kimi Code's model catalog, read from kimi's own files rather than
/// hardcoded — the same rule `ClaudeModelCatalog` and `CodexCatalog`
/// follow, and for the same reason: a hand-maintained table drifts the
/// day Moonshot ships a model.
///
/// `config.toml` is not merely the best source here, it is the ONLY
/// authoritative one: `--model <alias>` fails the whole turn with
/// `Model "…" is not configured in config.toml.` unless the alias has
/// a `[models.<alias>]` table. So the picker offers exactly those
/// aliases — a row it cannot honour is not a worse row, it is a killed
/// turn.
///
///   * top-level `default_model` — what a send with no explicit pick
///     runs as. (`model` is kimi's LEGACY v1 spelling and is still
///     honoured by kimi as a fallback, so it is read as one here too —
///     but reading ONLY the legacy key finds nothing on a current
///     install.)
///   * `[models.<alias>]` table headers — the alias list itself.
///
/// Sessions' `state.json` stays as a FALLBACK only, for a config we
/// could not read at all. Merging it in unconditionally would offer an
/// alias the user has since deleted from config.toml — i.e. a row that
/// reliably kills the turn that uses it.
///
/// There is deliberately no hardcoded fallback LIST. An unread catalog
/// offers "Default" alone, which is honest.
/// One `[models.<slug>]` entry of kimi's config.toml.
///
/// The three fields the picker needs, and all three are kimi's own —
/// `slug` is what `--model` accepts, `displayName` is what kimi calls
/// it, `efforts` is what it says the model can be asked for. Same shape
/// and same reasoning as `CodexCatalog.Model`.
struct KimiModel: Identifiable, Equatable {
    let slug: String
    /// `display_name` from the config ("Kimi K3"), else the slug. The
    /// generated slugs carry their provider (`kimi-for-coding/k3`), so
    /// without this a chip reads as a path rather than a model.
    let displayName: String
    /// `support_efforts` from the config, fast → deep. Empty when the
    /// model declares none — the chip then hides; the union of every
    /// model's levels is only for a slug the config does not name.
    let efforts: [String]
    /// `default_effort` — the level this model runs at when nothing is
    /// picked. Without it the effort chip's "Default" row says only
    /// "Default", which is the one control in the row that names no
    /// value at all — the model chip's Default row already names what
    /// it resolves to.
    let defaultEffort: String?
    /// `max_context_size` — the model's window, for the context chip's
    /// occupancy tooltip. nil when the entry declares none (an
    /// observed-only model), and the tooltip falls back to its
    /// constant.
    var maxContextSize: Int? = nil

    var id: String { slug }
}

@MainActor
final class KimiCatalog: ObservableObject {
    static let shared = KimiCatalog()

    /// Models to offer, the configured default first.
    @Published private(set) var models: [KimiModel] = []
    /// What `config.toml` declares — shown on the composer's model chip
    /// in place of a bare "Model", exactly as the codex chip names its
    /// own default.
    @Published private(set) var defaultModel: String? = nil

    /// Effort levels valid for a given model, fast → deep.
    ///
    /// Per-model exactly as codex's is, and for the same reason: kimi's
    /// own config records `support_efforts = [ "low", "high", "max" ]`
    /// per model, and a model may legitimately skip levels entirely.
    /// Offering a shared list would name levels that model does not
    /// have.
    ///
    /// A model we KNOW about answers for itself — including when the
    /// answer is "none at all". Moonshot's own changelog lists
    /// "thinking levels being offered for models that do not support
    /// them" as a bug they fixed, and their docs say levels are shown
    /// "when available for the selected model"; falling through to a
    /// union for a model that publishes no `support_efforts` would
    /// reproduce exactly that bug one app over. The composer hides the
    /// chip rather than offering a picker with nothing in it.
    ///
    /// The union is reached only when there is NO information — an
    /// unread config, or a model newer than the one we read — which is
    /// the same "unknown, so don't narrow" fallback
    /// `CodexCatalog.effortLevels(forModel:)` makes. It is safe HERE
    /// and would not be for codex: a level kimi does not support is
    /// CLAMPED (the env override "intentionally bypasses
    /// support_efforts"), where codex would reject the argument and
    /// kill the turn.
    func effortLevels(forModel slug: String?) -> [String] {
        if let slug, !slug.isEmpty {
            if let model = models.first(where: { $0.slug == slug }) {
                return model.efforts
            }
            return KimiCapabilities.effortLevels   // unknown to us
        }
        // "Default" — whatever `default_model` points at answers.
        if let fallback = defaultModel,
           let model = models.first(where: { $0.slug == fallback }) {
            return model.efforts
        }
        return KimiCapabilities.effortLevels
    }

    /// Kimi's own name for a slug, for the chip and the picker rows.
    func displayName(forModel slug: String) -> String {
        models.first { $0.slug == slug }?.displayName ?? slug
    }

    /// What "Default effort" actually runs at for a given model, when
    /// its config declares one. Resolved through the same
    /// selected-then-default chain as `effortLevels(forModel:)`, so the
    /// row can never name a level belonging to a different model.
    func defaultEffort(forModel slug: String?) -> String? {
        if let slug, !slug.isEmpty {
            return models.first { $0.slug == slug }?.defaultEffort
        }
        guard let fallback = defaultModel else { return nil }
        return models.first { $0.slug == fallback }?.defaultEffort
    }

    /// `max_context_size` for a model — the denominator kimi's own
    /// status bar divides by, and so the one the context chip's
    /// percentage uses. The slug handed in is either the model
    /// SELECTED in the composer or the `model` string off the wire's
    /// newest `usage.record`, both of which are the config alias
    /// (measured on a real install: `"model":"moonshot-ai/kimi-k3"`
    /// against `[models."moonshot-ai/kimi-k3"]`). Same resolution chain
    /// as `defaultEffort(forModel:)`; nil means the chip states a token
    /// count rather than a percentage over a guessed window.
    func maxContextSize(forModel slug: String?) -> Int? {
        if let slug, !slug.isEmpty {
            return models.first { $0.slug == slug }?.maxContextSize
        }
        guard let fallback = defaultModel else { return nil }
        return models.first { $0.slug == fallback }?.maxContextSize
    }

    /// (size, mtime) of the config the current lists were built from.
    private var loadedFingerprint: String? = nil
    private var loading = false

    private init() {}

    /// Load, and RE-load whenever `config.toml` has changed since the
    /// lists were built. Safe to call from every composer appearance —
    /// the check is one `stat`.
    ///
    /// Deliberately not the one-shot `loadStarted` flag the other two
    /// catalogs use, because kimi's config is the file that changes at
    /// exactly the wrong moment: it is EMPTY until `kimi login` runs,
    /// and login is a thing users do after opening SipAI and finding a
    /// kimi session waiting. A launch-time snapshot leaves the model
    /// picker permanently empty for the whole session that motivated
    /// signing in. (`ClaudeModelCatalog` has no equivalent problem —
    /// live `system.init` events keep correcting it.)
    func ensureLoaded() {
        let fingerprint = Self.configFingerprint()
        guard !loading, fingerprint != loadedFingerprint else { return }
        loading = true
        Task.detached(priority: .utility) {
            let found = Self.harvest()
            await MainActor.run {
                self.models = found.models
                self.defaultModel = found.defaultModel
                // Stamped with the fingerprint READ BEFORE the harvest:
                // a config rewritten mid-harvest must leave the two
                // disagreeing, so the next appearance re-reads rather
                // than trusting a list built from a file that has
                // already moved on.
                self.loadedFingerprint = fingerprint
                self.loading = false
            }
        }
    }

    /// Cheap change-detector for `config.toml`. A missing file has its
    /// own stable fingerprint, so "not there yet" costs one stat per
    /// composer appearance and turns into a real load the moment the
    /// file appears.
    nonisolated private static func configFingerprint() -> String {
        let path = KimiSessionScanner.configFile.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? -1
        return "\(size)/\(mtime)"
    }

    // MARK: - Harvest

    nonisolated private static func harvest()
    -> (models: [KimiModel], defaultModel: String?) {
        let config = readConfig()
        // Only when config.toml told us nothing at all. See the type
        // comment: an alias absent from config.toml is a turn-killer,
        // so observed models may fill a VOID, never extend a real list.
        // Those have no metadata — the slug is its own label, and the
        // effort list falls back to the union.
        if config.models.isEmpty {
            let observed = observedModels(limit: 25).map {
                KimiModel(slug: $0, displayName: $0, efforts: [],
                          defaultEffort: nil)
            }
            return (observed, config.defaultModel)
        }
        return (config.models, config.defaultModel)
    }

    /// What the picker needs out of kimi's `config.toml`: the declared
    /// default, and every `[models.<alias>]` table with the two fields
    /// kimi records about it.
    ///
    /// Hand-scanned rather than parsed as TOML because the file is only
    /// ever read for these few facts, and the app ships no TOML parser.
    ///
    ///   * The scalar is TOP-LEVEL only. `[secondary_model]` carries a
    ///     `default_model` of its own — the subagent model pool — so a
    ///     scan that kept reading past the first header would hand the
    ///     composer the wrong one whenever both are set.
    ///   * A table header can be bare (`[models.k2-turbo]`) or QUOTED,
    ///     and kimi's own writer always quotes, because the aliases it
    ///     generates contain a SLASH:
    ///     `[models."kimi-for-coding/k3-256k"]`.
    ///   * QUOTED vs BARE decides whether a `.` is a separator. In TOML
    ///     `[models."gpt-4.1"]` is one key and `[models.foo.params]` is
    ///     a nested table, so the dot may only be split on when the
    ///     name was NOT quoted. Splitting unconditionally truncates
    ///     every dotted model id to its head, and `k2.5`/`gpt-5.5`-style
    ///     names are the norm.
    ///   * `[models.…]` must not match `[secondary_model.models.…]`,
    ///     which is a different pool entirely.
    nonisolated private static func readConfig()
    -> (defaultModel: String?, models: [KimiModel]) {
        guard let data = try? Data(contentsOf: KimiSessionScanner.configFile)
        else { return (nil, []) }
        return parseConfig(String(decoding: data, as: UTF8.self))
    }

    /// The parse itself, split out as a PURE function of the file's
    /// text so `Verification/KimiCode` can drive it with fixtures
    /// instead of a `$KIMI_CODE_HOME` on disk — the same reason
    /// `ScheduledTaskScheduler.decide` is pure. Every rule described
    /// above is a case in that harness.
    nonisolated static func parseConfig(_ text: String)
    -> (defaultModel: String?, models: [KimiModel]) {
        var defaultModel: String? = nil
        var slugs: [String] = []
        var displayNames: [String: String] = [:]
        var efforts: [String: [String]] = [:]
        var defaultEfforts: [String: String] = [:]
        var contextSizes: [String: Int] = [:]
        var beforeFirstHeader = true
        var currentModel: String? = nil
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // Strip a trailing comment — kimi's own seeded config.toml
            // is nothing but commented lines, and `x = "y" # note`
            // is ordinary TOML. Only outside a quoted value: a `#`
            // inside the value is part of it.
            if let hash = line.firstIndex(of: "#"),
               line[line.startIndex..<hash].filter({ $0 == "\"" }).count % 2 == 0 {
                line = String(line[line.startIndex..<hash])
                    .trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("[") {
                beforeFirstHeader = false
                currentModel = modelTableAlias(line)
                // Deduped HERE rather than by the caller: a model with
                // sub-tables (`[models.x]` + `[models.x.params]`) names
                // one alias several times, and the list this returns is
                // a picker's rows.
                if let alias = currentModel, !slugs.contains(alias) {
                    slugs.append(alias)
                }
                continue
            }
            if let model = currentModel {
                if let name = TomlScalar.string(line, key: "display_name") {
                    displayNames[model] = name
                } else if let levels = TomlScalar.stringArray(
                    line, key: "support_efforts") {
                    efforts[model] = levels
                } else if let level = TomlScalar.string(
                    line, key: "default_effort") {
                    // `default_effort` must be read BEFORE `default_model`
                    // is tried below, which it is — this branch only runs
                    // inside a `[models.*]` table. The prefix check in
                    // `TomlScalar.string` is what stops `default_effort`
                    // from answering a request for `default_model` and
                    // vice versa.
                    defaultEfforts[model] = level
                } else if let window = TomlScalar.integer(
                    line, key: "max_context_size"), window > 0 {
                    contextSizes[model] = window
                }
                continue
            }
            guard beforeFirstHeader else { continue }
            if let value = TomlScalar.string(line, key: "default_model") {
                defaultModel = value
            } else if defaultModel == nil,
                      let legacy = TomlScalar.string(line, key: "model") {
                defaultModel = legacy
            }
        }
        // Default first, then the rest — the same ordering rule the
        // codex picker follows.
        if let def = defaultModel, let at = slugs.firstIndex(of: def) {
            slugs.remove(at: at)
            slugs.insert(def, at: 0)
        }
        return (defaultModel, slugs.map {
            KimiModel(slug: $0,
                      displayName: displayNames[$0] ?? $0,
                      efforts: efforts[$0] ?? [],
                      defaultEffort: defaultEfforts[$0],
                      maxContextSize: contextSizes[$0])
        })
    }

    /// `[models.foo]` / `[models."foo"]` → `foo`. Anything else → nil,
    /// including `[[models.foo]]` (an array of tables, which kimi's
    /// schema does not use) and `[secondary_model.models.foo]`.
    nonisolated private static func modelTableAlias(_ line: String) -> String? {
        guard line.hasPrefix("[models."), line.hasSuffix("]") else { return nil }
        var body = String(line.dropFirst("[models.".count).dropLast())
            .trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("\"") {
            // Quoted: the name runs to the CLOSING quote, and any dot
            // inside it is part of the name. A trailing `.params` after
            // the quote is a sub-table of the same model.
            guard let close = body.dropFirst().firstIndex(of: "\"")
            else { return nil }
            return String(body[body.index(after: body.startIndex)..<close])
        }
        // Bare: a nested table (`[models.foo.params]`) names the same
        // alias, so take the head — it dedupes against the plain header
        // rather than adding a row no `--model` would accept.
        if let dot = body.firstIndex(of: ".") {
            body = String(body[body.startIndex..<dot])
        }
        return body.isEmpty ? nil : body
    }

    /// Model slugs recorded by the newest sessions on disk. Reads only
    /// `state.json` — small, one per session — never a wire file, which
    /// carries whole request traces.
    nonisolated private static func observedModels(limit: Int) -> [String] {
        let fm = FileManager.default
        guard KimiSessionScanner.storeExists,
              let buckets = try? fm.contentsOfDirectory(
                at: KimiSessionScanner.sessionRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return [] }
        var candidates: [(url: URL, at: Date)] = []
        for bucket in buckets {
            guard let entries = try? fm.contentsOfDirectory(
                at: bucket,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for dir in entries where !dir.lastPathComponent.hasPrefix(".") {
                let at = (try? dir.resourceValues(
                    forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                candidates.append((dir.appendingPathComponent("state.json"), at))
            }
        }
        var found: [String] = []
        for entry in candidates.sorted(by: { $0.at > $1.at }).prefix(limit) {
            guard let data = try? Data(contentsOf: entry.url),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any] else { continue }
            // Key name is a guess, like everything else read out of
            // state.json — a miss costs a picker row, never a session.
            for key in ["model", "modelName", "model_name"] {
                if let slug = obj[key] as? String,
                   !slug.isEmpty, !found.contains(slug) {
                    found.append(slug)
                    break
                }
            }
        }
        return found
    }
}

/// Human-readable Claude model names, from either a full model id or a
/// picker alias. Versions are read out of the id itself — never a
/// hand-maintained table — so the label matches official naming and
/// stays accurate as Anthropic ships new models:
///
///     claude-fable-5             → "Fable 5"
///     claude-opus-4-5-20251101   → "Opus 4.5"
///     claude-haiku-4-5-20251001  → "Haiku 4.5"
///     claude-3-5-sonnet-20241022 → "Sonnet 3.5"
///     opus (picker alias)        → "Opus"
///
/// A minor version appears only when the id carries one ("Opus 5",
/// not "Opus 5.0" — the official names never zero-pad).
/// Unrecognizable ids come back verbatim rather than guessing.
enum ClaudeModelDisplay {
    /// Family words a Claude model id can carry, display-cased.
    private static let families: [String: String] = [
        "opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku",
        "fable": "Fable", "mythos": "Mythos", "instant": "Instant",
    ]

    /// Split a trailing variant marker ("[1m]") off an id. The marker
    /// is not part of the version, so every parse strips it first —
    /// and, since `name(for:)`, the display drops it for good.
    static func splitVariant(_ raw: String) -> (id: String, variant: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("]"), let open = trimmed.firstIndex(of: "[")
        else { return (trimmed, "") }
        return (String(trimmed[..<open]), String(trimmed[open...]))
    }

    /// Family token + numeric version parts of an id
    /// ("claude-opus-4-8[1m]" → ("opus", [4, 8])). Family is nil when no
    /// known family word appears; digits are empty for a bare alias or
    /// an id whose shape we don't recognize.
    static func parts(of raw: String) -> (family: String?, digits: [Int]) {
        var id = splitVariant(raw).id.lowercased()
        // Bedrock-style provider prefix.
        if id.hasPrefix("anthropic.") {
            id = String(id.dropFirst("anthropic.".count))
        }
        var family: String? = nil
        var digits: [Int] = []
        for token in id.split(separator: "-").map(String.init) {
            if token == "claude" || token == "latest" { continue }
            if families[token] != nil {
                if family == nil { family = token }
                continue
            }
            // Short numeric tokens are version parts; 8-digit tokens are
            // date snapshots and don't belong in the version.
            if token.count <= 3, token.allSatisfy(\.isNumber),
               let n = Int(token) {
                digits.append(n)
            }
        }
        return (family, digits)
    }

    /// The family token of a full id ("claude-fable-5" → "fable") —
    /// how an observed id is paired back to its picker alias when
    /// learning versioned names from what's already on this machine.
    /// Nil when no known family word appears.
    static func familyAlias(of raw: String) -> String? {
        guard raw.lowercased().contains("claude") else { return nil }
        return parts(of: raw).family
    }

    /// Whether a picker value is a FULL id ("claude-fable-5") rather
    /// than an alias ("fable"). The "Other models" rows send full ids,
    /// and a full id is never a key in the alias map: filing an
    /// observation under one would be recording that "claude-fable-5"
    /// resolves to itself, forever.
    static func isFullId(_ value: String) -> Bool {
        value.lowercased().contains("claude-")
    }

    /// Whether `fullId` can be what `alias` resolves to.
    ///
    /// An alias names a FAMILY ("sonnet" is the latest Sonnet), so an
    /// id from a different family is not a version of it — it is a
    /// contradiction, and the only way one is ever recorded is a
    /// mis-attributed observation: an id read off a turn that ran
    /// under some OTHER alias, filed under whatever the picker said by
    /// the time it was read.
    ///
    /// This refuses only what it can PROVE wrong, and everything else
    /// passes. The empty alias is claude's own default and may resolve
    /// to any family; an alias with no family word in it ("opusplan")
    /// cannot be judged from its spelling, and neither can an id with
    /// no family word in it. Guessing in either of those directions
    /// would refuse a pairing that is simply newer than this table.
    ///
    /// Costly to get wrong in one direction only, which is why it sits
    /// on both sides of the store: a wrong pairing does not fail, it
    /// RENAMES a model, and it renames it identically after a restart.
    static func canResolve(alias: String, to fullId: String) -> Bool {
        let aliasBase = splitVariant(alias).id.lowercased()
        guard !aliasBase.isEmpty else { return true }
        guard families[aliasBase] != nil else { return true }
        guard let idFamily = parts(of: fullId).family else { return true }
        return idFamily == aliasBase
    }

    /// True when `a` names a strictly newer version than `b`. This is
    /// the ordering behind "what does this alias resolve to": an alias
    /// always means the LATEST model of its family, so among the ids
    /// this machine has actually seen, the highest version is the
    /// alias's answer — not the most recently sighted one.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let da = parts(of: a).digits
        let db = parts(of: b).digits
        for i in 0..<max(da.count, db.count) {
            let x = i < da.count ? da[i] : 0
            let y = i < db.count ? db[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The name shown for a model id — version included, variant NOT.
    ///
    /// A trailing `[1m]` names the 1M-context spelling of a model, and
    /// BOTH spellings of one model occur on a normal machine.
    /// Re-attaching the marker would therefore render ONE model two
    /// ways depending on which id a given surface happened to see.
    ///
    /// So: a derived NAME never carries a variant. Dropping it costs
    /// nothing — on every model that reaches here the 1M window is
    /// already both the default and the maximum, so the marker
    /// distinguishes no capability the user could act on — and the
    /// exact recorded id stays one hover away on the chip, which is
    /// where ground truth belongs. A name is derived; an id is not.
    static func name(for raw: String) -> String {
        let id = splitVariant(raw).id
        guard !id.isEmpty else { return raw }
        // Aliases ("opus", "sonnet") have no version to surface — same
        // casing the picker rows already use.
        guard id.lowercased().contains("claude") else { return id.capitalized }
        let (family, digits) = parts(of: raw)
        // No recognizable family — show the id as recorded.
        guard let family = family, let cased = families[family] else { return id }
        guard let major = digits.first else { return cased }
        let version = digits.count > 1 ? "\(major).\(digits[1])" : "\(major)"
        return "\(cased) \(version)"
    }
}

/// What each picker alias currently resolves to, harvested from what
/// Claude Code itself has already recorded on this machine.
///
/// The composer's model rows want versioned names ("Opus 5", not
/// "Opus"), and the repo rule is that model lists are observed, never
/// tabled — a hardcoded alias→version map drifts the day a new model
/// ships. Observing only OUR OWN sends, though, is too narrow twice
/// over: a family never sent from SipAI never gets a version at all
/// ("Sonnet", "Haiku"), and a family whose mapping was learned before
/// a new model shipped stays pinned to the old one forever ("Opus
/// 4.8" long after `--model opus` began resolving to Opus 5).
///
/// So the harvest reads the ids Claude Code has recorded for this
/// account — its own state file plus the recent session store — and
/// keeps the HIGHEST version per family, which is exactly what the
/// alias means. Every id here is one this account was actually served
/// or offered; nothing is invented.
/// Which context window a session's percentage is drawn over.
///
/// One pure rule for all three agents, so the chip cannot mean
/// different things in different sections. The inputs arrive as
/// closures rather than as catalog references for the same reason
/// `ScheduledTaskScheduler.decide` takes its state as parameters: the
/// rule is then testable headlessly, with no MainActor catalog and no
/// files on disk.
///
/// Order, and why:
///
/// 1. **The model SELECTED in the composer.** The next call runs under
///    it, so its window is the one that answers "how close am I". This
///    is also what Claude Code divides by — the current main-loop
///    model, not whichever model produced the last call.
/// 2. **The model that produced the NUMBER**, when the selection
///    resolves to nothing. Covers a session opened cold whose picker
///    still reads Default, and a model the catalogs do not name.
/// 3. **nil — no percentage.** A window is never guessed. The chip
///    states the token count instead and says so, because a percentage
///    over an invented denominator is a specific wrong claim where a
///    count is merely less informative.
/// How the context chip STATES what the resolver and the readers found.
///
/// Pure, and deliberately not inside the SwiftUI view: these two rules
/// are the ones a reader checks against their agent's own terminal, so
/// they have to be exercisable without a window.
enum ContextUsageFormat {
    /// Compact token counts: "999", "9.9k", "258k", "1.0M".
    static func compact(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 {
            let k = Double(n) / 1000
            return k < 10 ? String(format: "%.1fk", k) : "\(Int(k.rounded()))k"
        }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }

    /// Whole percent, rounded the way claude's own indicator rounds,
    /// clamped to 1…100: a live session is never "0%", and a model that
    /// overruns the window this machine knows for it (a long-context
    /// tier nobody here has learned) reads as full rather than as
    /// impossible. 0 means there is nothing to state.
    static func percent(_ used: Int, of window: Int) -> Int {
        guard window > 0, used > 0 else { return 0 }
        return min(100, max(1, Int((Double(used) / Double(window) * 100).rounded())))
    }
}

enum ContextWindowResolver {
    static func resolve(agentKey: String,
                        selectedAlias: String?,
                        selectedFullId: String?,
                        numeratorModel: String?,
                        recordedWindow: Int,
                        aliasToId: (String) -> String?,
                        binaryWindow: (String) -> Int?,
                        learnedWindow: (String) -> Int?,
                        catalogWindow: (String?) -> Int?) -> Int? {
        func claudeWindow(_ id: String?) -> Int? {
            guard let id, !id.isEmpty else { return nil }
            // The shipped table first — it names every model the picker
            // offers and needs no turn to have run. The learned value
            // is what covers the ids it does not carry.
            if let w = binaryWindow(id), w > 0 { return w }
            if let w = learnedWindow(id), w > 0 { return w }
            return nil
        }
        if agentKey == "claude_code" {
            // A concrete pick is itself the id; an alias resolves
            // through the map this machine observed. An empty alias is
            // claude's Default, which the map records under "".
            let selectedId = (selectedFullId?.isEmpty == false)
                ? selectedFullId
                : aliasToId(selectedAlias ?? "")
            if let w = claudeWindow(selectedId) { return w }
            if let w = claudeWindow(numeratorModel) { return w }
            return nil
        }
        // Codex and kimi: the selection is a literal model id their own
        // catalogs answer for. `nil`/"" means Default, which each
        // catalog resolves through its configured default model.
        if let w = catalogWindow(selectedFullId?.isEmpty == false
                                    ? selectedFullId : selectedAlias),
           w > 0 {
            return w
        }
        // What the store recorded beside the number — codex stamps the
        // window on the same rollout record, and kimi's is joined from
        // its config by the model on the usage record.
        if recordedWindow > 0 { return recordedWindow }
        return nil
    }
}

enum ClaudeModelCatalog {
    struct Harvest {
        /// family alias → newest full id seen ("opus" → "claude-opus-5").
        var byFamily: [String: String] = [:]
        /// Model of the most recent session, for seeding the "" default.
        var newestSessionModel: String? = nil
        /// Every id offered, in sighting order — the pool the "Other
        /// models" section is drawn from. Same filter as `byFamily`
        /// (variant-stripped, family known, versioned); unlike it,
        /// nothing here is superseded by a newer version.
        var allIds: [String] = []
    }

    /// One SUCCESSFUL harvest per app launch, merged into the observed
    /// map.
    ///
    /// The latch lives here rather than on the session view because the
    /// center pane tears that view down whenever the user opens a chat
    /// or a note — a per-view latch would re-run the whole scan on
    /// every switch back. An empty `sessionURLs` (cold-launch sidebar
    /// scan still running) leaves the latch open: the state file alone
    /// can name every family, but only a session can seed the ""
    /// default.
    @MainActor private static var refreshed = false

    /// A harvest already on its way. The latch above can only be armed
    /// once the pass has RETURNED, so this is what stops the four
    /// callers of `seedLaunchOptions` from each starting their own.
    @MainActor private static var harvesting = false

    /// Forget this launch's harvest so the next call re-runs it.
    ///
    /// Exists for the factory reset, and the reason is worth stating:
    /// what a harvest produces is not cached in this enum, it is
    /// WRITTEN INTO OUR CONFIG — and the reset empties that file. The
    /// latch would then be claiming "already learned" over a map that
    /// no longer holds anything, leaving every model row on a bare
    /// family name ("Opus", not "Opus 5") until the app is relaunched.
    /// Any launch-scoped latch over data the reset wipes has to be
    /// cleared by the reset.
    @MainActor
    static func forgetHarvest() {
        refreshed = false
    }

    @MainActor
    static func refreshObservedNames(config: ConfigManager,
                                     sessionURLs: [URL]) {
        guard !refreshed, !harvesting else { return }
        harvesting = true
        Task.detached(priority: .utility) {
            let found = Self.harvest(sessionURLs: sessionURLs)
            await MainActor.run {
                harvesting = false
                // Only ever moves an alias FORWARD — see
                // ConfigManager.learnAgentModelFullIds.
                config.learnAgentModelFullIds(found.byFamily)
                // …while the pool behind "Other models" only ever
                // GROWS, and is trimmed by the installed binary, not
                // by version.
                config.learnAgentModelObservedIds(found.allIds)
                Self.refreshOtherModels(config: config)
                // The default is whatever claude picks with no --model
                // flag; versions can't rank it (Fable 5 and Opus 5 are
                // different families), so it stays a one-time seed the
                // first unflagged send corrects with ground truth.
                if let newest = found.newestSessionModel,
                   config.agentModelFullId(forAlias: "") == nil {
                    config.setAgentModelFullId(newest, forAlias: "")
                }
                // Latch on what was LEARNED, not on what was attempted.
                // Two conditions, and both are about completeness: the
                // sessions have to have been in hand (they carry the ""
                // default, which the state file cannot), and the pass
                // has to have come back with at least one name. A pass
                // that learned nothing is not a launch's worth of
                // knowledge — leaving the latch open costs one bounded
                // re-read the next time a session opens, where arming it
                // costs every model row its version until the app is
                // restarted.
                if !sessionURLs.isEmpty && !found.byFamily.isEmpty {
                    refreshed = true
                }
            }
        }
    }

    /// Rebuild the composer's "Other models" section: per family, the
    /// newest observed id BELOW what the alias resolves to NOW
    /// (`resolvedModel` — the binary's answer, never the map as of
    /// some earlier harvest), kept only if the installed claude still
    /// names it, and titled by the binary's own `display_name`.
    ///
    /// The binary scan is the "still offered" test. Claude's model
    /// table is literal strings in its executable, superseded models
    /// listed beside their successors, so a model claude has dropped stops being
    /// offered as `--model` the day its binary stops naming it, with
    /// no table of ours to go stale. The observation half is what keeps
    /// out ids the binary keeps only for legacy remapping (it still
    /// names Haiku 3.5, and carries no retirement flag): a row is a
    /// model THIS account has run.
    ///
    /// Cheap and idempotent — a config read, a few comparisons, and a
    /// binary scan cached by fingerprint off the MainActor — so it is
    /// simply CALLED wherever an input moves: the harvest tail, the
    /// live observation, the composer's appearance, and the pass that
    /// reads a new binary.
    @MainActor
    static func refreshOtherModels(config: ConfigManager) {
        let catalog = installedCatalog()
        let candidates = otherModelCandidates(
            aliases: ClaudeCapabilities.shared.modelAliases,
            observed: config.agentModelObservedIds(),
            catalog: catalog,
            resolvedId: { alias in
                resolvedModel(alias: alias,
                              observed: { config.agentModelFullId(forAlias: $0) })?.id
            })
        guard !candidates.isEmpty,
              let binary = AgentManager.binaryPath(for: "claude_code") else {
            ClaudeCapabilities.shared.setOtherModels([])
            return
        }
        Task.detached(priority: .utility) {
            let named = Self.idsNamedByBinary(at: binary,
                                              candidates: candidates.map(\.id))
            let rows = candidates
                .filter { named.contains($0.id) }
                .map {
                    ClaudeOtherModel(fullId: $0.id, family: $0.family,
                                     displayName: displayName(forId: $0.id,
                                                              catalog: catalog))
                }
            await MainActor.run { ClaudeCapabilities.shared.setOtherModels(rows) }
        }
    }

    /// What a send with NO `--model` runs as, read from claude's own
    /// configuration the way the codex and kimi Default rows read
    /// theirs: `ANTHROPIC_MODEL` in the environment the CHILD will see
    /// (`childEnvironmentFacts` — the process environment plus claude's
    /// own settings `env` blocks, never the login shell, which a SipAI
    /// child does not inherit), then the `model` key of the project's
    /// `.claude/settings.local.json` and `.claude/settings.json`, then
    /// the user's — claude's own precedence. Nil when none sets one,
    /// and the caller falls back to what a Default send was last
    /// OBSERVED to resolve to. A few small reads, the environment half
    /// cached by file fingerprint; callers cache per composer
    /// appearance.
    nonisolated static func configuredDefaultModel(cwd: URL?) -> String? {
        if let configured = childEnvironmentFacts().configuredModel {
            return configured
        }
        var files: [URL] = []
        if let cwd {
            files.append(cwd.appendingPathComponent(".claude/settings.local.json"))
            files.append(cwd.appendingPathComponent(".claude/settings.json"))
        }
        // Highest precedence first — `userSettingsFiles` is kept in
        // the order claude APPLIES them, which is the reverse.
        files.append(contentsOf: userSettingsFiles.reversed())
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  let model = obj["model"] as? String
            else { continue }
            let trimmed = model.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: Context window (binary model table)

    /// One model's entry in claude's own table.
    struct WindowEntry {
        let window: Int
        /// The base entry is already 1M with no suffix.
        let native1M: Bool
        /// A `[1m]` spelling of this id gets the long window.
        let supports1MSuffix: Bool
    }

    /// Context window for a model id, read from the table claude SHIPS.
    ///
    /// This is why the chip can state an occupancy on a claude session
    /// that has never run in this app: the window is a fact about the
    /// installed CLI, exactly as codex's is a fact about
    /// `models_cache.json` and kimi's about `config.toml`. Nothing here
    /// is hardcoded — a table of windows would drift the day a model
    /// ships, the same reason model lists are scraped.
    ///
    /// A `[1m]` id resolves through its BASE entry plus the base's
    /// `supports_1m_suffix` flag: the suffix names a different window
    /// on the same model, and the table records it once.
    ///
    /// nil for a model the table does not name — a gateway id, a custom
    /// `ANTHROPIC_MODEL`, a binary too old to carry the table. The chip
    /// then states the token count and says the window is unknown; it
    /// never divides by a guess.
    nonisolated static func contextWindow(forModelId raw: String,
                                          binary: String) -> Int? {
        let (base, variant) = ClaudeModelDisplay.splitVariant(raw)
        guard !base.isEmpty else { return nil }
        let table = windowTable(at: binary)
        guard let entry = table[base] else { return nil }
        if variant.lowercased() == "[1m]" {
            return entry.supports1MSuffix ? 1_000_000 : entry.window
        }
        return entry.window
    }

    /// Every `first_party` id in the binary's model table, with the
    /// window recorded beside it.
    ///
    /// The table is JS source, so an entry reads
    /// `first_party:"claude-opus-5",…,context:{window:1e6,native_1m:!0,
    /// supports_1m_suffix:!0}`. Two things about parsing it:
    ///
    /// * **`1e6` is a number.** Reading the digits alone answers 1, and
    ///   a one-token window turns every percentage into 100%.
    /// * **The id is found BACKWARD from the window, never forward from
    ///   the id.** An entry names its predecessor in `fallback_3p`
    ///   before stating its own window, so scanning forward from an id
    ///   can land on the NEXT model's window. `first_party` is the only
    ///   key that names the entry itself.
    ///
    /// Streamed in chunks with an overlap and never mapped, the same
    /// rule and the same reason as `idsNamedByBinary`: claude's updater
    /// rewrites its versions directory in place, and a mapped page
    /// under a writer is a SIGBUS. Cached by (path, size, mtime).
    nonisolated static func windowTable(at path: String) -> [String: WindowEntry] {
        let key = binaryKey(at: path) ?? "\(path)|missing"
        windowLock.lock()
        if let cached = windowCache, cached.key == key {
            windowLock.unlock()
            return cached.table
        }
        windowLock.unlock()

        var table: [String: WindowEntry] = [:]
        let needle = Data("context:{window:".utf8)
        // Enough to reach back over an entry's other keys to its
        // `first_party`, and forward over the flags to the closing
        // brace. Measured entries sit well inside this.
        let lookBehind = 2048
        let lookAhead = 256
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            var carry = Data()
            while true {
                let chunk = handle.readData(ofLength: 8 * 1024 * 1024)
                if chunk.isEmpty { break }
                var window = carry
                window.append(chunk)
                var from = window.startIndex
                while let hit = window.range(of: needle, in: from..<window.endIndex) {
                    let lo = window.index(hit.lowerBound,
                                          offsetBy: -min(lookBehind,
                                                         window.distance(from: window.startIndex,
                                                                         to: hit.lowerBound)))
                    let hi = window.index(hit.upperBound,
                                          offsetBy: min(lookAhead,
                                                        window.distance(from: hit.upperBound,
                                                                        to: window.endIndex)))
                    if let (id, entry) = Self.parseWindowEntry(
                        String(decoding: window[lo..<hi], as: UTF8.self)) {
                        table[id] = entry
                    }
                    from = hit.upperBound
                }
                // Overlap so an entry straddling the boundary is still
                // read whole on the next pass; a match seen twice
                // parses to the same pair.
                let keep = lookBehind + lookAhead + needle.count
                carry = window.count > keep ? Data(window.suffix(keep)) : window
            }
        }
        windowLock.lock()
        windowCache = WindowScan(key: key, table: table)
        windowLock.unlock()
        return table
    }

    /// One entry out of a decoded slice ending just past its
    /// `context:{window:…}`. Returns nil unless BOTH the id and a
    /// positive window are present — a half-read entry is not a fact.
    nonisolated private static func parseWindowEntry(_ text: String)
    -> (String, WindowEntry)? {
        guard let windowRange = text.range(of: "context:{window:",
                                           options: .backwards)
        else { return nil }
        // Backward to the entry's own id.
        let head = text[..<windowRange.lowerBound]
        guard let idKey = head.range(of: "first_party:\"", options: .backwards)
        else { return nil }
        let afterKey = head[idKey.upperBound...]
        guard let quote = afterKey.firstIndex(of: "\"") else { return nil }
        let id = String(afterKey[..<quote])
        guard !id.isEmpty else { return nil }

        let tail = text[windowRange.upperBound...]
        guard let close = tail.firstIndex(of: "}") else { return nil }
        let body = tail[..<close]
        var digits = ""
        var exponent = ""
        var inExponent = false
        for ch in body {
            if ch.isNumber {
                if inExponent { exponent.append(ch) } else { digits.append(ch) }
            } else if (ch == "e" || ch == "E"), !digits.isEmpty, !inExponent {
                inExponent = true
            } else {
                break
            }
        }
        // A window is at most a handful of digits; a mantissa or an
        // exponent past what an Int holds is not a table entry, and a
        // checked multiply refuses it rather than trapping on it.
        guard digits.count <= 15, var window = Int(digits), window > 0 else { return nil }
        if inExponent {
            guard let exp = Int(exponent), exp >= 0, exp <= 12 else { return nil }
            for _ in 0..<exp {
                let (scaled, overflow) = window.multipliedReportingOverflow(by: 10)
                guard !overflow else { return nil }
                window = scaled
            }
        }
        return (id, WindowEntry(
            window: window,
            native1M: body.contains("native_1m"),
            supports1MSuffix: body.contains("supports_1m_suffix")))
    }

    private struct WindowScan {
        let key: String
        let table: [String: WindowEntry]
    }
    nonisolated private static let windowLock = NSLock()
    nonisolated(unsafe) private static var windowCache: WindowScan? = nil

    // MARK: Binary scan

    /// Cache key for anything read out of the executable at `path`:
    /// the LINK's own (size, mtime) AND its resolved target's, the two
    /// stats `AgentCLIProbe.fingerprint` takes for the update monitor.
    ///
    /// `attributesOfItem` does not traverse a terminal symlink, so the
    /// path `AgentManager.binaryPath` answers for claude
    /// (`~/.local/bin/claude`) stats the link — which an updater that
    /// repoints it (claude's native installer) or recreates it (npm)
    /// moves, and one that rewrites the TARGET in place does not. Both
    /// halves, so a scan cannot describe a binary that is gone whichever
    /// way it went. Nil when nothing is at `path`.
    nonisolated static func binaryKey(at path: String) -> String? {
        let fm = FileManager.default
        guard let link = try? fm.attributesOfItem(atPath: path) else { return nil }
        func stamp(_ attrs: [FileAttributeKey: Any]?) -> String {
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs?[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? -1
            return "\(size)/\(mtime)"
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let target = resolved == path ? link : try? fm.attributesOfItem(atPath: resolved)
        return "\(path)|\(stamp(link))|\(resolved)|\(stamp(target))"
    }

    private struct BinaryScan {
        let key: String
        var asked: Set<String>
        var named: Set<String>
    }
    nonisolated private static let scanLock = NSLock()
    nonisolated(unsafe) private static var scanCache: BinaryScan? = nil

    /// Which of `candidates` the executable at `path` names.
    ///
    /// Streamed in chunks with an overlap, never mapped: claude's
    /// updater writes into its versions directory IN PLACE (a version
    /// file can sit empty for hours while its download completes), and a
    /// mapped page under a writer is a SIGBUS. Each id is searched followed by
    /// a quote, as the table spells it — `claude-fable-5` alone would
    /// match inside `claude-fable-5-1`. A dated id (`…-4-5-20251001`)
    /// is also tried undated, which is how the table spells those.
    /// Cached by (path, size, mtime): one read per binary.
    nonisolated static func idsNamedByBinary(at path: String,
                                             candidates: [String]) -> Set<String> {
        let key = binaryKey(at: path) ?? "\(path)|missing"
        let asked = Set(candidates)
        scanLock.lock()
        if let cached = scanCache, cached.key == key, asked.isSubset(of: cached.asked) {
            scanLock.unlock()
            return cached.named.intersection(asked)
        }
        scanLock.unlock()

        var probes: [String: [Data]] = [:]
        var longest = 0
        for id in asked {
            var spellings = [id + "\""]
            let tokens = id.split(separator: "-")
            if let last = tokens.last, last.count == 8, last.allSatisfy(\.isNumber) {
                spellings.append(tokens.dropLast().joined(separator: "-") + "\"")
            }
            let datas = spellings.map { Data($0.utf8) }
            probes[id] = datas
            longest = max(longest, datas.map(\.count).max() ?? 0)
        }
        var named: Set<String> = []
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            var carry = Data()
            while named.count < asked.count {
                let chunk = handle.readData(ofLength: 8 * 1024 * 1024)
                if chunk.isEmpty { break }
                var window = carry
                window.append(chunk)
                for (id, datas) in probes where !named.contains(id) {
                    if datas.contains(where: { window.range(of: $0) != nil }) {
                        named.insert(id)
                    }
                }
                carry = window.count > longest ? window.suffix(longest) : window
            }
        }
        scanLock.lock()
        if let cached = scanCache, cached.key == key {
            scanCache = BinaryScan(key: key,
                                   asked: cached.asked.union(asked),
                                   named: cached.named.union(named))
        } else {
            scanCache = BinaryScan(key: key, asked: asked, named: named)
        }
        scanLock.unlock()
        return named
    }

    /// Reads files — call from a detached task, never the MainActor.
    nonisolated static func harvest(sessionURLs: [URL]) -> Harvest {
        var out = Harvest()
        func offer(_ raw: String) {
            let id = ClaudeModelDisplay.splitVariant(raw).id
            // A variant ("[1m]") belongs to the alias the user picked,
            // not to the family's version, so only plain ids are learned.
            // The family is the casing table's, else the installed
            // binary's — a family the table has never heard of is still
            // one to the binary that ships it.
            guard !id.isEmpty,
                  let family = Self.family(ofId: id),
                  !ClaudeModelDisplay.parts(of: id).digits.isEmpty
            else { return }
            if !out.allIds.contains(id) { out.allIds.append(id) }
            if let known = out.byFamily[family],
               !ClaudeModelDisplay.isNewer(id, than: known) { return }
            out.byFamily[family] = id
        }
        for id in stateFileModelIds() { offer(id) }
        for url in sessionURLs {
            guard let model = AgentSessionScanner
                    .lastLaunchOptions(of: url).model,
                  !model.isEmpty else { continue }
            if out.newestSessionModel == nil { out.newestSessionModel = model }
            offer(model)
        }
        return out
    }

    /// Full model ids named anywhere in `~/.claude.json` that describe
    /// THIS account: the per-client cache slots (what each Claude Code
    /// client last ran), the per-project usage ledger (keyed by model
    /// id), and the extra options this account's own picker offers.
    /// Feature-flag blobs are deliberately not read — those describe
    /// the fleet, not the user.
    nonisolated private static func stateFileModelIds() -> [String] {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any]
        else { return [] }
        var ids: [String] = []
        if let slots = root["clientDataCacheSlots"] as? [String: Any] {
            for slot in slots.values {
                if let d = slot as? [String: Any],
                   let m = d["model"] as? String { ids.append(m) }
            }
        }
        if let projects = root["projects"] as? [String: Any] {
            for project in projects.values {
                if let d = project as? [String: Any],
                   let usage = d["lastModelUsage"] as? [String: Any] {
                    ids.append(contentsOf: usage.keys)
                }
            }
        }
        if let options = root["additionalModelOptionsCache"] as? [[String: Any]] {
            for option in options {
                if let v = option["value"] as? String { ids.append(v) }
            }
        }
        return ids
    }


    // MARK: Baked catalog (the alias table claude resolves through)

    /// The model catalog claude ships INSIDE its executable — what
    /// `--model opus` will run, read off the binary that will run it.
    ///
    /// This is the authority for a picker row's name. It needs no turn
    /// to have run and no state file to have been written: the instant
    /// the binary moves, the names move with it. The observed map
    /// (`ConfigManager.agentModelFullId`) is the FALLBACK — for a binary
    /// without the table, an alias the table does not name — and the
    /// hover's record of what actually ran.
    ///
    /// Two ids per entry, and the join between them is load-bearing:
    /// `catalogId` is what the alias table names (`claude-haiku-4-5`),
    /// `firstPartyId` is what reaches the wire, the transcripts and the
    /// window table (`claude-haiku-4-5-20251001`, or
    /// `claude-sonnet-4-20250514` for `claude-sonnet-4-0` — the
    /// difference is not always a date).
    struct BinaryCatalog: Equatable {
        struct Entry: Equatable {
            let catalogId: String
            let family: String
            let displayName: String
            let firstPartyId: String
            /// `capabilities` as the binary lists them — the flags
            /// claude's own resolver reads for this model (`effort`,
            /// `xhigh_effort`, `max_effort`, …). nil when the entry
            /// carries no list this scanner could read (no key, or a
            /// value of another shape), which is UNKNOWN, never "none".
            /// See `ClaudeModelCatalog.effortLevels`.
            var capabilities: [String]? = nil
        }
        /// In the binary's own order.
        let entries: [Entry]
        /// alias → catalog id ("opus" → "claude-opus-5").
        let aliasDefault: [String: String]
        /// alias → provider → catalog id ("opus" → ["foundry": …]).
        let aliasPerProvider: [String: [String: String]]
        let latestPerFamily: [String: String]
        let best: String?

        private let byCatalogId: [String: Entry]
        private let byWireId: [String: Entry]
        /// Every capability any entry lists, lowercased.
        private let capabilityVocabulary: Set<String>

        init(entries: [Entry], aliasDefault: [String: String],
             aliasPerProvider: [String: [String: String]],
             latestPerFamily: [String: String], best: String?) {
            self.entries = entries
            self.aliasDefault = aliasDefault
            self.aliasPerProvider = aliasPerProvider
            self.latestPerFamily = latestPerFamily
            self.best = best
            var byCatalog: [String: Entry] = [:]
            var byWire: [String: Entry] = [:]
            var vocabulary: Set<String> = []
            for entry in entries {
                byCatalog[entry.catalogId] = entry
                byWire[entry.firstPartyId] = entry
                for flag in entry.capabilities ?? [] { vocabulary.insert(flag.lowercased()) }
            }
            byCatalogId = byCatalog
            byWireId = byWire
            capabilityVocabulary = vocabulary
        }

        /// The entry for a wire id or a catalog id, variant stripped.
        func entry(forId raw: String) -> Entry? {
            let id = ClaudeModelDisplay.splitVariant(raw).id
            return byWireId[id] ?? byCatalogId[id]
        }

        /// Whether any entry lists `flag` — whether this table speaks
        /// that part of the vocabulary at all.
        func listsCapability(_ flag: String) -> Bool {
            capabilityVocabulary.contains(flag.lowercased())
        }
    }

    private struct CatalogScan {
        let key: String
        let catalog: BinaryCatalog?
    }
    nonisolated private static let catalogLock = NSLock()
    nonisolated(unsafe) private static var catalogCache: CatalogScan? = nil

    /// The catalog baked into the executable at `path`, or nil when it
    /// carries none (an older binary) or the shape moved.
    ///
    /// Same read discipline as `windowTable`: streamed in 8 MB chunks
    /// with an overlap, never mapped — claude's updater rewrites its
    /// versions directory in place. The catalog is found through
    /// `latest_per_family:{`, walking BACK to the `,models:[{id:"`
    /// that opens it; the anchor is not unique in every build (some
    /// also carry an empty schema seed spelling the same keys), so
    /// every occurrence is tried in file order and the first slice the
    /// scanner reads WHOLE — a closing brace reached, at least one
    /// model and one alias — is the table. A half-read slice is not a
    /// fact; it is skipped, and a binary with no whole slice answers nil
    /// so the observed map answers instead.
    ///
    /// Cached by `binaryKey` — one read per binary, nil included, so a
    /// binary without the table costs one scan and not one per name.
    ///
    /// The slice begins at `models:` and runs forward, so it reads the
    /// keys claude spells AT OR AFTER `models` — `aliases`, `defaults`,
    /// `best`, `latest_per_family` — which is their measured order in
    /// every shipping binary. A build that moved `aliases` BEFORE
    /// `models` would leave the parse with no alias table and answer
    /// nil, and the observed map would name the rows instead: a safe
    /// degradation, and the harness's live section (which parses the
    /// installed binary) is the tripwire that a shape moved.
    nonisolated static func binaryCatalog(at path: String) -> BinaryCatalog? {
        let key = binaryKey(at: path) ?? "\(path)|missing"
        catalogLock.lock()
        if let cached = catalogCache, cached.key == key {
            catalogLock.unlock()
            return cached.catalog
        }
        catalogLock.unlock()
        let found = scanBinaryCatalog(at: path)
        catalogLock.lock()
        catalogCache = CatalogScan(key: key, catalog: found)
        catalogLock.unlock()
        return found
    }

    /// `binaryCatalog`, but never READS: the cached table for `path`
    /// when the cache holds it, else nil.
    ///
    /// Every name lookup on a body pass goes through this. A cache miss
    /// there must cost two stats, not a 200 MB scan on the main thread
    /// — `ClaudeCapabilities.ensureLoaded` warms the cache off the
    /// MainActor and publishes when it lands, which is what re-renders
    /// the rows onto the binary's names.
    nonisolated static func cachedBinaryCatalog(at path: String) -> BinaryCatalog? {
        let key = binaryKey(at: path) ?? "\(path)|missing"
        catalogLock.lock()
        defer { catalogLock.unlock() }
        guard let cached = catalogCache, cached.key == key else { return nil }
        return cached.catalog
    }

    /// The installed claude's cached catalog — nil when no claude is
    /// installed, when it carries no table, or when nothing has read
    /// it yet this launch.
    nonisolated static func installedCatalog() -> BinaryCatalog? {
        guard let binary = AgentManager.binaryPath(for: "claude_code") else { return nil }
        return cachedBinaryCatalog(at: binary)
    }

    nonisolated private static func scanBinaryCatalog(at path: String) -> BinaryCatalog? {
        let anchor = Data("latest_per_family:{".utf8)
        let opener = Data(",models:[{id:\"".utf8)
        // The whole table sits before the anchor (14 KB measured) and
        // the keys after it close within a few hundred bytes; both
        // bounds leave room for the table to grow several times over.
        let lookBehind = 64 * 1024
        let lookAhead = 4 * 1024
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var carry = Data()
        var atEOF = false
        while true {
            let chunk = atEOF ? Data() : handle.readData(ofLength: 8 * 1024 * 1024)
            if chunk.isEmpty { atEOF = true }
            var window = carry
            window.append(chunk)
            if window.isEmpty { return nil }
            var from = window.startIndex
            while let hit = window.range(of: anchor, in: from..<window.endIndex) {
                // An anchor without its full look-ahead in hand waits
                // for the next chunk; the carry keeps it, history and
                // all. The file's end is the one place a short
                // look-ahead is the whole story.
                if !atEOF,
                   window.distance(from: hit.upperBound, to: window.endIndex) < lookAhead {
                    break
                }
                let lo = window.index(
                    hit.lowerBound,
                    offsetBy: -min(lookBehind,
                                   window.distance(from: window.startIndex,
                                                   to: hit.lowerBound)))
                if let open = window.range(of: opener, options: .backwards,
                                           in: lo..<hit.lowerBound) {
                    let hi = window.index(
                        hit.upperBound,
                        offsetBy: min(lookAhead,
                                      window.distance(from: hit.upperBound,
                                                      to: window.endIndex)))
                    // Past the leading comma: the scanner starts on
                    // `models:`.
                    let slice = Array(window[window.index(after: open.lowerBound)..<hi])
                    var scanner = CatalogScanner(slice)
                    if let catalog = scanner.parseCatalog() { return catalog }
                }
                from = hit.upperBound
            }
            if atEOF { return nil }
            let keep = lookBehind + lookAhead + anchor.count
            carry = window.count > keep ? Data(window.suffix(keep)) : window
        }
    }

    /// Hand-written scanner over the catalog SLICE — a minified JS
    /// object literal, which is why nothing here is a regex: every
    /// value can nest another (`provider_ids:{…}`, `context:{…,
    /// native_1m_3p:{…}}`, `capabilities:[…]`), and a character class
    /// cannot match a balanced group. Values are strings, numbers
    /// (`1e6` included), `!0`/`!1`, `null`, identifiers, arrays and
    /// objects; keys are bare identifiers. Only five keys of a model
    /// entry and two of an alias entry are READ; everything else is
    /// skipped by balanced, quote-aware counting, so a key added in a
    /// later build costs nothing. Recursion is bounded.
    private struct CatalogScanner {
        private let bytes: [UInt8]
        private var i = 0
        private static let maxDepth = 32

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        private func peek() -> UInt8? { i < bytes.count ? bytes[i] : nil }

        private mutating func skipSpace() {
            while let c = peek(), c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 {
                i += 1
            }
        }

        private mutating func take(_ c: UInt8) -> Bool {
            skipSpace()
            guard peek() == c else { return false }
            i += 1
            return true
        }

        private func isIdentifier(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A)
                || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24
        }

        private func isQuote(_ c: UInt8?) -> Bool { c == 0x22 || c == 0x27 }

        /// A string literal at the cursor, escapes resolved to the
        /// character they name (`\"`, `\\`, `\/`, `\n`, `\xHH`,
        /// `\uHHHH` with surrogate pairs). Nil on anything else, or
        /// unterminated.
        private mutating func readString() -> String? {
            skipSpace()
            guard let quote = peek(), isQuote(quote) else { return nil }
            i += 1
            var out: [UInt8] = []
            while let c = peek() {
                i += 1
                if c == 0x5C {
                    guard let escaped = peek() else { return nil }
                    i += 1
                    switch escaped {
                    case 0x6E: out.append(0x0A)   // n
                    case 0x74: out.append(0x09)   // t
                    case 0x72: out.append(0x0D)   // r
                    case 0x62: out.append(0x08)   // b
                    case 0x66: out.append(0x0C)   // f
                    case 0x76: out.append(0x0B)   // v
                    case 0x30: out.append(0x00)   // 0
                    case 0x78:                    // xHH
                        guard let value = readHex(digits: 2) else { return nil }
                        out.append(contentsOf: Array(String(UnicodeScalar(UInt8(value))).utf8))
                    case 0x75:                    // uHHHH, possibly a surrogate pair
                        guard var value = readHex(digits: 4) else { return nil }
                        if (0xD800...0xDBFF).contains(value),
                           peek() == 0x5C, i + 1 < bytes.count, bytes[i + 1] == 0x75 {
                            let mark = i
                            i += 2
                            if let low = readHex(digits: 4), (0xDC00...0xDFFF).contains(low) {
                                value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                i = mark
                            }
                        }
                        guard let scalar = UnicodeScalar(value) else { return nil }
                        out.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default: out.append(escaped)  // \" \' \\ \/ and any other
                    }
                    continue
                }
                if c == quote { return String(decoding: out, as: UTF8.self) }
                out.append(c)
            }
            return nil
        }

        /// `digits` hex digits at the cursor, consumed. Nil when fewer
        /// are there — a malformed escape is malformed input.
        private mutating func readHex(digits: Int) -> UInt32? {
            guard i + digits <= bytes.count else { return nil }
            var value: UInt32 = 0
            for k in 0..<digits {
                let c = bytes[i + k]
                let nibble: UInt32
                switch c {
                case 0x30...0x39: nibble = UInt32(c - 0x30)
                case 0x41...0x46: nibble = UInt32(c - 0x41 + 10)
                case 0x61...0x66: nibble = UInt32(c - 0x61 + 10)
                default: return nil
                }
                value = value << 4 | nibble
            }
            i += digits
            return value
        }

        /// An object key: a bare identifier or a quoted string.
        private mutating func readKey() -> String? {
            skipSpace()
            guard let c = peek() else { return nil }
            if isQuote(c) { return readString() }
            let start = i
            while let c = peek(), isIdentifier(c) { i += 1 }
            guard i > start else { return nil }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        /// A string value, or nil for any other value (skipped).
        /// `ok` is false only on malformed input.
        private mutating func readStringOrSkip(depth: Int) -> (ok: Bool, value: String?) {
            skipSpace()
            if isQuote(peek()) {
                guard let s = readString() else { return (false, nil) }
                return (true, s)
            }
            return (skipValue(depth: depth), nil)
        }

        /// Skip one value of any shape. False on malformed input or EOF.
        private mutating func skipValue(depth: Int) -> Bool {
            guard depth < Self.maxDepth else { return false }
            skipSpace()
            guard let c = peek() else { return false }
            switch c {
            case 0x22, 0x27:
                return readString() != nil
            case 0x7B: // {
                i += 1
                if take(0x7D) { return true }
                while true {
                    guard readKey() != nil, take(0x3A),
                          skipValue(depth: depth + 1) else { return false }
                    if take(0x2C) { continue }
                    return take(0x7D)
                }
            case 0x5B: // [
                i += 1
                if take(0x5D) { return true }
                while true {
                    guard skipValue(depth: depth + 1) else { return false }
                    if take(0x2C) { continue }
                    return take(0x5D)
                }
            case 0x21: // !0 / !1
                i += 1
                return skipValue(depth: depth + 1)
            case 0x2B, 0x2D, 0x2E, 0x30...0x39: // a number, exponent included
                while let c = peek(),
                      (c >= 0x30 && c <= 0x39) || c == 0x2E || c == 0x65 || c == 0x45
                        || c == 0x2B || c == 0x2D {
                    i += 1
                }
                return true
            default:
                // An identifier — null, true, a name — with `void 0`'s
                // trailing operand and a call's argument list allowed.
                guard isIdentifier(c) else { return false }
                while let c = peek(), isIdentifier(c) || c == 0x2E { i += 1 }
                skipSpace()
                if let n = peek(), n >= 0x30 && n <= 0x39 {
                    return skipValue(depth: depth + 1)
                }
                if take(0x28) {
                    if take(0x29) { return true }
                    while true {
                        guard skipValue(depth: depth + 1) else { return false }
                        if take(0x2C) { continue }
                        return take(0x29)
                    }
                }
                return true
            }
        }

        /// From `models:` to the `}` that closes the enclosing object.
        mutating func parseCatalog() -> BinaryCatalog? {
            var entries: [BinaryCatalog.Entry] = []
            var aliasDefault: [String: String] = [:]
            var aliasPerProvider: [String: [String: String]] = [:]
            var latest: [String: String] = [:]
            var best: String? = nil
            var sawLatest = false
            while true {
                skipSpace()
                if peek() == 0x7D { i += 1; break }
                guard let key = readKey(), take(0x3A) else { return nil }
                switch key {
                case "models":
                    guard let list = parseModels() else { return nil }
                    entries = list
                case "aliases":
                    guard parseAliases(into: &aliasDefault, &aliasPerProvider) else { return nil }
                case "latest_per_family":
                    guard let map = parseStringMap(depth: 1) else { return nil }
                    latest = map
                    sawLatest = true
                case "best":
                    let read = readStringOrSkip(depth: 1)
                    guard read.ok else { return nil }
                    best = read.value
                default:
                    guard skipValue(depth: 1) else { return nil }
                }
                if take(0x2C) { continue }
                skipSpace()
                guard peek() == 0x7D else { return nil }
            }
            // The anchor must be INSIDE what was parsed — a slice that
            // closed before reaching it belongs to some other object.
            guard sawLatest, !entries.isEmpty, !aliasDefault.isEmpty else { return nil }
            return BinaryCatalog(entries: entries, aliasDefault: aliasDefault,
                                 aliasPerProvider: aliasPerProvider,
                                 latestPerFamily: latest, best: best)
        }

        private mutating func parseModels() -> [BinaryCatalog.Entry]? {
            guard take(0x5B) else { return nil }
            var out: [BinaryCatalog.Entry] = []
            if take(0x5D) { return out }
            while true {
                guard let entry = parseEntry() else { return nil }
                out.append(entry)
                if take(0x2C) {
                    if take(0x5D) { return out }
                    continue
                }
                guard take(0x5D) else { return nil }
                return out
            }
        }

        /// One model entry. Missing `id` or `display_name` fails the
        /// WHOLE catalog: a dropped entry would be a silent hole in the
        /// catalog-id / wire-id join.
        private mutating func parseEntry() -> BinaryCatalog.Entry? {
            guard take(0x7B) else { return nil }
            var id: String? = nil
            var family: String? = nil
            var name: String? = nil
            var firstParty: String? = nil
            var capabilities: [String]? = nil
            while true {
                if take(0x7D) { break }
                guard let key = readKey(), take(0x3A) else { return nil }
                switch key {
                case "id":
                    guard let s = readString() else { return nil }
                    id = s
                case "family":
                    guard let s = readString() else { return nil }
                    family = s
                case "display_name":
                    guard let s = readString() else { return nil }
                    name = s
                case "provider_ids":
                    guard take(0x7B) else { return nil }
                    while true {
                        if take(0x7D) { break }
                        guard let provider = readKey(), take(0x3A) else { return nil }
                        let read = readStringOrSkip(depth: 3)
                        guard read.ok else { return nil }
                        if provider == "first_party", let s = read.value { firstParty = s }
                        if take(0x2C) { continue }
                        guard take(0x7D) else { return nil }
                        break
                    }
                case "capabilities":
                    // A list is read; a value of any other shape is
                    // skipped and leaves the entry's flags unknown — a
                    // field only the effort levels need must not take
                    // the NAMES down with it. A list that does not
                    // close is malformed input like any other.
                    skipSpace()
                    if peek() == 0x5B {
                        guard let list = parseStringList(depth: 2) else { return nil }
                        capabilities = list
                    } else {
                        guard skipValue(depth: 2) else { return nil }
                    }
                default:
                    guard skipValue(depth: 2) else { return nil }
                }
                if take(0x2C) { continue }
                guard take(0x7D) else { return nil }
                break
            }
            guard let id, !id.isEmpty, let name, !name.isEmpty else { return nil }
            guard let family = family ?? ClaudeModelDisplay.familyAlias(of: id),
                  !family.isEmpty else { return nil }
            return BinaryCatalog.Entry(catalogId: id, family: family,
                                       displayName: name,
                                       firstPartyId: firstParty ?? id,
                                       capabilities: capabilities)
        }

        /// `["a","b",…]` — the strings, in order. A value that is not a
        /// string is skipped, not recorded; a malformed list is nil.
        private mutating func parseStringList(depth: Int) -> [String]? {
            guard take(0x5B) else { return nil }
            var out: [String] = []
            if take(0x5D) { return out }
            while true {
                let read = readStringOrSkip(depth: depth + 1)
                guard read.ok else { return nil }
                if let s = read.value, !s.isEmpty { out.append(s) }
                if take(0x2C) { continue }
                guard take(0x5D) else { return nil }
                return out
            }
        }

        private mutating func parseAliases(into defaults: inout [String: String],
                                           _ perProvider: inout [String: [String: String]]) -> Bool {
            guard take(0x7B) else { return false }
            while true {
                if take(0x7D) { return true }
                guard let alias = readKey(), take(0x3A), take(0x7B) else { return false }
                while true {
                    if take(0x7D) { break }
                    guard let key = readKey(), take(0x3A) else { return false }
                    switch key {
                    case "default":
                        let read = readStringOrSkip(depth: 2)
                        guard read.ok else { return false }
                        if let s = read.value, !s.isEmpty { defaults[alias] = s }
                    case "per_provider":
                        guard let map = parseStringMap(depth: 2) else { return false }
                        if !map.isEmpty { perProvider[alias] = map }
                    default:
                        guard skipValue(depth: 2) else { return false }
                    }
                    if take(0x2C) { continue }
                    guard take(0x7D) else { return false }
                    break
                }
                if take(0x2C) { continue }
                return take(0x7D)
            }
        }

        /// `{key:"value",…}` — non-string values (a `null` provider
        /// column) are skipped, not recorded.
        private mutating func parseStringMap(depth: Int) -> [String: String]? {
            guard take(0x7B) else { return nil }
            var out: [String: String] = [:]
            while true {
                if take(0x7D) { return out }
                guard let key = readKey(), take(0x3A) else { return nil }
                let read = readStringOrSkip(depth: depth + 1)
                guard read.ok else { return nil }
                if let s = read.value, !s.isEmpty { out[key] = s }
                if take(0x2C) { continue }
                guard take(0x7D) else { return nil }
                return out
            }
        }
    }

    /// The name shown for a model id: the catalog's own `display_name`
    /// when the binary names the id (wire or catalog spelling, variant
    /// stripped), else the derived name. A NEW family therefore ships
    /// with its name in the same table, instead of rendering as a raw
    /// id until someone extends a casing table.
    nonisolated static func displayName(forId raw: String,
                                        catalog: BinaryCatalog?) -> String {
        if let entry = catalog?.entry(forId: raw) { return entry.displayName }
        return ClaudeModelDisplay.name(for: raw)
    }

    nonisolated static func displayName(forId raw: String) -> String {
        displayName(forId: raw, catalog: installedCatalog())
    }

    // MARK: Effort levels (per model)

    /// The effort levels claude takes for the model `id` (a wire or a
    /// catalog id, variant allowed), out of `offered` — the levels the
    /// installed `--help` lists, fast → deep.
    ///
    /// Effort support is PER MODEL, and claude says so in the same
    /// table the names come from: each entry lists `capabilities`, and
    /// claude's own resolver reads three of them. Without `effort` the
    /// model runs with no effort at all — claude omits the parameter
    /// (Haiku 4.5, Sonnet 4.5 and older). Without `xhigh_effort` or
    /// `max_effort`, that level is quietly run as `high` (Opus 4.6 and
    /// Sonnet 4.6 take `max` but not `xhigh`). Neither case fails: the
    /// turn runs, at a level other than the one the chip names, which
    /// is why the picker has to know.
    ///
    /// Nothing is narrowed on a guess, so each of these answers
    /// `offered` unchanged: a model the catalog does not name (claude
    /// treats an unknown first-party model as taking every level), an
    /// entry whose flags could not be read, a binary with no catalog, a
    /// Default nothing has resolved yet (`id` nil), and a flag the
    /// table does not use for ANY model — a table that no longer
    /// spells `effort` has renamed it, and reading that as "no model
    /// takes effort" would take the chip off every model at once.
    /// Levels other than `xhigh` and `max` pass through for a model
    /// that takes effort: claude's gate names only those two.
    ///
    /// Known gap, the safe way round: claude's resolver still takes
    /// effort for two entries whose `capabilities` omit it (Opus 4.5
    /// takes low, medium and high; Mythos 5 all five). Both get no chip
    /// here, and the turn runs at claude's default.
    nonisolated static func effortLevels(forId id: String?,
                                         catalog: BinaryCatalog?,
                                         offered: [String]) -> [String] {
        guard let id, !id.isEmpty, let catalog,
              let entry = catalog.entry(forId: id),
              let listed = entry.capabilities,
              catalog.listsCapability("effort")
        else { return offered }
        let flags = Set(listed.map { $0.lowercased() })
        guard flags.contains("effort") else { return [] }
        func takes(_ flag: String) -> Bool {
            flags.contains(flag) || !catalog.listsCapability(flag)
        }
        return offered.filter { level in
            switch level {
            case "xhigh": return takes("xhigh_effort")
            case "max": return takes("max_effort")
            default: return true
            }
        }
    }

    /// Whether a model takes claude's fast mode, decided the way claude
    /// decides it: the `fast_mode` capability of the catalog entry for a
    /// model the table names, else claude's own fallback for one it does
    /// not — an Opus 4.8 or Opus 5 id. nil when nothing resolves the
    /// model (a Default never observed), which the switch reads as
    /// allowed; claude then reports on it itself.
    ///
    /// A table that lists `fast_mode` for no model has renamed the flag,
    /// so its lists say nothing either way and the fallback answers —
    /// the vocabulary rule `effortLevels` follows.
    nonisolated static func fastModeSupported(forId id: String?,
                                              catalog: BinaryCatalog?) -> Bool? {
        guard let id, !id.isEmpty else { return nil }
        if let catalog, catalog.listsCapability("fast_mode"),
           let entry = catalog.entry(forId: id),
           let listed = entry.capabilities {
            return listed.contains { $0.lowercased() == "fast_mode" }
        }
        let bare = ClaudeModelDisplay.splitVariant(id).id.lowercased()
        return bare.contains("opus-4-8") || bare.contains("opus-5")
    }

    // MARK: The child's environment

    /// What the claude SipAI spawns will read out of its environment,
    /// as far as a model name is concerned.
    ///
    /// Two sources, and the login shell is neither: the child's
    /// environment is `AgentRunner.buildEnvironment` — this process's,
    /// plus PATH and the proxy names — and claude then applies the
    /// `env` block of its own settings files on top of it
    /// (`Object.assign(process.env, …)`, user settings first, so a
    /// later file wins and every file wins over the inherited value).
    /// A `.zshrc` export never reaches the child, so reading it here
    /// would name a model the child does not run.
    struct ChildEnvironmentFacts: Equatable {
        /// The provider column an alias resolves through — "bedrock",
        /// "vertex", "foundry" — or nil for first-party.
        let provider: String?
        /// `ANTHROPIC_DEFAULT_<FAMILY>_MODEL`, keyed by lowercase family.
        let overridesByFamily: [String: String]
        /// `ANTHROPIC_MODEL`, trimmed, or nil.
        let configuredModel: String?

        func override(forFamily family: String) -> String? {
            overridesByFamily[family.lowercased()]
        }

        /// The variable that carries a family's override — spelled
        /// once, for the hover that names it.
        static func overrideVariable(forFamily family: String) -> String {
            "ANTHROPIC_DEFAULT_\(family.uppercased())_MODEL"
        }
    }

    /// Claude's own switches for a third-party provider, spelled as
    /// claude spells them, in the order they are consulted.
    nonisolated static let claudeProviderSwitches: [(name: String, provider: String)] = [
        ("CLAUDE_CODE_USE_BEDROCK", "bedrock"),
        ("CLAUDE_CODE_USE_VERTEX", "vertex"),
        ("CLAUDE_CODE_USE_FOUNDRY", "foundry"),
    ]

    /// Non-empty and not one of the spellings of "off".
    nonisolated static func environmentFlagIsSet(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return false }
        return !["0", "false", "no", "off"].contains(value.lowercased())
    }

    /// The pure rule: `environment` is the process's, `settingsEnvironment`
    /// the merged `env` blocks, and the latter wins — as it does inside
    /// claude.
    nonisolated static func childEnvironmentFacts(
        environment: [String: String],
        settingsEnvironment: [String: String]
    ) -> ChildEnvironmentFacts {
        var merged = environment
        for (name, value) in settingsEnvironment { merged[name] = value }
        let provider = claudeProviderSwitches.first {
            environmentFlagIsSet(merged[$0.name])
        }?.provider
        var overrides: [String: String] = [:]
        let prefix = "ANTHROPIC_DEFAULT_"
        let suffix = "_MODEL"
        for (name, value) in merged
        where name.hasPrefix(prefix) && name.hasSuffix(suffix)
            && name.count > prefix.count + suffix.count {
            let family = name.dropFirst(prefix.count).dropLast(suffix.count).lowercased()
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { overrides[family] = trimmed }
        }
        let configured = merged["ANTHROPIC_MODEL"]?
            .trimmingCharacters(in: .whitespaces)
        return ChildEnvironmentFacts(
            provider: provider,
            overridesByFamily: overrides,
            configuredModel: (configured?.isEmpty == false) ? configured : nil)
    }

    /// The user-level settings files claude reads, in the order it
    /// APPLIES their `env` blocks (a later file wins). Project-level
    /// `.claude/settings*.json` blocks are not read: a name is asked
    /// for with no folder in hand, and a per-project provider switch is
    /// rare enough to state rather than plumb a cwd through every call.
    ///
    /// Assignable so a harness can point it at a throwaway directory;
    /// nothing in the app writes it.
    nonisolated(unsafe) static var userSettingsFiles: [URL] = {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude", isDirectory: true)
        return [dir.appendingPathComponent("settings.json"),
                dir.appendingPathComponent("settings.local.json")]
    }()

    private struct SettingsEnvironmentRead {
        let key: String
        let environment: [String: String]
    }
    nonisolated private static let settingsLock = NSLock()
    nonisolated(unsafe) private static var settingsCache: SettingsEnvironmentRead? = nil

    /// The merged `env` blocks of `files`, later files winning. Cached
    /// by the files' (size, mtime): a name is asked for per row per
    /// body pass, and a pass may pay a stat per file, never a read.
    nonisolated static func settingsEnvironment(files: [URL]) -> [String: String] {
        let key = files.map { file -> String in
            let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs?[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? -1
            return "\(file.path)|\(size)/\(mtime)"
        }.joined(separator: "‖")
        settingsLock.lock()
        if let cached = settingsCache, cached.key == key {
            settingsLock.unlock()
            return cached.environment
        }
        settingsLock.unlock()
        var env: [String: String] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  let block = obj["env"] as? [String: Any]
            else { continue }
            for (name, value) in block {
                if let s = value as? String {
                    env[name] = s
                } else if let n = value as? NSNumber {
                    // A JSON `true` is an NSNumber too; keep its word.
                    env[name] = CFGetTypeID(n) == CFBooleanGetTypeID()
                        ? (n.boolValue ? "true" : "false") : n.stringValue
                }
            }
        }
        settingsLock.lock()
        settingsCache = SettingsEnvironmentRead(key: key, environment: env)
        settingsLock.unlock()
        return env
    }

    /// The facts for THIS process's children.
    nonisolated static func childEnvironmentFacts() -> ChildEnvironmentFacts {
        childEnvironmentFacts(
            environment: ProcessInfo.processInfo.environment,
            settingsEnvironment: settingsEnvironment(files: userSettingsFiles))
    }

    // MARK: Resolving an alias

    enum AliasSource: Equatable {
        /// `ANTHROPIC_DEFAULT_<FAMILY>_MODEL`, verbatim, as claude takes it.
        case environment
        /// The catalog baked into the installed binary.
        case binary
        /// What a turn under this alias was last observed to run.
        case observed
    }

    struct Resolution: Equatable {
        /// A WIRE id — what the transcripts and the window table spell.
        let id: String
        let source: AliasSource
    }

    /// What `alias` resolves to on this machine, and where the answer
    /// came from. Pure: every input is a parameter, so the rule runs
    /// headless. Order is claude's own — the environment override
    /// before the catalog — and the observed map is the fallback for a
    /// binary without the table or an alias it does not name. Nil when
    /// nothing knows.
    nonisolated static func resolve(alias rawAlias: String,
                                    catalog: BinaryCatalog?,
                                    provider: String?,
                                    environmentOverride: String?,
                                    observed: String?) -> Resolution? {
        let alias = ClaudeModelDisplay.splitVariant(rawAlias).id.lowercased()
        guard !alias.isEmpty else { return nil }
        if let override = environmentOverride?.trimmingCharacters(in: .whitespaces),
           !override.isEmpty {
            return Resolution(id: override, source: .environment)
        }
        if let catalog {
            let column = provider.flatMap { catalog.aliasPerProvider[alias]?[$0] }
            if let catalogId = column ?? catalog.aliasDefault[alias] {
                let wire = catalog.entry(forId: catalogId)?.firstPartyId ?? catalogId
                return Resolution(id: wire, source: .binary)
            }
        }
        if let observed, !observed.isEmpty {
            return Resolution(id: observed, source: .observed)
        }
        return nil
    }

    /// `resolve` over the installed binary and this process's
    /// environment, with `observed` answering the map for an alias.
    ///
    /// The empty alias is claude's Default and is not in the catalog's
    /// alias table: claude's `best` is one FAMILY per account (fable
    /// where the account has it, opus otherwise), then that family's
    /// current resolution. The observed `""` id records the family, so
    /// its family is resolved like any alias and the observed id is
    /// what answers when the table cannot — which keeps the Default
    /// row from naming the version a Default send last happened to
    /// run rather than the one it will run next.
    nonisolated static func resolvedModel(alias raw: String,
                                          observed: (String) -> String?) -> Resolution? {
        let facts = childEnvironmentFacts()
        let catalog = installedCatalog()
        let alias = ClaudeModelDisplay.splitVariant(raw).id.lowercased()
        if alias.isEmpty {
            guard let recorded = observed(""), !recorded.isEmpty else { return nil }
            if let family = ClaudeModelDisplay.familyAlias(of: recorded),
               let resolved = resolve(alias: family, catalog: catalog,
                                      provider: facts.provider,
                                      environmentOverride: facts.override(forFamily: family),
                                      observed: nil) {
                return resolved
            }
            return Resolution(id: recorded, source: .observed)
        }
        return resolve(alias: alias, catalog: catalog,
                       provider: facts.provider,
                       environmentOverride: facts.override(forFamily: alias),
                       observed: observed(alias))
    }

    /// The family word of a model id: the casing table's when it knows
    /// the word, else the catalog's `family` for an id the binary
    /// names. A family the table has never heard of is still a family
    /// to the binary that ships it.
    nonisolated static func family(ofId id: String, catalog: BinaryCatalog?) -> String? {
        ClaudeModelDisplay.familyAlias(of: id)
            ?? catalog?.entry(forId: id)?.family.lowercased()
    }

    /// The same, for the installed binary's cached catalog — consulted
    /// only for an id the table cannot place, so a known family costs
    /// no lookup at all.
    nonisolated static func family(ofId id: String) -> String? {
        if let word = ClaudeModelDisplay.familyAlias(of: id) { return word }
        return installedCatalog()?.entry(forId: id)?.family.lowercased()
    }

    /// The family an alias names: the alias itself when it is a family
    /// word, else the family of the model the catalog resolves it to.
    nonisolated static func family(ofAlias alias: String, catalog: BinaryCatalog?) -> String? {
        if let word = ClaudeModelDisplay.parts(of: alias).family { return word }
        let base = ClaudeModelDisplay.splitVariant(alias).id.lowercased()
        guard let catalogId = catalog?.aliasDefault[base] else { return nil }
        return catalog?.entry(forId: catalogId)?.family.lowercased()
    }

    /// The "Other models" candidates: per alias family, the newest
    /// observed id BELOW what the alias resolves to now. Pure — the
    /// resolution arrives as a closure and the catalog as a value — so
    /// the anchor rule runs headless. The "still named by the installed
    /// claude" filter is applied by the caller, off the MainActor.
    nonisolated static func otherModelCandidates(
        aliases: [String],
        observed: [String],
        catalog: BinaryCatalog?,
        resolvedId: (String) -> String?
    ) -> [(family: String, id: String)] {
        var candidates: [(family: String, id: String)] = []
        for alias in aliases {
            guard let family = family(ofAlias: alias, catalog: catalog),
                  let current = resolvedId(alias)
            else { continue }
            let older = observed.filter {
                self.family(ofId: $0, catalog: catalog) == family
                    && ClaudeModelDisplay.isNewer(current, than: $0)
            }
            guard let best = older.max(by: { ClaudeModelDisplay.isNewer($1, than: $0) })
            else { continue }
            candidates.append((family, best))
        }
        return candidates
    }
}

/// One row in the permission-mode picker.
struct AgentPermissionMode: Identifiable, Hashable {
    /// The exact string `--permission-mode` accepts (e.g. "acceptEdits").
    let name: String
    var id: String { name }

    /// Short chip label, matching Claude Code's own mode table
    /// (default → "Manual", bypassPermissions → "Bypass Permissions", …).
    var title: String {
        switch name {
        case "bypassPermissions":
            return String(localized: "Bypass",
                          comment: "Permission-mode chip label for bypassPermissions")
        case "acceptEdits":
            return String(localized: "Accept Edits",
                          comment: "Permission-mode chip label for acceptEdits")
        case "dontAsk":
            return String(localized: "Don't Ask",
                          comment: "Permission-mode chip label for dontAsk")
        case "auto":
            return String(localized: "Auto",
                          comment: "Permission-mode chip label for auto")
        case "plan":
            return String(localized: "Plan",
                          comment: "Permission-mode chip label for plan")
        case "manual", "default":
            return String(localized: "Manual",
                          comment: "Permission-mode chip label for manual/default")
        default:
            return name
        }
    }

    /// One-line behavior hint shown in the picker menu. A mode with no
    /// hint still renders.
    var hint: String? {
        switch name {
        case "bypassPermissions":
            return String(localized: "Auto-approves everything",
                          comment: "Permission-mode hint: bypassPermissions")
        case "auto":
            return String(localized: "Classifies each call, prompts when unsure",
                          comment: "Permission-mode hint: auto")
        case "acceptEdits":
            return String(localized: "Auto-approves edits, prompts on bash",
                          comment: "Permission-mode hint: acceptEdits")
        case "dontAsk":
            return String(localized: "Never prompts; denies what isn't pre-allowed",
                          comment: "Permission-mode hint: dontAsk")
        case "manual", "default":
            return String(localized: "Prompts on every tool",
                          comment: "Permission-mode hint: manual/default")
        case "plan":
            return String(localized: "Planning only, no tools run",
                          comment: "Permission-mode hint: plan")
        default:
            return nil
        }
    }

    /// Most-permissive-first display order. Unknown modes sort last, in
    /// scraped order.
    static let displayOrder: [String] = [
        "bypassPermissions", "auto", "acceptEdits", "dontAsk", "manual",
        "default", "plan",
    ]
}

/// One row of the composer's "Other models" section: a full model id
/// this account has run that is no longer what its family's alias
/// resolves to, and that the installed claude still names. Sent
/// verbatim (`--model claude-fable-5`) — claude's help says a full
/// name is accepted wherever an alias is.
struct ClaudeOtherModel: Identifiable, Equatable {
    let fullId: String
    /// The family alias it sits under ("fable"), for ordering beneath
    /// that alias's row.
    let family: String
    /// The binary's own `display_name` for the id, else the derived
    /// name — decided once here so the composer and the scheduled-task
    /// panel cannot title one row two ways.
    let displayName: String
    var id: String { fullId }
}

/// Cached catalogs scraped from `claude --help`, with hardcoded
/// fallbacks. The scrape runs once per BINARY on a background thread —
/// keyed on the executable's fingerprint, so an update that lands under
/// a running app is re-read at the next composer appearance; until it
/// lands (or if it fails) callers see the fallbacks.
/// The environment the CLI scrapes run under — `claude --help` and
/// `codex features list`, the two reads every capability verdict here
/// (modes, efforts, aliases, and whether the Chat only row is offered at
/// all) is drawn from.
///
/// Either CLI may be an npm install: a `#!/usr/bin/env node` script. A
/// GUI app's own PATH is launchd's `/usr/bin:/bin:/usr/sbin:/sbin`, with
/// no `node` on it, so a scrape spawned in that environment exits 127
/// ("env: node: No such file or directory") before printing a line —
/// and every verdict drawn from it fails CLOSED, silently: the Chat only
/// row is simply absent. A scrape therefore runs in the environment an
/// agent child gets — the login-shell capture awaited, then
/// `AgentRunner.buildEnvironment()`, the pair `AgentCLIProbe.run` uses —
/// never in a second spelling of it.
///
/// A provider rather than a direct call because the headless harnesses
/// compile this file without `AgentRunner` or `ShellEnvironment`. The
/// app installs it in `SipAIApp.init`, before any view exists to trigger
/// a scrape; left nil (the harnesses), a scrape inherits this process's
/// environment — a shell's, whose PATH already finds `node`.
@MainActor
enum CLIScrapeEnvironment {
    static var provider: (@Sendable () async -> [String: String])? = nil
}

@MainActor
final class ClaudeCapabilities: ObservableObject {
    static let shared = ClaudeCapabilities()

    /// Fallback for when claude isn't installed or the help shape
    /// changed. Ordered for display.
    private static let modeFallback = ["bypassPermissions", "acceptEdits", "plan", "manual"]
    // Deliberately NOT offering "ultracode". Claude defines it as
    // "xhigh + dynamic workflow orchestration, this session only", and
    // under `-p` only the xhigh half is provable: requested through
    // the flag-settings layer (`{"ultracode":true}`) a headless run
    // records `effort: "xhigh"` and nothing confirms the orchestration
    // opt-in — no reminder, no field on init or result. `/effort
    // ultracode` is accepted headlessly and claims to set it for the
    // session; whether later resumed turns then orchestrate is
    // unmeasured. Offering a row would label xhigh with a promise
    // nobody has measured. `--help` does not list it either.
    private static let effortFallback = ["low", "medium", "high", "xhigh", "max"]
    private static let modelAliasFallback = ["fable", "opus", "sonnet", "haiku"]

    @Published private(set) var permissionModes: [AgentPermissionMode]
    @Published private(set) var effortLevels: [String]
    @Published private(set) var modelAliases: [String]

    /// What the installed `--help` says about the two flags Chat only
    /// needs (`ChatOnlyAvailability.ClaudeHelp`). nil until a scrape
    /// lands — and nil is "not offered", never a guess: the row waits
    /// for the binary to be read, the way the mode list does.
    @Published private(set) var chatOnlyHelp: ChatOnlyAvailability.ClaudeHelp? = nil

    /// Whether the installed claude takes `--thinking-display`
    /// (`ChatOnlyAvailability.acceptsThinkingDisplay`). nil until probed,
    /// and nil or false keeps the flag off a Chat only turn — which then
    /// runs exactly as it did, its line naming lookups only.
    @Published private(set) var acceptsThinkingSummaries: Bool? = nil

    /// The composer's "Other models" section: per family, the previous
    /// version this Mac has actually run that the installed claude
    /// still names. Computed by `ClaudeModelCatalog.refreshOtherModels`
    /// after each harvest; empty until then, and empty on a machine
    /// that has only ever run the newest of every family.
    @Published private(set) var otherModels: [ClaudeOtherModel] = []

    func setOtherModels(_ models: [ClaudeOtherModel]) {
        if otherModels != models { otherModels = models }
    }

    /// The levels to offer for the model a send runs as — `id` from
    /// `ConfigManager.resolvedClaudeModelId`, nil when nothing resolves
    /// it. `ClaudeModelCatalog.effortLevels` over the installed binary's
    /// CACHED catalog and the levels `--help` lists: two stats per body
    /// pass, and a cache still cold answers the whole list until this
    /// type's own pass lands and publishes `catalogKey`, which re-renders
    /// both pickers onto the model's own levels.
    func effortLevels(forModelId id: String?) -> [String] {
        ClaudeModelCatalog.effortLevels(forId: id,
                                        catalog: ClaudeModelCatalog.installedCatalog(),
                                        offered: effortLevels)
    }

    /// Whether the model a send runs as takes fast mode —
    /// `ClaudeModelCatalog.fastModeSupported` over the installed
    /// binary's cached catalog; `id` as for `effortLevels(forModelId:)`.
    /// A cache still cold answers by claude's own fallback rule.
    func fastModeSupported(forModelId id: String?) -> Bool? {
        ClaudeModelCatalog.fastModeSupported(forId: id,
                                             catalog: ClaudeModelCatalog.installedCatalog())
    }

    /// Why usage credits are unavailable, as claude itself last cached
    /// it (`ClaudeFastMode.creditsBlock`); nil when they are, or when
    /// nothing is cached. Refreshed by `refreshUsageCreditsBlock`.
    @Published private(set) var usageCreditsBlock: String? = nil
    private var creditsFingerprint: String? = nil

    /// Re-read `~/.claude.json` for the credits verdict when it changed
    /// since the last read — two stats otherwise. Called from the
    /// composer's appearance and when the model menu opens, never from
    /// a body pass; the read itself runs off the MainActor.
    func refreshUsageCreditsBlock() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = "\((attrs?[.size] as? NSNumber)?.int64Value ?? -1)/"
            + "\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)"
        guard stamp != creditsFingerprint else { return }
        creditsFingerprint = stamp
        Task.detached(priority: .utility) {
            let block = ClaudeFastMode.creditsBlock(claudeJSON: try? Data(contentsOf: url))
            await MainActor.run {
                if block != self.usageCreditsBlock { self.usageCreditsBlock = block }
            }
        }
    }

    /// The binary whose baked catalog the model names are read from,
    /// published once the pass that read it lands. Nothing draws the
    /// value; observers re-render on it, which is what moves every row
    /// from the observed fallback onto the binary's names without a
    /// scan on the main thread.
    @Published private(set) var catalogKey: String? = nil

    /// `ClaudeModelCatalog.binaryKey` of the binary the lists describe.
    /// A key, not a Bool: the composer appearance that follows an
    /// update compares two stats and re-scrapes only when the binary
    /// moved, and a missing binary keys to nothing and is looked for
    /// again next time.
    private var scrapedKey: String? = nil

    /// The config the "Other models" recompute writes through, set once
    /// at launch. Weak, like `AgentManager`'s.
    private weak var config: ConfigManager? = nil

    private init() {
        permissionModes = Self.ordered(Self.modeFallback).map(AgentPermissionMode.init)
        effortLevels = Self.effortFallback
        modelAliases = Self.modelAliasFallback
    }

    func configure(config: ConfigManager) {
        self.config = config
    }

    /// Scrape the installed binary unless the lists already describe
    /// it. Safe to call from every composer appearance: two stats when
    /// nothing moved.
    ///
    /// The same detached pass reads the binary's baked catalog
    /// (`ClaudeModelCatalog.binaryCatalog`), which leaves the table
    /// cached for every name lookup after it, appends any alias the
    /// catalog names that `--help` only listed by example, and
    /// recomputes "Other models" against the new resolution.
    func ensureLoaded() {
        guard let binary = AgentManager.binaryPath(for: "claude_code"),
              let key = ClaudeModelCatalog.binaryKey(at: binary),
              key != scrapedKey else { return }
        scrapedKey = key
        let makeEnvironment = CLIScrapeEnvironment.provider
        Task.detached(priority: .utility) {
            // The binary's two tables FIRST, before the spawns. A body
            // pass that asks for a name or a context window before they
            // are cached scans the executable on the calling thread —
            // `cachedBinaryCatalog` refuses to, the window table does not
            // — and the two spawns below take a second or two each.
            let catalog = ClaudeModelCatalog.binaryCatalog(at: binary)
            _ = ClaudeModelCatalog.windowTable(at: binary)
            let environment = await makeEnvironment?()
            let help = Self.helpText(binary: binary, environment: environment)
            let modes = help.isEmpty ? [] : Self.scrapePermissionModes(help)
            let efforts = help.isEmpty ? [] : Self.scrapeEffortLevels(help)
            let scraped = help.isEmpty ? [] : Self.scrapeModelAliases(help)
            let chatOnly = help.isEmpty ? nil
                : ChatOnlyAvailability.claudeHelp(fromHelpText: help)
            let thinkingDisplay = Self.probeThinkingDisplay(binary: binary,
                                                            environment: environment)
            await MainActor.run {
                // A newer binary's pass is on its way: this one
                // describes a file that is gone, and must not land last.
                guard self.scrapedKey == key else { return }
                if thinkingDisplay != self.acceptsThinkingSummaries {
                    self.acceptsThinkingSummaries = thinkingDisplay
                }
                // A help read that produced nothing is not a verdict
                // about this binary. Forget the key so the next composer
                // appearance asks again (the catalog read below is cached
                // by the same key, so a retry costs one spawn), rather
                // than leaving the chips on their fallbacks — and the
                // Chat only row hidden — for the rest of the launch.
                if help.isEmpty { self.scrapedKey = nil }
                if chatOnly != self.chatOnlyHelp { self.chatOnlyHelp = chatOnly }
                if !modes.isEmpty {
                    let ordered = Self.ordered(modes).map(AgentPermissionMode.init)
                    if ordered != self.permissionModes { self.permissionModes = ordered }
                }
                if !efforts.isEmpty, efforts != self.effortLevels {
                    self.effortLevels = efforts
                }
                // Merge rather than replace: help lists aliases by
                // example, so known ones must not disappear — and the
                // catalog's alias table is what claude actually
                // resolves, so an alias it names that the help did not
                // is appended rather than waiting on a fallback list.
                var merged = scraped
                for known in Self.modelAliasFallback where !merged.contains(known) {
                    merged.append(known)
                }
                if let catalog {
                    for alias in catalog.aliasDefault.keys.sorted()
                    where !merged.contains(alias) {
                        merged.append(alias)
                    }
                }
                if !merged.isEmpty, merged != self.modelAliases {
                    self.modelAliases = merged
                }
                if self.catalogKey != key { self.catalogKey = key }
                if let config = self.config {
                    ClaudeModelCatalog.refreshOtherModels(config: config)
                }
            }
        }
    }

    /// Re-run the scrape because the BINARY moved, whoever moved it.
    ///
    /// The lists are a cache of what one binary said, correct only
    /// while that binary is the one on disk. An update replaces it with
    /// one that may name different permission modes, effort levels and
    /// model aliases — and resolve every alias to a different model —
    /// and until this re-runs, every composer chip describes the
    /// binary that was just replaced, with nothing on screen admitting
    /// it. The update monitor calls this on any fingerprint move, its
    /// own button's and a terminal's alike.
    func reloadAfterBinaryChange() {
        scrapedKey = nil
        ensureLoaded()
    }

    // MARK: - Scraping (`--help` parsers)

    /// `environment` is `CLIScrapeEnvironment`'s — nil inherits this
    /// process's (the harnesses).
    nonisolated private static func helpText(binary: String,
                                             environment: [String: String]?) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["--help"]
        if let environment { p.environment = environment }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do {
            try p.run()
        } catch {
            return ""
        }
        // Read first, then wait — `claude --help` output fits the pipe
        // buffer, but reading after exit is the deadlock-safe order.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // A launcher that could not start — `env: node: No such file or
        // directory` from an npm install with no `node` on its PATH —
        // writes its complaint into the same pipe. Parsed as help, that
        // reads as a definite "this claude has no --tools", which is a
        // verdict about the binary; it is a failure, and says nothing.
        guard p.terminationStatus == 0 else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The `--thinking-display` verdict (see
    /// `ChatOnlyAvailability.thinkingDisplayProbeArguments`), or nil when
    /// the probe could not run at all — a launcher that failed to start
    /// says nothing about the flag either way. The refusal the probe
    /// looks for exits non-zero, so unlike `helpText` the status is not
    /// the test; the output is.
    nonisolated private static func probeThinkingDisplay(
        binary: String, environment: [String: String]?) -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ChatOnlyAvailability.thinkingDisplayProbeArguments
        if let environment { p.environment = environment }
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        if ChatOnlyAvailability.acceptsThinkingDisplay(probeOutput: text) { return true }
        // `--version` printed, or the option was refused as unknown: a
        // claude that runs and does not know the flag.
        let ran = p.terminationStatus == 0 || text.contains("unknown option")
        return ran ? false : nil
    }

    /// The description body of `flag` in the help text — from the flag's
    /// `<placeholder>` to the next flag, so wrapped lines are captured
    /// whole.
    nonisolated private static func flagBlock(_ text: String, flag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: flag)
        let pattern = "\(escaped)\\s+<[^>]+>(.+?)(?=\\n\\s*--|\\z)"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators]
        ), let match = regex.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)
        ), match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    nonisolated private static func scrapePermissionModes(_ help: String) -> [String] {
        guard let block = flagBlock(help, flag: "--permission-mode"),
              let listMatch = firstCapture(#"\(choices:\s*([^)]+)\)"#, in: block)
        else { return [] }
        var names: [String] = []
        for raw in listMatch.components(separatedBy: ",") {
            let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'\n\t"))
            if !name.isEmpty && !names.contains(name) { names.append(name) }
        }
        return names
    }

    nonisolated private static func scrapeEffortLevels(_ help: String) -> [String] {
        guard let block = flagBlock(help, flag: "--effort"),
              let listMatch = firstCapture(#"\(([^)]+)\)"#, in: block)
        else { return [] }
        var levels: [String] = []
        for raw in listMatch.components(separatedBy: ",") {
            let level = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !level.isEmpty && !levels.contains(level) { levels.append(level) }
        }
        return levels
    }

    nonisolated private static func scrapeModelAliases(_ help: String) -> [String] {
        guard let block = flagBlock(help, flag: "--model") else { return [] }
        var aliases: [String] = []
        guard let regex = try? NSRegularExpression(pattern: #"'([a-zA-Z0-9_\-\[\]]+)'"#)
        else { return [] }
        let range = NSRange(block.startIndex..., in: block)
        for match in regex.matches(in: block, range: range) {
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: block) else { continue }
            let quoted = String(block[r])
            if quoted.contains("claude-") { continue }  // full IDs stay typed-only
            if !quoted.isEmpty && !aliases.contains(quoted) { aliases.append(quoted) }
        }
        return aliases
    }

    nonisolated private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators]
        ), let match = regex.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)
        ), match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// Apply `AgentPermissionMode.displayOrder`; unknown names keep
    /// their scraped relative order after the known ones.
    nonisolated private static func ordered(_ names: [String]) -> [String] {
        let known = AgentPermissionMode.displayOrder.filter { names.contains($0) }
        let unknown = names.filter { !AgentPermissionMode.displayOrder.contains($0) }
        return known + unknown
    }
}


/// One service tier a codex model advertises, as its catalog entry
/// spells it: the id `-c service_tier=` takes ("priority",
/// "ultrafast"), and the name and description codex's own pickers show
/// for it ("Fast" · "1.5x speed"). Tool-derived text, drawn verbatim.
struct CodexServiceTier: Hashable {
    let id: String
    let name: String
    let description: String
}

/// Codex's speed rule — which service tier a turn runs at — restated
/// from codex's own resolution so the composer can say it and a send
/// can make `codex exec` do it. Pure, so the harness drives every case.
///
/// Two resolutions, and they differ on purpose:
///
///  * codex's INTERACTIVE clients (its terminal UI and desktop app) run
///    the user's choice — the config's `service_tier` — else the
///    model's catalog `default_service_tier`. That default is how a
///    model ships Fast out of the box.
///  * `codex exec`, the command every SipAI turn runs, applies the
///    config alone: its core never reads the catalog default.
///
/// A composer send follows the interactive rule, since a session here
/// is the same conversation someone would have in codex's own window,
/// and hands exec the tier the way codex's own picker hands it to its
/// core (`override`). A scheduled run is unattended exec work: it passes
/// the task's own pick, else nothing (`scheduled`). `codex exec resume`
/// re-resolves the tier on every
/// turn — a thread does not remember the one it last ran with — so what
/// one send passes decides that turn alone. In both resolutions, a tier
/// the model does not advertise is dropped (codex says so in an `error`
/// item), `flex` always passes, `default` is an explicit standard, and
/// codex's `fast_mode` feature switched off sends no tier but flex.
///
/// "The config" is codex's MERGED config for the session's folder
/// (`Settings`, asked of codex through `CodexConfigRead`), not the
/// user's file alone: a trusted project's `.codex/config.toml` sits
/// above that file and may name its own `service_tier` and `model`.
enum CodexSpeed {
    /// Codex's own value for an explicit standard: no tier, and no
    /// catalog default either.
    static let standard = "default"
    /// The one tier codex accepts whether or not a model lists it.
    static let flex = "flex"

    /// A model's advertised tiers and its catalog default, in the
    /// catalog's order.
    struct ModelTiers: Equatable {
        var tiers: [CodexServiceTier]
        var defaultTier: String?
    }

    /// What codex's merged config says about speed in one folder.
    struct Settings: Equatable {
        /// `service_tier`, else `default` under `[notice]
        /// fast_default_opt_out` — codex's own configured tier. Raw;
        /// `normalized` reads it.
        var configured: String?
        /// Codex's `fast_mode` feature: on unless set to false.
        var featureEnabled: Bool = true
        /// The model codex runs when the command line names none.
        var model: String? = nil
    }

    /// The settings out of a `config/read` answer's `config` object —
    /// codex's merged config as JSON, where a key nothing set arrives
    /// absent or as JSON null, and reads as unset either way.
    static func settings(fromEffectiveConfig config: [String: Any]) -> Settings {
        let tier = (config["service_tier"] as? String)
            .flatMap { normalized($0) == nil ? nil : $0 }
        let optedOut = ((config["notice"] as? [String: Any])?["fast_default_opt_out"]
                        as? Bool) == true
        let feature = (config["features"] as? [String: Any])?["fast_mode"] as? Bool
        let model = (config["model"] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return Settings(configured: tier ?? (optedOut ? standard : nil),
                        featureEnabled: feature != false,
                        model: model)
    }

    /// Codex's own normalisation: `fast` is another spelling of the
    /// tier it sends as `priority`. Blank reads as absent.
    static func normalized(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces).lowercased(),
              !value.isEmpty else { return nil }
        return value == "fast" ? "priority" : value
    }

    /// The tier a composer send runs at — nil is standard. `pick` is
    /// the session's choice (nil = follow codex), `configured` the
    /// config's `service_tier`, `model` nil for a model the catalog
    /// does not know: codex then judges whatever it is handed, so the
    /// pick (else the config) passes through as exec would take it.
    static func effective(pick: String?, configured: String?,
                          model: ModelTiers?, featureEnabled: Bool) -> String? {
        guard let model else {
            return execWould(configured: normalized(pick) ?? configured,
                             model: nil, featureEnabled: featureEnabled)
        }
        let requested = normalized(pick) ?? normalized(configured)
        if requested == flex { return flex }
        guard featureEnabled else { return nil }
        if let requested {
            if requested == standard { return nil }
            return model.tiers.contains { $0.id == requested } ? requested : nil
        }
        guard let fallback = normalized(model.defaultTier),
              model.tiers.contains(where: { $0.id == fallback })
        else { return nil }
        return fallback
    }

    /// What `codex exec` sends with nothing on its command line: the
    /// config's tier, filtered the same way — and never the catalog
    /// default. An unknown model keeps the configured tier; codex
    /// judges it then.
    static func execWould(configured: String?, model: ModelTiers?,
                          featureEnabled: Bool) -> String? {
        guard let requested = normalized(configured),
              requested != standard else { return nil }
        if requested == flex { return flex }
        guard featureEnabled else { return nil }
        guard let model else { return requested }
        return model.tiers.contains { $0.id == requested } ? requested : nil
    }

    /// The tier a SCHEDULED run gets (nil is standard): its pick, which
    /// travels on the command line and which exec judges exactly as it
    /// judges a configured tier, else exec's own resolution. Never the
    /// catalog default — nothing an unattended `codex exec` does reads
    /// it — so a model that starts on Fast in codex's own window can run
    /// a task at Standard, and the task card says which.
    static func scheduled(pick: String?, configured: String?,
                          model: ModelTiers?, featureEnabled: Bool) -> String? {
        execWould(configured: normalized(pick) ?? configured, model: model,
                  featureEnabled: featureEnabled)
    }

    /// The `-c service_tier=` a composer send passes, nil for none —
    /// what codex's own picker hands its core
    /// (`service_tier_update_for_core`): the tier in force, else
    /// `default`, an explicit standard. Pinned on every such turn, so no
    /// config layer below the command line — one edited since codex was
    /// last asked about this folder, say — can run the turn at a tier
    /// other than the one the composer states. Nothing only where codex's
    /// picker sends nothing, which leaves the tier to codex's config: its
    /// `fast_mode` feature off, or a model its catalog does not list —
    /// unless the speed was PICKED, which always travels.
    static func override(pick: String?, effective: String?,
                         model: ModelTiers?, featureEnabled: Bool) -> String? {
        if let effective { return effective }
        if normalized(pick) != nil { return standard }
        guard featureEnabled, model != nil else { return nil }
        return standard
    }

    /// The speed a task scheduled from a composer keeps: the composer's
    /// pick, else — while the composer runs a faster tier codex turns on
    /// by itself — that tier, written out. A task's run never applies a
    /// model's catalog default (`scheduled`), so a model that starts on
    /// Fast would otherwise schedule a standard-speed task from a switch
    /// that read on. nil keeps the task on Default.
    static func carriedToTask(pick: String?, effective: String?) -> String? {
        if let pick = normalized(pick) { return pick }
        guard let effective, isFaster(effective) else { return nil }
        return effective
    }

    /// The tier a Fast mode switch turns on: the one codex sends as
    /// `priority` (the tier its pickers name Fast), else one it names
    /// Fast, else the model's first advertised tier. nil for a model that
    /// advertises none — the switch is then not offered.
    static func fastTier(_ model: ModelTiers?) -> CodexServiceTier? {
        guard let tiers = model?.tiers, !tiers.isEmpty else { return nil }
        return tiers.first { $0.id == "priority" }
            ?? tiers.first { $0.name.caseInsensitiveCompare("fast") == .orderedSame }
            ?? tiers.first
    }

    /// Whether a tier is a FASTER one — anything but standard and flex,
    /// which trades speed for price the other way.
    static func isFaster(_ tier: String?) -> Bool {
        guard let tier = normalized(tier) else { return false }
        return tier != standard && tier != flex
    }
}

/// Codex's merged configuration as seen from one folder, asked OF CODEX:
/// `codex app-server`'s `config/read` with a `cwd` answers with every
/// layer codex merges for a turn there — the system file, managed
/// layers, the user's `config.toml`, and a TRUSTED project's
/// `.codex/config.toml` from that folder up to its root (an untrusted
/// project's is left out, as codex leaves it out). Measured: answered
/// from disk in about a tenth of a second, with no model called. Built
/// here and sent by `run` beside `CodexConfigWrite`, over the same
/// client — so SipAI never restates codex's layering, trust included.
enum CodexConfigRead {
    /// The request line, through `JSONSerialization`: the folder is a
    /// session's path, never spliced into text. `id` is the one the
    /// sender awaits (`CodexAppServerCall.answerId`).
    nonisolated static func request(cwd: String, id: Int) -> String? {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "config/read",
            "params": ["cwd": cwd],
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The answer's merged `config`; nil for an error or no answer.
    nonisolated static func config(fromAnswer answer: [String: Any]?) -> [String: Any]? {
        (answer?["result"] as? [String: Any])?["config"] as? [String: Any]
    }

    /// The folder as a turn spawned in it sees its own working directory
    /// — every symlink resolved, `/private` included (`realpath(3)`).
    /// Codex matches a trusted project against that form: asked with a
    /// symlinked spelling it can call a project trusted that `codex
    /// exec`, running there, does not. The path unchanged when it does
    /// not resolve.
    nonisolated static func physicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// One codex model as codex itself describes it.
struct CodexModel: Identifiable, Hashable {
    let slug: String
    let displayName: String
    /// Codex's own display ranking; lower sorts first.
    let priority: Int
    /// Reasoning levels this model accepts, in codex's own order
    /// (fast → deep). Empty when unknown.
    let efforts: [String]
    /// Every `service_tiers` entry, in the catalog's order; empty when
    /// the model lists none — the composer then offers no speed choice
    /// for it.
    var serviceTiers: [CodexServiceTier] = []
    /// The entry's `default_service_tier` — the tier codex's own
    /// pickers start the model on (see `CodexSpeed`). Written only by
    /// codex builds that know the field, so an older client's cache
    /// leaves it out; the installed codex's own `model/list` answer is
    /// read ahead of it (`CodexCatalog.listedTiers`).
    var defaultServiceTier: String? = nil
    /// The EFFECTIVE context window: the catalog's `context_window`
    /// scaled by its `effective_context_window_percent`, which is the
    /// number codex itself enforces and records on the rollout
    /// (272,000 × 95 % = 258,400, equal to `model_context_window` to
    /// the token). nil when the entry states none — the composer then
    /// falls back to the window the rollout recorded, and states no
    /// percentage if there is none.
    var contextWindow: Int? = nil
    /// The usable window a session gets with NO `model_context_window`
    /// in config — the entry's `context_window` times the percentage.
    /// What `contextWindow` equals until the user raises it.
    var defaultContextWindow: Int? = nil
    /// The raw `context_window` behind it, and the percentage codex
    /// leaves usable — for prose that explains the arithmetic
    /// ("272,000, of which 95% is usable") rather than restating a
    /// constant that the catalog is free to change.
    var defaultContextWindowSetting: Int? = nil
    var usablePercent: Int? = nil
    /// The usable window at the entry's `max_context_window`, the
    /// ceiling codex clamps `model_context_window` to — again times the
    /// percentage. nil when the entry allows nothing above the default,
    /// which is how a model with "no larger window" is told apart.
    var maxContextWindow: Int? = nil
    /// The raw `max_context_window` itself: the value to WRITE into
    /// config to reach `maxContextWindow`. nil on the same models.
    var maxContextWindowSetting: Int? = nil

    var id: String { slug }
}

/// Where and when codex's own catalog was fetched, off the cache's
/// header — what a table drawn from it is stamped with, so the reader
/// can tell how current "these models have a larger window" is.
struct CodexCatalogStamp: Equatable {
    let clientVersion: String?
    let fetchedAt: Date?
}

/// Codex model + effort catalog, read from codex's OWN sources rather
/// than hardcoded — same principle as `ClaudeModelCatalog`, and for the
/// same reason: a hand-maintained table drifts the day OpenAI ships a
/// model.
///
/// Three sources, most authoritative first:
///
///   * `~/.codex/models_cache.json` — codex's server-fetched catalog.
///     It carries everything the picker needs and nothing has to be
///     inferred: `display_name` for the label, `priority` for the
///     order, `visibility` ("hide" marks codex's internal models, e.g.
///     `codex-auto-review`, which is what `codex review` runs as), and
///     `supported_reasoning_levels` — a PER-MODEL effort list, already
///     ordered fast → deep.
///   * `~/.codex/config.toml` — the user's declared `model` /
///     `model_reasoning_effort`.
///   * the newest rollouts' `turn_context` records, which carry the
///     `model` and `effort` each turn actually ran with.
///
/// The cache alone is not enough: it is fetched periodically, so a
/// model the user is ALREADY running can be missing from it. The
/// other two sources are what make a just-shipped model offerable, so
/// the lists are UNIONED, never replaced.
@MainActor
final class CodexCatalog: ObservableObject {
    static let shared = CodexCatalog()

    /// Canonical fast → deep ranking, used only to order levels that
    /// came from the config/rollouts when the cache can't be read.
    /// The cache's own ordering wins whenever it is available.
    ///
    /// Nonisolated: `rank(of:)` reads it from the detached catalog load,
    /// and an immutable array of literals is safe to share.
    nonisolated private static let effortRank = [
        "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
    ]

    /// Offered when nothing at all could be read.
    private static let effortFallback = ["low", "medium", "high", "xhigh"]

    @Published private(set) var models: [CodexModel] = []
    @Published private(set) var allEfforts: [String] = CodexCatalog.effortFallback
    /// The model `~/.codex/config.toml` declares — what a send with no
    /// explicit pick actually runs as, and what the composer's model
    /// chip shows in place of a bare "Model".
    @Published private(set) var defaultModel: String? = nil
    /// The user's own top-level `model_context_window`, raw as written
    /// (codex clamps it per model — see `parseModelsCache`). nil when
    /// the file carries none, which is codex's default and the state
    /// "Back to default" restores.
    @Published private(set) var configuredContextWindow: Int? = nil
    /// A top-level `model_auto_compact_token_limit`, if the user set
    /// one. Never written by this app; surfaced because a value BELOW
    /// 90 % of a raised window pins compaction where it was, and the
    /// Help card is the only place that would say so.
    @Published private(set) var configuredAutoCompactLimit: Int? = nil
    /// The user's own speed as their `config.toml` states it: the
    /// top-level `service_tier`, else `default` when `[notice]
    /// fast_default_opt_out` is set (codex's "no Codex-managed fast
    /// defaults"), else nil. Raw — `CodexSpeed` normalises it. The
    /// stand-in for a folder codex has not yet answered for
    /// (`speedSettings(forFolder:)`).
    @Published private(set) var configuredServiceTier: String? = nil
    /// Codex's `fast_mode` feature as the user's file states it. Only an
    /// explicit `false` turns it off; with it off codex sends no tier
    /// but flex, whatever the command line says. A stand-in, like the
    /// tier above.
    @Published private(set) var fastModeFeatureEnabled: Bool = true
    /// Codex's own speed settings per session folder (`CodexConfigRead`)
    /// — what the user's file alone cannot show, since a trusted
    /// project's `.codex/config.toml` may name its own `service_tier`
    /// and `model`. Keyed by the folder's path.
    @Published private(set) var folderSpeedSettings: [String: CodexSpeed.Settings] = [:]
    /// When each folder was last asked about, answered or not — a codex
    /// that cannot answer is not spawned again on every appearance.
    /// Cleared whenever the user's file or the binary moves, so the next
    /// ask is not skipped.
    private var folderSettingsAskedAt: [String: Date] = [:]
    private var folderSettingsInFlight: Set<String> = []
    /// Bumped whenever an answer may describe a config that has since
    /// moved; a read that started under an older value is asked again.
    private var folderSettingsGeneration = 0
    /// The folder most recently asked about — the one on screen.
    private var latestSpeedFolder: String? = nil
    /// How long an ask stands before a composer appearance asks again.
    /// The model menu opening asks regardless.
    static let folderSettingsLifetime: TimeInterval = 60
    /// Tiers per model as the INSTALLED codex answered `model/list` —
    /// the binary every SipAI turn runs. Read ahead of the cache file,
    /// which another codex client on the same machine may have written
    /// with an older catalog (fewer tiers, no `default_service_tier`).
    /// Empty until codex has answered this launch.
    @Published private(set) var listedTiers: [String: CodexSpeed.ModelTiers] = [:]
    /// The cache header's client version and fetch time; nil until a
    /// cache has been read.
    @Published private(set) var catalogStamp: CodexCatalogStamp? = nil

    /// The feature names the installed `codex features list` prints —
    /// what `ChatOnlyAvailability` gates the Chat only row on, since
    /// codex takes an unknown `-c features.*` key silently. Token-free
    /// (no model, no network), read once per BINARY (`featuresKey`, the
    /// same link-plus-target stamp the claude scrape keys on) so an
    /// update is re-read at the next composer appearance. nil until
    /// read, and nil is "not offered".
    @Published private(set) var featureNames: Set<String>? = nil
    private var featuresKey: String? = nil

    /// Fingerprint of the two files the harvest reads, as of the lists
    /// on screen; nil until the first load. See `ensureLoaded`.
    private var loadedFingerprint: String? = nil
    private var loading = false
    /// When codex was last asked to bring its own catalog up to date —
    /// see `refreshFromCodex`.
    private var lastRefreshAt: Date? = nil
    private var refreshing = false
    /// A config write in flight — see `setContextWindow`.
    private var writing = false
    /// A reload asked for while a harvest was already running. That
    /// harvest read the files BEFORE the write landed and will stamp
    /// its (stale) fingerprint on completion, so the request is kept
    /// and honoured then — otherwise the card and the chip describe the
    /// file as it was until something else happens to re-read it.
    private var pendingReload = false

    private init() {}

    /// The one number "Use the maximum" writes: the largest raw
    /// `max_context_window` any listed model states. One global key
    /// serves every model because codex clamps it per model, so the
    /// largest ceiling is the value that reaches each model's own.
    /// nil when no listed model allows anything above its default.
    var maxContextWindowSetting: Int? {
        models.compactMap(\.maxContextWindowSetting).max()
    }

    /// Effort levels valid for a given model.
    ///
    /// Per-model on purpose: codex's catalog says `gpt-5.6-terra`
    /// accepts `ultra` while `gpt-5.5` stops at `xhigh`, so one shared
    /// list would offer a level the selected model rejects. Falls back
    /// to the union when the model is unknown (nil = "Default", or a
    /// model newer than the cache).
    func effortLevels(forModel slug: String?) -> [String] {
        if let slug, !slug.isEmpty,
           let model = models.first(where: { $0.slug == slug }),
           !model.efforts.isEmpty {
            return model.efforts
        }
        if let fallbackSlug = defaultModel,
           let model = models.first(where: { $0.slug == fallbackSlug }),
           !model.efforts.isEmpty {
            return model.efforts
        }
        return allEfforts
    }

    /// Codex's speed settings in a folder: its own answer for that
    /// folder once it has given one, else what the user's file says.
    func speedSettings(forFolder folder: String?) -> CodexSpeed.Settings {
        if let folder, let answered = folderSpeedSettings[folder] { return answered }
        return CodexSpeed.Settings(configured: configuredServiceTier,
                                   featureEnabled: fastModeFeatureEnabled,
                                   model: defaultModel)
    }

    /// The model a send with no pick runs as in this folder.
    func defaultModel(forFolder folder: String?) -> String? {
        speedSettings(forFolder: folder).model.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The model a send runs as — the pick, else the folder's default.
    private func resolvedSlug(_ slug: String?, folder: String?) -> String? {
        if let slug, !slug.isEmpty { return slug }
        return defaultModel(forFolder: folder)
    }

    /// A model's advertised tiers and catalog default: the installed
    /// codex's own `model/list` answer first, the cache file second.
    /// nil for a model neither knows, since a guessed tier is dropped by
    /// codex per request.
    func speedTiers(forModel slug: String?, folder: String?) -> CodexSpeed.ModelTiers? {
        guard let slug = resolvedSlug(slug, folder: folder) else { return nil }
        if let listed = listedTiers[slug] { return listed }
        guard let model = models.first(where: { $0.slug == slug }) else { return nil }
        return CodexSpeed.ModelTiers(tiers: model.serviceTiers,
                                     defaultTier: model.defaultServiceTier)
    }

    /// Whether the composer offers a speed choice for this model: it
    /// advertises a tier, and codex's `fast_mode` feature is on.
    func offersSpeed(forModel slug: String?, folder: String?) -> Bool {
        speedSettings(forFolder: folder).featureEnabled
            && !(speedTiers(forModel: slug, folder: folder)?.tiers.isEmpty ?? true)
    }

    /// The pick a send carries: the session's own speed, else — for a
    /// value saved before codex had a speed choice here — the tier
    /// codex names Fast.
    func speedPick(for options: AgentLaunchOptions, folder: String?) -> String? {
        if let pick = options.serviceTier, !pick.isEmpty { return pick }
        guard options.fastMode else { return nil }
        return fastTier(forModel: options.model, folder: folder)?.id
    }

    /// The tier the Fast mode switch turns on for this model
    /// (`CodexSpeed.fastTier`), nil when the model advertises none.
    func fastTier(forModel slug: String?, folder: String?) -> CodexServiceTier? {
        CodexSpeed.fastTier(speedTiers(forModel: slug, folder: folder))
    }

    /// The tier a composer send runs at (nil = standard) — codex's own
    /// interactive rule, `CodexSpeed.effective`.
    func effectiveServiceTier(for options: AgentLaunchOptions, folder: String?) -> String? {
        let settings = speedSettings(forFolder: folder)
        return CodexSpeed.effective(pick: speedPick(for: options, folder: folder),
                                    configured: settings.configured,
                                    model: speedTiers(forModel: options.model, folder: folder),
                                    featureEnabled: settings.featureEnabled)
    }

    /// The `-c service_tier=` value a composer send passes, nil for
    /// none — what makes `codex exec` run `effectiveServiceTier`.
    func serviceTierOverride(for options: AgentLaunchOptions, folder: String?) -> String? {
        CodexSpeed.override(
            pick: speedPick(for: options, folder: folder),
            effective: effectiveServiceTier(for: options, folder: folder),
            model: speedTiers(forModel: options.model, folder: folder),
            featureEnabled: speedSettings(forFolder: folder).featureEnabled)
    }

    /// The tier a scheduled task's run gets in this folder (nil =
    /// standard) — `CodexSpeed.scheduled` over codex's answer for the
    /// folder and the model's tiers, for the task card to name.
    func scheduledServiceTier(pick: String?, forModel slug: String?,
                              folder: String?) -> String? {
        let settings = speedSettings(forFolder: folder)
        return CodexSpeed.scheduled(pick: pick, configured: settings.configured,
                                    model: speedTiers(forModel: slug, folder: folder),
                                    featureEnabled: settings.featureEnabled)
    }

    /// The advertised tier with this id on the model in force, for its
    /// name and description.
    func serviceTier(id: String?, forModel slug: String?, folder: String?) -> CodexServiceTier? {
        guard let id = CodexSpeed.normalized(id) else { return nil }
        return speedTiers(forModel: slug, folder: folder)?.tiers.first { $0.id == id }
    }

    /// Ask codex how it resolves speed and the default model in this
    /// folder, unless it was asked within `folderSettingsLifetime`
    /// (`force` asks anyway — the menu that states the choice is
    /// opening). A spawn of codex's app-server, off the MainActor; an
    /// unanswered ask changes nothing on screen.
    func refreshSpeedSettings(forFolder folder: String?, force: Bool = false) {
        guard let folder, !folder.isEmpty else { return }
        latestSpeedFolder = folder
        if !force, let at = folderSettingsAskedAt[folder],
           Date().timeIntervalSince(at) < Self.folderSettingsLifetime { return }
        guard !folderSettingsInFlight.contains(folder),
              let binary = AgentManager.binaryPath(for: "codex") else { return }
        folderSettingsInFlight.insert(folder)
        let generation = folderSettingsGeneration
        Task.detached(priority: .utility) {
            let config = await CodexConfigRead.run(
                binary: binary, cwd: CodexConfigRead.physicalPath(folder))
            await MainActor.run {
                self.folderSettingsInFlight.remove(folder)
                // The config moved while codex was reading it: this
                // answer may describe the old one, so ask again.
                guard self.folderSettingsGeneration == generation else {
                    self.refreshSpeedSettings(forFolder: folder, force: true)
                    return
                }
                self.folderSettingsAskedAt[folder] = Date()
                guard let config else { return }
                let settings = CodexSpeed.settings(fromEffectiveConfig: config)
                if self.folderSpeedSettings[folder] != settings {
                    self.folderSpeedSettings[folder] = settings
                }
            }
        }
    }

    /// Every folder's answer may now describe a config that has moved:
    /// ask again for the folder on screen, and let each other folder be
    /// asked when it next appears. The answers stay until then — for a
    /// project folder an old answer is still nearer the truth than the
    /// user's file, which knows nothing of the project's own layer.
    private func speedSettingsMayHaveMoved() {
        folderSettingsGeneration += 1
        folderSettingsAskedAt = [:]
        if let folder = latestSpeedFolder {
            refreshSpeedSettings(forFolder: folder, force: true)
        }
    }

    /// The context window for a model, resolved the way
    /// `speedTiers(forModel:)` resolves: the selected model, else the
    /// configured default. nil for a model the catalog does not know —
    /// the rollout's own `model_context_window` covers that case, and
    /// a guessed window would misstate every percentage drawn over it.
    func contextWindow(forModel slug: String?) -> Int? {
        if let slug, !slug.isEmpty {
            return models.first { $0.slug == slug }?.contextWindow
        }
        guard let fallback = defaultModel else { return nil }
        return models.first { $0.slug == fallback }?.contextWindow
    }

    /// Load, and RE-load whenever `models_cache.json` or `config.toml`
    /// has changed since the lists were built — the same fingerprint
    /// rule as `KimiCatalog`, for a codex-shaped reason: the cache is
    /// rewritten by codex ITSELF whenever it runs with a stale one (a
    /// newer client version, an expired entry), so a one-shot snapshot
    /// describes the catalog as it stood before the user's next codex
    /// turn, and a model OpenAI shipped that morning shows only after a
    /// relaunch. Safe to call from every composer appearance — the
    /// check is two stats.
    func ensureLoaded() {
        ensureFeaturesLoaded()
        let fingerprint = Self.sourcesFingerprint()
        if !loading, fingerprint != loadedFingerprint {
            loading = true
            Task.detached(priority: .utility) {
                let found = Self.harvest()
                await MainActor.run {
                    if !found.models.isEmpty { self.models = found.models }
                    if !found.efforts.isEmpty { self.allEfforts = found.efforts }
                    self.defaultModel = found.defaultModel
                    self.configuredContextWindow = found.contextWindow
                    self.configuredAutoCompactLimit = found.autoCompactLimit
                    self.configuredServiceTier = found.serviceTier
                    self.fastModeFeatureEnabled = found.fastModeFeature ?? true
                    if let stamp = found.stamp { self.catalogStamp = stamp }
                    // A file that moved since the last harvest may have
                    // moved what codex answered for each folder too.
                    if let previous = self.loadedFingerprint, previous != fingerprint {
                        self.speedSettingsMayHaveMoved()
                    }
                    // Stamped with the fingerprint READ BEFORE the
                    // harvest: a file rewritten mid-harvest must leave
                    // the two disagreeing, so the next appearance
                    // re-reads rather than trusting a list built from
                    // a file that has already moved on.
                    self.loadedFingerprint = fingerprint
                    self.loading = false
                    // A write that landed while this harvest ran asked
                    // for a re-read it could not start; start it now.
                    if self.pendingReload {
                        self.pendingReload = false
                        self.loadedFingerprint = nil
                        self.ensureLoaded()
                    }
                }
            }
        }
        refreshFromCodex(force: false)
    }

    /// Re-run the load because the BINARY moved. Same reason as
    /// `ClaudeCapabilities.reloadAfterBinaryChange`: a codex update
    /// brings a catalog the old client was not shown, and the picker
    /// must not keep describing the binary that was replaced. A re-read
    /// alone would find the OLD cache — codex keys that file by client
    /// version and rewrites it only when it next runs — so the new
    /// binary is asked for its list first.
    func reloadAfterBinaryChange() {
        // The feature list is a per-binary read too (`ensureLoaded`
        // re-asks when its key is cleared).
        featuresKey = nil
        // So is the tier answer: it described the binary that was
        // replaced, and the cache answers until the new one has spoken.
        listedTiers = [:]
        // And each folder's settings came from the old binary's merge.
        speedSettingsMayHaveMoved()
        loadedFingerprint = nil
        refreshFromCodex(force: true)
        ensureLoaded()
    }

    /// Ask the installed codex for its feature list unless the set on
    /// hand already describes that binary. Two stats when nothing moved.
    /// Off the MainActor: a spawn, however fast, is not for a body pass.
    private func ensureFeaturesLoaded() {
        guard let binary = AgentManager.binaryPath(for: "codex"),
              let key = ClaudeModelCatalog.binaryKey(at: binary),
              key != featuresKey else { return }
        featuresKey = key
        let makeEnvironment = CLIScrapeEnvironment.provider
        Task.detached(priority: .utility) {
            let environment = await makeEnvironment?()
            let listing = Self.featuresListing(binary: binary, environment: environment)
            let names = listing.isEmpty ? nil
                : ChatOnlyAvailability.codexFeatures(fromListing: listing)
            await MainActor.run {
                // A newer binary's pass is on its way — same rule as the
                // claude scrape: a stale pass must not land last.
                guard self.featuresKey == key else { return }
                // A listing that failed is not a verdict about this
                // binary: forget the key so the next composer appearance
                // asks again, instead of hiding the Chat only row until
                // the app is relaunched.
                if names == nil { self.featuresKey = nil }
                if names != self.featureNames { self.featureNames = names }
            }
        }
    }

    /// `codex features list`, read the way `ClaudeCapabilities.helpText`
    /// reads `--help`: read first, then wait. The listing is a few KB
    /// and returns at once; stdin is closed so a codex that decided to
    /// read a prompt finds EOF rather than a pipe. `environment` is
    /// `CLIScrapeEnvironment`'s — an npm-installed codex is a `node`
    /// script, and without the agent-child PATH it cannot start at all.
    nonisolated private static func featuresListing(binary: String,
                                                    environment: [String: String]?) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["features", "list"]
        if let environment { p.environment = environment }
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return ""
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Set — or, with nil, remove — the user's `model_context_window`,
    /// THROUGH codex: `codex app-server`'s `config/value/write`, the
    /// same request its own desktop front-end makes. Codex's writer
    /// validates the value against its schema, keeps every other byte
    /// of the file, and treats a null as "remove the key", which is
    /// what makes "Back to default" a real default rather than a
    /// second number. SipAI never writes TOML into that file itself.
    ///
    /// The re-read afterwards is unconditional (`loadedFingerprint =
    /// nil`): the fingerprint is (size, mtime), and a write followed by
    /// a stat inside the same second is a race the chip would lose.
    /// The outcome is returned to the caller because a refusal has to
    /// be SHOWN — the card already says what it asked for, so silence
    /// would leave it claiming a change codex declined.
    func setContextWindow(_ raw: Int?) async -> CodexConfigWrite.Outcome {
        guard !writing else { return .unavailable }
        guard let binary = AgentManager.binaryPath(for: "codex") else {
            return .unavailable
        }
        writing = true
        let outcome = await CodexConfigWrite.run(binary: binary,
                                                  keyPath: "model_context_window",
                                                  value: raw)
        writing = false
        loadedFingerprint = nil
        if loading {
            pendingReload = true
        } else {
            ensureLoaded()
        }
        return outcome
    }

    /// How long one refresh through codex stands before a composer
    /// appearance asks again. Codex keeps its own cache TTL and answers
    /// from the file while that has not expired (measured: an answer in
    /// tens of milliseconds and no write), so this bounds process
    /// spawns, not network fetches.
    private static let refreshInterval: TimeInterval = 24 * 60 * 60

    /// Ask codex to bring its own model list up to date, then re-read.
    ///
    /// `codex app-server` answers `model/list` the way the TUI's picker
    /// is filled at bootstrap: from `models_cache.json` while that is
    /// current for the running client, from the server otherwise — and
    /// a server answer is written back to the file, which the
    /// fingerprint above then notices. No model is called and nothing
    /// is billed. Without this, a model the server lists only for a
    /// NEWER client stays invisible after an update until the user's
    /// next codex turn happens to refetch it, and one switched on
    /// server-side stays invisible until then as well.
    ///
    /// Forced after an update; otherwise at most once per
    /// `refreshInterval` per launch, from the composer's own
    /// appearance. A codex that is missing, signed out or offline
    /// answers nothing, and the cache stays as it was.
    func refreshFromCodex(force: Bool) {
        guard !refreshing,
              let binary = AgentManager.binaryPath(for: "codex") else { return }
        if !force, let last = lastRefreshAt,
           Date().timeIntervalSince(last) < Self.refreshInterval { return }
        refreshing = true
        lastRefreshAt = Date()
        Task.detached(priority: .utility) {
            let answer = await CodexModelListRefresh.answer(binary: binary)
            let listed = Self.listedTiers(fromAnswer: answer)
            await MainActor.run {
                self.refreshing = false
                // An answer that named no tiers (no app-server, signed
                // out and no bundled catalog) keeps what was known.
                if !listed.isEmpty, listed != self.listedTiers {
                    self.listedTiers = listed
                }
                self.ensureLoaded()
            }
        }
    }

    /// Change-detector over the two files the harvest reads. A missing
    /// file has its own stable fingerprint, so "not there yet" costs
    /// two stats per composer appearance and turns into a real load
    /// the moment codex writes it.
    nonisolated private static func sourcesFingerprint() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".codex/models_cache.json", ".codex/config.toml"].map { rel -> String in
            let path = home.appendingPathComponent(rel).path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs?[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? -1
            return "\(size)/\(mtime)"
        }.joined(separator: "|")
    }

    // MARK: - Harvest

    nonisolated private static func harvest()
    -> (models: [CodexModel], efforts: [String], defaultModel: String?,
        contextWindow: Int?, autoCompactLimit: Int?, stamp: CodexCatalogStamp?,
        serviceTier: String?, fastModeFeature: Bool?) {
        let config = readConfigDefaults()
        let cache = readModelsCache(contextWindowOverride: config.contextWindow)
        var models = cache.visible
        var efforts = models.flatMap(\.efforts).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }

        // Anything the machine has actually RUN but the cache doesn't
        // list — a model newer than the last catalog fetch. Appended
        // with no effort list of its own, so it falls back to the union.
        var observed: [String] = []
        func note(_ slug: String?) {
            guard let slug = slug?.trimmingCharacters(in: .whitespaces),
                  !slug.isEmpty,
                  // A model codex marks `hide` must stay hidden however
                  // we meet it. Filtering only the cache would let a
                  // hidden model back in through the ROLLOUTS with the
                  // hide flag defeated — `codex review` runs as
                  // `codex-auto-review`, so any machine that has used
                  // review has observed it.
                  !cache.hidden.contains(slug),
                  !models.contains(where: { $0.slug == slug }),
                  !observed.contains(slug) else { return }
            observed.append(slug)
        }
        func noteEffort(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespaces),
                  !value.isEmpty, !efforts.contains(value) else { return }
            efforts.append(value)
        }
        note(config.model)
        noteEffort(config.effort)
        for url in newestRollouts(limit: 25) {
            let seen = readTurnContext(of: url)
            note(seen.model)
            noteEffort(seen.effort)
        }

        // A model codex never listed carries no display name of its
        // own; the slug IS the name. Priority -1 so the user's own
        // just-shipped model leads the picker rather than trailing it.
        for slug in observed {
            models.append(CodexModel(slug: slug, displayName: slug,
                                     priority: -1, efforts: []))
        }
        models.sort {
            $0.priority != $1.priority ? $0.priority < $1.priority
                                       : $0.slug < $1.slug
        }
        // Only needed for levels that came from config/rollouts; the
        // cache's own order is already fast → deep and stable-sorts
        // through this unchanged.
        efforts.sort { rank(of: $0) < rank(of: $1) }
        return (models, efforts, config.model, config.contextWindow,
                config.autoCompactLimit, cache.stamp,
                config.serviceTier, config.fastModeFeature)
    }

    nonisolated private static func rank(of effort: String) -> Int {
        effortRank.firstIndex(of: effort) ?? effortRank.count
    }

    /// The cache file, handed to `parseModelsCache`. Reading and parsing
    /// are split so the parse can be driven with fixtures — the same
    /// reason `KimiCatalog.parseConfig` is pure.
    nonisolated private static func readModelsCache(contextWindowOverride: Int?)
    -> (visible: [CodexModel], hidden: Set<String>, stamp: CodexCatalogStamp?) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url) else { return ([], [], nil) }
        return parseModelsCache(data, contextWindowOverride: contextWindowOverride)
    }

    /// Codex's own catalog, split into what to offer and what codex
    /// says to hide. `visibility == "hide"` is codex telling us what
    /// not to show, which beats a deny-list of ours going stale — but
    /// the hidden SLUGS have to come back too, so the observation path
    /// can honour the same flag.
    nonisolated static func parseModelsCache(_ data: Data, contextWindowOverride: Int?)
    -> (visible: [CodexModel], hidden: Set<String>, stamp: CodexCatalogStamp?) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              let raw = obj["models"] as? [Any] else { return ([], [], nil) }
        let stamp = CodexCatalogStamp(
            clientVersion: (obj["client_version"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 },
            fetchedAt: (obj["fetched_at"] as? String).flatMap(parseFetchedAt))
        var out: [CodexModel] = []
        var hidden: Set<String> = []
        for case let entry as [String: Any] in raw {
            guard let slug = entry["slug"] as? String, !slug.isEmpty
            else { continue }
            guard (entry["visibility"] as? String) != "hide" else {
                hidden.insert(slug)
                continue
            }
            let name = (entry["display_name"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 } ?? slug
            let priority = (entry["priority"] as? NSNumber)?.intValue
                ?? Int.max
            var efforts: [String] = []
            for case let level as [String: Any]
            in (entry["supported_reasoning_levels"] as? [Any]) ?? [] {
                if let effort = level["effort"] as? String, !effort.isEmpty,
                   !efforts.contains(effort) {
                    efforts.append(effort)
                }
            }
            let tiers = serviceTiers(from: entry["service_tiers"])
            let defaultTier = (entry["default_service_tier"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            // Effective, not raw: the percentage is what codex leaves
            // usable, and dividing by the raw window would understate
            // occupancy on every codex session.
            //
            // `context_window` is the window a session runs with by
            // DEFAULT; `max_context_window` is how far the user's own
            // `model_context_window` may raise it. Measured on codex: a
            // 272,000 / 872,000 model configured to 872,000 records
            // 828,400 on its rollouts, and configured to 1,000,000
            // records the same 828,400 — the override is clamped to the
            // maximum and the percentage applies to the result. The
            // chip must divide by what codex enforces, which is this
            // arithmetic, not the raw default.
            // An entry stating only a maximum runs AT that maximum —
            // codex resolves `context_window.or(max_context_window)` —
            // so the raw default is the cap when the default is absent.
            let cap = (entry["max_context_window"] as? NSNumber)?.intValue ?? 0
            let stated = (entry["context_window"] as? NSNumber)?.intValue ?? 0
            let raw = stated > 0 ? stated : cap
            var base = raw
            if let override = contextWindowOverride, override > 0 {
                base = cap > 0 ? min(override, cap) : override
            }
            let pct = (entry["effective_context_window_percent"]
                        as? NSNumber)?.doubleValue
            func usable(_ tokens: Int) -> Int? {
                guard tokens > 0 else { return nil }
                if let pct, pct > 0, pct <= 100 {
                    return Int((Double(tokens) * pct / 100).rounded())
                }
                return tokens
            }
            // Default and maximum are kept apart from the effective
            // window so the Help card can state both — "258,400 now,
            // 828,400 at most" — while the chip keeps dividing by the
            // one in force. A cap no larger than the default is "no
            // larger window", not a maximum.
            let larger = cap > raw
            let percent = pct.flatMap { $0 > 0 && $0 <= 100 ? Int($0.rounded()) : nil }
            out.append(CodexModel(slug: slug, displayName: name,
                                  priority: priority, efforts: efforts,
                                  serviceTiers: tiers,
                                  defaultServiceTier: defaultTier,
                                  contextWindow: usable(base),
                                  defaultContextWindow: usable(raw),
                                  defaultContextWindowSetting: raw > 0 ? raw : nil,
                                  usablePercent: raw > 0 ? (percent ?? 100) : nil,
                                  maxContextWindow: larger ? usable(cap) : nil,
                                  maxContextWindowSetting: larger ? cap : nil))
        }
        return (out, hidden, stamp)
    }

    /// A `service_tiers` / `serviceTiers` list, in its own order: the
    /// cache and `model/list` spell the entries alike (`id`, `name`,
    /// `description`). An entry without an id is skipped; a nameless one
    /// is named by its id.
    nonisolated static func serviceTiers(from value: Any?) -> [CodexServiceTier] {
        var out: [CodexServiceTier] = []
        for case let entry as [String: Any] in (value as? [Any]) ?? [] {
            guard let id = (entry["id"] as? String)?
                    .trimmingCharacters(in: .whitespaces),
                  !id.isEmpty, !out.contains(where: { $0.id == id })
            else { continue }
            out.append(CodexServiceTier(
                id: id,
                name: (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                description: (entry["description"] as? String) ?? ""))
        }
        return out
    }

    /// The tiers per model out of the installed codex's `model/list`
    /// answer — `result.data[]`, each with `model` (or `id`),
    /// `serviceTiers` and `defaultServiceTier`. A model that names
    /// neither is left out, so the cache still answers for it.
    nonisolated static func listedTiers(fromAnswer answer: [String: Any]?)
    -> [String: CodexSpeed.ModelTiers] {
        guard let result = answer?["result"] as? [String: Any],
              let data = result["data"] as? [Any] else { return [:] }
        var out: [String: CodexSpeed.ModelTiers] = [:]
        for case let entry as [String: Any] in data {
            guard let slug = ((entry["model"] as? String) ?? (entry["id"] as? String))?
                    .trimmingCharacters(in: .whitespaces),
                  !slug.isEmpty,
                  entry["serviceTiers"] != nil || entry["defaultServiceTier"] != nil
            else { continue }
            out[slug] = CodexSpeed.ModelTiers(
                tiers: serviceTiers(from: entry["serviceTiers"]),
                defaultTier: (entry["defaultServiceTier"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 })
        }
        return out
    }

    /// `fetched_at` as codex writes it — RFC 3339 with a six-digit
    /// fraction ("2026-09-10T03:34:26.359497Z"). `ISO8601DateFormatter`
    /// reads at most three fraction digits, so the fraction is cut to
    /// the second before parsing; a stamp is not a thing to be precise
    /// about to the microsecond.
    nonisolated static func parseFetchedAt(_ text: String) -> Date? {
        var trimmed = text
        if let dot = trimmed.firstIndex(of: "."),
           let zone = trimmed[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            trimmed.removeSubrange(dot..<zone)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    /// The config file, handed to `parseConfigDefaults`.
    nonisolated private static func readConfigDefaults()
    -> (model: String?, effort: String?, contextWindow: Int?, autoCompactLimit: Int?,
        serviceTier: String?, fastModeFeature: Bool?) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        guard let data = try? Data(contentsOf: url) else {
            return (nil, nil, nil, nil, nil, nil)
        }
        return parseConfigDefaults(String(decoding: data, as: UTF8.self))
    }

    /// Top-level `model` / `model_reasoning_effort` /
    /// `model_context_window` / `model_auto_compact_token_limit` /
    /// `service_tier` from config.toml. Those are read BEFORE the first
    /// `[section]` header only — the file also carries
    /// `[marketplaces.*]`, `[plugins.*]` and `[profiles.*]` tables whose
    /// keys are not the global ones codex reads. Two tables are read by
    /// name for the speed: `[features] fast_mode` (nil unless the file
    /// says) and `[notice] fast_default_opt_out`, which codex's own
    /// pickers read as `service_tier = "default"` when no tier is set.
    /// The dotted top-level spellings of both count as well.
    nonisolated static func parseConfigDefaults(_ text: String)
    -> (model: String?, effort: String?, contextWindow: Int?, autoCompactLimit: Int?,
        serviceTier: String?, fastModeFeature: Bool?) {
        var model: String? = nil
        var effort: String? = nil
        var contextWindow: Int? = nil
        var autoCompactLimit: Int? = nil
        var serviceTier: String? = nil
        var fastModeFeature: Bool? = nil
        var fastDefaultOptOut = false
        /// nil while still above the first table header.
        var table: String? = nil
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = TomlScalar.tableName(line) ?? line
                continue
            }
            if let table {
                if table == "features",
                   let value = TomlScalar.bool(line, key: "fast_mode") {
                    fastModeFeature = value
                }
                if table == "notice",
                   TomlScalar.bool(line, key: "fast_default_opt_out") == true {
                    fastDefaultOptOut = true
                }
                continue
            }
            if let value = TomlScalar.bool(line, key: "features.fast_mode") {
                fastModeFeature = value
            }
            if TomlScalar.bool(line, key: "notice.fast_default_opt_out") == true {
                fastDefaultOptOut = true
            }
            if let value = TomlScalar.string(line, key: "service_tier"),
               serviceTier == nil {
                serviceTier = value
            }
            if let value = TomlScalar.string(line, key: "model"), model == nil {
                model = value
            }
            if let value = TomlScalar.string(line, key: "model_reasoning_effort"),
               effort == nil {
                effort = value
            }
            // The user's own window override, which codex clamps to the
            // model's maximum — see `parseModelsCache`.
            if let value = TomlScalar.integer(line, key: "model_context_window"),
               contextWindow == nil {
                contextWindow = value
            }
            if let value = TomlScalar.integer(line, key: "model_auto_compact_token_limit"),
               autoCompactLimit == nil {
                autoCompactLimit = value
            }
        }
        if serviceTier == nil, fastDefaultOptOut { serviceTier = CodexSpeed.standard }
        return (model, effort, contextWindow, autoCompactLimit, serviceTier, fastModeFeature)
    }

    nonisolated private static func newestRollouts(limit: Int) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: CodexSessionScanner.sessionRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var found: [(url: URL, at: Date)] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl")
            else { continue }
            let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            found.append((url, at))
        }
        return found.sorted { $0.at > $1.at }.prefix(limit).map(\.url)
    }

    /// `model` / `effort` off the first `turn_context` record in a
    /// rollout's head. Bounded and lossy for the same reason every
    /// other reader here is: this runs over a directory the user's
    /// other tools are writing to.
    nonisolated private static func readTurnContext(of url: URL)
    -> (model: String?, effort: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return (nil, nil)
        }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 512 * 1024)
        for line in String(decoding: head, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("turn_context") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  obj["type"] as? String == "turn_context",
                  let payload = obj["payload"] as? [String: Any]
            else { continue }
            return (payload["model"] as? String, payload["effort"] as? String)
        }
        return (nil, nil)
    }
}
