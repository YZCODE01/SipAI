// Headless checks for the composer's model chip — specifically, for the
// rule that decides what an alias is NAMED.
//
// The failure this exists for: a session running one model, the user
// picks a different one from the chip, and the chip snaps straight back
// to the model that was already running. Every model they pick reads as
// that one model. Quitting does not clear it, reinstalling the app does
// not clear it, and nothing on screen admits anything went wrong —
// because what broke is not the pick (the flag really does change) but
// the NAME, and the wrong name was written into config.json where it
// outlives everything.
//
// Two halves, and both are checked here:
//
//   1. The runner pairs an observed model id with the alias the turn
//      was LAUNCHED with, and the view's handler guards on its own
//      feed's replay rather than on the picker's current value.
//      Structural — those rules live in a SwiftUI view and a @MainActor
//      runner, neither of which this can instantiate.
//   2. The store refuses a pairing that contradicts its own alias, in
//      BOTH directions: it will not write one, and it ignores one
//      already on disk. The second is what recovers an install that a
//      shipped build already wrote to.
//
// And the other failure this now exists for: after a Claude Code
// update the rows keep naming the models the OLD binary resolved,
// until a turn happens to run under each alias. The names are read
// off the alias table baked into the installed executable (sections
// 6–7), from the environment the CHILD will see rather than the login
// shell (8), and "Other models" is anchored on that resolution (9);
// section 12 parses whatever claude is installed here.
//
// Nothing in this directory is part of the app target.

import Foundation

var failures = 0
var checks = 0

func check(_ label: String, _ condition: @autoclosure () -> Bool,
           _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition() {
        print("  ok    \(label)")
    } else {
        failures += 1
        let d = detail()
        print("  FAIL  \(label)\(d.isEmpty ? "" : " — \(d)")")
    }
}

func section(_ title: String) { print("\n\(title)") }

extension String {
    func repeated(_ n: Int) -> String { String(repeating: self, count: n) }
}

/// Source root, so the structural pass can be pointed at another
/// checkout (`./run.sh <source-root>`) to confirm it fails there.
let sourceRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func read(_ relative: String) -> String {
    (try? String(contentsOfFile: sourceRoot + "/" + relative,
                 encoding: .utf8)) ?? ""
}

/// This harness's own directory — where its fixtures live, which is
/// not the checkout under test when one is named.
let harnessSourceDir = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : FileManager.default.currentDirectoryPath

// The child-environment facts read THIS process's environment, so a
// value exported by the terminal running the harness must not decide
// a check.
for name in ["ANTHROPIC_MODEL", "CLAUDE_CODE_USE_BEDROCK",
             "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
    unsetenv(name)
}
for (name, _) in ProcessInfo.processInfo.environment
where name.hasPrefix("ANTHROPIC_DEFAULT_") {
    unsetenv(name)
}

// ───────────────────────────────────────── 1. the contradiction rule

section("1. An alias names a FAMILY, so a foreign family is provably wrong")

// The exact pairing measured on a real install: a session running
// claude-fable-5, the user picks Sonnet, and the id from the turn
// already in flight gets filed under "sonnet".
check("sonnet cannot resolve to a fable id",
      !ClaudeModelDisplay.canResolve(alias: "sonnet", to: "claude-fable-5"))
check("opus cannot resolve to a fable id",
      !ClaudeModelDisplay.canResolve(alias: "opus", to: "claude-fable-5"))
check("haiku cannot resolve to an opus id",
      !ClaudeModelDisplay.canResolve(alias: "haiku", to: "claude-opus-5"))

// Everything the rule cannot PROVE wrong has to pass, or a pairing
// newer than this table gets refused for being unfamiliar.
check("sonnet resolves to a sonnet id",
      ClaudeModelDisplay.canResolve(alias: "sonnet", to: "claude-sonnet-5"))
check("a dated id still resolves",
      ClaudeModelDisplay.canResolve(alias: "haiku",
                                    to: "claude-haiku-4-5-20251001"))
check("a [1m] id resolves for its family",
      ClaudeModelDisplay.canResolve(alias: "opus", to: "claude-opus-5[1m]"))
check("a [1m] ALIAS resolves for its family",
      ClaudeModelDisplay.canResolve(alias: "opus[1m]", to: "claude-opus-5"))
check("a bedrock-prefixed id resolves for its family",
      ClaudeModelDisplay.canResolve(alias: "sonnet",
                                    to: "anthropic.claude-sonnet-5"))
// "" is claude's own default and legitimately resolves to any family —
// it is the one key in the map that is not a family word.
check("the default alias accepts any family",
      ClaudeModelDisplay.canResolve(alias: "", to: "claude-fable-5"))
// An alias whose spelling names no family cannot be judged from its
// spelling, and neither can an id that names none.
check("an alias with no family word is not judged",
      ClaudeModelDisplay.canResolve(alias: "opusplan", to: "claude-opus-5"))
check("an id with no family word is not judged",
      ClaudeModelDisplay.canResolve(alias: "sonnet", to: "some-vendor-model"))

// ──────────────────────────────────── 2. the store, in both directions

section("2. The store refuses a mis-attribution and ignores one on disk")

let harnessDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sipai-modelchip-harness-\(ProcessInfo.processInfo.processIdentifier)")
SipaiPaths.dataDir = harnessDir
try? FileManager.default.removeItem(at: harnessDir)
SipaiPaths.ensureDataDir()
// The user-level settings files the child-environment facts read are
// pointed away from the real ~/.claude for the whole run; section 8
// plants its own.
ClaudeModelCatalog.userSettingsFiles = [harnessDir.appendingPathComponent("no-settings.json")]

/// Read config.json back as raw JSON — what is actually on disk, not
/// what the object in memory believes.
func storedMap() -> [String: String] {
    guard let data = try? Data(contentsOf: SipaiPaths.configFile),
          let obj = (try? JSONSerialization.jsonObject(with: data))
            as? [String: Any]
    else { return [:] }
    return (obj["agent_model_full_ids"] as? [String: String]) ?? [:]
}

/// Plant a raw config.json and hand back a manager that has read it.
func plant(_ json: [String: Any]) -> ConfigManager {
    let data = try! JSONSerialization.data(withJSONObject: json)
    try? data.write(to: SipaiPaths.configFile, options: .atomic)
    return MainActor.assumeIsolated { ConfigManager() }
}

MainActor.assumeIsolated {
    let config = plant([:])

    config.setAgentModelFullId("claude-sonnet-5", forAlias: "sonnet")
    check("a matching pairing is written",
          config.agentModelFullId(forAlias: "sonnet") == "claude-sonnet-5",
          config.agentModelFullId(forAlias: "sonnet") ?? "nil")

    config.setAgentModelFullId("claude-fable-5", forAlias: "sonnet")
    check("a contradicting write is refused",
          config.agentModelFullId(forAlias: "sonnet") == "claude-sonnet-5",
          config.agentModelFullId(forAlias: "sonnet") ?? "nil")
    check("the refused write never reached the file",
          storedMap()["sonnet"] == "claude-sonnet-5",
          storedMap()["sonnet"] ?? "nil")

    // The default key is not a family word and must stay writable to
    // any family — claude's default really is Fable here.
    config.setAgentModelFullId("claude-fable-5", forAlias: "")
    check("the default key still accepts any family",
          config.agentModelFullId(forAlias: "") == "claude-fable-5")
}

MainActor.assumeIsolated {
    // The state a shipped build already wrote on a real install. This
    // is the half that matters most: nothing else corrects it —
    // `learnAgentModelFullIds` only moves an alias forward BY VERSION,
    // and claude-fable-5 and claude-sonnet-5 carry the same version, so
    // a wrong one compares equal and outlives every relaunch.
    let config = plant(["agent_model_full_ids": [
        "": "claude-fable-5",
        "sonnet": "claude-fable-5",
        "opus": "claude-opus-5",
    ]])

    check("a contradiction already on disk reads as absent",
          config.agentModelFullId(forAlias: "sonnet") == nil,
          config.agentModelFullId(forAlias: "sonnet") ?? "nil")
    check("the picker row falls back to the bare alias name",
          config.rememberedModelName(forAlias: "sonnet") == "Sonnet",
          config.rememberedModelName(forAlias: "sonnet"))
    check("an intact neighbour keeps its version",
          config.rememberedModelName(forAlias: "opus") == "Opus 5",
          config.rememberedModelName(forAlias: "opus"))
    check("the default row keeps its name",
          config.rememberedModelName(forAlias: "") == "Fable 5",
          config.rememberedModelName(forAlias: ""))

    // One launch's harvest pass is enough to clear it from the file, so
    // a user never has to be told to edit config.json by hand.
    config.learnAgentModelFullIds(["haiku": "claude-haiku-4-5-20251001"])
    check("the launch merge prunes it from the file",
          storedMap()["sonnet"] == nil,
          storedMap()["sonnet"] ?? "nil")
    check("the merge leaves the honest entries alone",
          storedMap()["opus"] == "claude-opus-5"
          && storedMap()[""] == "claude-fable-5")
    check("the merge still learns",
          storedMap()["haiku"] == "claude-haiku-4-5-20251001")

    // And a harvest cannot introduce one either — the same rule, on the
    // third writer into that map.
    config.learnAgentModelFullIds(["sonnet": "claude-fable-5"])
    check("a harvested contradiction is refused",
          storedMap()["sonnet"] == nil,
          storedMap()["sonnet"] ?? "nil")
}

