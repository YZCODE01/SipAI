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

/// Source root, so the structural pass can be pointed at another
/// checkout (`./run.sh <source-root>`) to confirm it fails there.
let sourceRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func read(_ relative: String) -> String {
    (try? String(contentsOfFile: sourceRoot + "/" + relative,
                 encoding: .utf8)) ?? ""
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

section("5. This machine's own config (read-only)")

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

// ─────────────────────────────────────────────────────────── summary

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
