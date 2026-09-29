// Fast mode and codex's speed — the request, what the calls actually
// get, and what the composer says about it.
//
// Claude. The switch is an opt-in on claude's FLAG layer
// (`--settings {"fastMode":true}`), and only the models claude's own
// catalog marks `fast_mode` take it. On a Claude plan fast mode is paid
// from usage credits. When those are unavailable claude still ASKS for
// fast mode on every call; the API refuses it (a 429 carrying
// `anthropic-ratelimit-unified-overage-disabled-reason`); claude
// re-sends the call at standard speed, says so ONCE per turn in a
// `system` notification, and goes on reporting `fast_mode_state: "on"`.
// So a chip that trusts the state says fast mode is on while every call
// runs at standard speed — and the refused attempt makes each call a
// little slower than with the switch off. The chip therefore reads all
// four channels (`ClaudeFastModeReport`): the state, the reason beside
// it, the refusal, and each call's own `usage.speed`.
//
// Codex. A model advertises service tiers in codex's catalog (`Fast`,
// `Ultrafast`) and may name one its default. Codex's own pickers run
// the config's `service_tier`, else that default; `codex exec` — the
// command every SipAI turn runs — applies the config alone, and a
// resumed thread re-resolves it on every turn. A composer send follows
// codex's own pickers and pins the tier the way codex's picker pins it
// for its core (`CodexSpeed.override`); `default` is codex's explicit
// standard. "The config" is codex's MERGED config for the session's
// folder, asked of codex (`config/read`): a trusted project's
// `.codex/config.toml` sits above the user's file.
//
// Scheduled tasks. A task carries its own speed (`fast_mode`,
// `service_tier` in SKILL.md). Its run passes the pick verbatim and,
// with none, nothing — so a codex task on Default gets exec's own
// resolution, which never applies a catalog default
// (`CodexSpeed.scheduled`, `AgentLaunchOptions.scheduledRun`).
//
// The seed. A session with no saved picks opens its switch from the
// transcript — but a refused call records standard, so only a fast
// record may move the switch (`ClaudeFastMode.seededSwitch`).
//
// One switch. Both agents draw a single Fast mode switch, in the composer
// and on the task card. Codex's turns on the model's Fast tier
// (`CodexSpeed.fastTier`) and, off, pins standard; until it is flipped it
// shows what codex itself would run. Claude's always says what fast mode
// costs — on a Claude plan, usage credits alone.
//
// Sections 6 and 7 RUN the installed claude and codex against the
// local fake endpoint in ../ChatOnlyMode, each under a throwaway home
// with a junk key: nothing reaches a provider and no token is spent.
// Run this after any Claude Code or Codex upgrade — the catalog flags,
// the notification, the tier ids and exec's resolution are all
// somebody else's to change.
//
// Nothing here is part of the app target: this directory sits outside
// SipAI/, so these files are never compiled into the product. The
// stubs are borrowed from ../KimiCode rather than copied.
//
//   ./run.sh

import Foundation

let fm = FileManager.default
var checks = 0
var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    checks += 1
    print(cond ? "  PASS  \(label)" : "  FAIL  \(label) \(detail)")
    if !cond { failures += 1 }
}
func section(_ title: String) { print("\n\(title)") }
func note(_ text: String) { print("  note  \(text)") }

let harnessDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : fm.currentDirectoryPath
let sourceRoot = harnessDir + "/../.."
func read(_ rel: String) -> String {
    (try? String(contentsOfFile: sourceRoot + "/" + rel, encoding: .utf8)) ?? ""
}
func line(_ dict: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: dict), as: UTF8.self)
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sipai-fastmode-\(ProcessInfo.processInfo.processIdentifier)",
                            isDirectory: true)
try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)

// ───────────────────────────── 1. which claude models take fast mode

section("1. Claude: the catalog's fast_mode flag decides, claude's fallback covers the rest")

typealias CatEntry = ClaudeModelCatalog.BinaryCatalog.Entry
func catalog(_ entries: [CatEntry]) -> ClaudeModelCatalog.BinaryCatalog {
    ClaudeModelCatalog.BinaryCatalog(entries: entries, aliasDefault: [:],
                                     aliasPerProvider: [:], latestPerFamily: [:], best: nil)
}
let table = catalog([
    CatEntry(catalogId: "claude-opus-5-5", family: "opus", displayName: "Opus 5.5",
          firstPartyId: "claude-opus-5-5", capabilities: ["effort", "fast_mode"]),
    CatEntry(catalogId: "claude-opus-4-7", family: "opus", displayName: "Opus 4.7",
          firstPartyId: "claude-opus-4-7", capabilities: ["effort", "max_effort"]),
    CatEntry(catalogId: "claude-fable-5-1", family: "fable", displayName: "Fable 5.1",
          firstPartyId: "claude-fable-5-1", capabilities: ["effort"]),
    CatEntry(catalogId: "claude-opus-4-8", family: "opus", displayName: "Opus 4.8",
          firstPartyId: "claude-opus-4-8", capabilities: nil),
])
func takes(_ id: String?, _ cat: ClaudeModelCatalog.BinaryCatalog? = table) -> Bool? {
    ClaudeModelCatalog.fastModeSupported(forId: id, catalog: cat)
}
check("a model whose entry lists fast_mode takes it", takes("claude-opus-5-5") == true)
check("an Opus whose entry does not list it does not — not every Opus",
      takes("claude-opus-4-7") == false)
check("a non-Opus entry without the flag does not", takes("claude-fable-5-1") == false)
check("a [1m] spelling is its base model", takes("claude-opus-5-5[1m]") == true)
check("an entry with no readable list falls back to claude's own rule (opus-4-8)",
      takes("claude-opus-4-8") == true)
check("a model the table does not name: claude's fallback — Opus 5 takes it",
      takes("claude-opus-5-9") == true)
check("… and Opus 4.6 does not", takes("claude-opus-4-6") == false)
check("… and a Sonnet does not", takes("claude-sonnet-5") == false)
check("nothing resolved is UNKNOWN (nil), never a verdict", takes(nil) == nil && takes("") == nil)
check("no catalog at all: the fallback answers", takes("claude-opus-5", nil) == true
      && takes("claude-haiku-4-5", nil) == false)
let renamed = catalog([
    CatEntry(catalogId: "claude-opus-5", family: "opus", displayName: "Opus 5",
          firstPartyId: "claude-opus-5", capabilities: ["effort"]),
    CatEntry(catalogId: "claude-opus-4-7", family: "opus", displayName: "Opus 4.7",
          firstPartyId: "claude-opus-4-7", capabilities: ["effort"]),
])
check("a table that lists fast_mode for NO model has renamed it: the fallback answers",
      takes("claude-opus-5", renamed) == true && takes("claude-opus-4-7", renamed) == false)

let realHome = NSHomeDirectory()
let realClaude = [realHome + "/.local/bin/claude", "/opt/homebrew/bin/claude",
                  "/usr/local/bin/claude"]
    .first { fm.isExecutableFile(atPath: $0) }
let installedCatalog = realClaude.flatMap { ClaudeModelCatalog.binaryCatalog(at: $0) }
if let cat = installedCatalog {
    let fast = cat.entries.filter { ($0.capabilities ?? []).contains("fast_mode") }
    note("the installed claude marks fast_mode on: "
         + (fast.isEmpty ? "nothing" : fast.map(\.displayName).joined(separator: ", ")))
    check("the installed claude's table still spells fast_mode", cat.listsCapability("fast_mode"))
    check("every entry it marks takes the switch",
          fast.allSatisfy { takes($0.firstPartyId, cat) == true })
    let without = cat.entries.filter {
        $0.capabilities != nil && !($0.capabilities ?? []).contains("fast_mode")
    }
    check("every entry it leaves unmarked does not (incl. \(without.filter { $0.family == "opus" }.map(\.displayName).joined(separator: ", ")))",
          without.allSatisfy { takes($0.firstPartyId, cat) == false })
} else {
    note("no installed claude with a catalog — the live half of this section is skipped")
}

// ─────────────────────────────── 2. what claude's calls actually get

section("2. Claude: one verdict from four channels and the cached credits state")

typealias FastReport = ClaudeFastModeReport
func verdict(_ r: FastReport, requested: Bool = true, block: String? = nil) -> ClaudeFastMode.Verdict {
    ClaudeFastMode.verdict(requested: requested, report: r, creditsBlock: block)
}
let refusalText = "Fast mode disabled · usage credits exhausted"
check("switch off: off, whatever was said",
      verdict(FastReport(state: "on", lastSpeed: "fast"), requested: false) == .off)
check("requested and nothing said yet: requested", verdict(FastReport()) == .requested)
check("the newest call ran fast: running",
      verdict(FastReport(state: "on", lastSpeed: "fast")) == .running)
check("… and a call that ran fast overtakes an earlier refusal and a stale block",
      verdict(FastReport(refusal: refusalText, lastSpeed: "fast"), block: "out_of_credits") == .running)
check("a refusal wins over the state claude keeps reporting as \"on\"",
      verdict(FastReport(state: "on", refusal: refusalText, lastSpeed: "standard"))
        == .notServing(.refused(refusalText)))
check("cooldown", verdict(FastReport(state: "cooldown")) == .notServing(.cooldown))
check("a session-wide reason",
      verdict(FastReport(state: "off", disabledReason: "extra_usage_disabled"))
        == .notServing(.disabled("extra_usage_disabled")))
