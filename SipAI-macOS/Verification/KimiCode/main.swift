// main.swift — headless exercise of the kimi readers against fixtures.
//
// This does NOT prove the fixtures match what Kimi Code writes; only
// `run.sh` against a real binary can do that. What it proves is the
// half that is ours: given records of the documented shape, the parser
// and the scanner produce the rows the transcript expects — and, more
// usefully, that the traps this app has already been bitten by are
// closed (JSON null read as absent, request traces not replayed as
// conversation, a bounded lossy read, the cwd falling back through the
// bucket rather than to $HOME).
//
// Run via ./fixtures.sh.

import Foundation

var passed = 0
var failed = 0

func check(_ label: String, _ condition: @autoclosure () -> Bool,
           _ detail: @autoclosure () -> String = "") {
    if condition() {
        print("  PASS  \(label)")
        passed += 1
    } else {
        let d = detail()
        print("  FAIL  \(label)")
        if !d.isEmpty { print("        → \(d)") }
        failed += 1
    }
}

func section(_ title: String) { print("\n\(title)") }

/// Expected timestamps are written as the ISO strings the fixtures
/// carry, and parsed by the SAME parser the scanner uses — a hand-typed
/// epoch is a second implementation of the thing under test, and the
/// first draft of this file got one wrong.
func iso(_ s: String) -> Date? { AgentSessionScanner.isoDate(s) }

// MARK: - Fixture store

/// Under Caches rather than $TMPDIR, and not by accident: the scanner
/// drops any session whose cwd sits in a system temp root, so a fixture
/// built in `NSTemporaryDirectory()` scans as zero sessions and every
/// assertion below passes vacuously. (Asked for on the first run: it
/// did exactly that.) `/private/tmp` is used deliberately further down,
/// for the one session that SHOULD be dropped.
let fm = FileManager.default
let root = fm.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/sipai-kimi-fixture-\(UUID().uuidString)")

/// A space in the folder name on purpose — the dash-decoding fallback
/// is the part of path handling this repo has regressed on before.
let projectDir = root.appendingPathComponent("Project With Spaces")
try! fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

func writeSession(bucket: String, id: String, state: String,
                  wire: [String]) {
    let dir = root
        .appendingPathComponent("sessions")
        .appendingPathComponent(bucket)
        .appendingPathComponent(id)
    let agents = dir.appendingPathComponent("agents/main")
    try! fm.createDirectory(at: agents, withIntermediateDirectories: true)
    try! state.write(to: dir.appendingPathComponent("state.json"),
                     atomically: true, encoding: .utf8)
    let body = wire.joined(separator: "\n") + (wire.isEmpty ? "" : "\n")
    try! body.write(to: agents.appendingPathComponent("wire.jsonl"),
                    atomically: true, encoding: .utf8)
}

setenv("KIMI_CODE_HOME", root.path, 1)

// A session that records its cwd, holds a real exchange, and opens
// with the request trace the docs say wire.jsonl carries.
writeSession(
    bucket: "bucket-a",
    id: "sess-alpha",
    state: #"{"title":"Indexed title","cwd":"\#(projectDir.path)","createdAt":"2026-08-13T09:00:00.000Z"}"#,
    wire: [
        // Request trace: embeds the WHOLE conversation + tool schemas.
        // Replaying it would print every turn twice.
        #"{"type":"llm_request","tools":[{"name":"Read"}],"messages":[{"role":"user","content":"REPLAYED"},{"role":"assistant","content":"REPLAYED"}]}"#,
        #"{"role":"user","content":"first question","timestamp":"2026-08-13T09:00:01.000Z"}"#,
        #"{"role":"assistant","content":"thinking out loud","tool_calls":[{"type":"function","id":"tc_1","function":{"name":"Bash","arguments":"{\"command\":\"ls -la\"}"}}],"timestamp":"2026-08-13T09:00:02.000Z"}"#,
        #"{"role":"tool","tool_call_id":"tc_1","content":"total 0","timestamp":"2026-08-13T09:00:03.000Z"}"#,
        // `tools: null` must NOT read as a request trace (NSNull trap).
        #"{"role":"user","content":"second question","tools":null,"timestamp":"2026-08-13T09:05:00.000Z"}"#,
        #"{"role":"assistant","content":"final answer","error":null,"timestamp":"2026-08-13T09:05:04.000Z"}"#,
        // A wrapped envelope, and a system record that is not conversation.
        #"{"type":"event","event":{"role":"system","content":"you are kimi"}}"#,
    ])