// ────────────────────────────────── 3. the pair stored per session

section("3. A session's stored (alias, id) pair is read as a pair")

MainActor.assumeIsolated {
    let config = plant([:])
    var options = AgentLaunchOptions()
    options.permissionMode = "auto"
    options.model = "sonnet"
    options.effort = "max"
    options.modelFullId = "claude-sonnet-5"
    config.setAgentSessionLaunchOptions(options, for: "sess-1")
    let back = config.agentSessionLaunchOptions(for: "sess-1")
    check("a matching pair round-trips whole",
          back?.model == "sonnet" && back?.modelFullId == "claude-sonnet-5"
          && back?.permissionMode == "auto" && back?.effort == "max")
}

MainActor.assumeIsolated {
    // Reachable on a shipped build: the chip is clobbered mid-session
    // and then a send persists what it was showing. The chip PREFERS
    // the full id, so this pair renames the session's model on every
    // open, forever.
    let config = plant(["agent_session_launch_prefs": [
        "sess-2": ["mode": "auto", "effort": "max",
                   "model": "sonnet", "model_full_id": "claude-fable-5"],
    ]])
    let back = config.agentSessionLaunchOptions(for: "sess-2")
    check("a contradicting stored id is dropped",
          back?.modelFullId == nil, back?.modelFullId ?? "nil")
    check("the alias beside it is kept",
          back?.model == "sonnet", back?.model ?? "nil")
    check("the rest of the session's picks survive",
          back?.permissionMode == "auto" && back?.effort == "max")
}

try? FileManager.default.removeItem(at: harnessDir)

// ───────────────────────────────── 4. the runner pairs, the view guards

section("4. The observation carries its alias, and the replay is guarded")

let runner = read("SipAI/Models/AgentRunner.swift")
let view = read("SipAI/Views/Chat/AgentSessionView.swift")
check("AgentRunner.swift is readable at \(sourceRoot)", !runner.isEmpty)
check("AgentSessionView.swift is readable at \(sourceRoot)", !view.isEmpty)

// The runner is the only place that knows which alias a turn was
// launched with — by the time the id lands, the chips have moved on.
check("the runner captures the alias at send",
      runner.contains("launchedModelAlias = options.model ?? \"\""),
      "AgentRunner.send must capture the alias the turn runs under")
check("the runner publishes the pair, not a bare id",
      runner.contains("struct ResolvedModel")
      && runner.contains("@Published private(set) var resolvedModel"),
      "an id with no alias can only be attributed by guessing")
check("the pair is minted from the captured alias",
      runner.contains("ResolvedModel(alias: launchedModelAlias"),
      "minting it from anything live re-opens the whole bug")

// @Published replays to every resubscription and onReceive resubscribes
// per render, so the handler runs constantly with a value that may be
// several turns old. Every other live feed in this view guards on its
// own mirror; this one did not, and guarded on the picker instead —
// which is precisely the value a user's pick changes.
check("the handler guards on its own feed's mirror",
      view.contains("resolved != liveResolvedModel"),
      "without this the handler re-fires on every frame")
check("the mirror exists as view state",
      view.contains("@State private var liveResolvedModel"))