check("off with no reason", verdict(FastReport(state: "off")) == .notServing(.reportedOff))
check("before any call, the cached credits block answers",
      verdict(FastReport(), block: "out_of_credits") == .notServing(.credits("out_of_credits")))
check("a call that ran standard with the block cached names the block, not a shrug",
      verdict(FastReport(state: "on", lastSpeed: "standard"), block: "out_of_credits")
        == .notServing(.credits("out_of_credits")))
check("a call that ran standard with nothing else known",
      verdict(FastReport(state: "on", lastSpeed: "standard")) == .notServing(.ranStandard))
check("the transcript's last call is HISTORY: a fast one does not outrank the cached credits block",
      verdict(FastReport(seededSpeed: "fast"), block: "out_of_credits")
        == .notServing(.credits("out_of_credits")))
check("… on its own it still says the last reply ran fast",
      verdict(FastReport(seededSpeed: "fast")) == .running)
check("… and a live call outranks it either way",
      verdict(FastReport(lastSpeed: "standard", seededSpeed: "fast")) == .notServing(.ranStandard)
      && verdict(FastReport(lastSpeed: "fast", seededSpeed: "standard")) == .running)
check("a transcript that last ran standard, with nothing live",
      verdict(FastReport(seededSpeed: "standard")) == .notServing(.ranStandard))

