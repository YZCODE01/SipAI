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
    /// Display-only: it feeds the composer chip's versioned name
    /// ("Opus 5.0") while `model` stays the picker alias. Never emitted
    /// as a flag, never persisted; cleared when the user picks a model
    /// so a stale id can't shadow their choice.
    var modelFullId: String? = nil

    /// Flag list for an agent invocation. Blank values are skipped.
    /// Branches per agent: the three CLIs spell all three options
    /// differently.
    func flags(for agentKey: String = "claude_code") -> [String] {
        if agentKey == "codex" { return codexFlags() }
        if agentKey == "kimi" { return kimiFlags() }
        var argv: [String] = []
        if let mode = permissionMode, !mode.isEmpty {
            argv += ["--permission-mode", mode]
        }
        if let model = model, !model.isEmpty {
            argv += ["--model", model]
        }
        if let effort = effort, !effort.isEmpty {
            argv += ["--effort", effort]
        }
        return argv
    }

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
        if let mode = permissionMode, !mode.isEmpty,
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
}

/// One `key = "value"` line of a TOML file's top level.
///
/// Shared by the codex and kimi catalogs, which both read a
/// hand-editable `config.toml` for the user's declared default model.
/// One parser rather than two: the prefix check below is what stops
/// `model_reasoning_effort` from answering a request for `model`, and
/// a second copy is how that subtlety gets lost.
enum TomlScalar {
    static func string(_ line: String, key: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        let rest = line.dropFirst(key.count)
            .trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { return nil }   // not `model_x = …`
        let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2
        else { return nil }
        return String(value.dropFirst().dropLast())
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
        let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
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
    /// model declares none — the picker then falls back to the union.
    let efforts: [String]
    /// `default_effort` — the level this model runs at when nothing is
    /// picked. Without it the effort chip's "Default" row says only
    /// "Default", which is the one control in the row that names no
    /// value at all — the model chip's Default row already names what
    /// it resolves to.
    let defaultEffort: String?
    /// `max_context_size` — the model's window, for the token chip's
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

    /// `max_context_size` for a model, for the token chip's occupancy
    /// tooltip. The slug handed in is the `model` string off the wire's
    /// newest `usage.record`, which IS the config alias (measured on a
    /// real install: `"model":"moonshot-ai/kimi-k3"` against
    /// `[models."moonshot-ai/kimi-k3"]`). Same resolution chain as
    /// `defaultEffort(forModel:)`; nil means the tooltip keeps its
    /// fallback constant rather than stating a guessed window.
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
enum ClaudeModelCatalog {
    struct Harvest {
        /// family alias → newest full id seen ("opus" → "claude-opus-5").
        var byFamily: [String: String] = [:]
        /// Model of the most recent session, for seeding the "" default.
        var newestSessionModel: String? = nil
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

    /// Reads files — call from a detached task, never the MainActor.
    nonisolated static func harvest(sessionURLs: [URL]) -> Harvest {
        var out = Harvest()
        func offer(_ raw: String) {
            let id = ClaudeModelDisplay.splitVariant(raw).id
            // A variant ("[1m]") belongs to the alias the user picked,
            // not to the family's version, so only plain ids are learned.
            guard !id.isEmpty,
                  let family = ClaudeModelDisplay.familyAlias(of: id),
                  !ClaudeModelDisplay.parts(of: id).digits.isEmpty
            else { return }
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

/// Cached catalogs scraped from `claude --help`, with hardcoded
/// fallbacks. The scrape runs once per app launch on a background
/// thread; until it lands (or if it fails) callers see the fallbacks.
@MainActor
final class ClaudeCapabilities: ObservableObject {
    static let shared = ClaudeCapabilities()

    /// Fallback for when claude isn't installed or the help shape
    /// changed. Ordered for display.
    private static let modeFallback = ["bypassPermissions", "acceptEdits", "plan", "manual"]
    // Deliberately NOT offering "ultracode" even though `--effort
    // ultracode` parses without a warning: a headless run records
    // `effort: "xhigh"` — a downgrade from max — and no ultracode
    // orchestration reminder appears in `-p` mode (neither via the
    // flag nor the prompt keyword). Ultracode is an interactive-TUI
    // feature; offering it here would silently mean "xhigh".
    private static let effortFallback = ["low", "medium", "high", "xhigh", "max"]
    private static let modelAliasFallback = ["fable", "opus", "sonnet", "haiku"]

    @Published private(set) var permissionModes: [AgentPermissionMode]
    @Published private(set) var effortLevels: [String]
    @Published private(set) var modelAliases: [String]

    private var scrapeStarted = false

    private init() {
        permissionModes = Self.ordered(Self.modeFallback).map(AgentPermissionMode.init)
        effortLevels = Self.effortFallback
        modelAliases = Self.modelAliasFallback
    }

    /// Kick off the one-shot help scrape. Safe to call from every
    /// composer appearance — subsequent calls are no-ops.
    func ensureLoaded() {
        guard !scrapeStarted else { return }
        scrapeStarted = true
        guard let binary = AgentManager.binaryPath(for: "claude_code") else { return }
        Task.detached(priority: .utility) {
            let help = Self.helpText(binary: binary)
            guard !help.isEmpty else { return }
            let modes = Self.scrapePermissionModes(help)
            let efforts = Self.scrapeEffortLevels(help)
            let aliases = Self.scrapeModelAliases(help)
            await MainActor.run {
                if !modes.isEmpty {
                    self.permissionModes = Self.ordered(modes).map(AgentPermissionMode.init)
                }
                if !efforts.isEmpty { self.effortLevels = efforts }
                // Merge rather than replace: help lists aliases by
                // example, so known ones must not disappear.
                var merged = aliases
                for known in Self.modelAliasFallback where !merged.contains(known) {
                    merged.append(known)
                }
                if !merged.isEmpty { self.modelAliases = merged }
            }
        }
    }

    // MARK: - Scraping (`--help` parsers)

    nonisolated private static func helpText(binary: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["--help"]
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
        return String(data: data, encoding: .utf8) ?? ""
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


/// One codex model as codex itself describes it.
struct CodexModel: Identifiable, Hashable {
    let slug: String
    let displayName: String
    /// Codex's own display ranking; lower sorts first.
    let priority: Int
    /// Reasoning levels this model accepts, in codex's own order
    /// (fast → deep). Empty when unknown.
    let efforts: [String]

    var id: String { slug }
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

    private var loadStarted = false

    private init() {}

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

    /// One-shot load. Safe to call from every composer appearance.
    func ensureLoaded() {
        guard !loadStarted else { return }
        loadStarted = true
        Task.detached(priority: .utility) {
            let found = Self.harvest()
            await MainActor.run {
                if !found.models.isEmpty { self.models = found.models }
                if !found.efforts.isEmpty { self.allEfforts = found.efforts }
                self.defaultModel = found.defaultModel
            }
        }
    }

    // MARK: - Harvest

    nonisolated private static func harvest()
    -> (models: [CodexModel], efforts: [String], defaultModel: String?) {
        let cache = readModelsCache()
        var models = cache.visible
        var efforts = models.flatMap(\.efforts).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }

        let config = readConfigDefaults()
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
        return (models, efforts, config.model)
    }

    nonisolated private static func rank(of effort: String) -> Int {
        effortRank.firstIndex(of: effort) ?? effortRank.count
    }

    /// Codex's own catalog, split into what to offer and what codex
    /// says to hide. `visibility == "hide"` is codex telling us what
    /// not to show, which beats a deny-list of ours going stale — but
    /// the hidden SLUGS have to come back too, so the observation path
    /// can honour the same flag.
    nonisolated private static func readModelsCache()
    -> (visible: [CodexModel], hidden: Set<String>) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              let raw = obj["models"] as? [Any] else { return ([], []) }
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
            out.append(CodexModel(slug: slug, displayName: name,
                                  priority: priority, efforts: efforts))
        }
        return (out, hidden)
    }

    /// Top-level `model` / `model_reasoning_effort` from config.toml.
    /// Parsing stops at the first `[section]` header — the file also
    /// carries `[marketplaces.*]` and `[plugins.*]` tables whose keys
    /// are not the user's model choice.
    nonisolated private static func readConfigDefaults()
    -> (model: String?, effort: String?) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        guard let data = try? Data(contentsOf: url) else { return (nil, nil) }
        var model: String? = nil
        var effort: String? = nil
        for rawLine in String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            if let value = TomlScalar.string(line, key: "model"), model == nil {
                model = value
            }
            if let value = TomlScalar.string(line, key: "model_reasoning_effort"),
               effort == nil {
                effort = value
            }
        }
        return (model, effort)
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