check("the mirror is cleared with the other live mirrors",
      view.range(of: #"liveResolvedModel = nil"#) != nil,
      "a stale mirror suppresses an identical observation on the next session")
check("the id is filed under the alias it RAN under",
      view.contains("forAlias: resolved.alias"),
      "filing it under the picker's current value renames that alias")
check("the picker's current value is not used as the key",
      !view.contains("forAlias: launchOptions.model ?? \"\""),
      "this is the exact line that wrote the wrong name")
check("the chip is refined only while it shows that alias",
      view.contains("(launchOptions.model ?? \"\") == resolved.alias"),
      "otherwise a fresh pick is overwritten by the running turn's model")

// ──────────────────────────────────────────────────────── real config

section("5. Other models — the observed pool, the full-id guard, the fast switch")

MainActor.assumeIsolated {
    let config = plant([:])

    // The pool keeps every version, one spelling each, and never lets
    // a newer sighting push an older one out — that is the alias map's
    // job, not this one's.
    config.learnAgentModelObservedIds([
        "claude-fable-5-1", "claude-fable-5", "claude-fable-5[1m]",
        "claude-opus-4-8", "claude-haiku-4-5-20251001", "claude-haiku-4-5",
        "opus", "claude-mystery",
    ])
    let pool = config.agentModelObservedIds()
    check("every versioned family id is kept",
          pool.contains("claude-fable-5-1") && pool.contains("claude-fable-5")
          && pool.contains("claude-opus-4-8"), "\(pool)")
    check("a variant spelling does not add a second entry",
          !pool.contains("claude-fable-5[1m]") && pool.filter { $0.hasPrefix("claude-fable-5") }.count == 2,
          "\(pool)")
    check("a dated and an undated spelling of one version are one entry",
          pool.filter { $0.contains("haiku") }.count == 1, "\(pool)")
    check("an alias and an id with no version are not observations",
          !pool.contains("opus") && !pool.contains("claude-mystery"), "\(pool)")
    let before = pool.count
    config.learnAgentModelObservedIds(["claude-fable-5"])
    check("re-learning an id changes nothing", config.agentModelObservedIds().count == before)

    // A pick from the "Other models" section runs under its full id.
    // Filing the observation under that "alias" would record that an
    // id resolves to itself, forever.
    config.setAgentModelFullId("claude-fable-5", forAlias: "claude-fable-5")
    check("an observation under a full-id alias is not filed",
          config.agentModelFullId(forAlias: "claude-fable-5") == nil)
    check("a full id is recognised as one",
          ClaudeModelDisplay.isFullId("claude-fable-5") && !ClaudeModelDisplay.isFullId("fable"))

    // The fast switch, spelled per agent. Claude's is the flag-layer
    // opt-in; codex's is the tier its send resolved (the rule itself is
    // pinned in ../FastMode); kimi has none.
    let fast = AgentLaunchOptions(model: "opus", fastMode: true)
    let claudeArgv = fast.flags(for: "claude_code")
    check("claude: the switch is the --settings opt-in",
          claudeArgv.contains("--settings")
          && claudeArgv.contains(AgentLaunchOptions.claudeFastModeSettings), "\(claudeArgv)")
    check("claude: the opt-in JSON is compact and says exactly one thing",
          AgentLaunchOptions.claudeFastModeSettings == "{\"fastMode\":true}")
    check("claude: off means no --settings at all",
          !AgentLaunchOptions(model: "opus").flags(for: "claude_code").contains("--settings"))
    var codexOn = AgentLaunchOptions(model: "gpt-5.6-sol", fastMode: true)
    codexOn.codexServiceTierOverride = "priority"
    check("codex: the send's resolved tier is the flag",
          codexOn.flags(for: "codex").contains("service_tier=priority"))
    codexOn.codexServiceTierOverride = nil
    check("codex: nothing resolved, no flag — a saved switch alone is never passed raw",
          !codexOn.flags(for: "codex").joined(separator: " ").contains("service_tier"))
    check("kimi: nothing, ever",
          !AgentLaunchOptions(model: "k3", fastMode: true).flags(for: "kimi")
            .joined(separator: " ").contains("fast"))

    // Codex's speed pick survives the store, per agent and per session.
    var speedPick = AgentLaunchOptions(model: "gpt-6-sol")
    speedPick.serviceTier = "default"
    config.setAgentLaunchOptions(speedPick, for: "codex")
    check("codex's speed pick survives the per-agent store",
          config.agentLaunchOptions(for: "codex").serviceTier == "default")
    speedPick.serviceTier = "ultrafast"
    config.setAgentSessionLaunchOptions(speedPick, for: "speed-session")
    check("… and the per-session store",
          config.agentSessionLaunchOptions(for: "speed-session")?.serviceTier == "ultrafast")
    speedPick.serviceTier = nil
    config.setAgentSessionLaunchOptions(speedPick, for: "speed-session")
    check("… and Default is stored as an absent key",
          config.agentSessionLaunchOptions(for: "speed-session")?.serviceTier == nil)
}

// "Still offered by the CLI" is answered by the binary naming the id.
// A throwaway file standing in for claude's executable: the table
// spells ids with a closing quote, and `claude-fable-5` alone would
// match inside `claude-fable-5-1`.
let fakeBinary = harnessDir.appendingPathComponent("claude-fake-binary")
let tableJSON = #"{"claude-fable-5-1":"fable51","claude-opus-5":"opus5","claude-haiku-4-5":"haiku45"}"#
try? Data(("x".repeated(70_000) + tableJSON + "y".repeated(70_000)).utf8).write(to: fakeBinary)
let named = ClaudeModelCatalog.idsNamedByBinary(
    at: fakeBinary.path,
    candidates: ["claude-fable-5-1", "claude-fable-5", "claude-haiku-4-5-20251001", "claude-opus-4-8"])
check("an id the binary names is found", named.contains("claude-fable-5-1"))
check("an id that is only a PREFIX of a named one is not", !named.contains("claude-fable-5"))
check("a dated id is matched by its undated spelling", named.contains("claude-haiku-4-5-20251001"))
check("an id the binary does not name is not", !named.contains("claude-opus-4-8"))

// The Default row reads claude's own configuration for the folder.
let projectDir = harnessDir.appendingPathComponent("project")
try? FileManager.default.createDirectory(
    at: projectDir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
try? Data(#"{"model":"claude-fable-5"}"#.utf8)
    .write(to: projectDir.appendingPathComponent(".claude/settings.json"))
check("a project settings.json model is the configured default",
      ClaudeModelCatalog.configuredDefaultModel(cwd: projectDir) == "claude-fable-5")
try? Data(#"{"model":"opus[1m]"}"#.utf8)
    .write(to: projectDir.appendingPathComponent(".claude/settings.local.json"))
check("settings.local.json outranks settings.json — claude's own precedence",
      ClaudeModelCatalog.configuredDefaultModel(cwd: projectDir) == "opus[1m]")

// Structural — the wiring lives in views and the runner.
let composer = read("SipAI/Views/Chat/AgentComposer.swift")
let parser = read("SipAI/Models/AgentEventParsing.swift")
let panel = read("SipAI/Views/Chat/ScheduledTaskPanel.swift")
check("the composer draws an \"Other models\" section",
      composer.contains(".header(String(localized: \"Other models\""))
check("the composer's Default row reads the configured default first",
      composer.contains("configuredDefaultModel(cwd: folder)"))
check("the composer offers the fast switch under the model rows",
      composer.contains("footer: { fastModeFooter }"))
check("picking a model without fast mode clears the switch",
      composer.contains("if updated.fastMode, !fastModeSupported(forModel: value)"))
check("claude's fast switch is gated on the model's own catalog flag, not the family",
      composer.contains("caps.fastModeSupported(forModelId: id)"))
check("codex's speed is gated on the model's advertised tiers",
      composer.contains("codexCaps.offersSpeed(forModel: value, folder: codexFolder)"))
check("codex's tier is resolved by the send, not by the runner",
      !runner.contains("codexFastTier")
      && view.contains(".serviceTierOverride(for: options, folder: composerFolder.path)"))
check("the parser reads fast_mode_state off init and result",
      parser.components(separatedBy: "fast_mode_state").count >= 3)
check("the view mirrors the fast report behind its own guard",
      view.contains("guard report != liveFastModeReport else { return }"))
check("the scheduled-task picker carries the same section",
      panel.contains("capabilities.otherModels"))

// ─────────────────────────── 6. the catalog baked into the binary

section("6. The binary's own catalog is read whole, or not at all")

// The fixture is a SYNTHETIC object literal in the measured shape of
// claude's baked catalog — every value shape the real one carries
// (`null` provider columns, an entry with no `context`, a two-level
// `native_1m_3p`, `!0`/`!1`, `1e6`, arrays) plus a family this app has
// never heard of — fed through the SAME chunked reader as the real
// executable, via a throwaway file with filler on both sides.
let fixtureText = (try? String(contentsOfFile: harnessSourceDir + "/fixtures/claude-catalog-shape.js",
                               encoding: .utf8)) ?? ""
check("the catalog fixture is readable at \(harnessSourceDir)", !fixtureText.isEmpty)
SipaiPaths.ensureDataDir()

func fakeBinary(_ name: String, before: Int, body: String, after: Int) -> String {
    let url = harnessDir.appendingPathComponent(name)
    var data = Data(repeating: UInt8(ascii: "x"), count: before)
    data.append(Data(body.utf8))
    data.append(Data(repeating: UInt8(ascii: "y"), count: after))
    try? data.write(to: url)
    return url.path
}

let fixturePath = fakeBinary("claude-fixture", before: 70_000, body: fixtureText, after: 70_000)
let fixtureCatalog = ClaudeModelCatalog.binaryCatalog(at: fixturePath)
check("the table is read out of a throwaway binary", fixtureCatalog != nil)

if let c = fixtureCatalog {
    check("every alias default",
          c.aliasDefault == ["opus": "claude-opus-5", "sonnet": "claude-sonnet-5",
                             "haiku": "claude-haiku-4-5", "fable": "claude-fable-5-1",
                             "nova": "claude-nova-1"], "\(c.aliasDefault)")
    check("the foundry column for opus",
          c.aliasPerProvider["opus"]?["foundry"] == "claude-opus-4-6")
    check("an alias with no per_provider has no column",
          c.aliasPerProvider["haiku"] == nil)
    check("a null column is not recorded",
          c.aliasPerProvider["nova"] == nil, "\(c.aliasPerProvider["nova"] ?? [:])")
    check("haiku joins its catalog id to the dated wire id",
          c.entry(forId: "claude-haiku-4-5")?.firstPartyId == "claude-haiku-4-5-20251001")
    check("claude-sonnet-4-0 joins to claude-sonnet-4-20250514 — not a date",
          c.entry(forId: "claude-sonnet-4-0")?.firstPartyId == "claude-sonnet-4-20250514")
    check("the wire id looks its entry up too",
          c.entry(forId: "claude-sonnet-4-20250514")?.catalogId == "claude-sonnet-4-0")
    check("a null first_party joins to the catalog id",
          c.entry(forId: "claude-nova-1")?.firstPartyId == "claude-nova-1")
    check("every display_name, in the binary's order",
          c.entries.map(\.displayName) == ["Haiku 3.5", "Haiku 4.5", "Sonnet 4", "Sonnet 4.5",
                                           "Sonnet 4.6", "Sonnet 5", "Opus 4.6", "Opus 4.7",
                                           "Opus 4.8", "Opus 5", "Fable 5", "Fable 5.1",
                                           "Mythos 5.1", "Nova 0.9 preview", "Nova 1"],
          "\(c.entries.map(\.displayName))")
    check("a display_name the derived rule could not produce is the table's",
          ClaudeModelCatalog.displayName(forId: "claude-nova-0-9", catalog: c) == "Nova 0.9 preview"
          && ClaudeModelDisplay.name(for: "claude-nova-0-9") != "Nova 0.9 preview")
    check("values a later build may add are skipped, whatever their shape",
          c.aliasDefault["nova"] == "claude-nova-1" && c.entry(forId: "claude-sonnet-5")?.displayName == "Sonnet 5")
    check("best", c.best == "fable")
    check("latest_per_family",
          c.latestPerFamily == ["fable": "claude-fable-5-1", "opus": "claude-opus-5",
                                "sonnet": "claude-sonnet-5", "haiku": "claude-haiku-4-5",
                                "nova": "claude-nova-1"])
    check("no parsed id carries a variant marker",
          !c.entries.contains { $0.catalogId.contains("[") || $0.firstPartyId.contains("[") })
    check("a variant id names its base entry",
          ClaudeModelCatalog.displayName(forId: "claude-haiku-4-5-20251001[1m]", catalog: c) == "Haiku 4.5")
    check("an id the table does not name is named by the derived rule",
          ClaudeModelCatalog.displayName(forId: "claude-opus-4-1-20250805", catalog: c) == "Opus 4.1")
    check("a new family ships with its name in the table",
          ClaudeModelCatalog.displayName(forId: "claude-nova-1", catalog: c) == "Nova 1")
}

// The same reader over the shapes the real files take.
let chunk = 8 * 1024 * 1024
let straddle = ClaudeModelCatalog.binaryCatalog(
    at: fakeBinary("claude-straddle", before: chunk - 7_000, body: fixtureText, after: 50_000))
check("a table straddling the 8 MB chunk boundary is read whole", straddle == fixtureCatalog)
// 2.1.269 carries an EMPTY schema seed spelling the same keys 2.5 KB
// after the real table — a second anchor whose own slice is not a
// catalog.
let seed = "{schema_version:0,pricing_tiers:{},models:[],aliases:{},defaults:{},latest_per_family:{},alias_migration:{}}"
let glue = "};function w(){return{bakedCatalog:void 0,canonicalNameMemo:new Map}}var S="
let seedAfter = ClaudeModelCatalog.binaryCatalog(
    at: fakeBinary("claude-seed-after", before: 10_000,
                   body: fixtureText + glue + "z".repeated(2_500) + seed, after: 10_000))
check("the empty seed AFTER the table (the 2.1.269 shape) yields the table", seedAfter == fixtureCatalog)
let seedBefore = ClaudeModelCatalog.binaryCatalog(
    at: fakeBinary("claude-seed-before", before: 10_000,
                   body: seed + ";" + "z".repeated(2_500) + fixtureText, after: 10_000))
check("the empty seed BEFORE the table yields the table", seedBefore == fixtureCatalog)
check("the seed alone is not a catalog",
      ClaudeModelCatalog.binaryCatalog(at: fakeBinary("claude-seed-only", before: 1_000, body: seed, after: 1_000)) == nil)
check("a truncated table is nil, never a partial table",
      ClaudeModelCatalog.binaryCatalog(
        at: fakeBinary("claude-truncated", before: 1_000,
                       body: String(fixtureText.prefix(fixtureText.count * 6 / 10)), after: 1_000)) == nil)
let missingId = "{schema_version:0,models:[{id:\"claude-opus-5\",family:\"opus\",display_name:\"Opus 5\"},{family:\"opus\",display_name:\"Opus 4.8\"}],aliases:{opus:{default:\"claude-opus-5\"}},defaults:{},latest_per_family:{opus:\"claude-opus-5\"},alias_migration:{}}"
check("an entry with no id fails the WHOLE catalog",
      ClaudeModelCatalog.binaryCatalog(at: fakeBinary("claude-missing-id", before: 1_000, body: missingId, after: 1_000)) == nil)
let escaped = "{schema_version:0,models:[{id:\"claude-opus-5\",family:\"opus\",display_name:\"Opus\\u00A05 \\u2014 \\\"quoted\\\" \\/ \\uD83D\\uDE00\",provider_ids:{first_party:\"claude-opus-5\"}}],aliases:{opus:{default:\"claude-opus-5\"}},defaults:{},latest_per_family:{opus:\"claude-opus-5\"},alias_migration:{}}"
check("string escapes resolve to the characters they name",
      ClaudeModelCatalog.binaryCatalog(at: fakeBinary("claude-escapes", before: 1_000, body: escaped, after: 1_000))?
        .entry(forId: "claude-opus-5")?.displayName == "Opus\u{00A0}5 \u{2014} \"quoted\" / \u{1F600}")
let noAliases = "{schema_version:0,models:[{id:\"claude-opus-5\",family:\"opus\",display_name:\"Opus 5\"}],aliases:{},defaults:{},latest_per_family:{},alias_migration:{}}"
check("a table with no alias is not a catalog",
      ClaudeModelCatalog.binaryCatalog(at: fakeBinary("claude-no-aliases", before: 1_000, body: noAliases, after: 1_000)) == nil)
check("a file with no anchor at all (the 2.1.144 shape) is nil",
      ClaudeModelCatalog.binaryCatalog(at: fakeBinary("claude-no-catalog", before: 200_000, body: "models:[{id:\"claude-opus-5\"}]", after: 200_000)) == nil)
// The slice reads the keys at or after `models:`, which is their
// measured order in every shipping binary. A build that put `aliases`
// BEFORE `models` leaves the parse with no alias table and answers nil
// — a safe degradation to the observed map, pinned here so the
// assumption is visible if claude ever reorders.
let aliasesFirst = "{schema_version:0,aliases:{opus:{default:\"claude-opus-5\"}},models:[{id:\"claude-opus-5\",family:\"opus\",display_name:\"Opus 5\",provider_ids:{first_party:\"claude-opus-5\"}}],latest_per_family:{opus:\"claude-opus-5\"},alias_migration:{}}"
check("aliases before models is not parsed — a safe, documented limitation",
      ClaudeModelCatalog.binaryCatalog(at: fakeBinary("claude-aliases-first", before: 1_000, body: aliasesFirst, after: 1_000)) == nil)
check("a missing file is nil",
      ClaudeModelCatalog.binaryCatalog(at: harnessDir.appendingPathComponent("no-such-claude").path) == nil)

// The cache: one read per binary, and a read that never happened is
// not answered from it.
_ = ClaudeModelCatalog.binaryCatalog(at: fixturePath)
check("the cached read answers for the binary last read",
      ClaudeModelCatalog.cachedBinaryCatalog(at: fixturePath) == fixtureCatalog)
check("a binary nothing has read is not answered from the cache",
      ClaudeModelCatalog.cachedBinaryCatalog(at: harnessDir.appendingPathComponent("claude-straddle").path) == nil)
check("the key stats the link and its target",
      ClaudeModelCatalog.binaryKey(at: fixturePath)?.contains(fixturePath) == true
      && ClaudeModelCatalog.binaryKey(at: harnessDir.appendingPathComponent("no-such-claude").path) == nil)

// ────────────────────────────────── 7. the one resolution rule

section("7. An alias resolves through the environment, then the binary, then the map")

typealias Src = ClaudeModelCatalog.AliasSource
func res(_ alias: String, catalog: ClaudeModelCatalog.BinaryCatalog? = fixtureCatalog,
         provider: String? = nil, env: String? = nil,
         observed: String? = nil) -> (String, Src)? {
    ClaudeModelCatalog.resolve(alias: alias, catalog: catalog, provider: provider,
                               environmentOverride: env, observed: observed)
        .map { ($0.id, $0.source) }
}
check("the environment override beats the catalog and the map",
      res("opus", env: "claude-opus-4-8", observed: "claude-opus-4-7").map { $0 == ("claude-opus-4-8", .environment) } == true)
check("the catalog beats the map",
      res("opus", observed: "claude-opus-4-7").map { $0 == ("claude-opus-5", .binary) } == true)
check("the map answers for an alias the table does not name",
      res("opusplan", observed: "claude-opus-5").map { $0 == ("claude-opus-5", .observed) } == true)
check("nothing known is nil, never a guess", res("opusplan") == nil)
check("an empty alias is nil here — the wrapper owns the Default rule", res("") == nil)
check("foundry picks the per-provider column",
      res("opus", provider: "foundry").map { $0 == ("claude-opus-4-6", .binary) } == true)
check("a provider with no column for the alias falls to its default",
      res("haiku", provider: "foundry")?.0 == "claude-haiku-4-5-20251001")
check("a provider the table does not spell falls to the default",
      res("opus", provider: "mantle2")?.0 == "claude-opus-5")
check("the answer is the WIRE id",
      res("haiku")?.0 == "claude-haiku-4-5-20251001" && res("sonnet", provider: "vertex")?.0 == "claude-sonnet-4-5-20250929")
check("a variant alias resolves as its family, unmarked",
      res("opus[1m]")?.0 == "claude-opus-5" && res("OPUS")?.0 == "claude-opus-5")
check("a catalog-less binary falls to the map for every alias",
      res("opus", catalog: nil, observed: "claude-opus-4-8").map { $0 == ("claude-opus-4-8", .observed) } == true
      && res("sonnet", catalog: nil) == nil)
check("a new family's alias resolves through the table",
      res("nova").map { $0 == ("claude-nova-1", .binary) } == true)

// The wrapper: the installed binary (the fixture), this process's
// environment (scrubbed), and the config's observed map.
AgentManager.claudeBinaryPath = fixturePath
_ = ClaudeModelCatalog.binaryCatalog(at: fixturePath)

MainActor.assumeIsolated {
    let config = plant(["agent_model_full_ids": [
        "": "claude-fable-5",
        "opus": "claude-opus-4-8",
        "opusplan": "claude-opus-4-7",
        "mythos": "claude-fable-5",
    ]])
    check("an alias row names the binary's resolution, not the map's",
          config.rememberedModelName(forAlias: "opus") == "Opus 5",
          config.rememberedModelName(forAlias: "opus"))
    check("the id behind it is the wire id",
          config.resolvedModelId(forAlias: "haiku") == "claude-haiku-4-5-20251001")
    check("the Default row names the current version of the observed FAMILY",
          config.rememberedModelName(forAlias: "") == "Fable 5.1",
          config.rememberedModelName(forAlias: ""))
    check("the Default's source is the binary",
          config.resolvedModel(forAlias: "")?.source == .binary)
    check("a variant alias names the same, without the marker",
          config.rememberedModelName(forAlias: "opus[1m]") == "Opus 5")
    check("an alias the table does not name falls to the map",
          config.rememberedModelName(forAlias: "opusplan") == "Opus 4.7")
    check("a cross-family pairing is still refused under the fallback",
          config.resolvedModelId(forAlias: "mythos") == nil
          && config.rememberedModelName(forAlias: "mythos") == "Mythos")
    check("a full id names itself from the table",
          config.rememberedModelName(forAlias: "claude-sonnet-4-20250514") == "Sonnet 4")
    check("a new family's row is named by the table",
          config.rememberedModelName(forAlias: "nova") == "Nova 1")

    // A Default whose observed family the table does not name keeps
    // the observed id; no observed Default at all is nil.
    config.setAgentModelFullId("claude-instant-1", forAlias: "")
    check("an observed Default outside the table answers as itself",
          config.resolvedModel(forAlias: "")
              == ClaudeModelCatalog.Resolution(id: "claude-instant-1", source: .observed))
    let bare = plant([:])
    check("no observed Default is nil", bare.resolvedModel(forAlias: "") == nil)
    check("an empty alias with nothing known names nothing", bare.rememberedModelName(forAlias: "") == "")
}

// ─────────────────────────── 8. what the CHILD's environment says

section("8. Provider and overrides come from the child's environment, never the shell")

let facts = ClaudeModelCatalog.childEnvironmentFacts(
    environment: ["CLAUDE_CODE_USE_BEDROCK": "1",
                  "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-8",
                  "ANTHROPIC_MODEL": " opus "],
    settingsEnvironment: [:])
check("bedrock from the process environment", facts.provider == "bedrock")
check("the opus override, and no other family's",
      facts.override(forFamily: "opus") == "claude-opus-4-8"
      && facts.override(forFamily: "OPUS") == "claude-opus-4-8"
      && facts.override(forFamily: "sonnet") == nil)
check("ANTHROPIC_MODEL, trimmed", facts.configuredModel == "opus")
check("the variable a family's override lives in is spelled once",
      ClaudeModelCatalog.ChildEnvironmentFacts.overrideVariable(forFamily: "opus") == "ANTHROPIC_DEFAULT_OPUS_MODEL")
check("a settings env block OVERRIDES the process environment — Object.assign, as claude applies it",
      ClaudeModelCatalog.childEnvironmentFacts(
        environment: ["CLAUDE_CODE_USE_BEDROCK": "1", "ANTHROPIC_MODEL": "opus"],
        settingsEnvironment: ["CLAUDE_CODE_USE_BEDROCK": "0", "CLAUDE_CODE_USE_FOUNDRY": "true",
                              "ANTHROPIC_MODEL": "sonnet"])
        == ClaudeModelCatalog.ChildEnvironmentFacts(provider: "foundry", overridesByFamily: [:],
                                                    configuredModel: "sonnet"))
for off in ["0", "false", "off", "no", "", "  "] {
    check("\"\(off)\" does not set a provider",
          ClaudeModelCatalog.childEnvironmentFacts(
            environment: ["CLAUDE_CODE_USE_VERTEX": off], settingsEnvironment: [:]).provider == nil)
}
for on in ["1", "true", "TRUE", "yes"] {
    check("\"\(on)\" does",
          ClaudeModelCatalog.childEnvironmentFacts(
            environment: ["CLAUDE_CODE_USE_VERTEX": on], settingsEnvironment: [:]).provider == "vertex")
}
check("the switches are consulted in claude's order",
      ClaudeModelCatalog.childEnvironmentFacts(
        environment: ["CLAUDE_CODE_USE_FOUNDRY": "1", "CLAUDE_CODE_USE_BEDROCK": "1"],
        settingsEnvironment: [:]).provider == "bedrock")
check("an empty override is no override",
      ClaudeModelCatalog.childEnvironmentFacts(
        environment: ["ANTHROPIC_DEFAULT_OPUS_MODEL": "  "], settingsEnvironment: [:])
        .override(forFamily: "opus") == nil)

// The settings files, read for their `env` blocks alone, later files
// winning, cached by (size, mtime).
let settingsJSON = harnessDir.appendingPathComponent("settings.json")
let settingsLocal = harnessDir.appendingPathComponent("settings.local.json")
try? Data(#"{"model":"opus[1m]","env":{"CLAUDE_CODE_USE_VERTEX":true,"ANTHROPIC_DEFAULT_OPUS_MODEL":"claude-opus-4-7","HTTP_PROXY":"http://127.0.0.1:7890"}}"#.utf8)
    .write(to: settingsJSON)
try? Data(#"{"env":{"ANTHROPIC_DEFAULT_OPUS_MODEL":"claude-opus-4-6"}}"#.utf8)
    .write(to: settingsLocal)
let settingsEnv = ClaudeModelCatalog.settingsEnvironment(files: [settingsJSON, settingsLocal])
check("a JSON true reads as set", settingsEnv["CLAUDE_CODE_USE_VERTEX"] == "true")
check("settings.local.json wins over settings.json",
      settingsEnv["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "claude-opus-4-6")
check("only the env block is read", settingsEnv["model"] == nil && settingsEnv["HTTP_PROXY"] != nil)
check("a file that is not there contributes nothing",
      ClaudeModelCatalog.settingsEnvironment(files: [harnessDir.appendingPathComponent("absent.json")]).isEmpty)

// Same length, same mtime: the cache answers the old value. Move the
// mtime: the new one. The mtime is pinned to a whole second first so
// that restoring it is exact.
let localMtime = Date(timeIntervalSince1970: 1_700_000_000)
try? FileManager.default.setAttributes([.modificationDate: localMtime], ofItemAtPath: settingsLocal.path)
check("the pinned file reads as written",
      ClaudeModelCatalog.settingsEnvironment(files: [settingsJSON, settingsLocal])["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "claude-opus-4-6")
try? Data(#"{"env":{"ANTHROPIC_DEFAULT_OPUS_MODEL":"claude-opus-4-5"}}"#.utf8)
    .write(to: settingsLocal)
try? FileManager.default.setAttributes([.modificationDate: localMtime], ofItemAtPath: settingsLocal.path)
check("an unmoved fingerprint answers from the cache",
      ClaudeModelCatalog.settingsEnvironment(files: [settingsJSON, settingsLocal])["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "claude-opus-4-6")
try? FileManager.default.setAttributes([.modificationDate: localMtime.addingTimeInterval(2)],
                                       ofItemAtPath: settingsLocal.path)
check("a moved mtime re-reads",
      ClaudeModelCatalog.settingsEnvironment(files: [settingsJSON, settingsLocal])["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "claude-opus-4-5")

// Through the wrapper, with the user-level files pointed at the two
// above: the row names the override, the hover can name its source,
// and the provider column moves the families it has one for.
ClaudeModelCatalog.userSettingsFiles = [settingsJSON, settingsLocal]
let wrapped = ClaudeModelCatalog.childEnvironmentFacts()
check("the wrapper reads the process environment plus the settings blocks",
      wrapped.provider == "vertex" && wrapped.override(forFamily: "opus") == "claude-opus-4-5"
      && wrapped.configuredModel == nil)
MainActor.assumeIsolated {
    let config = plant(["agent_model_full_ids": ["opus": "claude-opus-5"]])
    check("the environment override names the row",
          config.rememberedModelName(forAlias: "opus") == "Opus 4.5"
          && config.resolvedModel(forAlias: "opus")?.source == .environment)
    check("the provider column names the rows it has",
          config.rememberedModelName(forAlias: "sonnet") == "Sonnet 4.5"
          && config.rememberedModelName(forAlias: "haiku") == "Haiku 4.5")
    check("the observed map is untouched by any of it",
          config.agentModelFullId(forAlias: "opus") == "claude-opus-5")
}
// The Default row's configured model: with no `ANTHROPIC_MODEL` in
// the child's environment, the user-level `model` key answers…
check("the user-level model key is the configured default when no ANTHROPIC_MODEL is set",
      ClaudeModelCatalog.configuredDefaultModel(cwd: nil) == "opus[1m]",
      ClaudeModelCatalog.configuredDefaultModel(cwd: nil) ?? "nil")
// …and `ANTHROPIC_MODEL` in a settings env block outranks it — read
// from the same facts, never from the login shell.
try? Data(#"{"env":{"ANTHROPIC_MODEL":"sonnet"}}"#.utf8).write(to: settingsLocal)
try? FileManager.default.setAttributes([.modificationDate: localMtime.addingTimeInterval(4)],
                                       ofItemAtPath: settingsLocal.path)
check("ANTHROPIC_MODEL from the settings env block outranks the model key",
      ClaudeModelCatalog.configuredDefaultModel(cwd: nil) == "sonnet")
check("the user-level `model` key is the fallback behind it",
      { () -> Bool in
          try? Data(#"{"model":"claude-fable-5"}"#.utf8).write(to: settingsJSON)
          try? FileManager.default.removeItem(at: settingsLocal)
          return ClaudeModelCatalog.configuredDefaultModel(cwd: nil) == "claude-fable-5"
      }())
try? FileManager.default.removeItem(at: settingsJSON)
ClaudeModelCatalog.userSettingsFiles = [harnessDir.appendingPathComponent("no-settings.json")]

// ─────────────────────────────────── 9. "Other models" under F4

section("9. Other models — anchored on the binary's resolution, named by it, fed live")

MainActor.assumeIsolated {
    // The plan's own example: the map still says opus = 4.8 (no turn
    // has run under the new binary), the binary says opus = 5, and
    // the pool holds 4.8 and 4.7. The row is 4.8 — the map at harvest
    // time would have put it at 4.7.
    let config = plant(["agent_model_full_ids": ["opus": "claude-opus-4-8"],
                        "agent_model_observed_ids": ["claude-opus-4-8", "claude-opus-4-7"]])
    let aliases = ["fable", "opus", "sonnet", "haiku"]
    @MainActor
    func candidates(_ config: ConfigManager) -> [(family: String, id: String)] {
        ClaudeModelCatalog.otherModelCandidates(
            aliases: aliases, observed: config.agentModelObservedIds(),
            catalog: fixtureCatalog,
            resolvedId: { config.resolvedModelId(forAlias: $0) })
    }
    let first = candidates(config)
    check("the anchor is the binary's resolution, not the map's",
          first.contains { $0.family == "opus" && $0.id == "claude-opus-4-8" }, "\(first)")
    check("an id in the catalog but never observed is not offered",
          !first.contains { $0.family == "haiku" } && !first.contains { $0.family == "sonnet" })
    check("an anchor with nothing observed below it offers no row",
          !first.contains { $0.family == "fable" })

    // The live path feeds the pool: a system.init under `opus` lands
    // claude-opus-5 in the pool as well as the map, so the day the
    // alias moves past it, it is a candidate without a harvest.
    config.setAgentModelFullId("claude-opus-5", forAlias: "opus")
    check("a live observation lands in the pool",
          config.agentModelObservedIds().contains("claude-opus-5"))
    check("…and the map", config.agentModelFullId(forAlias: "opus") == "claude-opus-5")
    config.setAgentModelFullId("claude-fable-5", forAlias: "claude-fable-5")
    check("a concrete pick that ran feeds the pool even though it files no alias",
          config.agentModelObservedIds().contains("claude-fable-5")
          && config.agentModelFullId(forAlias: "claude-fable-5") == nil)
    let second = candidates(config)
    check("the fable row appears the moment its predecessor is observed",
          second.contains { $0.family == "fable" && $0.id == "claude-fable-5" }, "\(second)")
    check("the anchor moving past the pool's newest promotes it",
          ClaudeModelCatalog.otherModelCandidates(
            aliases: ["opus"], observed: ["claude-opus-4-8", "claude-opus-4-7", "claude-opus-5"],
            catalog: fixtureCatalog,
            resolvedId: { _ in "claude-opus-5-1" })
            .first.map { $0.id == "claude-opus-5" } == true)

    // End to end through the fixture binary, on the same detached
    // path the app takes: the title is the binary's display_name, and
    // an observed id the binary does not name is dropped.
    config.learnAgentModelObservedIds(["claude-sonnet-4-9", "claude-nova-0-9", "claude-mystery-2"])
    // A family only the binary names: its ids are pooled (the table
    // cannot name the family, the catalog can), its alias's family is
    // read off the catalog, and its row is titled by the table.
    check("an id of a family only the binary names is pooled",
          config.agentModelObservedIds().contains("claude-nova-0-9"))
    check("…and would have a row, titled by the table, the moment its alias is listed",
          ClaudeModelCatalog.otherModelCandidates(
            aliases: ["nova"], observed: config.agentModelObservedIds(),
            catalog: fixtureCatalog,
            resolvedId: { config.resolvedModelId(forAlias: $0) })
            .first.map {
                $0.family == "nova" && $0.id == "claude-nova-0-9"
                    && ClaudeModelCatalog.displayName(forId: $0.id) == "Nova 0.9 preview"
            } == true)
    check("an id of a family nothing names is still not pooled",
          !config.agentModelObservedIds().contains { $0.contains("mystery") })
    ClaudeModelCatalog.refreshOtherModels(config: config)
}
let deadline = Date().addingTimeInterval(10)
while Date() < deadline,
      MainActor.assumeIsolated({ ClaudeCapabilities.shared.otherModels.isEmpty }) {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
MainActor.assumeIsolated {
    let rows = ClaudeCapabilities.shared.otherModels
    check("the section lands", !rows.isEmpty)
    check("the row's title is the binary's display_name",
          rows.first { $0.family == "opus" }?.displayName == "Opus 4.8"
          && rows.first { $0.family == "fable" }?.displayName == "Fable 5", "\(rows)")
    // The fallback alias list carries no `nova`, so the section — which
    // runs over the aliases the composer offers — has no nova row; the
    // candidate rule alone offers it once the alias is listed.
    check("a family the picker does not list has no row",
          !rows.contains { $0.family == "nova" })
    check("an observed id the binary does not name is dropped",
          !rows.contains { $0.family == "sonnet" }, "\(rows)")
}

// ─────────────────────────────────────── 10. the wiring (structural)

section("10. The wiring — read from the source")

let options = read("SipAI/Models/AgentLaunchOptions.swift")
let updates = read("SipAI/Models/AgentCLIUpdates.swift")
let app = read("SipAI/SipAIApp.swift")
let reset = read("SipAI/Models/FactoryReset.swift")

func body(of decl: String, in source: String) -> String {
    guard let start = source.range(of: decl) else { return "" }
    let rest = source[start.upperBound...]
    guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
    return String(rest[..<end.lowerBound])
}

check("the update monitor relearns on a moved fingerprint, not only on its own button",
      updates.contains("if previous != nil, current != previous {\n                relearnAfterUpdate(agentKey: key)"))
check("ClaudeCapabilities keys its scrape on the binary, not on a per-launch Bool",
      !options.contains("scrapeStarted") && options.contains("private var scrapedKey: String?"))
check("a scrape that lands after the binary moved again is dropped",
      options.contains("guard self.scrapedKey == key else { return }"))
check("ClaudeCapabilities takes the config the recompute writes through",
      options.contains("func configure(config: ConfigManager)"))
let capabilities: String = {
    guard let start = options.range(of: "final class ClaudeCapabilities") else { return "" }
    let rest = options[start.upperBound...]
    guard let end = rest.range(of: "\n}\n") else { return String(rest) }
    return String(rest[..<end.lowerBound])
}()
check("the scrape pass warms the catalog and appends the aliases it names",
      capabilities.contains("ClaudeModelCatalog.binaryCatalog(at: binary)")
      && capabilities.contains("catalog.aliasDefault.keys.sorted()"))
check("the pass publishes the binary it read, so observers re-render onto its names",
      options.contains("@Published private(set) var catalogKey: String?"))
check("the launch configures the catalogs and starts the first read",
      app.contains("ClaudeCapabilities.shared.configure(config: configManager)")
      && app.contains("ClaudeCapabilities.shared.ensureLoaded()"))
check("the chip's title does not read the id the session last ran under",
      !body(of: "private var modelChipTitle: String {", in: composer).contains("modelFullId"))
check("the hover names the resolution, the source and the last-run id",
      composer.contains("last ran as \\(last)") && composer.contains("set by \\("))
check("the composer's appearance recomputes Other models",
      composer.contains("if !isCodex && !isKimi {\n                ClaudeModelCatalog.refreshOtherModels(config: config)"))
check("the Other models rows are titled by the row, not re-derived",
      composer.contains("ComposerOptionRow(value: $0.fullId,\n                                  title: $0.displayName")
      && panel.contains("Text(verbatim: model.displayName)"))
check("the Default row resolves through the same rule",
      composer.contains("config.resolvedModelId(forAlias: \"\")"))
check("the view passes selectedFullId only for a concrete pick",
      view.contains("selectedFullId: ClaudeModelDisplay.isFullId(picked) ? picked : nil"))
check("the view's aliasToId is the one resolution rule",
      view.contains("aliasToId: { config.resolvedModelId(forAlias: $0) }"))
check("a live observation recomputes Other models",
      body(of: "private func adoptResolvedModel(", in: view).contains("ClaudeModelCatalog.refreshOtherModels(config: config)"))
check("no per-child fact is read from the login shell",
      !options.contains("ShellEnvironment.")
      && !composer.contains("resolveIfCaptured(\"ANTHROPIC_DEFAULT")
      && !view.contains("resolveIfCaptured(\"ANTHROPIC_DEFAULT"))
check("the scans share one binary key",
      options.components(separatedBy: "binaryKey(at: path) ?? \"\\(path)|missing\"").count == 5)
let flagsBody = body(of: "func flags(for agentKey: String = \"claude_code\")", in: options)
check("no resolved name reaches the command line",
      !flagsBody.isEmpty && !flagsBody.contains("resolvedModel") && !flagsBody.contains("displayName")
      && !flagsBody.contains("binaryCatalog"))
check("the factory reset makes no new catalog call",
      reset.components(separatedBy: "ClaudeModelCatalog.").count == 3)

// ──────────────────────────────────────────────────────── real config

section("11. This machine's own config (read-only)")

let realConfig = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/SipAI/config.json")
if let data = try? Data(contentsOf: realConfig),
   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
   let map = obj["agent_model_full_ids"] as? [String: String] {
    let bad = map.filter { !ClaudeModelDisplay.canResolve(alias: $0.key, to: $0.value) }
    if bad.isEmpty {
        print("  ok    no contradicting pairing on this install (\(map.count) entries)")
    } else {
        // Not a failure: the app heals this on its next launch. It is
        // reported because the wrong NAME is all a user ever sees, and
        // seeing which alias was hit is how the report is confirmed.
        for (alias, id) in bad.sorted(by: { $0.key < $1.key }) {
            print("  note  \"\(alias)\" is recorded as \(id) — will be pruned at next launch")
        }
    }
} else {
    print("  note  no config on this machine to read")
}

// ──────────────────────────────────── 12. the installed claude

section("12. The installed claude (read-only)")

// The stub answers nil for the binary, so the real one is looked for
// where its installers put it. Report-only: a claude that carries no
// catalog is the supported fallback, not a failure.
let realHome = NSHomeDirectory()
let realClaude = [realHome + "/.local/bin/claude", "/opt/homebrew/bin/claude",
                  "/usr/local/bin/claude"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }
if let real = realClaude {
    if let cat = ClaudeModelCatalog.binaryCatalog(at: real) {
        let resolved = URL(fileURLWithPath: real).resolvingSymlinksInPath().lastPathComponent
        print("  note  \(resolved): \(cat.entries.count) models, best = \(cat.best ?? "nil")")
        for alias in cat.aliasDefault.keys.sorted() {
            let id = cat.aliasDefault[alias] ?? ""
            let wire = cat.entry(forId: id)?.firstPartyId ?? id
            let columns = (cat.aliasPerProvider[alias] ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            print("        \(alias) → \(wire)\(columns.isEmpty ? "" : "   (\(columns))")")
        }
        print("        " + cat.entries.map(\.displayName).joined(separator: ", "))
        // The join is the point: an alias must resolve to an id the
        // window table (keyed by wire id) also names.
        let table = ClaudeModelCatalog.windowTable(at: real)
        for alias in ["opus", "sonnet", "haiku", "fable"] where cat.aliasDefault[alias] != nil {
            let id = ClaudeModelCatalog.resolve(alias: alias, catalog: cat, provider: nil,
                                                environmentOverride: nil, observed: nil)?.id ?? ""
            check("\(alias) resolves to an id the window table names (\(id))", table[id] != nil)
        }
    } else {
        print("  note  the installed claude carries no catalog — the observed map answers (supported)")
    }
    // Every other version still on disk: where a moved shape shows first.
    let versions = realHome + "/.local/share/claude/versions"
    for name in ((try? FileManager.default.contentsOfDirectory(atPath: versions)) ?? []).sorted() {
        let path = versions + "/" + name
        if let cat = ClaudeModelCatalog.binaryCatalog(at: path) {
            let aliases = cat.aliasDefault.keys.sorted().map { "\($0)=\(cat.aliasDefault[$0]!)" }
            print("  note  versions/\(name): \(cat.entries.count) models, " + aliases.joined(separator: " "))
        } else {
            print("  note  versions/\(name): no catalog")
        }
    }
} else {
    print("  note  no claude installed here to read")
}

// ─────────────────────────────── 13. effort levels are per MODEL

section("13. Effort levels are the model's own, read off the same catalog")

// The failure this exists for: the effort chip offered claude's five
// `--help` levels for EVERY model. Claude's catalog says Haiku 4.5
// takes no effort at all and Opus/Sonnet 4.6 no `xhigh`, and claude
// does not refuse either — it omits the effort, or quietly runs
// `high` — so the chip named a level the turn never ran at.
let help = ["low", "medium", "high", "xhigh", "max"]
if let c = fixtureCatalog {
    func levels(_ id: String?, _ offered: [String] = help,
                catalog: ClaudeModelCatalog.BinaryCatalog? = c) -> [String] {
        ClaudeModelCatalog.effortLevels(forId: id, catalog: catalog, offered: offered)
    }
    check("capabilities are read per entry, in the binary's order",
          c.entry(forId: "claude-opus-4-6")?.capabilities == ["context_management", "effort", "max_effort"],
          "\(c.entry(forId: "claude-opus-4-6")?.capabilities ?? [])")
    check("an empty list reads as empty",
          c.entry(forId: "claude-3-5-haiku")?.capabilities == [])
    check("a value that is not a string is skipped, not recorded",
          c.entry(forId: "claude-nova-1")?.capabilities == ["effort"],
          "\(c.entry(forId: "claude-nova-1")?.capabilities ?? [])")
    // Two entries, the second's flags given as `caps`, in a table that
    // is otherwise whole — for the rules about flags that are missing,
    // unreadable or never used by any model.
    func twoEntryTable(first: String, second: String) -> String {
        "{schema_version:0,models:[{id:\"claude-opus-5\",family:\"opus\",display_name:\"Opus 5\",provider_ids:{first_party:\"claude-opus-5\"}\(first)},{id:\"claude-opus-4-6\",family:\"opus\",display_name:\"Opus 4.6\",provider_ids:{first_party:\"claude-opus-4-6\"}\(second)}],aliases:{opus:{default:\"claude-opus-5\"}},defaults:{},latest_per_family:{opus:\"claude-opus-5\"},alias_migration:{}}"
    }
    func table(_ name: String, _ body: String) -> ClaudeModelCatalog.BinaryCatalog? {
        ClaudeModelCatalog.binaryCatalog(at: fakeBinary(name, before: 1_000, body: body, after: 1_000))
    }
    let allFlags = ",capabilities:[\"effort\",\"xhigh_effort\",\"max_effort\"]"
    if let t = table("claude-caps-missing", twoEntryTable(first: allFlags, second: "")),
       let e = t.entry(forId: "claude-opus-4-6") {
        check("an entry with no capabilities key is UNKNOWN (nil), not none", e.capabilities == nil)
        check("…and keeps every level", levels("claude-opus-4-6", catalog: t) == help)
    } else {
        check("the missing-key table reads", false)
    }
    if let t = table("claude-caps-object", twoEntryTable(first: allFlags, second: ",capabilities:{effort:!0,levels:[\"low\"]}")),
       let e = t.entry(forId: "claude-opus-4-6") {
        check("a capabilities value that is not a list is skipped — the table still reads, names intact",
              e.capabilities == nil && e.displayName == "Opus 4.6" && t.aliasDefault["opus"] == "claude-opus-5")
        check("…and that entry keeps every level", levels("claude-opus-4-6", catalog: t) == help)
    } else {
        check("a capabilities object does not fail the table", false)
    }
    if let t = table("claude-caps-unused", twoEntryTable(first: ",capabilities:[\"context_management\"]",
                                                       second: ",capabilities:[]")) {
        check("a table that never lists `effort` narrows no model (a renamed flag is not \"no effort\")",
              levels("claude-opus-5", catalog: t) == help && levels("claude-opus-4-6", catalog: t) == help)
    } else {
        check("the flag-less table reads", false)
    }
    if let t = table("claude-caps-no-xhigh", twoEntryTable(first: ",capabilities:[\"effort\",\"max_effort\"]",
                                                         second: ",capabilities:[\"effort\"]")) {
        check("a flag no model lists is not narrowed, one some model lists is",
              levels("claude-opus-4-6", catalog: t) == ["low", "medium", "high", "xhigh"]
              && levels("claude-opus-5", catalog: t) == help,
              "\(levels("claude-opus-4-6", catalog: t))")
    } else {
        check("the xhigh-less table reads", false)
    }
    let badList = "{schema_version:0,models:[{id:\"claude-opus-5\",family:\"opus\",display_name:\"Opus 5\",capabilities:[\"effort\",}],aliases:{opus:{default:\"claude-opus-5\"}},defaults:{},latest_per_family:{opus:\"claude-opus-5\"},alias_migration:{}}"
    check("a malformed capabilities list fails the WHOLE catalog, never a partial entry",
          ClaudeModelCatalog.binaryCatalog(at: fakeBinary("claude-bad-caps", before: 1_000, body: badList, after: 1_000)) == nil)
    check("a model without `effort` takes none — Haiku 4.5, by its wire id",
          levels("claude-haiku-4-5-20251001") == [], "\(levels("claude-haiku-4-5-20251001"))")
    check("…and by its catalog id", levels("claude-haiku-4-5") == [])
    check("an older model the same way (Sonnet 4.5)", levels("claude-sonnet-4-5-20250929") == [])
    check("`max` without `xhigh` — Opus 4.6",
          levels("claude-opus-4-6") == ["low", "medium", "high", "max"], "\(levels("claude-opus-4-6"))")
    check("…and Sonnet 4.6", levels("claude-sonnet-4-6") == ["low", "medium", "high", "max"])
    check("every level for a model that lists both", levels("claude-fable-5-1") == help)
    check("`effort` alone is the three base levels", levels("claude-nova-1") == ["low", "medium", "high"])
    check("a variant id answers for its base entry",
          levels("claude-opus-4-6[1m]") == ["low", "medium", "high", "max"])
    check("an id the catalog does not name is NOT narrowed", levels("claude-opus-9") == help)
    check("no id (a Default nothing has resolved) is not narrowed",
          levels(nil) == help && levels("") == help)
    check("no catalog (an older binary) is not narrowed",
          levels("claude-haiku-4-5", catalog: nil) == help)
    check("the help list's order is kept, and nothing it lacks is added",
          levels("claude-fable-5-1", ["high", "low"]) == ["high", "low"]
          && levels("claude-opus-4-6", ["low", "xhigh"]) == ["low"])
    check("a level claude's gate does not name passes for a model with effort, never for one without",
          levels("claude-fable-5-1", help + ["ultra"]).contains("ultra")
          && levels("claude-haiku-4-5", help + ["ultra"]) == [])
}

// The model a send runs as, through the one resolution rule, and the
// levels the pickers offer for it.
AgentManager.claudeBinaryPath = fixturePath
_ = ClaudeModelCatalog.binaryCatalog(at: fixturePath)
MainActor.assumeIsolated {
    let config = plant(["agent_model_full_ids": ["": "claude-fable-5"]])
    check("a picked alias resolves to its wire id",
          config.resolvedClaudeModelId(picked: "haiku", configuredDefault: nil) == "claude-haiku-4-5-20251001")
    check("a picked full id is its own answer",
          config.resolvedClaudeModelId(picked: "claude-opus-4-6", configuredDefault: "haiku") == "claude-opus-4-6")
    check("no pick: the configured default answers",
          config.resolvedClaudeModelId(picked: nil, configuredDefault: "haiku") == "claude-haiku-4-5-20251001"
          && config.resolvedClaudeModelId(picked: "", configuredDefault: "haiku") == "claude-haiku-4-5-20251001")
    check("a pick outranks the configured default",
          config.resolvedClaudeModelId(picked: "sonnet", configuredDefault: "haiku") == "claude-sonnet-5")
    check("no pick and no configured default: claude's Default, through the observed family",
          config.resolvedClaudeModelId(picked: nil, configuredDefault: nil) == "claude-fable-5-1")
    check("nothing known is nil",
          plant([:]).resolvedClaudeModelId(picked: nil, configuredDefault: nil) == nil)
    let caps = ClaudeCapabilities.shared
    check("the picker offers Haiku no level",
          caps.effortLevels(forModelId: config.resolvedClaudeModelId(picked: "haiku", configuredDefault: nil)) == [])
    check("…and an Opus 4.6 pick no XHigh",
          caps.effortLevels(forModelId: "claude-opus-4-6") == ["low", "medium", "high", "max"])
    check("…and a Default that resolves to Fable 5.1 every level",
          caps.effortLevels(forModelId: config.resolvedClaudeModelId(picked: nil, configuredDefault: nil))
            == caps.effortLevels)
    check("…and nothing resolved the whole list", caps.effortLevels(forModelId: nil) == caps.effortLevels)
}
// A cache that has not read the installed binary answers the whole
// list, so a cold launch never clears or hides a level on a guess.
AgentManager.claudeBinaryPath = harnessDir.appendingPathComponent("claude-straddle").path
_ = ClaudeModelCatalog.binaryCatalog(at: fixturePath)
MainActor.assumeIsolated {
    check("a cold catalog cache narrows nothing",
          ClaudeCapabilities.shared.effortLevels(forModelId: "claude-haiku-4-5")
            == ClaudeCapabilities.shared.effortLevels)
}
AgentManager.claudeBinaryPath = fixturePath

// The installed claude, where one is: its own table, read the same way.
if let real = realClaude, let cat = ClaudeModelCatalog.binaryCatalog(at: real) {
    let named = Set(cat.entries.map(\.catalogId))
    func live(_ id: String) -> [String] {
        ClaudeModelCatalog.effortLevels(forId: id, catalog: cat, offered: help)
    }
    if named.contains("claude-haiku-4-5") {
        check("installed: Haiku 4.5 takes no effort", live("claude-haiku-4-5") == [],
              "\(live("claude-haiku-4-5")) — claude moved the flag; re-measure")
    }
    if named.contains("claude-opus-4-6") {
        check("installed: Opus 4.6 takes max but not xhigh",
              live("claude-opus-4-6") == ["low", "medium", "high", "max"], "\(live("claude-opus-4-6"))")
    }
    for alias in ["opus", "sonnet", "fable", "haiku"] where cat.aliasDefault[alias] != nil {
        let id = ClaudeModelCatalog.resolve(alias: alias, catalog: cat, provider: nil,
                                            environmentOverride: nil, observed: nil)?.id ?? ""
        let found = live(id)
        print("  note  \(alias) → \(id): \(found.isEmpty ? "no effort" : found.joined(separator: " "))")
    }
    // The flag names the rule reads must still be spelled somewhere in
    // the table, or every model reads as taking no effort.
    let flags = Set(cat.entries.flatMap { $0.capabilities ?? [] })
    check("installed: the table still spells effort, xhigh_effort and max_effort",
          flags.isSuperset(of: ["effort", "xhigh_effort", "max_effort"]), "\(flags.sorted())")
} else {
    print("  note  no installed claude with a catalog — the live effort checks are skipped")
}

// The wiring: both pickers read the per-model rule, both clear a level
// a model pick strands, and both hide the control for a model that
// takes none.
check("the composer's claude branch reads the per-model rule",
      composer.contains("return caps.effortLevels(forModelId: config.resolvedClaudeModelId(\n            picked: model, configuredDefault: configuredDefault))"))
check("the composer no longer offers claude one flat list",
      !composer.contains("return caps.effortLevels\n"))
check("a model pick clears a stranded level for every agent, claude included",
      composer.contains("if let effort = updated.effort, !effort.isEmpty,\n                   !effortLevels(forModel: value).contains(effort) {")
      && !composer.contains("if isCodex || isKimi, let effort = updated.effort"))
check("the composer hides the chip for a model that takes no level",
      composer.contains("isCodex || !effortLevels.isEmpty"))
check("the task panel's claude branch reads the same rule",
      panel.contains("return capabilities.effortLevels(forModelId: config.resolvedClaudeModelId(\n            picked: draft.model, configuredDefault: claudeConfiguredDefault))"))
check("the task panel's model picker clears a stranded level",
      panel.contains("Picker(\"\", selection: modelBinding)")
      && body(of: "private var modelBinding: Binding<String> {", in: panel)
        .contains("!taskEffortLevels.contains(effort)"))
check("the task panel hides its effort picker the same way",
      panel.contains("if isCodexTask || !taskEffortLevels.isEmpty {"))
check("the task panel re-reads the folder's configured default when the folder moves",
      panel.contains(".onChange(of: draft.workingDirectory) { _, _ in\n            refreshClaudeConfiguredDefault()"))

// ───────────── 14. the rule against what the installed claude SENDS

section("14. What the installed claude sends, against the rule (fake endpoint, token-free)")

// Section 13 predicts claude's behaviour from its table; this asks
// claude. The installed binary runs one-line turns against the fake
// Messages endpoint the ChatOnlyMode harness uses, under a throwaway
// config directory and a junk key — nothing reaches a provider — and
// the effort each REQUEST carries is held to what the picker offers: a
// level it offers is sent as asked, a model it gives no level is sent
// none, and a level it withholds is not sent as itself. The child gets
// a minimal environment, so an effort or model exported in the shell
// running the harness cannot decide a check.
let fakeServerScript = harnessSourceDir + "/../ChatOnlyMode/fake_server.py"

func startFakeServer(recordDir: URL) -> (process: Process, port: Int)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [fakeServerScript, recordDir.path]
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

/// One turn; the effort its first Messages request carried, nil for
/// none. `ran` is false when claude did not reach the endpoint at all.
func sentEffort(claude: String, model: String, effort: String, port: Int,
                recordDir: URL, scratch: URL) -> (ran: Bool, effort: String?) {
    let fm = FileManager.default
    let cfg = scratch.appendingPathComponent("cfg-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? fm.createDirectory(at: cfg, withIntermediateDirectories: true)
    let before = Set((try? fm.contentsOfDirectory(atPath: recordDir.path)) ?? [])
    let p = Process()
    p.executableURL = URL(fileURLWithPath: claude)
    p.arguments = ["-p", "Reply with OK.", "--output-format", "stream-json", "--verbose",
                   "--model", model, "--effort", effort]
    // The link's own directory first: an npm-installed claude is a node
    // script, and its node sits beside it (Homebrew, nvm).
    let linkDir = URL(fileURLWithPath: claude).deletingLastPathComponent().path
    p.environment = ["PATH": "\(linkDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                     "HOME": scratch.path,
                     "CLAUDE_CONFIG_DIR": cfg.path,
                     "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)",
                     "ANTHROPIC_API_KEY": "sk-ant-harness-junk"]
    p.currentDirectoryURL = scratch
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (false, nil) }
    let deadline = Date().addingTimeInterval(90)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if p.isRunning { p.terminate() }
    p.waitUntilExit()
    let fresh = ((try? fm.contentsOfDirectory(atPath: recordDir.path)) ?? [])
        .filter { !before.contains($0) }.sorted()
    for name in fresh {
        guard let data = try? Data(contentsOf: recordDir.appendingPathComponent(name)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let body = obj["body"] as? [String: Any], body["messages"] != nil
        else { continue }
        return (true, (body["output_config"] as? [String: Any])?["effort"] as? String)
    }
    return (false, nil)
}

if let real = realClaude, let cat = ClaudeModelCatalog.binaryCatalog(at: real),
   FileManager.default.fileExists(atPath: fakeServerScript) {
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sipai-modelchip-effort-\(ProcessInfo.processInfo.processIdentifier)",
                                isDirectory: true)
    let recordDir = scratch.appendingPathComponent("rec", isDirectory: true)
    try? FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
    if let server = startFakeServer(recordDir: recordDir) {
        let cases: [(model: String, effort: String)] = [
            ("claude-haiku-4-5-20251001", "max"), ("claude-sonnet-4-5-20250929", "high"),
            ("claude-opus-4-6", "xhigh"), ("claude-opus-4-6", "max"),
            ("claude-sonnet-4-6", "xhigh"), ("claude-fable-5-1", "xhigh"),
        ]
        for c in cases {
            guard cat.entry(forId: c.model) != nil else {
                print("  note  the installed claude no longer names \(c.model) — case skipped")
                continue
            }
            let offered = ClaudeModelCatalog.effortLevels(forId: c.model, catalog: cat, offered: help)
            let sent = sentEffort(claude: real, model: c.model, effort: c.effort,
                                  port: server.port, recordDir: recordDir, scratch: scratch)
            let said = sent.effort ?? "none"
            if !sent.ran {
                check("\(c.model) --effort \(c.effort) reached the fake endpoint", false)
            } else if offered.isEmpty {
                check("\(c.model): no level offered, and claude sends none for --effort \(c.effort)",
                      sent.effort == nil, "sent \(said)")
            } else if offered.contains(c.effort) {
                check("\(c.model): \(c.effort) is offered, and claude sends it as asked",
                      sent.effort == c.effort, "sent \(said)")
            } else {
                check("\(c.model): \(c.effort) is withheld, and claude does not send it as itself",
                      sent.effort != c.effort, "sent \(said)")
            }
        }
        // The documented gap, reported rather than failed: claude still
        // takes effort for an entry that does not flag it.
        if cat.entry(forId: "claude-opus-4-5-20251101") != nil {
            let sent = sentEffort(claude: real, model: "claude-opus-4-5-20251101", effort: "high",
                                  port: server.port, recordDir: recordDir, scratch: scratch)
            let offered = ClaudeModelCatalog.effortLevels(forId: "claude-opus-4-5-20251101",
                                                          catalog: cat, offered: help)
            print("  note  Opus 4.5 (known gap): the picker offers \(offered.isEmpty ? "no level" : offered.joined(separator: " ")); claude sends \(sent.effort ?? "none") for --effort high")
        }
        server.process.terminate()
        server.process.waitUntilExit()
    } else {
        print("  note  the fake endpoint did not start — section skipped")
    }
    try? FileManager.default.removeItem(at: scratch)
} else {
    print("  note  no installed claude with a catalog, or no fake endpoint script — section skipped")
}

// ─────────────────────────────────────────────────────────── summary

// The scratch directory holds an 8 MB fake binary (the straddle case);
// left behind, every run adds one to $TMPDIR.
try? FileManager.default.removeItem(at: harnessDir)

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