func block(_ json: String?) -> String? {
    ClaudeFastMode.creditsBlock(claudeJSON: json.map { Data($0.utf8) })
}
check("credits: claude's cached reason is read",
      block(#"{"cachedExtraUsageDisabledReason":"out_of_credits","x":1}"#) == "out_of_credits")
check("credits: null (credits available) is no block",
      block(#"{"cachedExtraUsageDisabledReason":null}"#) == nil)
check("credits: an absent key, another shape, blank, garbage or no file are no block",
      block(#"{"a":1}"#) == nil && block(#"{"cachedExtraUsageDisabledReason":5}"#) == nil
      && block(#"{"cachedExtraUsageDisabledReason":"  "}"#) == nil
      && block("not json") == nil && block(nil) == nil)

// The switch a session with no saved picks opens with. A standard call
// is what every REFUSED call records, so reading it as "off" would
// switch such sessions off while credits are out — and keep them off
// after the credits come back.
check("seed: a fast record turns the switch on",
      ClaudeFastMode.seededSwitch(base: false, newestCallRanFast: true))
check("seed: a standard record never turns it off — a refused call records standard too",
      ClaudeFastMode.seededSwitch(base: true, newestCallRanFast: false))
check("seed: otherwise the sticky prefs answer",
      ClaudeFastMode.seededSwitch(base: true, newestCallRanFast: nil)
      && !ClaudeFastMode.seededSwitch(base: false, newestCallRanFast: nil)
      && !ClaudeFastMode.seededSwitch(base: false, newestCallRanFast: false))

// ─────────────────────────────── 3. the parser and the transcript

section("3. The parser reads every channel; the transcript keeps the speed")

let cwd = URL(fileURLWithPath: "/tmp")
func parse(_ s: String) -> [StreamEvent] { AgentEventParser.parse(line: s, fallbackCwd: cwd) }
let initEvents = parse(line(["type": "system", "subtype": "init", "session_id": "s1",
                             "model": "claude-opus-5-5", "cwd": "/tmp",
                             "fast_mode_state": "off",
                             "fast_mode_disabled_reason": "extra_usage_disabled"]))
check("init: state and reason", initEvents.first?.fastModeState == "off"
      && initEvents.first?.fastModeDisabledReason == "extra_usage_disabled")
let resultEvents = parse(line(["type": "result", "subtype": "success", "duration_ms": 10,
                               "num_turns": 1, "usage": [:], "fast_mode_state": "on"]))
check("result: state, and no reason when none is given",
      resultEvents.first?.fastModeState == "on" && resultEvents.first?.fastModeDisabledReason == nil)
func assistant(_ usage: [String: Any], parent: Any = NSNull(), model: String = "claude-opus-5-5")
-> [String: Any] {
    ["type": "assistant", "parent_tool_use_id": parent,
     "message": ["model": model, "usage": usage,
                 "content": [["type": "text", "text": "OK"],
                             ["type": "tool_use", "id": "t1", "name": "Bash",
                              "input": ["command": "true"]]]]]
}
let mainEvents = parse(line(assistant(["input_tokens": 5, "speed": "standard"])))
check("a main-loop call's speed rides every event of its record",
      mainEvents.count == 2 && mainEvents.allSatisfy { $0.callSpeed == "standard" })
check("a subagent's call says nothing about the session's speed",
      parse(line(assistant(["input_tokens": 5, "speed": "fast"], parent: "toolu_1")))
        .allSatisfy { $0.callSpeed == nil })
check("the harness's own <synthetic> text says nothing either",
      parse(line(assistant(["speed": "standard"], model: "<synthetic>")))
        .allSatisfy { $0.callSpeed == nil })
check("a record with no speed leaves it nil (an older claude)",
      parse(line(assistant(["input_tokens": 5]))).allSatisfy { $0.callSpeed == nil })

let refusalLine = line(["type": "system", "subtype": "notification",
                        "key": ClaudeFastMode.refusalKey, "text": refusalText,
                        "priority": "immediate", "color": "error",
                        "session_id": "s1", "uuid": "u1"])
check("the refusal notification is read, in claude's words",
      AgentEventParser.fastModeRefusal(line: refusalLine) == refusalText)
check("… and the parse itself draws nothing for it", parse(refusalLine).isEmpty)
check("another notification key is not a refusal",
      AgentEventParser.fastModeRefusal(line: line(["type": "system", "subtype": "notification",
                                                   "key": "something-else", "text": "x"])) == nil)
check("a user's text quoting the key is not a refusal",
      AgentEventParser.fastModeRefusal(line: line(["type": "user", "message": [
          "content": "what is \(ClaudeFastMode.refusalKey)?"]])) == nil)

let transcript = scratch.appendingPathComponent("t.jsonl")
let records: [[String: Any]] = [
    ["type": "assistant", "message": ["model": "claude-opus-5-5",
                                      "usage": ["input_tokens": 10, "speed": "fast"]]],
    ["type": "assistant", "message": ["model": "claude-opus-5-5",
                                      "usage": ["input_tokens": 12, "speed": "standard"]]],
    ["type": "assistant", "isSidechain": true,
     "message": ["model": "claude-opus-5-5", "usage": ["input_tokens": 3, "speed": "fast"]]],
]
try? (records.map(line).joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
let seed = AgentSessionScanner.lastContextTokens(of: transcript)
check("the transcript's newest MAIN call names the speed (a newer subagent call does not)",
      seed.speed == "standard" && seed.tokens == 12, "\(seed)")

// ─────────────────────────────────────── 4. codex's speed rule

section("4. Codex: the interactive rule, exec's rule, and the one flag between them")

let fastTier = CodexServiceTier(id: "priority", name: "Fast", description: "1.5x speed")
let ultra = CodexServiceTier(id: "ultrafast", name: "Ultrafast", description: "The fastest")
let sol = CodexSpeed.ModelTiers(tiers: [fastTier], defaultTier: "priority")
let astra = CodexSpeed.ModelTiers(tiers: [fastTier], defaultTier: nil)
let twoTiers = CodexSpeed.ModelTiers(tiers: [fastTier, ultra], defaultTier: nil)
func speed(pick: String?, config: String?, model: CodexSpeed.ModelTiers?, feature: Bool = true)
-> (effective: String?, exec: String?, flag: String?) {
    let e = CodexSpeed.effective(pick: pick, configured: config, model: model, featureEnabled: feature)
    let x = CodexSpeed.execWould(configured: config, model: model, featureEnabled: feature)
    return (e, x, CodexSpeed.override(pick: pick, effective: e, model: model, featureEnabled: feature))
}
func same(_ a: (String?, String?, String?), _ b: (String?, String?, String?)) -> Bool {
    a.0 == b.0 && a.1 == b.1 && a.2 == b.2
}
check("a model that ships Fast: Default runs it, and exec needs telling",
      same(speed(pick: nil, config: nil, model: sol), ("priority", nil, "priority")))
check("… Standard picked: passed as `default` — an explicit pick is always passed",
      same(speed(pick: "default", config: nil, model: sol), (nil, nil, "default")))
check("config says Fast: Default runs it, pinned though exec would run it anyway",
      same(speed(pick: nil, config: "priority", model: astra), ("priority", "priority", "priority")))
check("… Standard picked over it: `default` stops the configured tier",
      same(speed(pick: "default", config: "priority", model: astra), (nil, "priority", "default")))
check("nothing configured, no model default: standard, pinned as `default` like codex's picker",
      same(speed(pick: nil, config: nil, model: astra), (nil, nil, "default")))
check("a second tier picked: passed as itself",
      same(speed(pick: "ultrafast", config: nil, model: twoTiers), ("ultrafast", nil, "ultrafast")))
check("a picked tier the model does not advertise is standard, and passed as such",
      same(speed(pick: "ultrafast", config: nil, model: astra), (nil, nil, "default")))
check("codex's fast_mode feature off: no tier, and nothing pinned unless a speed was picked",
      same(speed(pick: "priority", config: "priority", model: astra, feature: false), (nil, nil, "default"))
      && same(speed(pick: nil, config: "priority", model: astra, feature: false), (nil, nil, nil)))
check("flex passes even then", speed(pick: "flex", config: nil, model: astra, feature: false).effective == "flex"
      && speed(pick: nil, config: "flex", model: astra, feature: false).flag == "flex")
check("`fast` is codex's other spelling of `priority`",
      same(speed(pick: nil, config: "fast", model: astra), ("priority", "priority", "priority")))
check("an opted-out default (`default` in config) keeps a Fast-default model standard",
      same(speed(pick: nil, config: "default", model: sol), (nil, nil, "default")))
check("a model the catalog does not know, followed: the configured tier passes for codex to judge",
      same(speed(pick: nil, config: "priority", model: nil), ("priority", "priority", "priority"))
      && same(speed(pick: nil, config: nil, model: nil), (nil, nil, nil)))
check("… picked: the pick passes through for codex to judge",
      same(speed(pick: "ultrafast", config: nil, model: nil), ("ultrafast", nil, "ultrafast"))
      && same(speed(pick: "default", config: "priority", model: nil), (nil, "priority", "default")))
check("a pick equal to what exec would run anyway is still passed",
      same(speed(pick: "priority", config: "priority", model: astra), ("priority", "priority", "priority")))
check("an unadvertised configured tier: standard, pinned — nothing unadvertised reaches codex",
      same(speed(pick: nil, config: "ultrafast", model: astra), (nil, nil, "default")))

// Codex's merged config, as `config/read` answers it for a folder.
let readAll = CodexSpeed.settings(fromEffectiveConfig: [
    "service_tier": "fast", "model": "gpt-6-astra",
    "features": ["fast_mode": false, "memories": true],
    "notice": ["fast_default_opt_out": true],
])
check("config/read: the tier, the feature and the model are read off codex's merged config",
      readAll == CodexSpeed.Settings(configured: "fast", featureEnabled: false, model: "gpt-6-astra"))
check("… an opt-out with no tier reads as `default`, codex's own configured tier",
      CodexSpeed.settings(fromEffectiveConfig: ["notice": ["fast_default_opt_out": true]]).configured == "default")
check("… JSON null and absent keys read as unset, the feature as on",
      CodexSpeed.settings(fromEffectiveConfig: ["service_tier": NSNull(), "model": NSNull(),
                                                "features": ["fast_mode": NSNull()], "notice": NSNull()])
      == CodexSpeed.Settings(configured: nil, featureEnabled: true, model: nil)
      && CodexSpeed.settings(fromEffectiveConfig: [:]) == CodexSpeed.Settings())
check("… a blank tier or model is unset",
      CodexSpeed.settings(fromEffectiveConfig: ["service_tier": " ", "model": ""]) == CodexSpeed.Settings())
let oddFolder = "/Users/a b/\"quoted\" \\ back/ünï"
let readLine = CodexConfigRead.request(cwd: oddFolder, id: 2) ?? ""
let readObj = (try? JSONSerialization.jsonObject(with: Data(readLine.utf8))) as? [String: Any]
check("the request is codex's config/read with the folder as a JSON string, whatever it spells",
      readObj?["method"] as? String == "config/read" && (readObj?["id"] as? Int) == 2
      && ((readObj?["params"] as? [String: Any])?["cwd"] as? String) == oddFolder
      && !readLine.contains("\n"))
check("the answer's config is read out of result, and an error is no answer",
      CodexConfigRead.config(fromAnswer: ["id": 2, "result": ["config": ["model": "m"]]])?["model"] as? String == "m"
      && CodexConfigRead.config(fromAnswer: ["id": 2, "error": ["message": "x"]]) == nil
      && CodexConfigRead.config(fromAnswer: nil) == nil)
let linked = scratch.appendingPathComponent("linked-folder")
try? fm.createSymbolicLink(at: linked, withDestinationURL: scratch)
check("the folder is asked about by its physical path, as a turn spawned there sees it",
      CodexConfigRead.physicalPath(linked.path) == CodexConfigRead.physicalPath(scratch.path)
      && CodexConfigRead.physicalPath(scratch.path).hasPrefix("/private/")
      && CodexConfigRead.physicalPath("/no/such/folder/here") == "/no/such/folder/here")
check("faster: priority and ultrafast; not flex, standard or none",
      CodexSpeed.isFaster("priority") && CodexSpeed.isFaster("ultrafast") && CodexSpeed.isFaster("fast")
      && !CodexSpeed.isFaster("flex") && !CodexSpeed.isFaster("default") && !CodexSpeed.isFaster(nil))
check("normalisation trims, lowercases and reads blank as absent",
      CodexSpeed.normalized(" Fast ") == "priority" && CodexSpeed.normalized("  ") == nil)

var codexOpts = AgentLaunchOptions(model: "gpt-6-sol")
codexOpts.serviceTier = "priority"
check("a pick alone is never passed raw — only the resolved override is",
      !codexOpts.flags(for: "codex").joined(separator: " ").contains("service_tier"))
codexOpts.codexServiceTierOverride = "priority"
check("the override is passed as codex's own -c key",
      codexOpts.flags(for: "codex").suffix(2) == ["-c", "service_tier=priority"])
codexOpts.codexServiceTierOverride = CodexSpeed.standard
check("… standard as `default`", codexOpts.flags(for: "codex").contains("service_tier=default"))
check("claude and kimi never see a tier",
      !codexOpts.flags(for: "claude_code").joined(separator: " ").contains("service_tier")
      && !codexOpts.flags(for: "kimi").joined(separator: " ").contains("service_tier"))

// A scheduled task's run — unattended exec work. Its own pick travels;
// no pick passes nothing, so the run gets exec's own resolution, which
// never applies a model's catalog default — the task's Default.
func scheduled(_ pick: String?, config: String?, model: CodexSpeed.ModelTiers?,
               feature: Bool = true) -> String? {
    CodexSpeed.scheduled(pick: pick, configured: config, model: model, featureEnabled: feature)
}
check("task, no pick: exec's own resolution — a model's catalog default is not applied",
      scheduled(nil, config: nil, model: sol) == nil
      && speed(pick: nil, config: nil, model: sol).effective == "priority")
check("… the config's tier is", scheduled(nil, config: "priority", model: astra) == "priority"
      && scheduled(nil, config: "fast", model: astra) == "priority")
check("task, a pick: the pick, judged as exec judges a configured tier",
      scheduled("priority", config: nil, model: astra) == "priority"
      && scheduled("default", config: "priority", model: astra) == nil
      && scheduled("ultrafast", config: nil, model: astra) == nil
      && scheduled("ultrafast", config: nil, model: twoTiers) == "ultrafast")
check("task, the feature off: no tier but flex",
      scheduled("priority", config: nil, model: astra, feature: false) == nil
      && scheduled("flex", config: nil, model: astra, feature: false) == "flex")

// One Fast mode switch per agent: codex's turns on the model's Fast tier.
let fastByName = CodexServiceTier(id: "turbo", name: "Fast", description: "")
check("the switch's tier is the one codex sends as priority, first",
      CodexSpeed.fastTier(twoTiers)?.id == "priority"
      && CodexSpeed.fastTier(CodexSpeed.ModelTiers(tiers: [ultra, fastTier], defaultTier: nil))?.id == "priority")
check("… else the one codex names Fast, else the first advertised",
      CodexSpeed.fastTier(CodexSpeed.ModelTiers(tiers: [ultra, fastByName], defaultTier: nil))?.id == "turbo"
      && CodexSpeed.fastTier(CodexSpeed.ModelTiers(tiers: [ultra], defaultTier: nil))?.id == "ultrafast")
check("… and a model with no tier offers no switch",
      CodexSpeed.fastTier(CodexSpeed.ModelTiers(tiers: [], defaultTier: nil)) == nil
      && CodexSpeed.fastTier(nil) == nil)
check("a task scheduled from a composer keeps the composer's pick",
      CodexSpeed.carriedToTask(pick: "default", effective: nil) == "default"
      && CodexSpeed.carriedToTask(pick: "fast", effective: "priority") == "priority")
check("… and, with none, a faster tier codex turns on by itself — written out, since a task's run would not apply it",
      CodexSpeed.carriedToTask(pick: nil, effective: "priority") == "priority"
      && speed(pick: nil, config: nil, model: sol).effective == "priority"
      && scheduled(nil, config: nil, model: sol) == nil
      && scheduled(CodexSpeed.carriedToTask(pick: nil, effective: "priority"),
                   config: nil, model: sol) == "priority")
check("… while a standard composer leaves the task on Default",
      CodexSpeed.carriedToTask(pick: nil, effective: nil) == nil
      && CodexSpeed.carriedToTask(pick: nil, effective: "flex") == nil)

func taskRun(_ agent: String, model: String?, fast: Bool, tier: String?) -> AgentLaunchOptions {
    AgentLaunchOptions.scheduledRun(agent: agent, mode: nil, model: model, effort: "high",
                                    fastMode: fast, serviceTier: tier)
}
let claudeTask = taskRun("claude_code", model: "opus", fast: true, tier: "priority")
check("a claude task's fast mode travels as claude's own opt-in",
      claudeTask.flags(for: "claude_code").suffix(2)
        == ["--settings", AgentLaunchOptions.claudeFastModeSettings])
check("… a codex tier on its file does not travel with it",
      claudeTask.codexServiceTierOverride == nil
      && !claudeTask.flags(for: "claude_code").joined(separator: " ").contains("service_tier"))
check("… and a claude task without it asks for nothing",
      !taskRun("claude_code", model: "opus", fast: false, tier: nil)
        .flags(for: "claude_code").contains("--settings"))
let codexTask = taskRun("codex", model: "gpt-6-astra", fast: true, tier: "fast")
check("a codex task's pick travels as codex's -c key, normalised, and claude's switch does not",
      codexTask.flags(for: "codex").suffix(2) == ["-c", "service_tier=priority"] && !codexTask.fastMode)
check("… Standard travels as `default`, stopping a configured tier",
      taskRun("codex", model: nil, fast: false, tier: "default").flags(for: "codex").suffix(2)
        == ["-c", "service_tier=default"])
check("… Default passes nothing — exec's own resolution",
      !taskRun("codex", model: "gpt-6-astra", fast: false, tier: nil)
        .flags(for: "codex").joined(separator: " ").contains("service_tier"))
let kimiTask = taskRun("kimi", model: "k", fast: true, tier: "priority")
check("kimi takes neither", !kimiTask.fastMode && kimiTask.codexServiceTierOverride == nil
      && kimiTask.flags(for: "kimi") == ["--model", "k"])
check("mode, model and effort ride as they did",
      AgentLaunchOptions.scheduledRun(agent: "claude_code", mode: "bypassPermissions", model: "opus",
                                      effort: "max", fastMode: false, serviceTier: nil)
        == AgentLaunchOptions(permissionMode: "bypassPermissions", model: "opus", effort: "max"))

// ─────────────────────────────────── 5. codex's own files and answers

section("5. Codex: the config, the cache and model/list are read as codex spells them")

let cfgPlain = CodexCatalog.parseConfigDefaults("""
model = "gpt-6-astra"
service_tier = "priority"

[projects."/x"]
trust_level = "trusted"
""")
check("config: the top-level service_tier", cfgPlain.serviceTier == "priority" && cfgPlain.fastModeFeature == nil)
let cfgOff = CodexCatalog.parseConfigDefaults("""
model = "gpt-6-astra"
[features]
js_repl = false
fast_mode = false # off
""")
check("config: [features] fast_mode = false (a trailing comment allowed)", cfgOff.fastModeFeature == false)
check("config: the dotted spelling counts too",
      CodexCatalog.parseConfigDefaults("features.fast_mode = false\n").fastModeFeature == false)
let cfgOptOut = CodexCatalog.parseConfigDefaults("""
model = "gpt-6-sol"
[notice]
fast_default_opt_out = true
""")
check("config: [notice] fast_default_opt_out reads as `default`", cfgOptOut.serviceTier == "default")
check("config: an explicit tier outranks the opt-out",
      CodexCatalog.parseConfigDefaults("service_tier = \"priority\"\n[notice]\nfast_default_opt_out = true\n")
        .serviceTier == "priority")
check("config: a service_tier under [profiles.x] is not the global one",
      CodexCatalog.parseConfigDefaults("model = \"a\"\n[profiles.fast]\nservice_tier = \"priority\"\n")
        .serviceTier == nil)
check("config: the other keys still read (a table above them does not end the file for the tables)",
      cfgOff.model == "gpt-6-astra" && cfgPlain.model == "gpt-6-astra")
check("config: a TOML literal string ('…') reads like a basic one",
      CodexCatalog.parseConfigDefaults("service_tier = 'priority'\n").serviceTier == "priority")
check("config: a trailing comment after the value is not part of it",
      CodexCatalog.parseConfigDefaults("service_tier = \"priority\" # the fast one\n").serviceTier == "priority")
check("config: a header carrying a comment still opens its table",
      CodexCatalog.parseConfigDefaults("[features] # flags\nfast_mode = false\n").fastModeFeature == false)
check("toml: a basic string unescapes \\\" and \\\\, a literal keeps backslashes",
      TomlScalar.string(#"k = "a\"b\\c""#, key: "k") == #"a"b\c"#
      && TomlScalar.string(#"k = 'C:\x'"#, key: "k") == #"C:\x"#)
check("toml: a multi-line string, two values or an open quote read as nothing, never a guess",
      TomlScalar.string(#"k = """x""""#, key: "k") == nil
      && TomlScalar.string(#"k = "a" "b""#, key: "k") == nil
      && TomlScalar.string(#"k = "open"#, key: "k") == nil)
check("toml: a key is matched whole (`model` does not read `model_provider`)",
      TomlScalar.string(#"model_provider = "x""#, key: "model") == nil)

let cache = Data("""
{"client_version":"x","fetched_at":"2026-01-01T00:00:00Z","models":[
{"slug":"m-two","display_name":"Two","priority":1,"visibility":"list",
 "service_tiers":[{"id":"priority","name":"Fast","description":"1.5x speed"},
                  {"id":"ultrafast","name":"Ultrafast","description":"The fastest"}],
 "default_service_tier":"priority"},
{"slug":"m-none","display_name":"None","priority":2,"visibility":"list","service_tiers":[]}
]}
""".utf8)
let parsed = CodexCatalog.parseModelsCache(cache, contextWindowOverride: nil).visible
check("cache: every tier, in order, with the catalog default",
      parsed.first?.serviceTiers.map(\.id) == ["priority", "ultrafast"]
      && parsed.first?.defaultServiceTier == "priority")
check("cache: a model listing none has none", parsed.last?.serviceTiers.isEmpty == true)

let answer: [String: Any] = ["id": 2, "result": ["data": [
    ["model": "gpt-6-sol", "serviceTiers": [["id": "priority", "name": "Fast", "description": "1.5x speed"]],
     "defaultServiceTier": "priority"],
    ["id": "gpt-5.6-sol", "serviceTiers": [["id": "priority", "name": "Fast", "description": "d"],
                                           ["id": "ultrafast", "name": "Ultrafast", "description": "u"]],
     "defaultServiceTier": NSNull()],
    ["model": "no-tier-keys"],
] as [Any]]]
let listed = CodexCatalog.listedTiers(fromAnswer: answer)
check("model/list: tiers and default per model",
      listed["gpt-6-sol"]?.defaultTier == "priority" && listed["gpt-6-sol"]?.tiers.map(\.id) == ["priority"])
check("model/list: `id` stands in for `model`, and a null default is none",
      listed["gpt-5.6-sol"]?.tiers.count == 2 && listed["gpt-5.6-sol"]?.defaultTier == nil)
check("model/list: a model naming neither key is left to the cache", listed["no-tier-keys"] == nil)
check("model/list: an error answer, or none, names nothing",
      CodexCatalog.listedTiers(fromAnswer: ["id": 2, "error": ["message": "x"]]).isEmpty
      && CodexCatalog.listedTiers(fromAnswer: nil).isEmpty)

// ─────────────────────────── helpers for the two live sections

let fakeServerScript = harnessDir + "/../ChatOnlyMode/fake_server.py"

func startFakeServer(recordDir: URL, extra: [String] = []) -> (process: Process, port: Int)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [fakeServerScript, recordDir.path] + extra
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    var text = ""
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, !text.contains("\n") {
        let chunk = out.fileHandleForReading.availableData
        if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05); continue }
        text += String(decoding: chunk, as: UTF8.self)
    }
    guard let r = text.range(of: "PORT="),
          let port = Int(text[r.upperBound...].prefix { $0.isNumber }) else {
        p.terminate()
        return nil
    }
    return (p, port)
}

/// The recorded requests, oldest first, whose path ends in `suffix`.
func requests(in dir: URL, pathSuffix suffix: String) -> [[String: Any]] {
    ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().compactMap { name in
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let path = obj["path"] as? String,
              path.split(separator: "?").first.map({ $0.hasSuffix(suffix) }) == true
        else { return nil }
        return (obj["body"] as? [String: Any]) ?? [:]
    }
}
func clear(_ dir: URL) {
    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
        try? fm.removeItem(at: dir.appendingPathComponent(name))
    }
}

/// Run a child to completion (bounded), stdout captured through a file
/// so a chatty child cannot fill a pipe and stall.
func run(_ exe: String, _ args: [String], environment: [String: String], cwd: URL,
         timeout: TimeInterval = 90) -> (status: Int32, out: String) {
    let outFile = scratch.appendingPathComponent("out-\(UUID().uuidString.prefix(8))")
    fm.createFile(atPath: outFile.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: outFile) else { return (-1, "") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = environment
    p.currentDirectoryURL = cwd
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = handle
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if p.isRunning { p.terminate() }
    p.waitUntilExit()
    try? handle.close()
    let text = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
    try? fm.removeItem(at: outFile)
    return (p.terminationStatus, text)
}

// ───────────────────────── 6. the live claude, against a refusing API

section("6. The installed claude, fast mode refused for want of credits (fake endpoint, token-free)")

/// The report the runner builds, fed the way the runner feeds it.
func report(fromStdout out: String) -> (report: FastReport, sessionId: String?) {
    var r = FastReport()
    var sid: String? = nil
    for raw in out.split(separator: "\n") {
        let l = String(raw)
        if let text = AgentEventParser.fastModeRefusal(line: l) {
            r.refusal = text
            r.lastSpeed = "standard"
        }
        for event in parse(l) {
            if let state = event.fastModeState {
                r.state = state
                r.disabledReason = event.fastModeDisabledReason
            }
            if let s = event.callSpeed { r.lastSpeed = s }
            if case .systemInit(let id, _, _) = event.kind, !id.isEmpty { sid = id }
        }
    }
    return (r, sid)
}

func claudeRun(_ claude: String, model: String, optIn: Bool, port: Int, home: URL) -> String {
    let cfg = home.appendingPathComponent("cfg", isDirectory: true)
    try? fm.createDirectory(at: cfg, withIntermediateDirectories: true)
    let linkDir = URL(fileURLWithPath: claude).deletingLastPathComponent().path
    var args = ["-p", "Reply with OK.", "--output-format", "stream-json", "--verbose",
                "--model", model]
    if optIn { args += ["--settings", AgentLaunchOptions.claudeFastModeSettings] }
    return run(claude, args, environment: [
        "PATH": "\(linkDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "HOME": home.path,
        "CLAUDE_CONFIG_DIR": cfg.path,
        "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)",
        "ANTHROPIC_API_KEY": "sk-ant-harness-junk",
        // Fast mode's organisation check goes to Anthropic's own host,
        // not the base URL; the junk key would only fail it there.
        "CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK": "1",
    ], cwd: home).out
}

func transcriptSpeed(home: URL, sessionId: String?) -> String? {
    guard let sid = sessionId else { return nil }
    let projects = home.appendingPathComponent("cfg/projects")
    let match = ((try? fm.subpathsOfDirectory(atPath: projects.path)) ?? [])
        .first { $0.hasSuffix(sid + ".jsonl") }
    return match.flatMap { AgentSessionScanner.lastContextTokens(of: projects.appendingPathComponent($0)).speed }
}

if let claude = realClaude, fm.fileExists(atPath: fakeServerScript) {
    let fastModel = installedCatalog?.entries
        .first { ($0.capabilities ?? []).contains("fast_mode") }?.firstPartyId ?? "claude-opus-5-5"
    note("model: \(fastModel)")

    // (a) Credits out: every call is asked fast, refused, re-sent.
    let recA = scratch.appendingPathComponent("recA", isDirectory: true)
    try? fm.createDirectory(at: recA, withIntermediateDirectories: true)
    if let server = startFakeServer(recordDir: recA, extra: ["--refuse-fast", "out_of_credits"]) {
        let homeA = scratch.appendingPathComponent("homeA", isDirectory: true)
        try? fm.createDirectory(at: homeA, withIntermediateDirectories: true)
        let out = claudeRun(claude, model: fastModel, optIn: true, port: server.port, home: homeA)
        let sent = requests(in: recA, pathSuffix: "/messages").filter { $0["messages"] != nil }
        let (r, sid) = report(fromStdout: out)
        check("the opt-in reaches the wire: the first call asks for speed \"fast\"",
              (sent.first?["speed"] as? String) == "fast", "\(sent.map { $0["speed"] ?? "none" })")
        check("the refused call is re-sent at standard speed (no speed field)",
              sent.count >= 2 && sent[1]["speed"] == nil)
        check("claude says so in its own words, and the reader has them",
              !(r.refusal ?? "").isEmpty, r.refusal ?? "none")
        check("claude still reports fast_mode_state \"on\" — why the chip cannot trust it alone",
              r.state == "on", r.state ?? "none")
        check("the call's own speed says standard", r.lastSpeed == "standard", r.lastSpeed ?? "none")
        check("the verdict: requested, and refused in claude's words",
              verdict(r) == .notServing(.refused(r.refusal ?? "")))
        check("the transcript keeps the outcome for the next open",
              transcriptSpeed(home: homeA, sessionId: sid) == "standard")
        server.process.terminate(); server.process.waitUntilExit()
    } else { note("the fake endpoint did not start — (a) skipped") }

    // (b) Credits fine: served fast, asked once.
    let recB = scratch.appendingPathComponent("recB", isDirectory: true)
    try? fm.createDirectory(at: recB, withIntermediateDirectories: true)
    if let server = startFakeServer(recordDir: recB) {
        let homeB = scratch.appendingPathComponent("homeB", isDirectory: true)
        try? fm.createDirectory(at: homeB, withIntermediateDirectories: true)
        let out = claudeRun(claude, model: fastModel, optIn: true, port: server.port, home: homeB)
        let sent = requests(in: recB, pathSuffix: "/messages").filter { $0["messages"] != nil }
        let (r, sid) = report(fromStdout: out)
        check("served: one fast request, no re-send",
              sent.count == 1 && (sent.first?["speed"] as? String) == "fast",
              "\(sent.map { $0["speed"] ?? "none" })")
        check("served: no refusal, the call ran fast, the verdict says running",
              r.refusal == nil && r.lastSpeed == "fast" && verdict(r) == .running)
        check("served: the transcript says fast", transcriptSpeed(home: homeB, sessionId: sid) == "fast")
        clear(recB)
        // (c) The same claude without the opt-in never asks at all.
        let homeC = scratch.appendingPathComponent("homeC", isDirectory: true)
        try? fm.createDirectory(at: homeC, withIntermediateDirectories: true)
        let outC = claudeRun(claude, model: fastModel, optIn: false, port: server.port, home: homeC)
        let sentC = requests(in: recB, pathSuffix: "/messages").filter { $0["messages"] != nil }
        let (rc, _) = report(fromStdout: outC)
        check("without the opt-in no call asks for fast mode",
              !sentC.isEmpty && sentC.allSatisfy { $0["speed"] == nil })
        note("without the opt-in claude reports fast_mode_state \(rc.state ?? "none")"
             + (rc.disabledReason.map { ", reason \($0)" } ?? ""))
        server.process.terminate(); server.process.waitUntilExit()
    } else { note("the fake endpoint did not start — (b)/(c) skipped") }

    // (d) Usage credits refused for a reason other than running out:
    // claude says nothing in the turn, switches fast mode off for the
    // session, and names the reason on the result.
    let recD = scratch.appendingPathComponent("recD", isDirectory: true)
    try? fm.createDirectory(at: recD, withIntermediateDirectories: true)
    if let server = startFakeServer(recordDir: recD, extra: ["--refuse-fast", "org_level_disabled"]) {
        let homeD = scratch.appendingPathComponent("homeD", isDirectory: true)
        try? fm.createDirectory(at: homeD, withIntermediateDirectories: true)
        let (r, _) = report(fromStdout: claudeRun(claude, model: fastModel, optIn: true,
                                                   port: server.port, home: homeD))
        check("credits turned off by the organisation: no notification, fast_mode_state off with claude's reason",
              r.refusal == nil && r.state == "off" && r.disabledReason == "extra_usage_disabled",
              "\(r)")
        check("… and the verdict names that reason",
              verdict(r) == .notServing(.disabled("extra_usage_disabled")))
        server.process.terminate(); server.process.waitUntilExit()
    } else { note("the fake endpoint did not start — (d) skipped") }

    // (e) A rate limit on the fast request with a long retry-after:
    // claude pauses fast mode, re-sends at standard, reports cooldown.
    let recE = scratch.appendingPathComponent("recE", isDirectory: true)
    try? fm.createDirectory(at: recE, withIntermediateDirectories: true)
    if let server = startFakeServer(recordDir: recE, extra: ["--rate-limit-fast", "120"]) {
        let homeE = scratch.appendingPathComponent("homeE", isDirectory: true)
        try? fm.createDirectory(at: homeE, withIntermediateDirectories: true)
        let (r, _) = report(fromStdout: claudeRun(claude, model: fastModel, optIn: true,
                                                   port: server.port, home: homeE))
        let sent = requests(in: recE, pathSuffix: "/messages").filter { $0["messages"] != nil }
        check("a long rate limit: the call is re-sent at standard speed and claude reports cooldown",
              sent.count >= 2 && sent.last?["speed"] == nil && r.state == "cooldown",
              "\(sent.map { $0["speed"] ?? "none" }) state \(r.state ?? "none")")
        check("… and the verdict says paused", verdict(r) == .notServing(.cooldown))
        server.process.terminate(); server.process.waitUntilExit()
    } else { note("the fake endpoint did not start — (e) skipped") }
} else {
    note("no installed claude, or no fake endpoint script — section skipped")
}

// ─────────────────────────────── 7. the live codex, against exec

section("7. The installed codex runs exactly the tier the composer names (fake endpoint, token-free)")

let realCodex = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", realHome + "/.local/bin/codex"]
    .first { fm.isExecutableFile(atPath: $0) }

/// One app-server request, answered by the installed binary under a
/// throwaway home — `model/list` from its bundled catalog, since
/// nothing there is signed in; `config/read` from disk. stdin stays
/// open until the answer arrives: codex exits at EOF before answering
/// anything still queued.
func appServerAnswer(codex: String, home: URL, environment: [String: String],
                     request: String) -> [String: Any]? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: codex)
    p.arguments = ["app-server"]
    var env = environment
    env["CODEX_HOME"] = home.path
    p.environment = env
    let input = Pipe(), output = Pipe()
    p.standardInput = input
    p.standardOutput = output
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let lines = CodexAppServerHandshake.lines + [request]
    input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    let lock = NSLock()
    var buffer = Data()
    output.fileHandleForReading.readabilityHandler = { h in
        let chunk = h.availableData
        lock.lock(); buffer.append(chunk); lock.unlock()
    }
    var found: [String: Any]? = nil
    let deadline = Date().addingTimeInterval(40)
    while found == nil && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
        lock.lock(); let data = buffer; lock.unlock()
        for raw in data.split(separator: UInt8(ascii: "\n")) {
            if let obj = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any],
               (obj["id"] as? NSNumber)?.intValue == 2 { found = obj }
        }
    }
    output.fileHandleForReading.readabilityHandler = nil
    try? input.fileHandleForWriting.close()
    p.terminate()
    p.waitUntilExit()
    return found
}

enum CodexAppServerHandshake {
    static let lines = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"sipai","title":"SipAI","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
    ]
}

if let codex = realCodex, fm.fileExists(atPath: fakeServerScript) {
    let linkDir = URL(fileURLWithPath: codex).deletingLastPathComponent().path
    let baseEnv = ["PATH": "\(linkDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                   "HOME": scratch.path]
    let listHome = scratch.appendingPathComponent("codex-list", isDirectory: true)
    try? fm.createDirectory(at: listHome, withIntermediateDirectories: true)
    let tiers = CodexCatalog.listedTiers(fromAnswer: appServerAnswer(
        codex: codex, home: listHome, environment: baseEnv,
        request: #"{"jsonrpc":"2.0","id":2,"method":"model/list","params":{}}"#))
    check("the installed codex answers model/list with tiers, offline", !tiers.isEmpty)
    let withDefault = tiers.first { $0.value.defaultTier != nil && !$0.value.tiers.isEmpty }?.key
    let noDefault = tiers.first { $0.value.defaultTier == nil
        && $0.value.tiers.contains { $0.id == "priority" } }?.key
    let multi = tiers.first { $0.value.tiers.count >= 2 }
    note("a model with a default tier: \(withDefault ?? "none"); without: \(noDefault ?? "none"); two or more: \(multi?.key ?? "none")")

    let rec = scratch.appendingPathComponent("recX", isDirectory: true)
    try? fm.createDirectory(at: rec, withIntermediateDirectories: true)
    if let server = startFakeServer(recordDir: rec) {
        /// One exec turn under a fresh throwaway CODEX_HOME — its own
        /// `config.toml` naming `userModel`, and optionally a project
        /// `.codex/config.toml` in the working folder, trusted or not.
        /// With `read`, codex is first asked for its merged config there
        /// through the REAL request and parse (`CodexConfigRead`), and
        /// the argv is built from that answer, as a composer send is.
        func probe(userModel: String, config extra: String, project: String? = nil,
                   trusted: Bool = false, read: Bool = false,
                   argvFor makeArgv: (CodexSpeed.Settings?) -> [String])
        -> (ran: Bool, tier: String?, model: String?, settings: CodexSpeed.Settings?) {
            let home = scratch.appendingPathComponent("codex-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let work = home.appendingPathComponent("cwd", isDirectory: true)
            try? fm.createDirectory(at: work, withIntermediateDirectories: true)
            if let project {
                let dot = work.appendingPathComponent(".codex", isDirectory: true)
                try? fm.createDirectory(at: dot, withIntermediateDirectories: true)
                try? project.write(to: dot.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            }
            // Codex matches trust against the physical path, as a turn
            // spawned in the folder reports it.
            let trust = trusted
                ? "[projects.\"\(CodexConfigRead.physicalPath(work.path))\"]\ntrust_level = \"trusted\"\n" : ""
            let config = """
            model_provider = "fake"
            model = "\(userModel)"
            \(extra)

            [model_providers.fake]
            name = "fake"
            base_url = "http://127.0.0.1:\(server.port)"
            wire_api = "responses"

            \(trust)
            """
            try? config.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            var settings: CodexSpeed.Settings? = nil
            if read, let line = CodexConfigRead.request(cwd: CodexConfigRead.physicalPath(work.path), id: 2),
               let merged = CodexConfigRead.config(fromAnswer: appServerAnswer(
                   codex: codex, home: home, environment: baseEnv, request: line)) {
                settings = CodexSpeed.settings(fromEffectiveConfig: merged)
            }
            clear(rec)
            var env = baseEnv
            env["CODEX_HOME"] = home.path
            _ = run(codex, ["exec", "--json", "--skip-git-repo-check"] + makeArgv(settings) + ["hi"],
                    environment: env, cwd: work)
            let sent = requests(in: rec, pathSuffix: "/responses")
            try? fm.removeItem(at: home)
            guard let body = sent.last else { return (false, nil, nil, settings) }
            return (true, body["service_tier"] as? String, body["model"] as? String, settings)
        }
        func sentTier(model: String, config extra: String, argv: [String]) -> (ran: Bool, tier: String?) {
            let r = probe(userModel: model, config: extra, argvFor: { _ in argv })
            return (r.ran, r.tier)
        }
        /// A composer send: codex's answer for the folder, the pick, and
        /// the model's tiers from model/list, resolved by the REAL rule
        /// into the REAL argv — against what the request then carries,
        /// and against the tier the case expects, so a read that came
        /// back empty cannot pass by agreeing with itself.
        func composerSend(_ label: String, userModel: String, pickModel: String?, pick: String?,
                          configLine: String = "", project: String? = nil, trusted: Bool = false,
                          expect: String?) {
            var stated: String? = nil
            let r = probe(userModel: userModel, config: configLine, project: project,
                          trusted: trusted, read: true) { settings in
                let s = settings ?? CodexSpeed.Settings()
                let modelTiers = (pickModel ?? s.model).flatMap { tiers[$0] }
                var options = AgentLaunchOptions(model: pickModel)
                options.serviceTier = pick
                stated = CodexSpeed.effective(pick: pick, configured: s.configured,
                                              model: modelTiers, featureEnabled: s.featureEnabled)
                options.codexServiceTierOverride = CodexSpeed.override(
                    pick: pick, effective: stated, model: modelTiers, featureEnabled: s.featureEnabled)
                return options.flags(for: "codex")
            }
            check("\(label): the composer says \(stated ?? "standard"), the request carries \(r.tier ?? "none")",
                  r.ran && r.settings != nil && r.tier == stated && stated == expect,
                  !r.ran ? "(codex did not reach the endpoint)"
                  : r.settings == nil ? "(codex did not answer config/read)"
                  : "expected \(expect ?? "standard")")
        }

        if let sol = withDefault, let solTiers = tiers[sol], let solDefault = solTiers.defaultTier {
            let bare = sentTier(model: sol, config: "", argv: [])
            check("\(sol) with nothing passed: exec ignores the catalog default (\(solDefault)) — why the composer passes it",
                  bare.ran && bare.tier == nil, bare.tier ?? "none")
            composerSend("\(sol), Default", userModel: sol, pickModel: sol, pick: nil, expect: solDefault)
            composerSend("\(sol), Standard", userModel: sol, pickModel: sol, pick: CodexSpeed.standard, expect: nil)
            composerSend("\(sol), Default under an opted-out config", userModel: sol, pickModel: sol, pick: nil,
                         configLine: "[notice]\nfast_default_opt_out = true", expect: nil)
        } else { note("no listed model ships a default tier — those cases skipped") }

        if let astra = noDefault {
            composerSend("\(astra), Default under a config asking for priority", userModel: astra,
                         pickModel: astra, pick: nil, configLine: "service_tier = \"priority\"",
                         expect: "priority")
            composerSend("\(astra), Standard over that config", userModel: astra, pickModel: astra,
                         pick: CodexSpeed.standard, configLine: "service_tier = \"priority\"", expect: nil)
            composerSend("\(astra), Fast picked", userModel: astra, pickModel: astra, pick: "priority",
                         expect: "priority")
            let off = sentTier(model: astra, config: "[features]\nfast_mode = false",
                               argv: ["-c", "service_tier=priority"])
            check("\(astra): with codex's fast_mode feature off, codex drops even an explicit tier",
                  off.ran && off.tier == nil, off.tier ?? "none")
            composerSend("\(astra), Fast picked with the feature off", userModel: astra, pickModel: astra,
                         pick: "priority", configLine: "[features]\nfast_mode = false", expect: nil)

            // A trusted project's own `.codex/config.toml` sits above the
            // user's file — invisible to a read of that file alone, which
            // is why the composer asks codex about the folder.
            let projectTier = "service_tier = \"priority\"\n"
            let trustedRead = probe(userModel: astra, config: "", project: projectTier, trusted: true,
                                    read: true, argvFor: { _ in [] })
            check("config/read: a trusted project's service_tier is in codex's answer, and exec runs it",
                  trustedRead.settings?.configured == "priority" && trustedRead.ran
                  && trustedRead.tier == "priority",
                  "\(trustedRead.settings?.configured ?? "none") / \(trustedRead.tier ?? "none")")
            let untrustedRead = probe(userModel: astra, config: "", project: projectTier, trusted: false,
                                      read: true, argvFor: { _ in [] })
            check("… an untrusted project's is not, and exec ignores it too",
                  untrustedRead.settings != nil && untrustedRead.settings?.configured == nil
                  && untrustedRead.ran && untrustedRead.tier == nil,
                  "\(untrustedRead.settings?.configured ?? "none") / \(untrustedRead.tier ?? "none")")
            check("… the user's file alone would have stated standard there",
                  CodexSpeed.effective(pick: nil,
                                       configured: CodexCatalog.parseConfigDefaults("model = \"\(astra)\"\n").serviceTier,
                                       model: tiers[astra], featureEnabled: true) == nil)
            composerSend("\(astra), Default in a trusted project asking for priority", userModel: astra,
                         pickModel: astra, pick: nil, project: projectTier, trusted: true,
                         expect: "priority")
            composerSend("\(astra), Standard picked in that project", userModel: astra, pickModel: astra,
                         pick: CodexSpeed.standard, project: projectTier, trusted: true, expect: nil)
            composerSend("\(astra), Default in the same project untrusted", userModel: astra,
                         pickModel: astra, pick: nil, project: projectTier, trusted: false, expect: nil)
            // An answer from before the project's file was edited: the
            // composer states what it was told (standard), and the pinned
            // `default` holds the turn to that — passing nothing, as the
            // rule once did when exec seemed to agree, would have let the
            // project's new tier run under a chip saying Standard (the
            // trusted read above: nothing passed, priority sent).
            let before = CodexSpeed.Settings(configured: nil, featureEnabled: true, model: astra)
            var pinned: String? = nil
            let stale = probe(userModel: astra, config: "", project: projectTier, trusted: true) { _ in
                var options = AgentLaunchOptions(model: astra)
                let stated = CodexSpeed.effective(pick: nil, configured: before.configured,
                                                  model: tiers[astra], featureEnabled: before.featureEnabled)
                options.codexServiceTierOverride = CodexSpeed.override(
                    pick: nil, effective: stated, model: tiers[astra], featureEnabled: before.featureEnabled)
                pinned = options.codexServiceTierOverride
                return options.flags(for: "codex")
            }
            check("an answer older than the project's edit: Standard stated, `default` pinned, none sent",
                  pinned == CodexSpeed.standard && stale.ran && stale.tier == nil,
                  "pinned \(pinned ?? "nothing"), sent \(stale.tier ?? "none")")

            // The project may name the model too: with no pick, the turn
            // runs the project's model, and its tiers are what count.
            if let sol = withDefault, let solDefault = tiers[sol]?.defaultTier {
                let projectModel = "model = \"\(sol)\"\n"
                let byProject = probe(userModel: astra, config: "", project: projectModel, trusted: true,
                                      read: true, argvFor: { _ in [] })
                check("config/read: a trusted project's model is codex's answer, and exec runs it",
                      byProject.settings?.model == sol && byProject.ran && byProject.model == sol,
                      "\(byProject.settings?.model ?? "none") / \(byProject.model ?? "none")")
                composerSend("Default model in a project naming \(sol): its default tier", userModel: astra,
                             pickModel: nil, pick: nil, project: projectModel, trusted: true,
                             expect: solDefault)
            }
        } else { note("no listed model offers priority without a default — those cases skipped") }

        // Resumed turns — every SipAI send after a thread's first — re-resolve
        // the tier on their own; what one send passed is not remembered.
        // The override rule depends on it.
        if let astra = noDefault {
            let home = scratch.appendingPathComponent("codex-resume", isDirectory: true)
            let work = home.appendingPathComponent("cwd", isDirectory: true)
            try? fm.createDirectory(at: work, withIntermediateDirectories: true)
            try? """
            model_provider = "fake"
            model = "\(astra)"

            [model_providers.fake]
            name = "fake"
            base_url = "http://127.0.0.1:\(server.port)"
            wire_api = "responses"

            """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            var env = baseEnv
            env["CODEX_HOME"] = home.path
            clear(rec)
            let first = run(codex, ["exec", "--json", "--skip-git-repo-check", "-c", "service_tier=priority", "one"],
                            environment: env, cwd: work)
            let firstTier = requests(in: rec, pathSuffix: "/responses").last?["service_tier"] as? String
            let thread = first.out.split(separator: "\n").compactMap { line -> String? in
                guard line.contains("thread.started"), let at = line.firstIndex(of: "{"),
                      let obj = (try? JSONSerialization.jsonObject(with: Data(line[at...].utf8))) as? [String: Any]
                else { return nil }
                return obj["thread_id"] as? String
            }.first
            if let thread {
                clear(rec)
                _ = run(codex, ["exec", "resume", "--json", "--skip-git-repo-check", thread, "two"],
                        environment: env, cwd: work)
                let resumed = requests(in: rec, pathSuffix: "/responses").last
                check("a resumed thread does not remember its tier: priority, then nothing passed, then none",
                      firstTier == "priority" && resumed != nil && resumed?["service_tier"] == nil,
                      "\(firstTier ?? "none") → \(resumed?["service_tier"] ?? "none")")
            } else {
                check("the resume probe got a thread id", false, String(first.out.prefix(160)))
            }
            try? fm.removeItem(at: home)
        }

        if let multi, let other = multi.value.tiers.first(where: { $0.id != "priority" }) {
            composerSend("\(multi.key), \(other.name) picked", userModel: multi.key, pickModel: multi.key,
                         pick: other.id, expect: other.id)
        } else { note("no listed model offers two tiers — that case skipped") }

        /// A scheduled task's run: the REAL builder's argv, the tier the
        /// task card states (`CodexSpeed.scheduled` over codex's answer
        /// for the folder), and what the request then carries.
        func taskSend(_ label: String, userModel: String, pick: String?,
                      configLine: String = "", project: String? = nil, trusted: Bool = false,
                      expect: String?) {
            var stated: String? = nil
            let r = probe(userModel: userModel, config: configLine, project: project,
                          trusted: trusted, read: true) { settings in
                let s = settings ?? CodexSpeed.Settings()
                stated = CodexSpeed.scheduled(pick: pick, configured: s.configured,
                                              model: tiers[userModel], featureEnabled: s.featureEnabled)
                return AgentLaunchOptions.scheduledRun(agent: "codex", mode: nil, model: userModel,
                                                       effort: nil, fastMode: false,
                                                       serviceTier: pick).flags(for: "codex")
            }
            check("task: \(label): the card says \(stated ?? "standard"), the request carries \(r.tier ?? "none")",
                  r.ran && r.settings != nil && r.tier == stated && stated == expect,
                  !r.ran ? "(codex did not reach the endpoint)"
                  : r.settings == nil ? "(codex did not answer config/read)"
                  : "expected \(expect ?? "standard")")
        }
        if let sol = withDefault {
            taskSend("\(sol), Default: its catalog default is not applied unattended", userModel: sol,
                     pick: nil, expect: nil)
            if let solDefault = tiers[sol]?.defaultTier {
                taskSend("\(sol), its default tier picked", userModel: sol, pick: solDefault,
                         expect: solDefault)
            }
        }
        if let astra = noDefault {
            taskSend("\(astra), Default under a config asking for priority", userModel: astra,
                     pick: nil, configLine: "service_tier = \"priority\"", expect: "priority")
            taskSend("\(astra), Standard over that config", userModel: astra,
                     pick: CodexSpeed.standard, configLine: "service_tier = \"priority\"", expect: nil)
            taskSend("\(astra), Fast picked", userModel: astra, pick: "priority", expect: "priority")
            taskSend("\(astra), Default in a trusted project asking for priority", userModel: astra,
                     pick: nil, project: "service_tier = \"priority\"\n", trusted: true,
                     expect: "priority")
        }

        server.process.terminate(); server.process.waitUntilExit()
    } else { note("the fake endpoint did not start — section skipped") }
} else {
    note("no installed codex, or no fake endpoint script — section skipped")
}

// ─────────────────────────────────────── 8. the wiring (structural)

section("8. The wiring — read from the source")

let runnerSrc = read("SipAI/Models/AgentRunner.swift")
let parserSrc = read("SipAI/Models/AgentEventParsing.swift")
let viewSrc = read("SipAI/Views/Chat/AgentSessionView.swift")
let composerSrc = read("SipAI/Views/Chat/AgentComposer.swift")
let configSrc = read("SipAI/Models/ConfigManager.swift")
let schedulerSrc = read("SipAI/Models/ScheduledTaskScheduler.swift")
let optionsSrc = read("SipAI/Models/AgentLaunchOptions.swift")
check("the runner reads the refusal beside the parse", runnerSrc.contains("AgentEventParser.fastModeRefusal(line: line)"))
check("the runner takes every call's speed, from its own stdout and from the tailer",
      runnerSrc.components(separatedBy: "$0.lastSpeed = speed").count - 1 == 2)
check("a new turn clears the previous turn's refusal", runnerSrc.contains("updateFastModeReport { $0.refusal = nil }"))
check("a refusal marks its call standard at once, so an older fast call cannot outrank it",
      runnerSrc.contains("$0.refusal = refusal\n                    $0.lastSpeed = \"standard\""))
check("the runner no longer resolves a tier itself — the send does",
      runnerSrc.contains("args.append(contentsOf: options.flags(for: agentKey))")
      && !runnerSrc.contains("codexFastTier"))
check("the parser stamps the speed on text, tool and thought events",
      parserSrc.components(separatedBy: "callSpeed: speed").count - 1 == 3)
check("the parser reads the reason off init and result",
      parserSrc.components(separatedBy: "fast_mode_disabled_reason").count - 1 == 2)
check("the send resolves codex's tier, per send, in the session's folder",
      viewSrc.contains(".serviceTierOverride(for: options, folder: composerFolder.path)"))
check("… and the context window's Default is the folder's model too",
      viewSrc.contains("codexCatalog.defaultModel(forFolder: composerFolder.path)"))
check("the view mirrors the whole report and seeds the transcript's speed",
      viewSrc.contains("runner.$fastModeReport") && viewSrc.contains("seededCallSpeed = loaded.lastCallSpeed")
      && viewSrc.contains("seededCallSpeed = cached.lastCallSpeed"))
check("the transcript's speed travels as history, never as the live speed",
      viewSrc.contains("report.seededSpeed = seededCallSpeed")
      && !viewSrc.contains("report.lastSpeed = seededCallSpeed"))
check("a live report re-reads claude's cached credits verdict",
      viewSrc.contains("ClaudeCapabilities.shared.refreshUsageCreditsBlock()"))
check("the chip draws the verdict's glyph, struck through when not served",
      composerSrc.contains("trailingMenuLabel(modelChipTitle, icon: fastModeIcon)")
      && composerSrc.contains("\"bolt.slash.fill\""))
check("claude's switch is gated on the catalog, not the family",
      composerSrc.contains("caps.fastModeSupported(forModelId: id)")
      && !composerSrc.contains("return family == \"opus\""))
check("… and off every cloud provider claude runs on",
      composerSrc.contains("if claudeCloudProvider != nil { return false }")
      && composerSrc.contains("ClaudeModelCatalog.childEnvironmentFacts().provider"))
check("the credits verdict is refreshed on appearance and when the menu opens",
      composerSrc.components(separatedBy: "caps.refreshUsageCreditsBlock()").count - 1 == 2)
check("codex gets ONE Fast mode switch — off pins standard, on the model's Fast tier — and a model pick drops a tier it does not advertise",
      composerSrc.contains("codexFastModeSwitch")
      && composerSrc.contains("updated.serviceTier = turnOn ? fast?.id : CodexSpeed.standard")
      && !composerSrc.contains("ComposerOptionRow(value: CodexSpeed.standard")
      && composerSrc.contains("codexCaps.serviceTier(id: tier, forModel: value, folder: codexFolder) == nil"))
check("… and it shows what the send will run: codex's own speed here until it is flipped, and says so",
      composerSrc.contains("codexFastTier != nil && CodexSpeed.isFaster(codexEffectiveTier)")
      && composerSrc.contains("let on = codexFastOn")
      && composerSrc.contains("if on, codexCaps.speedPick(for: options, folder: codexFolder) == nil {")
      && composerSrc.contains("String(localized: \"On by default in \\(agentName)\""))
check("… and the bolt, the hover and a task made from here read the SAME switch — a tier on a model the catalog does not list lights nothing",
      composerSrc.contains("return codexFastOn ? \"bolt.fill\" : nil")
      && composerSrc.contains("guard codexFastOn, let tier = codexEffectiveTier else { return nil }")
      && composerSrc.contains("effective: codexFastOn ? codexEffectiveTier : nil")
      && !composerSrc.contains("CodexSpeed.isFaster(codexEffectiveTier) ? \"bolt.fill\"")
      && composerSrc.components(separatedBy: "CodexSpeed.isFaster(codexEffectiveTier)").count - 1 == 1)
check("claude's switch says what fast mode costs in BOTH states, and every line wraps rather than being cut short",
      composerSrc.contains("lines: ClaudeFastModeWords.lines(")
      && composerSrc.contains("String(localized: \"\\(agentName) fast mode is paid only from usage credits.\"")
      && composerSrc.contains("Text(verbatim: line)\n                            .sipFont(11)\n                            .foregroundColor(SipDesign.textSecondary)\n                            .fixedSize(horizontal: false, vertical: true)")
      && composerSrc.contains(".frame(width: 230 * SipFont.ratio(fontScale), alignment: .leading)"))
check("… the reason stays on screen with the switch OFF, not only once a send is refused",
      composerSrc.contains("case .off:\n            if let block = creditsBlock {\n                lines.append(String(localized: \"Right now, \\(credits(block))\","))
check("the composer asks codex about its folder on appearance, on a folder change, and — fresh — when the menu opens",
      composerSrc.components(separatedBy: "codexCaps.refreshSpeedSettings(forFolder: codexFolder)").count - 1 == 2
      && composerSrc.contains("codexCaps.refreshSpeedSettings(forFolder: codexFolder, force: true)"))
check("no codex speed or default-model read in the composer skips the folder",
      !composerSrc.contains("codexCaps.configuredServiceTier")
      && !composerSrc.contains("codexCaps.fastModeFeatureEnabled")
      && !composerSrc.contains("codexCaps.defaultModel ")
      && !composerSrc.contains("codexCaps.defaultModel.")
      && !composerSrc.contains("codexCaps.defaultModel,")
      && composerSrc.contains("codexCaps.defaultModel(forFolder: codexFolder)"))
check("codex's answer is asked with the folder's physical path, over the shared client",
      optionsSrc.contains("cwd: CodexConfigRead.physicalPath(folder))")
      && read("SipAI/Models/AgentCLIUpdates.swift")
          .contains("request(cwd: cwd, id: CodexAppServerCall.answerId)"))
check("a moved config file or a new binary asks again for the folder on screen",
      optionsSrc.components(separatedBy: "speedSettingsMayHaveMoved()").count - 1 == 3)
check("a Default pick's model is the folder's, for the tiers as for the chip",
      optionsSrc.contains("return defaultModel(forFolder: folder)")
      && optionsSrc.contains("guard let slug = resolvedSlug(slug, folder: folder) else { return nil }"))
check("the pick is persisted in both maps",
      configSrc.components(separatedBy: "prefs[\"service_tier\"] = tier").count - 1 == 2
      && configSrc.components(separatedBy: "serviceTier: field(\"service_tier\")").count - 1 == 2)
check("a scheduled run launches with the TASK's speed, through the one builder, and resolves nothing itself",
      schedulerSrc.contains("AgentLaunchOptions.scheduledRun(")
      && schedulerSrc.contains("effort: def.effort, fastMode: def.fastMode,")
      && schedulerSrc.contains("serviceTier: def.serviceTier)")
      && !schedulerSrc.contains("codexServiceTierOverride")
      && !schedulerSrc.contains("var options = AgentLaunchOptions()"))
check("a session with no saved picks is seeded through the rule — a standard record cannot switch it off",
      viewSrc.contains("seeded.fastMode = ClaudeFastMode.seededSwitch(")
      && !viewSrc.contains("if let fast = scanned.fastMode { seeded.fastMode = fast }"))
let panelSrc = read("SipAI/Views/Chat/ScheduledTaskPanel.swift")
let taskFileSrc = read("SipAI/Models/ScheduledTaskDefinition.swift")
let popoverSrc = read("SipAI/Views/UsagePopover.swift")
check("the task file owns fast_mode and service_tier, read and written",
      taskFileSrc.contains("\"effort\", \"fast_mode\", \"service_tier\",")
      && taskFileSrc.contains("case \"fast_mode\":   def.fastMode = isTrue(value)")
      && taskFileSrc.contains("if fastMode { fields.append(\"fast_mode: true\") }")
      && taskFileSrc.contains("fields.append(\"service_tier: \\(tier)\")"))
check("the task card offers claude's switch on the task's model and codex's in the task's folder — the same one switch",
      panelSrc.contains("let supported = claudeTaskTakesFastMode(model: draft.model)")
      && panelSrc.contains("lines: ClaudeFastModeWords.lines(")
      && panelSrc.contains("codexCatalog.fastTier(forModel: draft.model, folder: folder)")
      && panelSrc.contains("draft.serviceTier = turnOn ? fast?.id : CodexSpeed.standard")
      && panelSrc.contains("codexCatalog.scheduledServiceTier(pick: draft.serviceTier,")
      && !panelSrc.contains("Picker(\"\", selection: optionalBinding($draft.serviceTier))"))
check("… and the card's summary names a codex speed only where the checkbox offers one — never a raw tier id",
      panelSrc.contains("let known = codexCatalog.serviceTier(id: tier, forModel: def.model,")
      && panelSrc.contains("return known.name")
      && !panelSrc.contains("?.name ?? tier"))
check("… asks codex about that folder, and claude's credits, when it appears or the folder moves",
      panelSrc.components(separatedBy: "refreshSpeedSources()").count - 1 == 4
      && panelSrc.contains("codexCatalog.refreshSpeedSettings(forFolder: Self.runFolder(draft))")
      && panelSrc.contains("capabilities.refreshUsageCreditsBlock()"))
check("… and a model pick drops a speed the new model cannot take",
      panelSrc.contains("!claudeTaskTakesFastMode(model: draft.model) {\n                    draft.fastMode = false")
      && panelSrc.contains("folder: Self.runFolder(draft)) == nil {\n                    draft.serviceTier = nil"))
check("a task made from the composer takes its speed, like its model and effort — as the switch shows it",
      composerSrc.contains("fastMode: !isCodex && !isKimi && options.fastMode")
      && composerSrc.contains("serviceTier: isCodex ? codexTaskSpeedPick : nil")
      && composerSrc.contains("CodexSpeed.carriedToTask(pick: codexCaps.speedPick(for: options, folder: codexFolder),"))
check("the fast-mode and credits sentences are spelled once, and the usage window reads them",
      composerSrc.components(separatedBy: "String(localized: \"Needs usage credits · ").count - 1 == 1
      && composerSrc.components(separatedBy: "String(localized: \"your usage credits are used up\"").count - 1 == 1
      && popoverSrc.contains("ClaudeFastModeWords.credits(reason)"))
check("the usage window shows credit figures only while credits are on — never a spend beside \"off\"",
      popoverSrc.contains("guard enabled else {")
      && popoverSrc.contains("spent this month")
      && !popoverSrc.contains("of \\(limitText)"))
check("model/list feeds the tiers", optionsSrc.contains("Self.listedTiers(fromAnswer: answer)"))
check("… and a new codex binary forgets the old one's answer",
      optionsSrc.contains("featuresKey = nil\n        // So is the tier answer")
      && optionsSrc.contains("listedTiers = [:]"))
check("the send's override knows whether the speed was picked",
      optionsSrc.contains("pick: speedPick(for: options, folder: folder),"))

// ─────────────────────────────────────────────────────────── summary

try? fm.removeItem(at: scratch)
print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