// Same bucket, NO cwd of its own — must inherit the bucket's.
writeSession(
    bucket: "bucket-a",
    id: "sess-beta",
    state: #"{"createdAt":"2026-08-13T10:00:00.000Z"}"#,
    wire: [
        #"{"role":"user","content":"<scheduled-task name=\"nightly-audit\"></scheduled-task>run the audit","timestamp":"2026-08-13T10:00:01.000Z"}"#,
        #"{"role":"assistant","content":"done","timestamp":"2026-08-13T10:00:09.000Z"}"#,
    ])

// A scratch session: cwd inside a system temp root.
writeSession(
    bucket: "bucket-tmp",
    id: "sess-scratch",
    state: #"{"cwd":"/private/tmp/probe","createdAt":"2026-08-13T11:00:00.000Z"}"#,
    wire: [#"{"role":"user","content":"probe","timestamp":"2026-08-13T11:00:01.000Z"}"#])

// A session whose wire file is empty — an abandoned shell.
writeSession(bucket: "bucket-a", id: "sess-empty",
             state: #"{"createdAt":"2026-08-13T12:00:00.000Z"}"#, wire: [])

try! #"{"id":"sess-alpha","title":"Indexed title"}"#
    .write(to: root.appendingPathComponent("session_index.jsonl"),
           atomically: true, encoding: .utf8)

// NOT a `defer`: this file ends in `exit()`, which does not run them.

// MARK: - Store location

section("Store location")
check("KIMI_CODE_HOME is honoured",
      KimiSessionScanner.sessionRoot.path
        == root.appendingPathComponent("sessions").path,
      KimiSessionScanner.sessionRoot.path)
check("storeExists sees the fixture", KimiSessionScanner.storeExists)

// MARK: - Scan

section("Scan")
let sessions = KimiSessionScanner.scan()
let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

check("scratch session is dropped", byId["sess-scratch"] == nil,
      "found \(sessions.count) sessions: \(sessions.map(\.id))")
check("three real sessions remain", sessions.count == 3,
      "\(sessions.map(\.id))")
check("every row is tagged kimi", sessions.allSatisfy { $0.agentKey == "kimi" })

if let alpha = byId["sess-alpha"] {
    check("alpha takes its title from the index",
          alpha.title == "Indexed title", alpha.title)
    check("alpha's cwd comes from state.json",
          alpha.projectPath?.path == projectDir.path,
          alpha.projectPath?.path ?? "nil")
    check("alpha points at agents/main/wire.jsonl",
          alpha.fileURL.pathComponents.suffix(3) == ["agents", "main", "wire.jsonl"],
          alpha.fileURL.path)
    check("alpha's activity is its LAST user message, not the first",
          alpha.lastUserMessageAt == iso("2026-08-13T09:05:00.000Z"),
          String(describing: alpha.lastUserMessageAt))
    check("alpha is not an empty shell", alpha.isEmptyShell == false)
} else {
    check("alpha was scanned", false)
}

if let beta = byId["sess-beta"] {
    check("beta inherits the bucket's cwd (never $HOME)",
          beta.projectPath?.path == projectDir.path,
          beta.projectPath?.path ?? "nil")
    check("beta is filed under its scheduled task",
          beta.scheduledTaskName == "nightly-audit",
          beta.scheduledTaskName ?? "nil")
    check("beta's title is the prompt, not the marker",
          beta.title == "run the audit", beta.title)
} else {
    check("beta was scanned", false)
}

if let empty = byId["sess-empty"] {
    check("an empty wire file marks an empty shell", empty.isEmptyShell)
} else {
    check("the empty shell was scanned", false)
}

check("sessionIds() sees every directory, scratch included",
      KimiSessionScanner.sessionIds().isSuperset(of:
        ["sess-alpha", "sess-beta", "sess-scratch", "sess-empty"]))

// MARK: - Session directory / discovery

section("Session directory and discovery")
if let alpha = byId["sess-alpha"] {
    check("sessionDirectory walks back up from the wire file",
          KimiSessionScanner.sessionDirectory(of: alpha.fileURL)?
            .lastPathComponent == "sess-alpha",
          KimiSessionScanner.sessionDirectory(of: alpha.fileURL)?.path ?? "nil")
}
check("discovery ignores ids it already knew",
      KimiSessionScanner.discoverSession(
        cwd: projectDir,
        excluding: ["sess-alpha", "sess-beta", "sess-scratch", "sess-empty"],
        since: Date(timeIntervalSince1970: 0)) == nil)
check("discovery ignores a session in another folder",
      KimiSessionScanner.discoverSession(
        cwd: URL(fileURLWithPath: "/Users/nobody/elsewhere"),
        excluding: [], since: Date(timeIntervalSince1970: 0)) == nil)
check("discovery ignores a directory older than the send",
      KimiSessionScanner.discoverSession(
        cwd: projectDir, excluding: [],
        since: Date().addingTimeInterval(3600)) == nil)
let found = KimiSessionScanner.discoverSession(
    cwd: projectDir, excluding: ["sess-beta", "sess-empty"],
    since: Date(timeIntervalSince1970: 0))
check("discovery finds the one new session for this cwd",
      found?.id == "sess-alpha", found?.id ?? "nil")

// MARK: - History

section("History (readHistory)")
if let alpha = byId["sess-alpha"] {
    let items = KimiSessionScanner.readHistory(of: alpha.fileURL)
    var users: [String] = []
    var assistants: [String] = []
    var tools: [(String, String)] = []
    var results: [(String, String, Bool)] = []
    for item in items {
        switch item.kind {
        case .userText(let t): users.append(t)
        case .assistantText(let t): assistants.append(t)
        case .toolUse(_, let name, let input):
            tools.append((name, (input["command"] as? String) ?? ""))
        case .toolResult(let id, let c, let e): results.append((id, c, e))
        case .interrupted, .compaction: break
        }
    }
    check("the request trace is NOT replayed as conversation",
          !users.contains("REPLAYED") && !assistants.contains("REPLAYED"),
          "users=\(users) assistants=\(assistants)")
    check("both user messages are read", users.count == 2, "\(users)")
    check("a `tools: null` record is still a message",
          users.contains("second question"), "\(users)")
    check("the scheduled-task marker is stripped from the bubble",
          !users.contains { $0.contains("<scheduled-task") }, "\(users)")
    check("assistant text is read", assistants == ["thinking out loud", "final answer"],
          "\(assistants)")
    check("a tool call becomes a tool row with its arguments parsed",
          tools.first?.0 == "Bash" && tools.first?.1 == "ls -la",
          "\(tools)")
    check("the tool result pairs by tool_call_id",
          results.first?.0 == "tc_1" && results.first?.1 == "total 0",
          "\(results)")
    check("`error: null` does not mark a result as failed",
          results.allSatisfy { !$0.2 }, "\(results)")
    check("a system record is not conversation",
          !assistants.contains("you are kimi")
            && !users.contains("you are kimi"))
}

// MARK: - Stdout parser

section("Stdout parser (KimiEventParser)")
let cwd = projectDir

func kinds(_ line: String) -> [StreamEventKind] {
    KimiEventParser.parse(line: line, fallbackCwd: cwd).map(\.kind)
}

check("a user echo is dropped (send() already drew it)",
      kinds(#"{"role":"user","content":"hi"}"#).isEmpty)

let assistant = kinds(#"{"role":"assistant","content":"hello","tool_calls":[{"type":"function","id":"tc_9","function":{"name":"Read","arguments":"{\"file_path\":\"/tmp/x\"}"}}]}"#)
check("assistant text + tool call are two events", assistant.count == 2,
      "\(assistant.count)")
if case .assistantText(let t)? = assistant.first {
    check("assistant text is carried through", t == "hello", t)
} else { check("first event is assistant text", false) }
if assistant.count > 1, case .toolUse(let id, let name, let input) = assistant[1] {
    check("tool call keeps its id and name", id == "tc_9" && name == "Read",
          "\(id) \(name)")
    check("JSON-string arguments are decoded",
          (input["file_path"] as? String) == "/tmp/x", "\(input)")
} else { check("second event is a tool use", false) }

let toolResult = kinds(#"{"role":"tool","tool_call_id":"tc_9","content":"file body"}"#)
if case .toolResult(let id, let out, let err)? = toolResult.first {
    check("tool result decodes", id == "tc_9" && out == "file body" && !err,
          "\(id) \(out) \(err)")
} else { check("tool role yields a tool result", false) }

check("a tool result with no id is dropped rather than orphaned",
      kinds(#"{"role":"tool","content":"nowhere to attach"}"#).isEmpty)

// The PTY trap that cost codex a silently blank transcript.
let dirty = kinds("\u{4}\u{8}\u{8}{\"role\":\"assistant\",\"content\":\"through a pty\"}\r")
if case .assistantText(let t)? = dirty.first {
    check("tty handshake bytes + CRLF are tolerated", t == "through a pty", t)
} else { check("a pty-dirtied line still parses", false, "\(dirty.count) events") }

check("a blank line is not an event", kinds("").isEmpty)
check("garbage is not an event", kinds("not json at all").isEmpty)

let blocks = kinds(#"{"role":"assistant","content":[{"type":"text","text":"block one"},{"type":"image"},{"type":"text","text":"block two"}]}"#)
if case .assistantText(let t)? = blocks.first {
    check("array content is flattened, non-text blocks invent nothing",
          t == "block one\nblock two", t.debugDescription)
} else { check("array content parses", false) }

if case .error(let m)? = kinds(#"{"type":"error","message":"rate limited"}"#).first {
    check("an error record surfaces its message", m == "rate limited", m)
} else { check("error records parse", false) }

check("`error: null` on an assistant record is not an error",
      kinds(#"{"role":"assistant","content":"fine","error":null}"#)
        .contains { if case .error = $0 { return true }; return false } == false)

// MARK: - Launch flags

section("Launch flags")
var options = AgentLaunchOptions()
options.permissionMode = "bypassPermissions"   // leaked from another agent
options.effort = "xhigh"
check("a permission mode never reaches kimi's argv",
      options.flags(for: "kimi").isEmpty,
      "\(options.flags(for: "kimi"))")
options.model = "kimi-k2.5"
check("only the model is emitted",
      options.flags(for: "kimi") == ["--model", "kimi-k2.5"],
      "\(options.flags(for: "kimi"))")

// Effort has no flag on kimi — it travels as an env var, so it must
// keep OUT of argv and land in the overlay instead.
check("effort stays out of kimi's argv",
      options.flags(for: "kimi").contains("--effort") == false,
      "\(options.flags(for: "kimi"))")
check("effort becomes the env override",
      KimiCapabilities.environmentOverlay(agentKey: "kimi", effort: "xhigh")
        == ["KIMI_MODEL_THINKING_EFFORT": "xhigh"])
check("Default effort sets NO variable — kimi's own model-aware effort stands",
      KimiCapabilities.environmentOverlay(agentKey: "kimi", effort: nil).isEmpty)
check("a blank effort sets no variable either",
      KimiCapabilities.environmentOverlay(agentKey: "kimi", effort: "  ").isEmpty)
check("no other agent gets the kimi override",
      KimiCapabilities.environmentOverlay(agentKey: "claude_code",
                                          effort: "xhigh").isEmpty)

// MARK: - config.toml

// The picker's whole source of truth: measured on kimi 0.36.1,
// `--model <alias>` fails the turn unless the alias has a
// `[models.<alias>]` table, and the default is `default_model`.
section("config.toml")

let cfg = KimiCatalog.parseConfig("""
# a comment
default_model = "k2-turbo"   # trailing comment

[thinking]
effort = "high"

[models.k2-turbo]
provider = "moonshot"

[models."kimi-k2-thinking"]
provider = "moonshot"

[models.k2-turbo.params]
temperature = 0.6

[secondary_model]
default_model = "cheap-one"

[secondary_model.models.subagent-only]
provider = "moonshot"
""")
check("default_model is read", cfg.defaultModel == "k2-turbo",
      cfg.defaultModel ?? "nil")
check("[secondary_model] default_model does not win",
      cfg.defaultModel != "cheap-one", cfg.defaultModel ?? "nil")
let cfgSlugs = cfg.models.map(\.slug)
check("bare and quoted [models.*] aliases are both collected",
      cfgSlugs.contains("k2-turbo") && cfgSlugs.contains("kimi-k2-thinking"),
      "\(cfgSlugs)")
check("a nested [models.x.y] table adds no second alias",
      cfgSlugs.filter { $0 == "k2-turbo" }.count == 1, "\(cfgSlugs)")
check("[secondary_model.models.*] is not a picker row",
      cfgSlugs.contains("subagent-only") == false, "\(cfgSlugs)")
check("the default model sorts first", cfgSlugs.first == "k2-turbo",
      "\(cfgSlugs)")

// The shape kimi's OWN writer produces (`kimi provider catalog add`).
// Every alias it generates is quoted and contains a slash, and the
// models carry the two fields the picker reads.
let real = KimiCatalog.parseConfig("""
[providers.kimi-for-coding]
base_url = "https://api.kimi.com/coding"
type = "anthropic"

[models."kimi-for-coding/k3-256k"]
provider = "kimi-for-coding"
model = "k3-256k"
max_context_size = 262_144
capabilities = [ "image_in", "thinking", "tool_use" ]
display_name = "Kimi K3-256K"
support_efforts = [ "low", "high", "max" ]

[models."kimi-for-coding/kimi-for-coding-highspeed"]
provider = "kimi-for-coding"
display_name = "Kimi For Coding HighSpeed"
""")
check("a slash in a quoted alias survives",
      real.models.map(\.slug).contains("kimi-for-coding/k3-256k"),
      "\(real.models.map(\.slug))")
check("display_name is read for the chip",
      real.models.first { $0.slug == "kimi-for-coding/k3-256k" }?
        .displayName == "Kimi K3-256K")
check("support_efforts is read per model",
      real.models.first { $0.slug == "kimi-for-coding/k3-256k" }?
        .efforts == ["low", "high", "max"],
      "\(real.models.first { $0.slug == "kimi-for-coding/k3-256k" }?.efforts ?? [])")
check("a model declaring no support_efforts gets an empty list, not a guess",
      real.models.first { $0.slug.hasSuffix("highspeed") }?.efforts == [])
check("`capabilities` is not mistaken for an effort list",
      real.models.first { $0.slug == "kimi-for-coding/k3-256k" }?
        .efforts.contains("tool_use") == false)
// Moonshot's own changelog lists "thinking levels being offered for
// models that do not support them" as a bug they FIXED. A model that
// publishes no support_efforts must therefore offer none — not the
// union, which is only for a model we have no information about.
check("a model publishing no support_efforts offers NO levels",
      real.models.first { $0.slug.hasSuffix("highspeed") }
        .map { $0.efforts.isEmpty } == true)
check("the union is not reachable from a model we DO know",
      real.models.allSatisfy { $0.efforts != KimiCapabilities.effortLevels })
// `max_context_size` feeds the token chip's occupancy tooltip; TOML
// allows `262_144`, and kimi's writer emits bare digits — both must
// read as one number.
check("max_context_size is read per model, underscores included",
      real.models.first { $0.slug == "kimi-for-coding/k3-256k" }?
        .maxContextSize == 262_144,
      "\(String(describing: real.models.first { $0.slug == "kimi-for-coding/k3-256k" }?.maxContextSize))")
check("a model declaring no max_context_size answers nil, not a guess",
      real.models.first { $0.slug.hasSuffix("highspeed") }?
        .maxContextSize == nil)

// A dot inside a QUOTED alias is part of the name; a dot in a BARE
// header separates a sub-table. Getting this backwards truncates every
// dotted model id — and dotted ids (k2.5, gpt-5.5) are the norm.
check("a dotted quoted alias is not truncated",
      KimiCatalog.parseConfig("[models.\"vendor/gpt-5.5\"]\nx = 1")
        .models.map(\.slug) == ["vendor/gpt-5.5"],
      "\(KimiCatalog.parseConfig("[models.\"vendor/gpt-5.5\"]\nx = 1").models.map(\.slug))")
check("a bare dotted header is still a sub-table of its head",
      KimiCatalog.parseConfig("[models.plain]\n[models.plain.params]\nx = 1")
        .models.map(\.slug) == ["plain"])

// v1 spelling: kimi still honours a lone `model` as the default, so we
// do too — but only when `default_model` is absent.
check("legacy `model` is honoured as a fallback default",
      KimiCatalog.parseConfig("model = \"old-one\"").defaultModel == "old-one")
check("`default_model` outranks legacy `model` whichever comes first",
      KimiCatalog.parseConfig("model = \"old\"\ndefault_model = \"new\"")
        .defaultModel == "new")
check("kimi's own seeded stub yields nothing rather than a guess",
      KimiCatalog.parseConfig("""
      # ~/.kimi-code/config.toml
      # This file starts empty so built-in defaults can apply.
      """).defaultModel == nil)

// MARK: - The real wire envelope

// Every record below is COPIED VERBATIM out of a session kimi 0.36.1
// actually wrote (2026-08-14), including a real tool call. This is the
// half of the store that was pure guesswork until then, and the guess
// was wrong in the way that matters most: kimi records only the USER's
// half as chat messages. Everything the agent does is a loop EVENT
// with no `role` in it, so a transcript replayed as the user's prompts
// and nothing else — live streaming worked, reopening the session
// showed half a conversation.
section("Wire envelope (verbatim from kimi 0.36.1)")

writeSession(bucket: "wd_real_aaaa", id: "session_real",
             state: #"{"id":"session_real","cwd":"\#(projectDir.path)","createdAt":1786766760876}"#,
             wire: [
    #"{"type":"metadata","protocol_version":"1.5","created_at":1786766760890}"#,
    #"{"type":"profile.bind","modelAlias":"moonshot-ai/kimi-k3","thinkingEffort":"max","systemPrompt":"You are Kimi Code CLI…"}"#,
    #"{"type":"permission.set_mode","mode":"auto","time":1786766760912}"#,
    #"{"type":"turn.prompt","input":[{"type":"text","text":"Create a file"}],"origin":{"kind":"user"},"time":1786766760913}"#,
    #"{"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"Create a file"}],"toolCalls":[]},"time":1786766760914}"#,
    #"{"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>\nAuto permission mode is active."}]},"time":1786766760914}"#,
    #"{"type":"llm.tools_snapshot","hash":"f75b","tools":[{"name":"Agent","description":"Launch a subagent"}]}"#,
    #"{"type":"llm.request","kind":"loop","model":"kimi-k3","thinkingEffort":"low","messages":[{"role":"user","content":"Create a file"}]}"#,
    #"{"type":"context.append_loop_event","event":{"type":"step.begin","turnId":"0","step":1},"time":1786766760915}"#,
    #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"think","think":"The user wants a file. Simple."}},"time":1786766761000}"#,
    #"{"type":"context.append_loop_event","event":{"type":"tool.call","toolCallId":"Write_0","name":"Write","args":{"path":"probe.txt","content":"HELLO"}},"time":1786766761100}"#,
    #"{"type":"context.append_loop_event","event":{"type":"tool.result","parentUuid":"3dd8","toolCallId":"Write_0","result":{"output":"Wrote 5 bytes to probe.txt"}},"time":1786766761200}"#,
    #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"Done — probe.txt created."}},"time":1786766761300}"#,
    #"{"type":"context.append_loop_event","event":{"type":"step.end","turnId":"0","finishReason":"end_turn"},"time":1786766761400}"#,
    #"{"type":"usage.record","model":"moonshot-ai/kimi-k3","usage":{"inputOther":2045,"output":42,"inputCacheRead":18944},"usageScope":"turn"}"#,
    #"{"type":"turn.ended","turnId":0,"reason":"completed","durationMs":6847,"time":1786766767760}"#,
])

let realWire = KimiSessionScanner.sessionRoot
    .appendingPathComponent("wd_real_aaaa/session_real/agents/main/wire.jsonl")
let rows = KimiSessionScanner.readHistory(of: realWire)

func kindName(_ k: AgentSessionHistoryItem.Kind) -> String {
    switch k {
    case .userText: return "user"
    case .assistantText: return "assistant"
    case .toolUse: return "tool_use"
    case .toolResult: return "tool_result"
    default: return "other"
    }
}
let shape = rows.map { kindName($0.kind) }
check("the whole turn replays in order",
      shape == ["user", "tool_use", "tool_result", "assistant"], "\(shape)")

if case .assistantText(let t)? = rows.first(where: {
    if case .assistantText = $0.kind { return true }; return false
})?.kind {
    check("assistant text comes from content.part, not a chat message",
          t == "Done — probe.txt created.", t)
} else { check("assistant text is recovered at all", false) }

if case .toolUse(let id, let name, let input)? = rows.first(where: {
    if case .toolUse = $0.kind { return true }; return false
})?.kind {
    check("tool.call keeps its id and name", id == "Write_0" && name == "Write")
    check("tool.call args become the tool input",
          input["path"] as? String == "probe.txt", "\(input.keys)")
} else { check("a tool call is recovered", false) }

if case .toolResult(let id, let out, let err)? = rows.first(where: {
    if case .toolResult = $0.kind { return true }; return false
})?.kind {
    check("tool.result pairs by toolCallId", id == "Write_0")
    check("tool.result output is read", out == "Wrote 5 bytes to probe.txt", out)
    check("a successful tool result is not an error", err == false)
} else { check("a tool result is recovered", false) }

check("the injected <system-reminder> is not a user turn",
      rows.allSatisfy {
          if case .userText(let t) = $0.kind { return !t.contains("system-reminder") }
          return true
      })
check("`think` parts are not replayed as replies",
      rows.allSatisfy {
          if case .assistantText(let t) = $0.kind { return !t.contains("Simple.") }
          return true
      })
check("llm.request does NOT replay the conversation it embedded",
      rows.filter { kindName($0.kind) == "user" }.count == 1, "\(shape)")
check("the derived title comes from the real prompt, not the reminder",
      KimiSessionScanner.scan().first { $0.id == "session_real" }?
        .title.contains("Create a file") == true)

// The context chip. Reading `inputOther` alone would under-report by
// the whole cached prefix; reading a record NOT scoped to a turn is how
// claude got "14242k tokens" and codex got "19741k". The call's own
// OUTPUT is excluded on purpose — kimi's own status bar divides the
// input side by the model's window, and this chip has to agree with the
// terminal a user can hold beside it.
check("context tokens sum the three INPUT fields, not the output",
      KimiSessionScanner.lastContextTokens(of: realWire) == 2045 + 18944,
      "\(KimiSessionScanner.lastContextTokens(of: realWire))")
// The record's `model` string IS the config alias — the join that
// lets the occupancy tooltip divide by that entry's
// `max_context_size` instead of the claude constant.
check("the usage record's model rides out with the tokens",
      KimiSessionScanner.lastContextUsage(of: realWire).model
        == "moonshot-ai/kimi-k3",
      "\(String(describing: KimiSessionScanner.lastContextUsage(of: realWire).model))")

// Kimi's own announcement of its session id, verbatim from a real run.
check("the resume hint yields the session id",
      KimiEventParser.announcedSessionId(line:
        #"{"role":"meta","type":"session.resume_hint","session_id":"session_8c83","command":"kimi -r session_8c83"}"#)
        == "session_8c83")
check("an ordinary meta line announces nothing",
      KimiEventParser.announcedSessionId(line:
        #"{"role":"meta","type":"system.version","version":"0.36.1"}"#) == nil)
check("a session_id on some OTHER record is not adopted",
      KimiEventParser.announcedSessionId(line:
        #"{"role":"meta","type":"something.else","session_id":"session_wrong"}"#) == nil)
check("the resume hint is not also a transcript row",
      KimiEventParser.parse(line:
        #"{"role":"meta","type":"session.resume_hint","session_id":"session_8c83"}"#,
        fallbackCwd: projectDir).isEmpty)
check("a session directory is locatable by id alone",
      KimiSessionScanner.sessionDirectory(forId: "session_real")?
        .lastPathComponent == "session_real")

// MARK: - Summary

try? fm.removeItem(at: root)
print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
