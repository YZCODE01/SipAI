// Headless verification for the composer's "Chat only" mode. See run.sh.
//
// Not part of the app target — this directory sits outside SipAI/, and
// the Xcode project lists its sources explicitly.
//
// Same discipline as ScheduledTaskScheduler.decide: the argv rules, the
// gate, the policy-file codec and the server request layer are pure
// functions of their inputs, exercised without an AgentManager or a
// window. The REAL readers, the REAL policy file and the REAL server
// driver are compiled (Stubs.swift stands in for the app types around
// them), and the CLI sections drive the REAL binaries against a FAKE
// local endpoint under throwaway homes — token-free.

import Foundation

var failures = 0
var checks = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    print((ok ? "  ok   " : "  FAIL ") + label + (detail.isEmpty ? "" : " — \(detail)"))
    if !ok { failures += 1 }
}
func skip(_ label: String, _ why: String) {
    print("  SKIP " + label + " — " + why)
}
func note(_ text: String) { print("  note " + text) }

let env = ProcessInfo.processInfo.environment
let fixtures = URL(fileURLWithPath: env["SIPAI_CHATONLY_FIXTURES"] ?? "fixtures", isDirectory: true)
let sourceRoot = URL(fileURLWithPath: env["SIPAI_CHATONLY_SRC"] ?? "../..", isDirectory: true)
let serverScript = env["SIPAI_CHATONLY_SERVER"] ?? "fake_server.py"
let liveTurns = env["SIPAI_CHATONLY_LIVE"] == "1"
let liveThoughts = env["SIPAI_CHATONLY_LIVE_THOUGHTS"] == "1"
/// Which agents the live thoughts section spends a turn on — all three
/// unless `SIPAI_CHATONLY_LIVE_AGENTS` names some (comma-separated keys).
let liveThoughtAgents = Set((env["SIPAI_CHATONLY_LIVE_AGENTS"] ?? "claude_code,codex,kimi")
    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
let fm = FileManager.default
/// A complete one-pixel PNG: codex reads the file it is handed and kimi
/// decodes what it is sent, so a stand-in string will not do here.
let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

// Scrape-environment probe: a SUB-invocation of this binary that section
// 6b makes under the GUI app's bare launchd PATH. It drives the REAL
// `CodexCatalog.ensureLoaded()` (and so the real `featuresListing`),
// with the provider installed exactly as `SipAIApp.init` installs it
// ("provider") or not at all ("none"), and prints what the catalog
// ended up holding. Runs before anything else and exits.
if let probeMode = env["SIPAI_CHATONLY_SCRAPE_PROBE"] {
    // Top-level code runs on the main thread; the catalog is MainActor
    // state, and `RunLoop.main` drains the hops its detached read makes.
    let line: String = MainActor.assumeIsolated {
        if probeMode == "provider" {
            CLIScrapeEnvironment.provider = {
                await ShellEnvironment.prepare()
                return AgentRunner.buildEnvironment()
            }
        }
        CodexCatalog.shared.ensureLoaded()
        // A working read lands in well under a second; a launcher that
        // cannot start fails instantly — so a few seconds with nothing
        // is the failure, and the provider case returns as soon as the
        // names land.
        let deadline = Date().addingTimeInterval(probeMode == "provider" ? 30 : 6)
        while CodexCatalog.shared.featureNames == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let names = CodexCatalog.shared.featureNames
        let required = names.map { ChatOnlyAvailability.codexRequiredFeatures.isSubset(of: $0) } ?? false
        return "PROBE features=\(names?.count ?? -1) required=\(required)"
    }
    print(line)
    exit(0)
}

// MARK: - Helpers

func real(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

func lines(of url: URL) -> [String] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

func object(_ line: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
}

func source(_ relative: String) -> String {
    (try? String(contentsOf: sourceRoot.appendingPathComponent(relative), encoding: .utf8)) ?? ""
}

/// Run a CLI to completion with a bounded wait; returns stdout+stderr.
func run(_ path: String, _ args: [String], cwd: URL? = nil,
         environment: [String: String] = [:], timeout: TimeInterval = 120) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    var e = ProcessInfo.processInfo.environment
    for key in e.keys where key.hasPrefix("DYLD_") { e.removeValue(forKey: key) }
    for (k, v) in environment { e[k] = v }
    p.environment = e
    if let cwd { p.currentDirectoryURL = cwd }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    var data = Data()
    let reader = DispatchQueue(label: "harness.read")
    let done = DispatchSemaphore(value: 0)
    reader.async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
    if p.isRunning { p.terminate() }
    p.waitUntilExit()
    _ = done.wait(timeout: .now() + 5)
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// The fake model endpoint: one process per section, recording every
/// request it receives into a directory the test reads back.
final class FakeServer {
    let recordDir: URL
    let port: Int
    private let process: Process
    private var counter = 0

    init?(script: [String: Any]? = nil, anthropicScript: [String: Any]? = nil, chatDelay: Double = 0,
          think: Bool = false) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sipai-chatonly-fake-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        recordDir = dir.appendingPathComponent("rec", isDirectory: true)
        var args = [serverScript, recordDir.path]
        if let script {
            let file = dir.appendingPathComponent("script.json")
            try? JSONSerialization.data(withJSONObject: script).write(to: file)
            args += ["--script", file.path]
        }
        if let anthropicScript {
            let file = dir.appendingPathComponent("anthropic-script.json")
            try? JSONSerialization.data(withJSONObject: anthropicScript).write(to: file)
            args += ["--anthropic-script", file.path]
        }
        if chatDelay > 0 { args += ["--chat-delay", String(chatDelay)] }
        if think { args.append("--think") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        process = p
        // The port line is the first thing it prints.
        var text = ""
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05); continue }
            text += String(decoding: chunk, as: UTF8.self)
            if text.contains("\n") { break }
        }
        guard let range = text.range(of: "PORT="),
              let found = Int(text[range.upperBound...].prefix { $0.isNumber }) else {
            p.terminate()
            return nil
        }
        port = found
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    /// Every request recorded so far, oldest first; `body` is the parsed
    /// JSON body.
    func requests() -> [[String: Any]] {
        guard let names = try? fm.contentsOfDirectory(atPath: recordDir.path) else { return [] }
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json"),
                  let data = try? Data(contentsOf: recordDir.appendingPathComponent(name)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }
    }

    func clear() {
        try? fm.removeItem(at: recordDir)
        try? fm.createDirectory(at: recordDir, withIntermediateDirectories: true)
    }

    func newest() -> [String: Any]? { requests().last }
    func body(_ request: [String: Any]?) -> [String: Any] { (request?["body"] as? [String: Any]) ?? [:] }
}

/// A CLI on this machine, the way the app's own detection would find it.
func binary(_ key: String) -> String? { AgentManager.binaryPath(for: key) }

func toolNames(codexBody b: [String: Any]) -> [String] {
    ((b["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
}
/// A codex request's HOSTED tools — entries with a `type` and no
/// `name`, which `toolNames(codexBody:)` cannot see. Codex's web search
/// is one.
func hostedTools(codexBody b: [String: Any]) -> [[String: Any]] {
    ((b["tools"] as? [[String: Any]]) ?? []).filter { $0["name"] == nil }
}
/// Exactly one hosted tool, and it is web search with live access.
func liveWebSearch(codexBody b: [String: Any]) -> Bool {
    let hosted = hostedTools(codexBody: b)
    return hosted.count == 1 && hosted[0]["type"] as? String == "web_search"
        && hosted[0]["external_web_access"] as? Bool == true
}
func toolNames(claudeBody b: [String: Any]) -> [String] {
    ((b["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
}
/// Every tool_result block a Messages request carries.
func toolResults(claudeBody b: [String: Any]) -> [(id: String, text: String, isError: Bool)] {
    var found: [(id: String, text: String, isError: Bool)] = []
    for message in (b["messages"] as? [[String: Any]]) ?? [] {
        for block in (message["content"] as? [[String: Any]]) ?? [] where block["type"] as? String == "tool_result" {
            let content = block["content"]
            let text = (content as? String)
                ?? ((content as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
            found.append(((block["tool_use_id"] as? String) ?? "", text, (block["is_error"] as? Bool) ?? false))
        }
    }
    return found
}
func toolNames(kimiBody b: [String: Any]) -> [String] {
    ((b["tools"] as? [[String: Any]]) ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
}
func systemText(claudeBody b: [String: Any]) -> String {
    if let s = b["system"] as? String { return s }
    if let parts = b["system"] as? [[String: Any]] {
        return parts.compactMap { $0["text"] as? String }.joined()
    }
    return ""
}
func bodyBytes(_ b: [String: Any]) -> Int {
    (try? JSONSerialization.data(withJSONObject: b))?.count ?? 0
}

let persona = ChatOnlyPersona.text
let personaMarker = "helpful, knowledgeable assistant"

// ====================================================================
print("1. ARGV RULES — ChatOnlyArgv / ChatOnlyPersona / ChatOnlyMode")

var chat = AgentLaunchOptions()
chat.chatOnly = true
var plain = AgentLaunchOptions()

check("persona: web lookups are on, every other tool is named as off",
      persona.contains("look it up on the web") && persona.contains("no other tools")
      && persona.contains("cannot read, search or change files or run commands"))
check("persona is under 500 characters and names no agent",
      persona.count < 500
      && !persona.lowercased().contains("claude") && !persona.lowercased().contains("codex")
      && !persona.lowercased().contains("kimi"), "\(persona.count) chars")

let claudeArgv = ChatOnlyArgv.claude(options: chat, snapshotFlagListed: true)
let webTools = ChatOnlyArgv.claudeWebTools.joined(separator: ",")
check("claude: the kept built-ins are exactly the two web lookups — nothing that touches files or runs commands",
      ChatOnlyArgv.claudeWebTools == ["WebSearch", "WebFetch"])
check("claude: the exact list, in order — the web tools named AND pre-approved",
      claudeArgv == ["--tools", webTools, "--allowedTools", webTools,
                     "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                     "--system-prompt", persona, "--system-prompt-snapshot", "off"],
      claudeArgv.joined(separator: " ").prefix(120).description)
check("claude: every variadic flag is followed by a `-` token",
      ChatOnlyArgv.variadicFlagsAreClosed(claudeArgv))
check("claude: the snapshot flag rides a Default turn too, when listed",
      ChatOnlyArgv.claude(options: plain, snapshotFlagListed: true) == ["--system-prompt-snapshot", "off"])
check("claude: nothing on a Default turn when the help does not list it",
      ChatOnlyArgv.claude(options: plain, snapshotFlagListed: false).isEmpty)
check("claude: Chat only without the listed snapshot flag drops that pair alone",
      ChatOnlyArgv.claude(options: chat, snapshotFlagListed: false)
        == ["--tools", webTools, "--allowedTools", webTools,
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
            "--system-prompt", persona])
check("claude: `flags(for:)` drops --permission-mode under Chat only",
      { var o = chat; o.permissionMode = "plan"; return !o.flags(for: "claude_code").contains("--permission-mode") }())
check("variadicFlagsAreClosed rejects `--tools \"\" <positional>`",
      !ChatOnlyArgv.variadicFlagsAreClosed(["--tools", "", "some prompt"]))
check("variadicFlagsAreClosed rejects `--allowedTools X <positional>`",
      !ChatOnlyArgv.variadicFlagsAreClosed(["--allowedTools", "WebSearch", "some prompt"]))

let codexResumed = ChatOnlyArgv.codex(options: chat, bornPlain: true, personaFile: "/x/persona.md")
let codexFirst = ChatOnlyArgv.codex(options: chat, bornPlain: false, personaFile: "/x/persona.md")
let expectedSwitches = [
    "features.shell_tool=false", "features.unified_exec=false", "features.view_image=false",
    "features.multi_agent=false", "features.apps=false", "features.browser_use=false",
    "features.computer_use=false", "features.image_generation=false", "features.sleep_tool=false",
    "features.plugins=false", "features.skill_search=false", "features.tool_suggest=false",
    "features.goals=false", "features.memories=false", "web_search=\"live\"",
    "tools.experimental_request_user_input.enabled=false",
    "sandbox_mode=\"read-only\"", "approval_policy=\"never\"",
    "include_permissions_instructions=false", "include_collaboration_mode_instructions=false",
    "include_apps_instructions=false", "skills.include_instructions=false",
    // Readable reasoning summaries — the thoughts a Chat only turn's
    // activity line shows.
    "model_reasoning_summary=\"detailed\"",
]
func cValues(_ argv: [String]) -> [String] {
    var out: [String] = []
    var i = 0
    while i + 1 < argv.count { if argv[i] == "-c" { out.append(argv[i + 1]) }; i += 2 }
    return out
}
check("codex: every switch is a `-c` pair (exec resume takes no long flags)",
      codexResumed.count % 2 == 0 && stride(from: 0, to: codexResumed.count, by: 2).allSatisfy { codexResumed[$0] == "-c" })
check("codex: the exact switch set on a resumed turn, plus the persona file",
      cValues(codexResumed) == expectedSwitches + ["model_instructions_file=\"/x/persona.md\""])
check("codex: the BIRTH RULE — no persona file on a thread's first turn",
      cValues(codexFirst) == expectedSwitches && !codexFirst.contains { $0.contains("model_instructions_file") })
check("codex: web search stays on, LIVE — a TOP-LEVEL key, never tools.web_search",
      cValues(codexResumed).contains("web_search=\"live\"") && !cValues(codexResumed).contains { $0.hasPrefix("tools.web_search") })
check("codex: `flags(for:)` drops the sandbox preset under Chat only",
      { var o = chat; o.permissionMode = "full-access"; return !o.flags(for: "codex").contains("--dangerously-bypass-approvals-and-sandbox") }())
check("codex: nothing on a Default turn", ChatOnlyArgv.codex(options: plain, bornPlain: true, personaFile: "/x").isEmpty)
check("kimi: argv unchanged (the shape is the file and the server)",
      ChatOnlyArgv.kimi(options: chat).isEmpty && chat.flags(for: "kimi").isEmpty)

var picked = AgentLaunchOptions()
picked.permissionMode = "plan"
ChatOnlyMode.select(ChatOnlyMode.rowValue, into: &picked)
check("picking Chat only clears the permission mode", picked.chatOnly && picked.permissionMode == nil)
ChatOnlyMode.select("acceptEdits", into: &picked)
check("picking a mode row clears Chat only", !picked.chatOnly && picked.permissionMode == "acceptEdits")
ChatOnlyMode.select(nil, into: &picked)
check("picking Default clears both", !picked.chatOnly && picked.permissionMode == nil)
check("the chip's selected value is the sentinel under Chat only",
      ChatOnlyMode.selectedValue(chat) == ChatOnlyMode.rowValue && ChatOnlyMode.selectedValue(plain) == nil)

// ====================================================================
print("2. CODEX over the fake Responses provider (throwaway CODEX_HOME)")

func codexHome(port: Int) -> URL {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sipai-chatonly-codex-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? fm.createDirectory(at: home, withIntermediateDirectories: true)
    let config = """
    model_provider = "fake"
    model = "gpt-5.5"

    [model_providers.fake]
    name = "fake"
    base_url = "http://127.0.0.1:\(port)"
    wire_api = "responses"

    """
    try? config.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    return home
}

func threadId(_ out: String) -> String? {
    for line in out.split(separator: "\n") where line.contains("thread.started") {
        if let start = line.firstIndex(of: "{"),
           let id = object(String(line[start...]))["thread_id"] as? String { return id }
    }
    return nil
}

if let codex = binary("codex"), let server = FakeServer() {
    let home = codexHome(port: server.port)
    let cwd = home.appendingPathComponent("cwd", isDirectory: true)
    try? fm.createDirectory(at: cwd, withIntermediateDirectories: true)
    let personaFile = home.appendingPathComponent("persona.md")
    try? ChatOnlyPersona.ensureFile(at: personaFile)
    let e = ["CODEX_HOME": home.path]
    let base = ["exec", "--json", "--skip-git-repo-check"]

    // (a) Chat only flag set on a NEW thread: tools off, nothing lean.
    let first = run(codex, base + ChatOnlyArgv.codex(options: chat, bornPlain: false, personaFile: personaFile.path)
                    + ["one word"], cwd: cwd, environment: e)
    let firstBody = server.body(server.newest())
    let firstTools = toolNames(codexBody: firstBody)
    check("first turn: exit 0 and a thread id", first.status == 0 && threadId(first.out) != nil,
          String(first.out.prefix(160)))
    check("first turn: none of exec_command / write_stdin / view_image / computer-use",
          !firstTools.contains { ["exec_command", "write_stdin", "view_image"].contains($0) || $0.contains("computer") },
          firstTools.joined(separator: ","))
    check("first turn: under a CLEAN home the only NAMED tool left is [\"apply_patch\"]",
          firstTools == ["apply_patch"], firstTools.joined(separator: ","))
    check("first turn: the hosted web search rides along, live (one {type: web_search, external_web_access: true})",
          liveWebSearch(codexBody: firstBody), String(describing: hostedTools(codexBody: firstBody)))
    // Codex ignores a `-c` key it does not know — and newer codex SAYS
    // so, as an `item.completed` error item ("Codex is ignoring N
    // unrecognized configuration settings…", each key named). A key of
    // OURS in that list is a switch codex renamed: the tool it was
    // meant to turn off is back on, under a chip saying Chat only. An
    // older codex prints nothing either way, and this passes vacuously.
    check("first turn: codex recognises every Chat only switch (no 'unrecognized configuration settings' warning)",
          !first.out.lowercased().contains("unrecognized configuration settings"),
          first.out.components(separatedBy: "\n").first { $0.lowercased().contains("unrecognized") }
              .map { String($0.prefix(240)) } ?? "")
    let firstInstructions = (firstBody["instructions"] as? String) ?? ""
    check("first turn: the instructions are codex's own (≥ 20,000 chars) — born plain",
          firstInstructions.count >= 20_000, "\(firstInstructions.count)")
    check("first turn: tools off shrinks the request (≤ 30 KB against ~40 KB default)",
          bodyBytes(firstBody) <= 30_000, "\(bodyBytes(firstBody)) bytes")

    // (c) The birth sequence: default → lean resume → default resume.
    if let tid = threadId(first.out) {
        server.clear()
        let lean = run(codex, ["exec", "resume", "--json", "--skip-git-repo-check"]
                       + ChatOnlyArgv.codex(options: chat, bornPlain: true, personaFile: personaFile.path)
                       + [tid, "two"], cwd: cwd, environment: e)
        let leanBody = server.body(server.newest())
        let leanInstructions = (leanBody["instructions"] as? String) ?? ""
        check("lean resume: exit 0 on the same thread", lean.status == 0 && threadId(lean.out) == tid)
        check("lean resume: the persona IS the instructions",
              leanInstructions.contains(personaMarker) && leanInstructions.count < 600, "\(leanInstructions.count) chars")
        check("lean resume: tools still [\"apply_patch\"]", toolNames(codexBody: leanBody) == ["apply_patch"])
        check("lean resume: web search still live", liveWebSearch(codexBody: leanBody),
              String(describing: hostedTools(codexBody: leanBody)))
        check("lean resume: the request is small (≤ 8 KB)", bodyBytes(leanBody) <= 8_000, "\(bodyBytes(leanBody)) bytes")
        server.clear()
        let back = run(codex, ["exec", "resume", "--json", "--skip-git-repo-check", tid, "three"],
                       cwd: cwd, environment: e)
        let backBody = server.body(server.newest())
        let backInstructions = (backBody["instructions"] as? String) ?? ""
        check("default resume after a lean one: the full instructions are back (≥ 20,000 chars)",
              back.status == 0 && backInstructions.count >= 20_000, "\(backInstructions.count)")
        check("default resume: the tools are back",
              toolNames(codexBody: backBody).contains("exec_command"), toolNames(codexBody: backBody).joined(separator: ","))
        // The rollout's birth record.
        let rollouts = ((try? fm.subpathsOfDirectory(atPath: home.appendingPathComponent("sessions").path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") && $0.contains(tid) }
        if let rel = rollouts.first {
            let meta = lines(of: home.appendingPathComponent("sessions/" + rel)).first.map(object) ?? [:]
            let payload = (meta["payload"] as? [String: Any]) ?? [:]
            let birth = (payload["base_instructions"] as? [String: Any]) ?? [:]
            let provenance = (birth["provenance"] as? [String: Any]) ?? [:]
            check("rollout: session_meta.base_instructions.provenance.type == \"model\" (never \"custom\")",
                  provenance["type"] as? String == "model", String(describing: provenance))
        } else {
            check("rollout for the thread found", false, home.path)
        }
    }

    // (d) A lean FIRST turn is refused by the argv rule, never by codex.
    check("a lean first turn is refused by the ARGV RULE (codex would accept it and pin the persona)",
          !ChatOnlyArgv.codex(options: chat, bornPlain: false, personaFile: personaFile.path)
            .contains { $0.contains("model_instructions_file") })

    // (g, §7.7) Unknown `-c` keys never fail the turn — the reason the gate
    // is POSITIVE. An older codex ignored them in silence; a newer one
    // still ignores them and runs the turn, but emits a warning item
    // naming each key. Either way "no refusal" proves nothing about
    // whether a switch took, so the row is offered only where the
    // installed codex NAMES the features it switches off.
    server.clear()
    let unknown = run(codex, base + ["-c", "features.no_such=false", "-c", "no_such_top=1", "-c", "tools.x.enabled=false", "one"],
                      cwd: cwd, environment: e)
    check("unknown -c keys: codex runs the turn anyway (exit 0, a thread) — no refusal to lean on",
          unknown.status == 0 && threadId(unknown.out) != nil,
          String(unknown.out.prefix(200)))
    note("this codex " + (unknown.out.lowercased().contains("unrecognized configuration settings")
        ? "WARNS about unknown -c keys (an item.completed error item) and still runs the turn"
        : "ignores unknown -c keys in silence"))
    server.stop()

    // (b) apply_patch under read-only/never is REFUSED and writes nothing.
    let patch: [String: Any] = [
        "type": "custom_tool_call", "name": "apply_patch", "call_id": "call_harness_1", "id": "ctc_harness_1",
        "input": "*** Begin Patch\n*** Add File: hello-from-harness.txt\n+hi\n*** End Patch\n",
    ]
    if let scripted = FakeServer(script: patch) {
        let home2 = codexHome(port: scripted.port)
        let cwd2 = home2.appendingPathComponent("cwd", isDirectory: true)
        try? fm.createDirectory(at: cwd2, withIntermediateDirectories: true)
        let r = run(codex, base + ChatOnlyArgv.codex(options: chat, bornPlain: false, personaFile: personaFile.path)
                    + ["add a file"], cwd: cwd2, environment: ["CODEX_HOME": home2.path])
        let outputs = scripted.requests().flatMap { req -> [[String: Any]] in
            ((scripted.body(req)["input"] as? [[String: Any]]) ?? [])
                .filter { ($0["type"] as? String)?.hasSuffix("tool_call_output") == true }
        }
        let refusal = (outputs.first?["output"] as? String) ?? ""
        check("apply_patch emitted by the provider: codex sent the call back REFUSED",
              r.status == 0 && !outputs.isEmpty
              && (refusal.lowercased().contains("rejected") || refusal.lowercased().contains("aborted")),
              refusal.isEmpty ? String(r.out.prefix(200)) : refusal)
        check("apply_patch: nothing was written",
              !fm.fileExists(atPath: cwd2.appendingPathComponent("hello-from-harness.txt").path))
        scripted.stop()
        try? fm.removeItem(at: home2)
    } else {
        skip("apply_patch refusal", "the fake server did not start")
    }

    // (e) A web search reads the same live and on reopen. The provider
    // emits one `web_search_call` per action codex has; the live feed
    // (`exec --json`) spells each call's `query`, and the rollout keeps
    // only the `action` — which the reader must spell the same way, or
    // the row is dropped on reopen.
    let searches: [(action: [String: Any], line: String)] = [
        (["type": "search", "query": "latest stable Python release"], "latest stable Python release"),
        (["type": "open_page", "url": "https://www.python.org/downloads/"], "https://www.python.org/downloads/"),
        (["type": "find_in_page", "url": "https://www.python.org/downloads/", "pattern": "3.14"],
         "'3.14' in https://www.python.org/downloads/"),
    ]
    for (action, line) in searches {
        let kind = (action["type"] as? String) ?? "?"
        let call: [String: Any] = ["type": "web_search_call", "id": "ws_harness_\(kind)", "status": "completed", "action": action]
        guard let scripted = FakeServer(script: call) else { skip("web search \(kind)", "the fake server did not start"); continue }
        let home3 = codexHome(port: scripted.port)
        let cwd3 = home3.appendingPathComponent("cwd", isDirectory: true)
        try? fm.createDirectory(at: cwd3, withIntermediateDirectories: true)
        let r = run(codex, base + ChatOnlyArgv.codex(options: chat, bornPlain: false, personaFile: personaFile.path)
                    + ["what is new"], cwd: cwd3, environment: ["CODEX_HOME": home3.path])
        scripted.stop()
        var liveLine: String? = nil
        for raw in r.out.split(separator: "\n") {
            for event in CodexEventParser.parse(line: String(raw), fallbackCwd: cwd3).events {
                if case .toolUse(_, let name, let input) = event.kind, name == "web_search" {
                    liveLine = input["query"] as? String
                }
            }
        }
        check("web search (\(kind)): the live row reads \"\(line.prefix(40))\"", liveLine == line, liveLine ?? "no row")
        let rollout = threadId(r.out).flatMap { tid in
            ((try? fm.subpathsOfDirectory(atPath: home3.appendingPathComponent("sessions").path)) ?? [])
                .first { $0.hasSuffix(".jsonl") && $0.contains(tid) }
                .map { home3.appendingPathComponent("sessions/" + $0) }
        }
        var reopened: String? = nil
        for item in rollout.map({ CodexSessionScanner.readHistory(of: $0, root: home3.appendingPathComponent("sessions")) }) ?? [] {
            if case .toolUse(_, let name, let input) = item.kind, name == "web_search_call" {
                reopened = input["command"] as? String
            }
        }
        check("web search (\(kind)): the REOPENED row reads the same", reopened == line, reopened ?? "row dropped")
        try? fm.removeItem(at: home3)
    }

    // (h) An image turn as SipAI sends one — the marker in the text, `-i`
    // after the prompt — read back through the REAL reader. Codex wraps
    // the image in text blocks of its own; read as words they would put
    // a temp path in the bubble and in the session's title, and the
    // Chat only record and the branch pencil (which match the user's
    // words) would never find the turn.
    if let imageServer = FakeServer() {
        let home4 = codexHome(port: imageServer.port)
        let cwd4 = home4.appendingPathComponent("cwd", isDirectory: true)
        try? fm.createDirectory(at: cwd4, withIntermediateDirectories: true)
        let picture = home4.appendingPathComponent("pic.png")
        try? Data(base64Encoded: onePixelPNG)?.write(to: picture)
        let words = "What is in this picture?"
        let r = run(codex, base + ChatOnlyArgv.codex(options: chat, bornPlain: false, personaFile: personaFile.path)
                    + ChatOnlyImages.codexTrailingArgs(resuming: false, sessionId: nil,
                                                       text: AttachmentInline.imageMarker(name: "pic.png") + "\n\n" + words,
                                                       imageFiles: [picture.path]),
                    cwd: cwd4, environment: ["CODEX_HOME": home4.path])
        imageServer.stop()
        let sessions4 = home4.appendingPathComponent("sessions")
        let rollout = threadId(r.out).flatMap { tid in
            ((try? fm.subpathsOfDirectory(atPath: sessions4.path)) ?? [])
                .first { $0.hasSuffix(".jsonl") && $0.contains(tid) }
                .map { sessions4.appendingPathComponent($0) }
        }
        let raw = rollout.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        check("codex image turn: codex wraps the image in text blocks of its own (the measured shape)",
              r.status == 0 && raw.contains("<image name=[Image #1]") && raw.contains("\"</image>\""),
              "exit \(r.status)")
        let rows = rollout.map { userRows(CodexSessionScanner.readHistory(of: $0, root: sessions4)) } ?? []
        check("codex image turn: the reopened row is the user's words — codex's wrapper is gone",
              rows.map(\.0) == [words], rows.map(\.0).description)
        check("codex image turn: …and it names the image on its paperclip line",
              rows.first?.1 == ["pic.png"], String(describing: rows.first?.1))
        try? fm.removeItem(at: home4)
    } else {
        skip("codex image turn", "the fake server did not start")
    }
    try? fm.removeItem(at: home)
} else {
    skip("codex over the fake provider", binary("codex") == nil ? "codex is not installed" : "the fake server did not start")
}

// ====================================================================
print("3. CLAUDE over the fake Messages endpoint (throwaway CLAUDE_CONFIG_DIR)")

func sessionId(_ out: String) -> String? {
    for line in out.split(separator: "\n") where line.contains("\"type\":\"system\"") {
        if let start = line.firstIndex(of: "{"),
           let id = object(String(line[start...]))["session_id"] as? String { return id }
    }
    return nil
}
func initTools(_ out: String) -> [String]? {
    for line in out.split(separator: "\n") where line.contains("\"subtype\":\"init\"") {
        if let start = line.firstIndex(of: "{") {
            return object(String(line[start...]))["tools"] as? [String]
        }
    }
    return nil
}

if let claude = binary("claude_code"), let server = FakeServer() {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sipai-chatonly-claude-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let cfg = home.appendingPathComponent("cfg", isDirectory: true)
    let cwd = home.appendingPathComponent("cwd", isDirectory: true)
    try? fm.createDirectory(at: cfg, withIntermediateDirectories: true)
    try? fm.createDirectory(at: cwd, withIntermediateDirectories: true)
    let marker = "CLAUDEMD-MARKER-\(UUID().uuidString.prefix(6))"
    try? "# project notes\n\(marker)\n".write(to: cwd.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
    let e = ["CLAUDE_CONFIG_DIR": cfg.path,
             "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(server.port)",
             "ANTHROPIC_API_KEY": "sk-ant-harness-junk"]
    let base = ["-p"]
    let tail = ["--output-format", "stream-json", "--verbose"]

    // The exact argv the runner builds: prompt, the stream flags, then
    // the Chat only list — and no --resume on a new session.
    let first = run(claude, base + ["Reply with the single word OK."] + tail
                    + ChatOnlyArgv.claude(options: chat, snapshotFlagListed: true), cwd: cwd, environment: e)
    let body = server.body(server.newest())
    let system = systemText(claudeBody: body)
    check("first turn: exit 0 with a session id", first.status == 0 && sessionId(first.out) != nil,
          String(first.out.prefix(200)))
    check("system.init reports exactly the two web tools",
          initTools(first.out).map(Set.init) == Set(ChatOnlyArgv.claudeWebTools), String(describing: initTools(first.out)))
    check("the request carries exactly the two web tools, inline (neither deferred)",
          Set(toolNames(claudeBody: body)) == Set(ChatOnlyArgv.claudeWebTools)
          && toolNames(claudeBody: body).count == 2
          && !((body["tools"] as? [[String: Any]]) ?? []).contains { $0["defer_loading"] != nil },
          toolNames(claudeBody: body).joined(separator: ","))
    // The persona plus claude's own billing-header line (~140 chars) —
    // nothing of claude's ~28 KB agent prompt.
    check("the system prompt is the persona (plus claude's header line: ≤ persona + 200 chars)",
          system.count <= persona.count + 200 && system.contains(personaMarker), "\(system.count) chars")
    let messagesText = (try? JSONSerialization.data(withJSONObject: body["messages"] ?? [])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    check("CLAUDE.md rides in the MESSAGES, not the system prompt",
          messagesText.contains(marker) && !system.contains(marker))
    check("the whole request is small (≤ 6 KB)", bodyBytes(body) <= 6_000, "\(bodyBytes(body)) bytes")
    check("--system-prompt-snapshot off is accepted (the turn produced a result)",
          first.out.contains("\"type\":\"result\""))

    // The snapshot trap, measured: a session whose transcript holds a
    // recorded prompt snapshot sends the RECORD on resume unless the
    // flag says off — the persona is silently ignored.
    if let sid = sessionId(first.out) {
        server.clear()
        // A Default turn WITHOUT the flag records a snapshot (if this
        // claude records them at all).
        let plainTurn = run(claude, base + ["two"] + tail + ["--resume", sid], cwd: cwd, environment: e)
        check("default resume without the flag: exit 0", plainTurn.status == 0)
        let transcript = ((try? fm.subpathsOfDirectory(atPath: cfg.appendingPathComponent("projects").path)) ?? [])
            .first { $0.hasSuffix("\(sid).jsonl") }
            .map { cfg.appendingPathComponent("projects/" + $0) }
        let recordsSnapshot = transcript.map { lines(of: $0).contains { $0.contains("prompt_snapshot") } } ?? false
        note("this claude " + (recordsSnapshot ? "RECORDS a prompt_snapshot attachment on a plain turn"
                                                  : "records no prompt snapshot on a plain turn"))
        server.clear()
        let withoutOff = run(claude, base + ["three"] + tail + ["--resume", sid, "--system-prompt", persona],
                             cwd: cwd, environment: e)
        let withoutOffSystem = systemText(claudeBody: server.body(server.newest()))
        server.clear()
        let withOff = run(claude, base + ["four"] + tail + ["--resume", sid]
                          + ChatOnlyArgv.claude(options: chat, snapshotFlagListed: true), cwd: cwd, environment: e)
        let withOffSystem = systemText(claudeBody: server.body(server.newest()))
        check("resume + persona + snapshot OFF: the persona is what is sent",
              withOff.status == 0 && withOffSystem.contains(personaMarker), "\(withOffSystem.count) chars")
        if recordsSnapshot {
            check("resume + persona WITHOUT the flag: the RECORDED prompt wins (the trap the flag exists for)",
                  withoutOff.status == 0 && !withoutOffSystem.contains(personaMarker), "\(withoutOffSystem.count) chars")
        } else {
            note("no snapshot recorded, so the flag has nothing to override on this claude yet")
        }
        server.clear()
        let backToDefault = run(claude, base + ["five"] + tail + ["--resume", sid]
                                + ChatOnlyArgv.claude(options: plain, snapshotFlagListed: true), cwd: cwd, environment: e)
        let backSystem = systemText(claudeBody: server.body(server.newest()))
        check("default resume with the flag: claude's own prompt is rendered fresh (persona gone)",
              backToDefault.status == 0 && !backSystem.contains(personaMarker) && backSystem.count > 600,
              "\(backSystem.count) chars")
    }
    server.stop()

    // (f) The web tools RUN: a Chat only turn carries no approver, so
    // they are pre-approved for the turn. The fake endpoint answers the
    // first request with a WebSearch call; claude runs it (its side
    // request carries the server-side search tool) and hands back the
    // result — unless the pre-approval is missing, or the user's own
    // settings deny the tool.
    let searchCall: [String: Any] = ["name": "WebSearch", "input": ["query": "latest stable Python release"]]
    func scriptedSearch(_ argv: [String], settings: String? = nil)
    -> (reported: [String]?, result: (id: String, text: String, isError: Bool)?, sideSearch: Bool)? {
        guard let scripted = FakeServer(anthropicScript: searchCall) else { return nil }
        defer { scripted.stop() }
        let cfg2 = home.appendingPathComponent("cfg-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? fm.createDirectory(at: cfg2, withIntermediateDirectories: true)
        if let settings {
            try? settings.write(to: cfg2.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        }
        let r = run(claude, base + ["What is new?"] + tail + argv, cwd: cwd,
                    environment: ["CLAUDE_CONFIG_DIR": cfg2.path,
                                  "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(scripted.port)",
                                  "ANTHROPIC_API_KEY": "sk-ant-harness-junk"])
        let bodies = scripted.requests().map { scripted.body($0) }
        let result = bodies.flatMap { toolResults(claudeBody: $0) }.first { $0.id == "toolu_harness_1" }
        let side = bodies.contains { b in
            ((b["tools"] as? [[String: Any]]) ?? []).contains { ($0["type"] as? String)?.hasPrefix("web_search_") == true }
        }
        return (initTools(r.out), result, side)
    }
    let chatList = ChatOnlyArgv.claude(options: chat, snapshotFlagListed: true)
    if let ran = scriptedSearch(chatList) {
        check("a WebSearch call RUNS under the Chat only list (side request carries the server search tool; result handed back)",
              ran.result?.isError == false && ran.result?.text.contains("Web search results for query") == true && ran.sideSearch,
              String(ran.result?.text.prefix(120) ?? "no tool_result"))
    } else {
        skip("scripted WebSearch", "the fake server did not start")
    }
    var unapproved = chatList
    if let i = unapproved.firstIndex(of: "--allowedTools") { unapproved.removeSubrange(i...(i + 1)) }
    if let ran = scriptedSearch(unapproved) {
        check("…and WITHOUT --allowedTools the call is refused for want of an approver (the pair is load-bearing)",
              ran.result?.isError == true && ran.result?.text.contains("haven't granted") == true,
              String(ran.result?.text.prefix(120) ?? "no tool_result"))
    }
    if let ran = scriptedSearch(chatList, settings: "{\"permissions\":{\"deny\":[\"WebSearch\"]}}") {
        check("a deny rule in the user's own settings wins: claude drops WebSearch from the turn",
              ran.reported.map { !$0.contains("WebSearch") && $0.contains("WebFetch") } ?? false,
              String(describing: ran.reported))
    }
    // A `--tools` name claude does not HAVE is dropped, not refused —
    // which is what an account without WebSearch (Bedrock, a gateway)
    // relies on: the list names it, claude keeps WebFetch, the turn runs.
    if let bogus = FakeServer() {
        var bogusList = chatList
        bogusList = bogusList.map { $0 == webTools ? "WebFetch,NoSuchTool" : $0 }
        let r = run(claude, base + ["one word"] + tail + bogusList, cwd: cwd,
                    environment: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent("cfg-bogus").path,
                                  "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(bogus.port)",
                                  "ANTHROPIC_API_KEY": "sk-ant-harness-junk"])
        bogus.stop()
        check("a --tools name this claude lacks is dropped without error (the Bedrock/gateway case): exit 0, the rest listed",
              r.status == 0 && initTools(r.out) == ["WebFetch"] && r.out.contains("\"type\":\"result\""),
              String(describing: initTools(r.out)))
    }
    try? fm.removeItem(at: home)
} else {
    skip("claude over the fake endpoint", binary("claude_code") == nil ? "claude is not installed" : "the fake server did not start")
}

// ====================================================================
print("4. KIMI over the fake chat provider (throwaway KIMI_CODE_HOME)")

func kimiHome(port: Int) -> URL {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sipai-chatonly-kimi-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? fm.createDirectory(at: home, withIntermediateDirectories: true)
    let config = """
    default_model = "fake/fake-model"

    [providers.fake]
    base_url = "http://127.0.0.1:\(port)/v1"
    type = "openai"
    api_key = "junk"

    [models."fake/fake-model"]
    provider = "fake"
    model = "fake-model"
    max_context_size = 262144
    capabilities = [ "tool_use", "image_in" ]

    """
    try? config.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    return home
}

func kimiSessionId(_ out: String) -> String? {
    for line in out.split(separator: "\n") where line.contains("session.resume_hint") {
        if let start = line.firstIndex(of: "{"),
           let id = object(String(line[start...]))["session_id"] as? String { return id }
    }
    return nil
}

/// `sessions/*/<id>` — the store's own layout, walked the way
/// `KimiSessionScanner.sessionDirectory(forId:)` walks it.
func kimiSessionDir(home: URL, id: String) -> URL? {
    let root = home.appendingPathComponent("sessions", isDirectory: true)
    guard let buckets = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
    for bucket in buckets {
        let dir = bucket.appendingPathComponent(id, isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue { return dir }
    }
    return nil
}

if let kimi = binary("kimi"), let server = FakeServer() {
    let home = kimiHome(port: server.port)
    let cwd = home.appendingPathComponent("cwd", isDirectory: true)
    try? fm.createDirectory(at: cwd, withIntermediateDirectories: true)
    let e = ["KIMI_CODE_HOME": home.path]
    let stream = ["--output-format", "stream-json"]

    // (a) The policy file around --prompt --session.
    let first = run(kimi, ["--prompt", "Reply with the single word OK."] + stream, cwd: cwd, environment: e)
    let firstBody = server.body(server.newest())
    let firstTools = toolNames(kimiBody: firstBody)
    check("first turn: exit 0 with a session id", first.status == 0 && kimiSessionId(first.out) != nil,
          String(first.out.prefix(200)))
    check("first turn: the ordinary tool set (≥ 20 tools)", firstTools.count >= 20, "\(firstTools.count)")
    if let sid = kimiSessionId(first.out), let dir = kimiSessionDir(home: home, id: sid) {
        let wire = dir.appendingPathComponent("agents/main/wire.jsonl")
        let file = KimiToolPolicy.disabledFile(sessionDir: dir)
        check("the policy file path is <session>/tool-policy/state.json",
              file.path == dir.appendingPathComponent("tool-policy/state.json").path)
        check("capture on a session with no policy file → .absent",
              KimiToolPolicy.capture(at: file) == .record(.absent))

        // (d) names(fromWire:) over the REAL wire equals the measured list.
        let own = KimiToolPolicy.names(fromWire: wire)
        check("names(fromWire:) reads the session's own llm.tools_snapshot",
              own != nil && !(own ?? []).isEmpty, "\(own?.count ?? 0)")
        check("the snapshot's names equal the measured 2.0.1 list (a kimi that adds a tool fails HERE)",
              Set(own ?? []) == Set(KimiToolPolicy.fallbackNames),
              "extra: \(Set(own ?? []).subtracting(KimiToolPolicy.fallbackNames).sorted()) missing: \(Set(KimiToolPolicy.fallbackNames).subtracting(own ?? []).sorted())")
        check("the wire's profile.bind names the profile the server route binds (\"\(KimiWebTurn.profileName)\")",
              lines(of: wire).contains { $0.contains("\"type\":\"profile.bind\"") && object($0)["profileName"] as? String == KimiWebTurn.profileName })

        let names = KimiToolPolicy.namesToDisable(sessionSnapshot: own, storeSnapshot: nil)
        try? KimiToolPolicy.write(names: names, to: file)
        check("the written file decodes to the names it was given",
              (try? Data(contentsOf: file)).flatMap(KimiToolPolicy.decode) == names)
        server.clear()
        let second = run(kimi, ["--prompt", "again, one word"] + stream + ["--session", sid], cwd: cwd, environment: e)
        let secondBody = server.body(server.newest())
        check("policy file present: --prompt --session sends only the kept web lookup (FetchURL — this home has no search provider)",
              second.status == 0 && toolNames(kimiBody: secondBody) == ["FetchURL"],
              toolNames(kimiBody: secondBody).joined(separator: ","))
        check("the written list names no tool Chat only keeps",
              KimiToolPolicy.chatOnlyKeeps.isDisjoint(with: names))
        check("policy file present: the request shrinks (≤ 20 KB against ~85 KB)",
              bodyBytes(secondBody) <= 20_000, "\(bodyBytes(secondBody)) bytes")

        // (e) A Chat only turn records a snapshot of its kept web
        // tools alone; the name source must skip it.
        let newestRaw: [String]? = {
            var newest: [String]? = nil
            for line in lines(of: wire) where line.contains("llm.tools_snapshot") {
                let o = object(line)
                if o["type"] as? String == "llm.tools_snapshot", let tools = o["tools"] as? [[String: Any]] {
                    newest = tools.compactMap { $0["name"] as? String }
                }
            }
            return newest
        }()
        check("the wire's NEWEST snapshot now names only the kept web lookup (a Chat only turn records one)",
              newestRaw == ["FetchURL"], String(describing: newestRaw))
        check("names(fromWire:) skips it and still answers the last ORDINARY turn's snapshot",
              KimiToolPolicy.names(fromWire: wire) == own)

        // Wildcard is NOT honoured.
        try? Data("{\"disabledTools\":[\"*\"]}".utf8).write(to: file)
        server.clear()
        let wild = run(kimi, ["--prompt", "wild, one word"] + stream + ["--session", sid], cwd: cwd, environment: e)
        check("[\"*\"] is NOT honoured (the tools come back) — so nobody simplifies to it",
              wild.status == 0 && toolNames(kimiBody: server.body(server.newest())).count >= 20,
              "\(toolNames(kimiBody: server.body(server.newest())).count) tools")

        // Restore removes the file; the tools come back.
        try? KimiToolPolicy.restore(.absent, at: file)
        check("restore(.absent) removes the file", !fm.fileExists(atPath: file.path))
        server.clear()
        let restored = run(kimi, ["--prompt", "restored, one word"] + stream + ["--session", sid], cwd: cwd, environment: e)
        check("file removed: --prompt --session runs with the tools again",
              restored.status == 0 && toolNames(kimiBody: server.body(server.newest())).count >= 20)

        // Restore of prior CONTENT puts the bytes back byte for byte.
        let prior = "{\"disabledTools\":[\"Bash\"]}"
        try? Data(prior.utf8).write(to: file)
        let captured = KimiToolPolicy.capture(at: file)
        check("capture of a known-shape file keeps its exact bytes", captured == .record(.content(prior)))
        try? KimiToolPolicy.write(names: names, to: file)
        if case .record(let record) = captured { try? KimiToolPolicy.restore(record, at: file) }
        check("restore(.content) puts the prior bytes back",
              (try? String(contentsOf: file, encoding: .utf8)) == prior)
        try? Data("{\"disabledTools\":[\"Bash\"],\"other\":1}".utf8).write(to: file)
        check("a file of another shape is REFUSED (unknownShape), never rewritten",
              KimiToolPolicy.capture(at: file) == .unknownShape)
        try? Data("not json".utf8).write(to: file)
        check("a non-JSON file is refused too", KimiToolPolicy.capture(at: file) == .unknownShape)
        try? fm.removeItem(at: file)
        check("decode refuses a non-string entry", KimiToolPolicy.decode(Data("{\"disabledTools\":[1]}".utf8)) == nil)
        check("the journal codec round-trips both records",
              KimiToolPolicy.decodeRecord(KimiToolPolicy.encodeRecord(.absent)) == .absent
              && KimiToolPolicy.decodeRecord(KimiToolPolicy.encodeRecord(.content(prior))) == .content(prior)
              && KimiToolPolicy.decodeRecord(["state": "weird"]) == nil)
        check("namesToDisable unions the snapshot with the measured list, less the web lookups, sorted",
              KimiToolPolicy.namesToDisable(sessionSnapshot: ["Zeta", "Bash", "WebSearch"], storeSnapshot: nil)
                == Set(KimiToolPolicy.fallbackNames + ["Zeta"]).subtracting(KimiToolPolicy.chatOnlyKeeps).sorted()
              && KimiToolPolicy.namesToDisable(sessionSnapshot: nil, storeSnapshot: ["Omega"]).contains("Omega"))
        // Compared against the wire's CURRENT answer: the turns above
        // appended newer (smaller) snapshots since `own` was read.
        check("newestNames(inStore:) finds this session's newest ordinary-turn snapshot",
              KimiToolPolicy.newestNames(inStore: home.appendingPathComponent("sessions"))
                == KimiToolPolicy.names(fromWire: wire))
    } else {
        check("session directory for the first turn found", false, home.path)
    }

    // (b)+(c) The server path, through the REAL driver over the REAL
    // KimiWebServerCall.Session.
    setenv("KIMI_CODE_HOME", home.path, 1)
    AgentRunner.extraEnvironment["KIMI_CODE_HOME"] = home.path
    check("the scanner honours KIMI_CODE_HOME",
          real(KimiSessionScanner.sessionRoot) == real(home.appendingPathComponent("sessions")))
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        switch await KimiWebServerCall.Session.start(binary: kimi, scratchDirectory: cwd) {
        case .failed(let why):
            check("kimi web started", false, why)
        case .started(let session):
            server.clear()
            // Create — with the RESOLVED cwd (the body builder does it).
            let created = await KimiWebTurn.createSession(session, cwd: cwd)
            guard case .success(let sid) = created else {
                check("POST /sessions created a session", false, String(describing: created))
                await session.shutdown(); return
            }
            check("POST /sessions created a session", true, sid)
            let dir = kimiSessionDir(home: home, id: sid)
            check("the directory exists before any turn (state.json, no wire)",
                  dir != nil && fm.fileExists(atPath: dir!.appendingPathComponent("state.json").path)
                  && !fm.fileExists(atPath: dir!.appendingPathComponent("agents/main/wire.jsonl").path))
            let body = KimiWebTurn.createSessionBody(cwd: cwd)
            let sentCwd = ((body["metadata"] as? [String: Any])?["cwd"] as? String) ?? ""
            check("the create body carries the RESOLVED cwd — realpath(3), /private included (kimi refuses the session under --prompt otherwise)",
                  sentCwd == KimiWebTurn.resolvedPath(cwd) && (sentCwd.hasPrefix("/private/") || !cwd.path.hasPrefix("/var/")),
                  sentCwd)

            // (c) The never-prompted refusal: --prompt --session on it.
            let early = run(kimi, ["--prompt", "x"] + stream + ["--session", sid], cwd: cwd, environment: e)
            check("a never-prompted server session refuses --prompt: \"model.not_configured: Model not set\"",
                  early.out.contains("model.not_configured: Model not set"), String(early.out.prefix(200)))

            // (c) The profile refusal, word for word.
            let noProfile = await session.request(method: "POST", path: KimiWebTurn.promptsPath(sid),
                                                  body: ["content": [["type": "text", "text": "x"]],
                                                         "disabled_tools": KimiToolPolicy.fallbackNames])
            let refusal: String = {
                switch noProfile {
                case .success(let data): return KimiWebTurn.refusal(from: data) ?? "(no refusal)"
                case .failure(let error): return error.localizedDescription
                }
            }()
            check("disabled_tools WITHOUT profile/model is refused: \"Cannot set session disabled tools: agent profile is not bound\"",
                  refusal.contains("Cannot set session disabled tools: agent profile is not bound"), refusal)

            // (b) The first prompt, tool-less.
            server.clear()
            // The runner's exact list: the store's newest ordinary
            // snapshot unioned with the measured one, less the kept web
            // lookups.
            let serverList = KimiToolPolicy.namesToDisable(
                sessionSnapshot: nil,
                storeSnapshot: KimiToolPolicy.newestNames(inStore: home.appendingPathComponent("sessions")))
            let prompted = await KimiWebTurn.prompt(session, sessionId: sid, text: "Reply with the single word OK.",
                                                    model: "fake/fake-model", disabledTools: serverList)
            guard case .success(let promptId) = prompted else {
                check("POST /prompts with profile+model+disabled_tools accepted", false, String(describing: prompted))
                await session.shutdown(); return
            }
            check("POST /prompts with profile+model+disabled_tools accepted", true, promptId)
            let idle = await KimiWebTurn.waitIdle(session, sessionId: sid) { false }
            check("the session reports idle after the turn", idle)
            let promptBody = server.body(server.newest())
            check("the server-path prompt sent only the kept web lookup (FetchURL)",
                  toolNames(kimiBody: promptBody) == ["FetchURL"]
                  && (promptBody["messages"] as? [Any])?.isEmpty == false, toolNames(kimiBody: promptBody).joined(separator: ","))
            check("the server-path request is small (≤ 20 KB)", bodyBytes(promptBody) <= 20_000, "\(bodyBytes(promptBody)) bytes")
            let wire = dir?.appendingPathComponent("agents/main/wire.jsonl")
            let history = wire.map { KimiSessionScanner.readHistory(of: $0) } ?? []
            check("the wire holds the turn (a user row and the assistant's OK)",
                  history.contains { if case .userText(let t) = $0.kind { return t.contains("single word") }; return false }
                  && history.contains { if case .assistantText(let t) = $0.kind { return t == "OK" }; return false },
                  "\(history.count) items")
            let policy = dir.map { KimiToolPolicy.disabledFile(sessionDir: $0) }
            check("the SERVER wrote the policy file for that prompt",
                  policy.map { fm.fileExists(atPath: $0.path) } ?? false)
            check("…in the measured shape (decode succeeds)",
                  policy.flatMap { try? Data(contentsOf: $0) }.flatMap(KimiToolPolicy.decode) != nil)

            // (b2) An image, the way the runner sends a new session's
            // first turn — the marker in the text, the bytes as a block —
            // read back through the REAL reader: the user's words, with
            // the image named, and nothing kimi added around it.
            server.clear()
            if case .success(let imageSid) = await KimiWebTurn.createSession(session, cwd: cwd) {
                let words = "What is in this picture?"
                let sent = await KimiWebTurn.prompt(
                    session, sessionId: imageSid,
                    text: AttachmentInline.imageMarker(name: "pic.png") + "\n\n" + words,
                    model: "fake/fake-model", disabledTools: serverList,
                    images: [AgentImage(name: "pic.png", base64: onePixelPNG, mediaType: "image/png")])
                let finished: Bool
                if case .success = sent {
                    finished = await KimiWebTurn.waitIdle(session, sessionId: imageSid) { false }
                } else {
                    finished = false
                }
                check("kimi image turn: the server took the image and finished the turn", finished,
                      String(describing: sent))
                let imageDir = kimiSessionDir(home: home, id: imageSid)
                let rows = imageDir.map {
                    userRows(KimiSessionScanner.readHistory(of: $0.appendingPathComponent("agents/main/wire.jsonl")))
                } ?? []
                check("kimi image turn: the reopened row is the user's words",
                      rows.map(\.0) == [words], rows.map(\.0).description)
                check("kimi image turn: …and it names the image on its paperclip line",
                      rows.first?.1 == ["pic.png"], String(describing: rows.first?.1))
                if let imageDir {
                    try? KimiToolPolicy.restore(.absent, at: KimiToolPolicy.disabledFile(sessionDir: imageDir))
                }
            } else {
                check("kimi image turn: a second server session was created", false)
            }
            await session.shutdown()
            // The file OUTLIVES the server; the restore removes it.
            check("the policy file survives the server's shutdown",
                  policy.map { fm.fileExists(atPath: $0.path) } ?? false)
            if let policy { try? KimiToolPolicy.restore(.absent, at: policy) }
            check("restore(.absent) removed it", policy.map { !fm.fileExists(atPath: $0.path) } ?? false)
            server.clear()
            let after = run(kimi, ["--prompt", "after the server, one word"] + stream + ["--session", sid], cwd: cwd, environment: e)
            check("--prompt --session then runs an ordinary agent turn (tools back)",
                  after.status == 0 && toolNames(kimiBody: server.body(server.newest())).count >= 20,
                  String(after.out.prefix(200)))
            check("names(fromWire:) on the server-born session skips its Chat only snapshot and finds the agent turn's",
                  wire.flatMap { KimiToolPolicy.names(fromWire: $0) }?.isEmpty == false)
        }
    }
    _ = semaphore.wait(timeout: .now() + 240)

    // Stop on the server path: the action route is mounted but refuses
    // on 2.0.1; POST /shutdown certainly ends a running turn.
    if let slow = FakeServer(chatDelay: 8) {
        let slowHome = kimiHome(port: slow.port)
        let slowCwd = slowHome.appendingPathComponent("cwd", isDirectory: true)
        try? fm.createDirectory(at: slowCwd, withIntermediateDirectories: true)
        setenv("KIMI_CODE_HOME", slowHome.path, 1)
        AgentRunner.extraEnvironment["KIMI_CODE_HOME"] = slowHome.path
        let done = DispatchSemaphore(value: 0)
        Task {
            defer { done.signal() }
            guard case .started(let session) = await KimiWebServerCall.Session.start(binary: kimi, scratchDirectory: slowCwd),
                  case .success(let sid) = await KimiWebTurn.createSession(session, cwd: slowCwd),
                  case .success(let pid) = await KimiWebTurn.prompt(session, sessionId: sid, text: "slow",
                                                                     model: "fake/fake-model",
                                                                     disabledTools: KimiToolPolicy.fallbackNames)
            else { check("slow server-path prompt started", false); return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let abortAnswer = await session.request(method: "POST",
                                                    path: KimiWebTurn.abortPath(session: sid, prompt: pid),
                                                    ceiling: KimiWebTurn.abortCeiling)
            switch abortAnswer {
            case .success(let data):
                note("prompt action route answered: " + (KimiWebTurn.refusal(from: data) ?? "ok"))
            case .failure(let error):
                note("prompt action route answered: " + error.localizedDescription)
            }
            let started = Date()
            await session.shutdown()
            let took = Date().timeIntervalSince(started)
            check("POST /shutdown ends a running turn and the server exits (≤ 15 s)", took <= 15, String(format: "%.1f s", took))
            let dir = kimiSessionDir(home: slowHome, id: sid)
            let wireLines = dir.map { lines(of: $0.appendingPathComponent("agents/main/wire.jsonl")) } ?? []
            check("the wire records the cut turn (turn.ended cancelled / prompt.aborted)",
                  wireLines.contains { $0.contains("\"reason\":\"cancelled\"") || $0.contains("prompt.aborted") })
        }
        // A probe that never finishes must be a NAMED failure: a bare
        // timed-out wait used to move on in silence, and the two checks
        // above simply did not exist in that run's count (seen once —
        // `shutdown` did not return within the wait, against a
        // `finish` whose every step is bounded at ~10 s in total).
        let abortWait = Date()
        let abortFinished = done.wait(timeout: .now() + 120) == .success
        check("slow server-path abort probe finished (shutdown returned) within 120 s", abortFinished,
              String(format: "%.0f s", Date().timeIntervalSince(abortWait)))
        slow.stop()
        try? fm.removeItem(at: slowHome)
    }
    // (g) Where kimi has a search provider it offers `WebSearch` too,
    // and a Chat only turn keeps it. A `[services.moonshot_search]`
    // section is the token-free way to give a throwaway home one (a kimi
    // login does the same through the managed provider).
    let searchHome = kimiHome(port: server.port)
    let searchCwd = searchHome.appendingPathComponent("cwd", isDirectory: true)
    try? fm.createDirectory(at: searchCwd, withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: searchHome.appendingPathComponent("config.toml")) {
        handle.seekToEndOfFile()
        handle.write(Data("[services.moonshot_search]\nbase_url = \"http://127.0.0.1:\(server.port)/search\"\napi_key = \"junk\"\n".utf8))
        try? handle.close()
    }
    let se = ["KIMI_CODE_HOME": searchHome.path]
    server.clear()
    let plainSearch = run(kimi, ["--prompt", "Reply with the single word OK."] + stream, cwd: searchCwd, environment: se)
    let offered = toolNames(kimiBody: server.body(server.newest()))
    check("with a search provider kimi offers WebSearch (the name Chat only keeps)",
          plainSearch.status == 0 && offered.contains("WebSearch"), "\(offered.count) tools")
    if let sid = kimiSessionId(plainSearch.out), let dir = kimiSessionDir(home: searchHome, id: sid) {
        let file = KimiToolPolicy.disabledFile(sessionDir: dir)
        let list = KimiToolPolicy.namesToDisable(
            sessionSnapshot: KimiToolPolicy.names(fromWire: dir.appendingPathComponent("agents/main/wire.jsonl")),
            storeSnapshot: nil)
        try? KimiToolPolicy.write(names: list, to: file)
        server.clear()
        let chatSearch = run(kimi, ["--prompt", "again, one word"] + stream + ["--session", sid], cwd: searchCwd, environment: se)
        try? KimiToolPolicy.restore(.absent, at: file)
        let kept = toolNames(kimiBody: server.body(server.newest()))
        check("…and a Chat only turn keeps exactly the two web lookups (FetchURL, WebSearch)",
              chatSearch.status == 0 && Set(kept) == KimiToolPolicy.chatOnlyKeeps && kept.count == 2,
              kept.joined(separator: ","))
    } else {
        check("session directory for the search-provider turn found", false, searchHome.path)
    }
    try? fm.removeItem(at: searchHome)

    unsetenv("KIMI_CODE_HOME")
    AgentRunner.extraEnvironment.removeValue(forKey: "KIMI_CODE_HOME")
    server.stop()
    try? fm.removeItem(at: home)
} else {
    skip("kimi over the fake provider", binary("kimi") == nil ? "kimi is not installed" : "the fake server did not start")
}

// ====================================================================
print("5. ATTACHMENT STRIP on the three readers (committed fixtures)")

let composed = AttachmentInline.block(name: "notes.md", text: "ALPHA BODY LINE", truncated: false)
    + "\n\nWhat does this say? <sipai-attachment name=\"unbalanced\">still mine"
check("block + names round-trip", AttachmentInline.names(in: composed) == ["notes.md"])
check("stripping keeps the user's words and the unbalanced tag's text",
      AttachmentInline.stripping(composed) == "What does this say? <sipai-attachment name=\"unbalanced\">still mine")
check("an unbalanced tag names nothing, exactly as it strips nothing",
      AttachmentInline.names(in: "<sipai-attachment name=\"x\">no close").isEmpty
      && AttachmentInline.stripping("<sipai-attachment name=\"x\">no close") == "<sipai-attachment name=\"x\">no close")
check("names come back unescaped, in order",
      AttachmentInline.names(in: AttachmentInline.block(name: "a&b \"c\".txt", text: "z", truncated: true)
                                  + AttachmentInline.block(name: "d.md", text: "y", truncated: false)) == ["a&b \"c\".txt", "d.md"])
check("filesLine is the chat page's comma-joined shape",
      AttachmentInline.filesLine(in: AttachmentInline.block(name: "a.txt", text: "1", truncated: false)
                                     + AttachmentInline.block(name: "b.txt", text: "2", truncated: false)) == "a.txt, b.txt"
      && AttachmentInline.filesLine(in: "plain") == nil)
check("the per-message cap is 200,000 characters", AttachmentInline.perMessageCharCap == 200_000)

func userRows(_ items: [AgentSessionHistoryItem]) -> [(String, [String])] {
    items.compactMap { if case .userText(let t) = $0.kind { return (t, $0.attachedFiles) }; return nil }
}

let claudeFixture = fixtures.appendingPathComponent("claude-attachment.jsonl")
let claudeRows = userRows(AgentSessionScanner.readHistory(of: claudeFixture))
check("claude reader: the block is stripped, the words and the unbalanced text stay",
      claudeRows.contains { $0.0 == "What does this say? still mine" || $0.0.contains("What does this say?") && $0.0.contains("still mine") && !$0.0.contains("ALPHA BODY") },
      claudeRows.map(\.0).joined(separator: " | "))
check("claude reader: the paperclip names ride the row", claudeRows.contains { $0.1 == ["notes.md"] })
check("claude reader: the file's contents reach no row",
      !AgentSessionScanner.readHistory(of: claudeFixture).contains { if case .userText(let t) = $0.kind { return t.contains("ALPHA BODY") }; return false })
check("claude title cleaner strips the block too",
      !AgentSessionScanner.cleanSessionMetaText(composed).contains("ALPHA BODY"))

let codexFixture = fixtures.appendingPathComponent("codex-attachment.jsonl")
let codexRows = userRows(CodexSessionScanner.readHistory(of: codexFixture))
check("codex reader: the block is stripped, the words and the unbalanced tag stay",
      codexRows.contains { $0.0 == "What does this say? <sipai-attachment name=\"unbalanced\">still mine" },
      codexRows.map(\.0).joined(separator: " | "))
check("codex reader: the paperclip names ride the row", codexRows.contains { $0.1 == ["notes.md"] })
// Measured from `codex exec -i`: the image between two text blocks of
// codex's own, then the text SipAI sent.
let imageBlocks: [Any] = [
    ["type": "input_text", "text": "<image name=[Image #1] path=\"/tmp/x/pic.png\">"],
    ["type": "input_image", "image_url": "data:image/png;base64,AAAA"],
    ["type": "input_text", "text": "</image>"],
    ["type": "input_text", "text": "Look at this."],
]
check("codex: an image's wrapper blocks come off as a PAIR around the image; the words stay",
      CodexSessionScanner.userText(fromContent: imageBlocks) == "Look at this.",
      CodexSessionScanner.userText(fromContent: imageBlocks))
check("codex: …while a message that merely QUOTES the tags keeps them",
      CodexSessionScanner.userText(fromContent: [["type": "input_text", "text": "<image name=[Image #1]>"],
                                                 ["type": "input_text", "text": "</image>"]])
          == "<image name=[Image #1]>\n</image>")
check("codex: strippedTaskMarker strips the block ahead of the task marker",
      CodexSessionScanner.strippedTaskMarker("<scheduled-task name=\"t\"></scheduled-task>" + composed)
        == "What does this say? <sipai-attachment name=\"unbalanced\">still mine")

let kimiFixture = fixtures.appendingPathComponent("kimi-attachment.wire.jsonl")
let kimiRows = userRows(KimiSessionScanner.readHistory(of: kimiFixture))
check("kimi reader: the block is stripped, the words and the unbalanced text stay",
      kimiRows.contains { $0.0.contains("What does this say?") && $0.0.contains("still mine") && !$0.0.contains("ALPHA BODY") },
      kimiRows.map(\.0).joined(separator: " | "))
check("kimi reader: the paperclip names ride the row", kimiRows.contains { $0.1 == ["notes.md"] })

// ====================================================================
print("6. SOURCE READS — the views, the runner, the persistence, the heal")

let composer = source("SipAI/Views/Chat/AgentComposer.swift")
let view = source("SipAI/Views/Chat/AgentSessionView.swift")
let runner = source("SipAI/Models/AgentRunner.swift")
let config = source("SipAI/Models/ConfigManager.swift")
let panel = source("SipAI/Views/Chat/ScheduledTaskPanel.swift")
let app = source("SipAI/SipAIApp.swift")
let manager = source("SipAI/Models/AgentManager.swift")
let chatView = source("SipAI/Views/Chat/ChatView.swift")
let settings = source("SipAI/Views/Settings/SettingsView.swift")
let catalog = source("SipAI/Resources/Localizable.xcstrings")

check("composer: the Chat only row sits FIRST among the overrides, after Default (claude/codex)",
      composer.contains("return [defaultRow] + overrides + CodexCapabilities.modePresets")
      && composer.contains("return [defaultRow] + overrides + caps.permissionModes"))
check("composer: kimi's chip is a two-row picker (Auto-approve · Chat only)",
      composer.contains("return [autoRow] + overrides"))
check("composer: the pick goes through the one writer (ChatOnlyMode.select)",
      composer.contains("ChatOnlyMode.select(value, into: &options)"))
check("composer: the pool hovers name the agent through the label, one per agent",
      composer.contains("Uses your \\(agentName) limits") && composer.contains("Uses your \\(agentName) membership")
      && composer.contains("Uses your \\(agentName) plan"))
check("composer: the kimi draft note is appended on a draft alone",
      composer.contains("if isKimi && folderEditable"))
check("composer: the + attaches under Chat only, inserts paths otherwise",
      composer.contains("if chatOnlyActive, let onStageFiles {") && composer.contains("Attached files are sent with your message"))
check("composer: the text field forwards drops under Chat only alone",
      composer.contains("onDropFiles: chatOnlyActive ? onStageFiles : nil"))
check("GrowingTextField: both closures are re-pointed in updateNSView (the Coordinator rule)",
      composer.range(of: "func updateNSView(_ nsView: NSScrollView, context: Context) {\n        // The coordinator is made ONCE").map { r in
          composer[r.upperBound...].prefix(1400).contains("applyDropHandlers(to: tv)")
              && composer[r.upperBound...].prefix(1400).contains("context.coordinator.parent = self")
      } ?? false)
check("composer: the row is gated (ChatOnlyGate) and the chip reads the gated state",
      composer.contains("private var chatOnlyOffered: Bool { ChatOnlyGate.offered(agentKey: agentKey) }")
      && composer.contains("private var chatOnlyActive: Bool { options.chatOnly && chatOnlyOffered }"))
check("composer: the schedule mode never reads chatOnly (a task is an agent task)",
      panel.contains("Chat only") && !panel.contains("chatOnly") && composer.contains("Chat only never reaches a task"))
check("view: the placeholder swaps under Chat only", view.contains("Chat with \\(sessionAgentName)…"))
check("view: a send composes the blocks and clears the staged files",
      view.contains("let text = attaching.isEmpty ? typed : outgoingText(for: typed)")
      && view.contains("stagedAttachments = []"))
check("view: every send goes through the gated options", !view.contains("options: launchOptions)"))
check("view: staged files stash with the draft on every change, never on disappear",
      view.contains(".onChange(of: stagedAttachments) { _, _ in stashComposerAttachments() }")
      && !view.contains("onDisappear { stashComposerAttachments"))
check("view: the per-message cap is enforced at attach time",
      view.contains("inlined + text.count <= AttachmentInline.perMessageCharCap"))
check("view: the paperclip line rides both the history row and the live row",
      view.contains("attachedFiles: item.attachedFiles") && view.contains("attachedFiles: event.attachedFiles"))
check("view: a kimi session is healed on open", view.contains("agents.healKimiToolPolicies(sessionId: id)"))
check("runner: the bridge's flags are omitted on a claude Chat only turn",
      runner.contains("if let bridge = bridge, !options.chatOnly {"))
check("runner: codex's bornPlain is `resuming`, nothing else",
      runner.contains("options: options, bornPlain: resuming,"))
check("runner: the persona file is ensured before a codex Chat only spawn",
      runner.contains("try ChatOnlyPersona.ensureFile(at: SipaiPaths.chatOnlyInstructionsFile)"))
check("runner: a kimi draft's Chat only turn routes to the server path",
      runner.contains("if isKimi, options.chatOnly, sessionId?.isEmpty ?? true {"))
check("runner: a resumed kimi Chat only turn writes the policy file before the spawn and restores at finalize",
      runner.contains("guard await prepareKimiToolPolicy(sessionId: id) else {")
      && runner.contains("restoreKimiToolPolicyIfPending()"))
check("runner: the journal is written BEFORE the file", runner.range(of: "onKimiToolPolicyJournal?(id, record)").map { r in
    runner[r.upperBound...].prefix(400).contains("KimiToolPolicy.write(names:") } ?? false)
check("runner: an unknown-shape file refuses the send with a row naming it",
      runner.contains("case .unknownShape:") && runner.contains("tool-policy file has a shape SipAI doesn't know"))
check("runner: the server-born id rides the existing discovery closure + awaitSessionFile",
      runner.contains("adoptDiscoveredSession(id: sid, fileURL: nil)") && runner.contains("awaitSessionFile(id: sid)"))
check("runner: Stop on the server path aborts then shuts down",
      runner.contains("await KimiWebTurn.abort(session, sessionId: sid, promptId: promptId)"))
// The display text is born through the readers' own cleaner for a
// scheduled run's marker (`strippedTaskMarker` strips the attachment
// blocks FIRST, then the `<scheduled-task>` tag): the live row must
// match its record, and a raw marker in the bubble never did.
check("runner: the send strips the blocks AND the scheduled marker for the bubble, and keeps the wire text",
      runner.contains("let display = CodexSessionScanner.strippedTaskMarker(trimmed)")
      && runner.contains("inFlightUserText = display")
      && CodexSessionScanner.strippedTaskMarker("<scheduled-task name=\"t\"></scheduled-task>\nhello "
                                                + AttachmentInline.block(name: "a.txt", text: "x", truncated: false)) == "hello")
check("config: chat_only in both prefs maps, read and written",
      config.components(separatedBy: "prefs[\"chat_only\"] == \"1\"").count == 3
      && config.components(separatedBy: "prefs[\"chat_only\"] = \"1\"").count == 3)
check("config: the kimi journal has its three writers", config.contains("func kimiToolPolicyRestores()")
      && config.contains("func setKimiToolPolicyRestore(") && config.contains("func clearKimiToolPolicyRestore("))
check("manager: the journal and the label reach the runner through closures",
      manager.contains("runner.onKimiToolPolicyJournal = {") && manager.contains("runner.agentLabelProvider = {"))
check("app: the heal runs at launch", app.contains("agentManager.healKimiToolPolicies()"))
// The wording is free to move; what must hold is that the chat page's
// empty-state sentence names the mode as the chip's row names it.
check("chat page: sentence B names the Chat only mode", chatView.contains("**Chat only** mode"))
check("settings: the Help card and the About-chats paragraph name the mode",
      settings.contains("case chatOnly") && settings.contains("What is Chat only?") && settings.contains("**Chat only** mode"))

// Every new key carries a zh-Hans value.
for key in ["Chat only", "%@ can look things up on the web but can't read or change files. Attach files with +.",
            "Uses your %@ plan", "Uses your %@ limits", "Uses your %@ membership",
            "The first message of a new session arrives all at once; later ones stream.",
            "Attached files are sent with your message", "Chat with %@…", "Attach file",
            "What is Chat only?", "%@ approves its own tool calls on a headless run"] {
    let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let present = catalog.range(of: "\"\(escaped)\" : {").map { r in
        catalog[r.upperBound...].prefix(600).contains("\"zh-Hans\"")
    } ?? false
    check("catalog: \"\(key.prefix(48))\" has a zh-Hans value", present)
}

// ====================================================================
print("6b. SCRAPE ENVIRONMENT — the gate's CLI reads must run where the app runs")

// The app is launched by launchd, whose PATH is /usr/bin:/bin:/usr/sbin:/sbin.
// An npm-installed CLI is a `#!/usr/bin/env node` script, and with no
// `node` on that PATH it exits 127 before printing — the codex feature
// list came back empty and the Chat only row was simply absent. Every
// scrape must take the agent-child environment, through the one provider.
let launchOptionsSource = source("SipAI/Models/AgentLaunchOptions.swift")
let spawnCount = launchOptionsSource.components(separatedBy: "Process()").count - 1
let envCount = launchOptionsSource.components(separatedBy: "if let environment { p.environment = environment }").count - 1
check("every CLI scrape in AgentLaunchOptions.swift takes the scrape environment",
      spawnCount > 0 && spawnCount == envCount, "\(spawnCount) spawns, \(envCount) take it")
check("both scrapes are handed the provider's environment",
      launchOptionsSource.contains("Self.helpText(binary: binary, environment: environment)")
      && launchOptionsSource.contains("Self.featuresListing(binary: binary, environment: environment)")
      && launchOptionsSource.components(separatedBy: "let environment = await makeEnvironment?()").count - 1 == 2)
let helpTextBody: String = {
    guard let start = launchOptionsSource.range(of: "func helpText(binary: String") else { return "" }
    let rest = launchOptionsSource[start.upperBound...]
    let end = rest.range(of: "nonisolated private static func")?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
}()
check("a failed claude --help is not parsed as help (helpText checks the exit status)",
      helpTextBody.contains("guard p.terminationStatus == 0 else { return \"\" }"))
check("a failed read un-latches its key, so the next appearance retries",
      launchOptionsSource.contains("if help.isEmpty { self.scrapedKey = nil }")
      && launchOptionsSource.contains("if names == nil { self.featuresKey = nil }"))
let appInit = app.range(of: "init() {").map { String(app[$0.lowerBound...].prefix(1500)) } ?? ""
check("SipAIApp.init installs the provider with the agent-child environment",
      appInit.contains("CLIScrapeEnvironment.provider = {")
      && appInit.contains("await ShellEnvironment.prepare()")
      && appInit.contains("return AgentRunner.buildEnvironment()"))

// Behaviour, under the app's own PATH: this binary re-run with a bare
// environment, driving the REAL CodexCatalog read.
if binary("codex") != nil {
    // The probe drives the REAL `CodexCatalog.ensureLoaded()`, whose tail
    // also runs `refreshFromCodex` — a `codex app-server` + `model/list`
    // that may write `models_cache.json` back. Under a throwaway
    // CODEX_HOME (the environment reaches every child through the
    // provider's `buildEnvironment`) that write lands in the throwaway,
    // never in the user's real store; `features list` needs nothing
    // from the home to answer (measured: 149 features under an empty
    // one). Same isolation every other codex section here uses.
    let probeHome = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sipai-chatonly-probe-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? fm.createDirectory(at: probeHome, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: probeHome) }
    func probe(_ mode: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.environment = ["HOME": fm.homeDirectoryForCurrentUser.path,
                         "CODEX_HOME": probeHome.path,
                         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                         "SIPAI_CHATONLY_SCRAPE_PROBE": mode]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").first { $0.hasPrefix("PROBE ") }.map(String.init) ?? ""
    }
    let codexPath = binary("codex") ?? ""
    // Read the FIRST bytes only: a native codex is a ~100 MB Mach-O, and
    // decoding it whole as UTF-8 just to test a shebang is what a
    // `String(contentsOfFile:)` would do.
    let isNodeScript: Bool = {
        let resolved = (codexPath as NSString).resolvingSymlinksInPath
        guard let handle = FileHandle(forReadingAtPath: resolved) else { return false }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 64)
        return String(decoding: head, as: UTF8.self).hasPrefix("#!/usr/bin/env node")
    }()
    let with = probe("provider")
    check("under the bare PATH WITH the provider: the feature list lands and names shell_tool + unified_exec",
          with.contains("required=true"), with)
    let without = probe("none")
    if isNodeScript {
        // Negative control: this is the reported bug, reproduced — a
        // harness that cannot fail it would pass for the wrong reason.
        check("negative control: WITHOUT the provider an npm codex cannot start (the reported bug)",
              without.contains("features=-1"), without)
    } else {
        note("codex here is not a node script, so the bare PATH does not break it; the negative control needs an npm install (\(without))")
    }
    // The isolation must have REACHED the child: codex writes into its
    // home even for `features list` (a `tmp/`), so a throwaway that is
    // still empty means CODEX_HOME never propagated and the probe just
    // ran `app-server` against the real store.
    let wroteToThrowaway = ((try? fm.contentsOfDirectory(atPath: probeHome.path))?.isEmpty == false)
    check("probe: codex ran under the throwaway CODEX_HOME, not the real store", wroteToThrowaway,
          (try? fm.contentsOfDirectory(atPath: probeHome.path))?.joined(separator: ",") ?? "unreadable")
} else {
    skip("scrape environment, behaviourally", "codex is not installed")
}

// ====================================================================
print("7. GATES — the row is offered only where the installed CLI names the switches")

let helpWith = "Options:\n  --tools <tools...>                    Specify the list\n  --system-prompt-snapshot <on|off>     Record the system prompt\n  --resume [sessionId]  Resume\n"
let helpWithoutTools = "Options:\n  --system-prompt-snapshot <on|off>     Record\n  --resume [sessionId]  Resume\n"
let helpWithoutSnapshot = "Options:\n  --tools <tools...>   Specify\n  --system-prompt <prompt>   System prompt to use\n"
let helpMention = "Options:\n  --safe-mode   ignores files unless --tools names them, --system-prompt-snapshot included\n"
let full = ChatOnlyAvailability.claudeHelp(fromHelpText: helpWith)
check("claude help: both flags listed", full == .init(listsTools: true, listsSnapshot: true))
check("claude help: --tools absent → the row is absent",
      !ChatOnlyAvailability.offered(agent: "claude_code",
                                    claudeHelp: ChatOnlyAvailability.claudeHelp(fromHelpText: helpWithoutTools),
                                    codexVersion: nil, codexFeatures: nil, kimiVersion: nil))
check("claude help: --system-prompt-snapshot absent → the flag is absent from the argv, the row stays",
      { let h = ChatOnlyAvailability.claudeHelp(fromHelpText: helpWithoutSnapshot)
        return h.listsTools && !h.listsSnapshot
            && ChatOnlyAvailability.offered(agent: "claude_code", claudeHelp: h, codexVersion: nil, codexFeatures: nil, kimiVersion: nil)
            && !ChatOnlyArgv.claude(options: chat, snapshotFlagListed: h.listsSnapshot).contains("--system-prompt-snapshot") }())
check("claude help: a flag merely MENTIONED in another option's text is not listed",
      ChatOnlyAvailability.claudeHelp(fromHelpText: helpMention) == .init(listsTools: false, listsSnapshot: false))
check("claude help: nil (not read yet) → not offered",
      !ChatOnlyAvailability.offered(agent: "claude_code", claudeHelp: nil, codexVersion: nil, codexFeatures: nil, kimiVersion: nil))

let listing = "apps                 stable             true\nshell_tool           stable             true\nunified_exec         stable             true\nweb_search_cached    under development  false\n2026-09-21T00:00:00Z WARN  something\n"
let parsed = ChatOnlyAvailability.codexFeatures(fromListing: listing)
check("codex listing: names parsed, a log line ignored",
      parsed == ["apps", "shell_tool", "unified_exec", "web_search_cached"], parsed.sorted().joined(separator: ","))
check("codex: version at the floor with both features → offered",
      ChatOnlyAvailability.offered(agent: "codex", claudeHelp: nil, codexVersion: "0.155.1", codexFeatures: parsed, kimiVersion: nil))
check("codex: a newer version is accepted",
      ChatOnlyAvailability.offered(agent: "codex", claudeHelp: nil, codexVersion: "0.160.0", codexFeatures: parsed, kimiVersion: nil))
check("codex: below the floor → absent",
      !ChatOnlyAvailability.offered(agent: "codex", claudeHelp: nil, codexVersion: "0.154.0", codexFeatures: parsed, kimiVersion: nil))
check("codex: a listing without shell_tool → absent (the gate is POSITIVE)",
      !ChatOnlyAvailability.offered(agent: "codex", claudeHelp: nil, codexVersion: "0.155.1",
                                    codexFeatures: ChatOnlyAvailability.codexFeatures(fromListing: "apps  stable  true\nunified_exec  stable  true\n"),
                                    kimiVersion: nil))
check("codex: no listing yet → absent",
      !ChatOnlyAvailability.offered(agent: "codex", claudeHelp: nil, codexVersion: "0.155.1", codexFeatures: nil, kimiVersion: nil))
check("kimi: 2.0.1 and above → offered; 1.9.9 → absent; unreadable → absent",
      ChatOnlyAvailability.offered(agent: "kimi", claudeHelp: nil, codexVersion: nil, codexFeatures: nil, kimiVersion: "2.0.1")
      && ChatOnlyAvailability.offered(agent: "kimi", claudeHelp: nil, codexVersion: nil, codexFeatures: nil, kimiVersion: "2.1.0")
      && !ChatOnlyAvailability.offered(agent: "kimi", claudeHelp: nil, codexVersion: nil, codexFeatures: nil, kimiVersion: "1.9.9")
      && !ChatOnlyAvailability.offered(agent: "kimi", claudeHelp: nil, codexVersion: nil, codexFeatures: nil, kimiVersion: "beta"))
check("versionAtLeast pads with zeros (2.0 ≥ 2.0.0) and refuses nil", ChatOnlyAvailability.versionAtLeast("2.0", "2.0.0")
      && ChatOnlyAvailability.versionAtLeast("2.0.0", "2.0") && !ChatOnlyAvailability.versionAtLeast(nil, "1.0"))
check("an unknown agent is never offered",
      !ChatOnlyAvailability.offered(agent: "other", claudeHelp: full, codexVersion: "9.9.9", codexFeatures: parsed, kimiVersion: "9.9.9"))

// "Not offered" and "not read yet" both answer false above; only the
// second may hold a saved Chat only pick — sent in that window it would
// run as an agent turn, with the agent's tools.
check("settled: nothing read yet is NOT a verdict, for any of the three",
      !ChatOnlyAvailability.isSettled(agent: "claude_code", claudeHelp: nil, codexVersion: nil, codexFeatures: nil, kimiVersion: nil)
      && !ChatOnlyAvailability.isSettled(agent: "codex", claudeHelp: nil, codexVersion: nil, codexFeatures: nil, kimiVersion: nil)
      && !ChatOnlyAvailability.isSettled(agent: "kimi", claudeHelp: nil, codexVersion: nil, codexFeatures: nil, kimiVersion: nil))
check("settled: a read help text is a verdict, whichever way it went",
      ChatOnlyAvailability.isSettled(agent: "claude_code", claudeHelp: full, codexVersion: nil, codexFeatures: nil, kimiVersion: nil)
      && ChatOnlyAvailability.isSettled(agent: "claude_code",
                                        claudeHelp: ChatOnlyAvailability.claudeHelp(fromHelpText: helpWithoutTools),
                                        codexVersion: nil, codexFeatures: nil, kimiVersion: nil))
check("settled: codex at the floor waits for its feature list; below it needs none",
      !ChatOnlyAvailability.isSettled(agent: "codex", claudeHelp: nil, codexVersion: "0.155.1", codexFeatures: nil, kimiVersion: nil)
      && ChatOnlyAvailability.isSettled(agent: "codex", claudeHelp: nil, codexVersion: "0.155.1", codexFeatures: parsed, kimiVersion: nil)
      && ChatOnlyAvailability.isSettled(agent: "codex", claudeHelp: nil, codexVersion: "0.154.0", codexFeatures: nil, kimiVersion: nil))
check("settled: kimi's version read is its verdict, even an unparseable one",
      ChatOnlyAvailability.isSettled(agent: "kimi", claudeHelp: nil, codexVersion: nil, codexFeatures: nil, kimiVersion: "beta"))
// The composer holds the send while unsettled, and the host refuses it
// again (the Enter key and the button both reach `handleSend`).
check("the composer holds a Chat only pick the gate has not read, and says so",
      composer.contains("options.chatOnly && !ChatOnlyGate.settled(agentKey: agentKey)")
      && composer.contains("&& !sending && !externalBusy && !chatOnlyPending")
      && composer.contains("Checking whether \\(agentName) offers Chat only."))
check("…and the host's send refuses it too, before anything is sent",
      view.contains("if launchOptions.chatOnly, !ChatOnlyGate.settled(agentKey: sessionAgentKey) { return }"))

// The installed CLIs, read the way the app reads them.
if let claude = binary("claude_code") {
    let help = run(claude, ["--help"]).out
    let live = ChatOnlyAvailability.claudeHelp(fromHelpText: help)
    check("installed claude: --help lists --tools (else the row is rightly absent — re-measure)", live.listsTools)
    note("installed claude lists --system-prompt-snapshot: \(live.listsSnapshot)")
}
if let codex = binary("codex") {
    let listing = run(codex, ["features", "list"]).out
    let features = ChatOnlyAvailability.codexFeatures(fromListing: listing)
    let version = run(codex, ["--version"]).out
    check("installed codex: `features list` names shell_tool and unified_exec",
          ChatOnlyAvailability.codexRequiredFeatures.isSubset(of: features), "\(features.count) names")
    note("installed codex version line: " + version.trimmingCharacters(in: .whitespacesAndNewlines))
}
if let kimi = binary("kimi") {
    let version = run(kimi, ["--version"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    check("installed kimi: version ≥ \(ChatOnlyAvailability.kimiVersionFloor)",
          ChatOnlyAvailability.versionAtLeast(version, ChatOnlyAvailability.kimiVersionFloor), version)
}

// ====================================================================
print("8. IMAGES — the per-agent image channel, and no base64 in a transcript")

// A staged image resolves to this: name + base64 + a provider-safe
// media type. `ChatAttachment` builds it in the app; here it is a fixed
// value so the wire shapes can be pinned without an image pipeline.
let sampleImage = AgentImage(name: "shot.png", base64: "aGVsbG8=", mediaType: "image/png")
let secondImage = AgentImage(name: "b.jpg", base64: "d29ybGQ=", mediaType: "image/jpeg")

// (a) The DISPLAY marker: named on the paperclip line, stripped from
//     the bubble, and carrying no data — so a transcript record that
//     holds it holds no base64.
let imgMarker = AttachmentInline.imageMarker(name: "shot.png")
let withMarker = imgMarker + "\n\nWhat is in this picture?"
check("image marker: the name is on the paperclip line",
      AttachmentInline.names(in: withMarker) == ["shot.png"], AttachmentInline.names(in: withMarker).description)
check("image marker: stripped from the drawn bubble",
      AttachmentInline.stripping(withMarker) == "What is in this picture?",
      AttachmentInline.stripping(withMarker))
check("image marker: carries no base64", !imgMarker.contains("aGVsbG8"))

// (b) claude reads a stream-json message on stdin: image blocks first
//     (base64), then the text — which is the WIRE text, marker included.
let claudeLine = ChatOnlyImages.claudeStdinLine(text: withMarker, images: [sampleImage])
let claudeMsg = object(claudeLine)
let claudeContent = ((claudeMsg["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
check("claude stdin: one JSON user record, newline-terminated",
      claudeMsg["type"] as? String == "user" && claudeLine.hasSuffix("\n"))
check("claude stdin: image block first, base64 in source.data, then text",
      claudeContent.count == 2
      && claudeContent[0]["type"] as? String == "image"
      && ((claudeContent[0]["source"] as? [String: Any])?["data"] as? String) == "aGVsbG8="
      && ((claudeContent[0]["source"] as? [String: Any])?["media_type"] as? String) == "image/png"
      && claudeContent[1]["type"] as? String == "text",
      claudeContent.description)
check("claude stdin: the text block carries the wire text (marker included, recorded verbatim)",
      (claudeContent.last?["text"] as? String) == withMarker)

// (c) kimi's server prompt: image blocks (source.kind == base64), text last.
let kimiBlocks = ChatOnlyImages.kimiContentBlocks(text: withMarker, images: [sampleImage, secondImage])
check("kimi blocks: two images then the text, each with source.kind == base64",
      kimiBlocks.count == 3
      && kimiBlocks[0]["type"] as? String == "image"
      && ((kimiBlocks[0]["source"] as? [String: Any])?["kind"] as? String) == "base64"
      && kimiBlocks[1]["type"] as? String == "image"
      && kimiBlocks[2]["type"] as? String == "text",
      kimiBlocks.description)
check("kimi blocks: the image names ride the blocks",
      (kimiBlocks[0]["name"] as? String) == "shot.png" && (kimiBlocks[1]["name"] as? String) == "b.jpg")

// (d) codex reads FILES: the extension follows the media type.
check("codex file extension: png/jpeg/gif/webp map, default png",
      ChatOnlyImages.codexFileExtension(mediaType: "image/png") == "png"
      && ChatOnlyImages.codexFileExtension(mediaType: "image/jpeg") == "jpg"
      && ChatOnlyImages.codexFileExtension(mediaType: "image/gif") == "gif"
      && ChatOnlyImages.codexFileExtension(mediaType: "image/webp") == "webp"
      && ChatOnlyImages.codexFileExtension(mediaType: "image/heic") == "png")

// (e) A resumed kimi turn has no image channel — one rule, keyed once.
check("kimi resume accepts no image", ChatOnlyImages.kimiResumeAcceptsImages == false)

// (e2) codex `-i` is VARIADIC on `codex exec` and swallows the prompt
//      if placed first (measured: codex then reads stdin and dies
//      "No prompt provided"). Every `-i` must come AFTER the positional
//      prompt — on a new thread and on a resume.
func codexOrderOK(resuming: Bool, sessionId: String?) -> Bool {
    let tail = ChatOnlyImages.codexTrailingArgs(
        resuming: resuming, sessionId: sessionId, text: "the prompt",
        imageFiles: ["/tmp/a.png", "/tmp/b.jpg"])
    guard let textAt = tail.firstIndex(of: "the prompt") else { return false }
    let flagIndices = tail.enumerated().filter { $0.element == "-i" }.map(\.offset)
    guard flagIndices.count == 2 else { return false }
    // Every -i after the prompt, and the id (resume) before it.
    let flagsAfterPrompt = flagIndices.allSatisfy { $0 > textAt }
    let idOK = !resuming || (tail.first == sessionId)
    return flagsAfterPrompt && idOK
}
check("codex images: -i comes after the prompt on a new thread", codexOrderOK(resuming: false, sessionId: nil))
check("codex images: -i comes after id and prompt on a resume", codexOrderOK(resuming: true, sessionId: "thread-1"))
check("codex images: no image files → just the prompt (new) / id+prompt (resume)",
      ChatOnlyImages.codexTrailingArgs(resuming: false, sessionId: nil, text: "p", imageFiles: []) == ["p"]
      && ChatOnlyImages.codexTrailingArgs(resuming: true, sessionId: "t", text: "p", imageFiles: []) == ["t", "p"])

// (f) THE no-leak property, end to end through the REAL claude reader:
//     a recorded image turn draws its text with the marker stripped and
//     the image NAMED, and never the base64. All three readers flatten
//     only text blocks, so the base64 image block is dropped on reopen;
//     this pins it for the claude reader as the representative.
do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sipai-img-reader-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("s.jsonl")
    let bigBase64 = String(repeating: "QUJD", count: 4000)  // 16k chars, unmistakable if it leaked
    let record: [String: Any] = [
        "type": "user", "uuid": "u1", "timestamp": "2026-09-21T00:00:00Z",
        "message": ["role": "user", "content": [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": bigBase64]],
            ["type": "text", "text": withMarker],
        ]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: record)
    try! (String(decoding: data, as: UTF8.self) + "\n").write(to: file, atomically: true, encoding: .utf8)
    let rows = userRows(AgentSessionScanner.readHistory(of: file))
    let drawn = rows.map { $0.0 }.joined(separator: "\n")
    let named = rows.flatMap { $0.1 }
    check("reader: the drawn bubble is the user's words, marker gone",
          drawn == "What is in this picture?", drawn)
    check("reader: the image is NAMED on reopen", named == ["shot.png"], named.description)
    check("reader: NO base64 in the drawn transcript or the names",
          !drawn.contains("QUJD") && !named.joined().contains("QUJD"))
    try? fm.removeItem(at: dir)
}

// ====================================================================
print("8b. THOUGHTS — the model's thinking reaches a Chat only turn, and only one")

func thoughts(_ events: [StreamEvent]) -> [String] {
    events.compactMap { event -> String? in
        if case .thinking(let t) = event.kind { return t }
        return nil
    }
}
func kinds(_ items: [AgentSessionHistoryItem]) -> [String] {
    items.map { item -> String in
        switch item.kind {
        case .userText: return "user"
        case .assistantText: return "text"
        case .thinking: return "thought"
        case .toolUse: return "tool"
        case .toolResult: return "result"
        case .interrupted: return "interrupted"
        case .compaction: return "compaction"
        }
    }
}
func historyThoughts(_ items: [AgentSessionHistoryItem]) -> [String] {
    items.compactMap { item -> String? in
        if case .thinking(let t) = item.kind { return t }
        return nil
    }
}
let anywhere = URL(fileURLWithPath: NSTemporaryDirectory())

// (a) The probe that gates claude's readable-thinking flag. The flag is
// not in `--help`; a claude that knows it refuses a bogus value by naming
// the flag and its choices.
check("probe: a claude that knows --thinking-display names it and its choices → accepted",
      ChatOnlyAvailability.acceptsThinkingDisplay(probeOutput:
        "error: option '--thinking-display <display>' argument 'sipai-probe' is invalid. Allowed choices are summarized, omitted, highlights."))
check("probe: an unknown-option refusal → not accepted",
      !ChatOnlyAvailability.acceptsThinkingDisplay(probeOutput: "error: unknown option '--thinking-display'"))
check("probe: a bare version (the flag silently ignored) → not accepted",
      !ChatOnlyAvailability.acceptsThinkingDisplay(probeOutput: "9.9.9 (Claude Code)"))
if let claude = binary("claude_code") {
    let probe = run(claude, ChatOnlyAvailability.thinkingDisplayProbeArguments, timeout: 30)
    check("probe: the INSTALLED claude takes --thinking-display (its Chat only turns ask for readable thinking)",
          ChatOnlyAvailability.acceptsThinkingDisplay(probeOutput: probe.out),
          String(probe.out.prefix(200)))
} else {
    skip("probe: the installed claude", "claude is not installed")
}

// (b) The argv: Chat only turns alone, behind the verdict.
let withThinking = ChatOnlyArgv.claude(options: chat, snapshotFlagListed: true,
                                       thinkingDisplayAccepted: true)
if let at = withThinking.firstIndex(of: "--thinking-display"), at + 1 < withThinking.count {
    check("argv: an accepted flag rides a Chat only turn as `--thinking-display summarized`",
          withThinking[at + 1] == "summarized")
} else {
    check("argv: an accepted flag rides a Chat only turn as `--thinking-display summarized`", false,
          withThinking.joined(separator: " "))
}
check("argv: the list stays closed — no variadic swallows the value",
      ChatOnlyArgv.variadicFlagsAreClosed(withThinking))
check("argv: never on an agent turn, accepted or not",
      !ChatOnlyArgv.claude(options: plain, snapshotFlagListed: true,
                           thinkingDisplayAccepted: true).contains("--thinking-display"))
check("argv: never unless the probe accepted it",
      !ChatOnlyArgv.claude(options: chat, snapshotFlagListed: true,
                           thinkingDisplayAccepted: false).contains("--thinking-display"))

// (c) The live parsers: no thought unless asked — which is every agent
// turn — and never an empty one.
let claudeThought = #"{"type":"assistant","message":{"id":"m1","role":"assistant","model":"fake","content":[{"type":"thinking","thinking":"Weighing it.","signature":"sig"}]}}"#
let claudeEmpty = #"{"type":"assistant","message":{"id":"m1","role":"assistant","model":"fake","content":[{"type":"thinking","thinking":"","signature":"sig"}]}}"#
check("claude parser: a thought is dropped unless asked",
      AgentEventParser.parse(line: claudeThought, fallbackCwd: anywhere).isEmpty)
check("claude parser: asked, a thought with text is ONE .thinking",
      thoughts(AgentEventParser.parse(line: claudeThought, fallbackCwd: anywhere,
                                      includeThinking: true)) == ["Weighing it."])
check("claude parser: an empty block (display omitted) is nothing, asked or not",
      AgentEventParser.parse(line: claudeEmpty, fallbackCwd: anywhere, includeThinking: true).isEmpty)
let codexThought = #"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"**Weighing it**\n\nThe page says 3.14."}}"#
let codexEmpty = #"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":""}}"#
check("codex parser: a reasoning summary is dropped unless asked",
      CodexEventParser.parse(line: codexThought, fallbackCwd: anywhere).events.isEmpty)
check("codex parser: asked, it is ONE .thinking",
      thoughts(CodexEventParser.parse(line: codexThought, fallbackCwd: anywhere,
                                      includeThinking: true).events)
          == ["**Weighing it**\n\nThe page says 3.14."])
check("codex parser: an empty summary is nothing, asked or not",
      CodexEventParser.parse(line: codexEmpty, fallbackCwd: anywhere, includeThinking: true).events.isEmpty)

// (d) The readers, and the per-turn filter a reopen applies.
do {
    let dir = anywhere.appendingPathComponent("sipai-thoughts-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("t.jsonl")
    let records: [[String: Any]] = [
        ["type": "user", "uuid": "u1", "message": ["role": "user", "content": "first"]],
        ["type": "assistant", "uuid": "a1", "message": ["role": "assistant", "model": "fake", "content": [
            ["type": "thinking", "thinking": "T-one", "signature": "s"],
            ["type": "text", "text": "A1"]]]],
        ["type": "user", "uuid": "u2", "message": ["role": "user", "content": "second"]],
        ["type": "assistant", "uuid": "a2", "message": ["role": "assistant", "model": "fake", "content": [
            ["type": "thinking", "thinking": "T-two", "signature": "s"],
            ["type": "text", "text": "A2"]]]],
    ]
    let text = records.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        .joined(separator: "\n") + "\n"
    try? text.write(to: file, atomically: true, encoding: .utf8)
    let without = AgentSessionScanner.readHistory(of: file)
    let with = AgentSessionScanner.readHistory(of: file, includeThinking: true)
    check("claude reader: no thought unless asked — an agent session reads exactly as before",
          kinds(without) == ["user", "text", "user", "text"], kinds(without).description)
    check("claude reader: asked, each thought in place",
          kinds(with) == ["user", "thought", "text", "user", "thought", "text"], kinds(with).description)
    let kept = AgentSessionHistoryItem.keepingThoughts(with, inTurns: ["u2"])
    check("filter: only the RECORDED Chat only turn keeps its thought",
          kinds(kept) == ["user", "text", "user", "thought", "text"] && historyThoughts(kept) == ["T-two"],
          kinds(kept).description)
    check("filter: with no turn recorded, the read equals the agent read",
          kinds(AgentSessionHistoryItem.keepingThoughts(with, inTurns: [])) == kinds(without))
    try? fm.removeItem(at: dir)
}
let reasoningRecord = #"{"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"**Weighing it**"}],"encrypted_content":null}}"#
let emptyReasoning = #"{"type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"abc"}}"#
var plainRollout = CodexSessionScanner.RolloutDecoder()
check("codex reader: a reasoning record is nothing unless asked",
      plainRollout.items(forLine: reasoningRecord).isEmpty)
var thinkingRollout = CodexSessionScanner.RolloutDecoder(includeThinking: true)
check("codex reader: asked, its summary is a thought",
      historyThoughts(thinkingRollout.items(forLine: reasoningRecord)) == ["**Weighing it**"])
check("codex reader: an empty summary is nothing, asked or not",
      thinkingRollout.items(forLine: emptyReasoning).isEmpty)
// Codex's code mode: a search's own `item_completed` record is the row
// on reopen; beside the older `web_search_call` it is ONE row. The call
// record carries NO id (measured over every rollout on a real store),
// so the pair is matched by count within the turn, and the item and the
// call spell the search differently (`query` vs `action.queries`).
func toolCommands(_ items: [AgentSessionHistoryItem]) -> [String] {
    items.compactMap { item -> String? in
        if case .toolUse(_, let name, let input) = item.kind {
            return "\(name):\((input["command"] as? String) ?? "")"
        }
        return nil
    }
}
do {
    var both = CodexSessionScanner.RolloutDecoder()
    let dual = [
        #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"WebSearch","id":"ws_1","query":"probe terms","action":{"type":"search","query":"probe terms"}}}}"#,
        #"{"type":"response_item","payload":{"type":"web_search_call","status":"completed","action":{"type":"search","queries":["probe terms","probe terms again"]}}}"#,
    ].flatMap { both.items(forLine: $0) }
    check("codex reader: a search recorded twice (item_completed, then an id-less web_search_call) is ONE row",
          toolCommands(dual) == ["web_search_call:probe terms"], toolCommands(dual).description)
    var twice = CodexSessionScanner.RolloutDecoder()
    let repeated = [
        #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"WebSearch","id":"ws_2","query":"same terms","action":{"type":"search","query":"same terms"}}}}"#,
        #"{"type":"response_item","payload":{"type":"web_search_call","status":"completed","action":{"type":"search","queries":["same terms"]}}}"#,
        #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"WebSearch","id":"ws_3","query":"same terms","action":{"type":"search","query":"same terms"}}}}"#,
        #"{"type":"response_item","payload":{"type":"web_search_call","status":"completed","action":{"type":"search","queries":["same terms"]}}}"#,
    ].flatMap { twice.items(forLine: $0) }
    check("codex reader: two searches for one query, each recorded twice, are TWO rows",
          toolCommands(repeated) == ["web_search_call:same terms", "web_search_call:same terms"],
          toolCommands(repeated).description)
    var sameId = CodexSessionScanner.RolloutDecoder()
    let byId = [
        #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"WebSearch","id":"ws_4","query":"id terms","action":{"type":"search","query":"id terms"}}}}"#,
        #"{"type":"response_item","payload":{"type":"web_search_call","id":"ws_4","status":"completed","action":{"type":"search","query":"id terms"}}}"#,
        #"{"type":"response_item","payload":{"type":"web_search_call","status":"completed","action":{"type":"search","queries":["a later, unpaired call"]}}}"#,
    ].flatMap { sameId.items(forLine: $0) }
    check("codex reader: a pair sharing an id is one row, and leaves the count clean for the next id-less call",
          toolCommands(byId) == ["web_search_call:id terms", "web_search_call:a later, unpaired call"],
          toolCommands(byId).description)
    var acrossTurns = CodexSessionScanner.RolloutDecoder()
    let split = [
        #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"WebSearch","id":"ws_5","query":"turn one","action":{"type":"search","query":"turn one"}}}}"#,
        #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}"#,
        #"{"type":"response_item","payload":{"type":"web_search_call","status":"completed","action":{"type":"search","queries":["turn two"]}}}"#,
    ].flatMap { acrossTurns.items(forLine: $0) }
    check("codex reader: the pair count resets per turn — a call in the next turn is its own row",
          toolCommands(split) == ["web_search_call:turn one", "web_search_call:turn two"],
          toolCommands(split).description)
    var codeMode = CodexSessionScanner.RolloutDecoder()
    let script = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","status":"completed","call_id":"c1","input":"const r = await tools.web__run({search_query:[{q:\"x\"}]}); text(r);"}}"#
    let ext = #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Extension","kind":"web.search","id":"exec-1","query":"https://www.python.org/downloads/","action":{"type":"openPage","url":"https://www.python.org/downloads/"}}}}"#
    let codeRows = [script, ext].flatMap { codeMode.items(forLine: $0) }
    check("codex reader: under code mode the search is read off its own record, as the live feed spells it",
          toolCommands(codeRows).last == "web_search_call:https://www.python.org/downloads/",
          toolCommands(codeRows).description)
    var older = CodexSessionScanner.RolloutDecoder()
    check("codex reader: an older rollout with only `web_search_call` reads as before",
          toolCommands(older.items(forLine: #"{"type":"response_item","payload":{"type":"web_search_call","id":"ws_9","status":"completed","action":{"type":"open_page","url":"https://a.org/x"}}}"#))
              == ["web_search_call:https://a.org/x"])
    let completed = #"{"type":"item.completed","item":{"id":"exec-7","type":"web_search","query":"site:python.org latest ...","action":{"type":"search","queries":["site:python.org latest"]}}}"#
    let results = CodexEventParser.parse(line: completed, fallbackCwd: anywhere).events.compactMap { event -> String? in
        if case .toolResult(_, let output, _) = event.kind { return output }
        return nil
    }
    check("codex parser: a completed search's result is its query — code mode names it nowhere else live",
          results == ["site:python.org latest ..."], results.description)
}

let thinkPart = #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"think","think":"Weighing it.","reasoningKey":"reasoning_content"}},"time":1}"#
var plainWire = KimiSessionScanner.WireDecoder()
check("kimi reader: a think part is nothing unless asked", plainWire.items(forLine: thinkPart).isEmpty)
var thinkingWire = KimiSessionScanner.WireDecoder(includeThinking: true)
check("kimi reader: asked, it is a thought",
      historyThoughts(thinkingWire.items(forLine: thinkPart)) == ["Weighing it."])

// (d2) Kimi's thoughts reach a live turn off the wire: each goes BEFORE
// the row it led to, in order, and waits while that row is not on
// stdout yet. `KimiSessionScanner.thoughtPlacements` is what the runner
// applies; the rows here are what it maps its events to.
do {
    let wire: [AgentSessionHistoryItem] = [
        AgentSessionHistoryItem(kind: .userText("q"), recordUuid: "p1"),
        AgentSessionHistoryItem(kind: .thinking("A")),
        AgentSessionHistoryItem(kind: .toolUse(id: "X", name: "FetchURL", input: [:])),
        AgentSessionHistoryItem(kind: .toolResult(toolUseId: "X", content: "page", isError: false)),
        AgentSessionHistoryItem(kind: .thinking("B")),
        AgentSessionHistoryItem(kind: .assistantText("The answer.")),
    ]
    typealias Row = KimiSessionScanner.LiveRow
    func placed(_ rows: [Row], already: Int = 0, final: Bool = false) -> [String] {
        KimiSessionScanner.thoughtPlacements(wireItems: wire, turnRows: rows,
                                             alreadyPlaced: already, final: final)
            .map { "\($0.text)@\($0.at)" }
    }
    check("kimi placement: each thought goes before the row it led to, in order",
          placed([.toolUse(id: "X"), .toolResult, .text("The answer.")]) == ["A@0", "B@3"],
          placed([.toolUse(id: "X"), .toolResult, .text("The answer.")]).description)
    check("kimi placement: a thought whose row is not on stdout yet WAITS (and so does every later one)",
          placed([.toolUse(id: "X"), .toolResult]) == ["A@0"])
    // A step cut off by Stop: its thought is the wire's last record, with
    // no row after it to anchor to.
    let stopped = Array(wire.prefix(5))
    let leftover = KimiSessionScanner.thoughtPlacements(
        wireItems: stopped, turnRows: [.toolUse(id: "X"), .toolResult, .other],
        alreadyPlaced: 0, final: true).map { "\($0.text)@\($0.at)" }
    check("kimi placement: the final read places a leftover after the last step, ahead of an error row",
          leftover == ["A@0", "B@3"], leftover.description)
    check("kimi placement: …and only the final read",
          KimiSessionScanner.thoughtPlacements(
              wireItems: stopped, turnRows: [.toolUse(id: "X"), .toolResult],
              alreadyPlaced: 0, final: false).map(\.text) == ["A"])
    check("kimi placement: thoughts already placed are not placed again",
          placed([.thought, .toolUse(id: "X"), .toolResult, .text("The answer.")], already: 1) == ["B@3"])
    check("kimi placement: stdout text that carries the wire's text part (and more) is its anchor",
          placed([.toolUse(id: "X"), .toolResult, .text("The answer. Sources: …")]) == ["A@0", "B@3"])

    func placements(_ items: [AgentSessionHistoryItem], _ rows: [Row],
                    already: Int = 0, final: Bool = false) -> [String] {
        KimiSessionScanner.thoughtPlacements(wireItems: items, turnRows: rows,
                                             alreadyPlaced: already, final: final)
            .map { "\($0.text)@\($0.at)" }
    }
    func item(_ kind: AgentSessionHistoryItem.Kind) -> AgentSessionHistoryItem {
        AgentSessionHistoryItem(kind: kind)
    }
    // A tail holding ONE user message comes back whole from the reader,
    // the end of the turn before it included.
    let withOldTail = [item(.thinking("OLD")), item(.toolUse(id: "OLD-X", name: "FetchURL", input: [:])),
                       item(.assistantText("The old answer."))] + wire
    check("kimi placement: only the turn's own records count — the turn before it is ignored",
          placements(withOldTail, [.toolUse(id: "X"), .toolResult, .text("The answer.")]) == ["A@0", "B@3"],
          placements(withOldTail, [.toolUse(id: "X"), .toolResult, .text("The answer.")]).description)
    check("kimi placement: a tail that opened inside the turn places nothing (its thoughts cannot be counted)",
          placements(Array(wire.dropFirst()), [.toolUse(id: "X"), .toolResult, .text("The answer.")],
                     final: true).isEmpty)
    check("kimi placement: a compaction summary in the user column does not open the turn",
          placements([AgentSessionHistoryItem(kind: .userText("summary"), isSystemNotice: true)] + wire,
                     [.toolUse(id: "X"), .toolResult, .text("The answer.")]) == ["A@0", "B@3"])
    // The same sentence twice in one turn: each thought goes to its own saying.
    let twice = [item(.userText("q")), item(.thinking("A")), item(.assistantText("Checking.")),
                 item(.toolUse(id: "X", name: "FetchURL", input: [:])),
                 item(.toolResult(toolUseId: "X", content: "page", isError: false)),
                 item(.thinking("B")), item(.assistantText("Checking."))]
    let twiceRows: [Row] = [.text("Checking."), .toolUse(id: "X"), .toolResult, .text("Checking.")]
    check("kimi placement: a sentence said twice anchors each thought to its own saying",
          placements(twice, twiceRows) == ["A@0", "B@4"], placements(twice, twiceRows).description)
    check("kimi placement: …and a later saying not on stdout yet WAITS rather than taking the earlier one",
          placements(twice, Array(twiceRows.prefix(3))) == ["A@0"],
          placements(twice, Array(twiceRows.prefix(3))).description)
    // Two thoughts before one step, and two text parts of one message.
    let pair = [item(.userText("q")), item(.thinking("A")), item(.thinking("B")),
                item(.toolUse(id: "X", name: "FetchURL", input: [:]))]
    check("kimi placement: two thoughts before one step both go before it, in order",
          placements(pair, [.toolUse(id: "X")]) == ["A@0", "B@1"])
    let parts = [item(.userText("q")), item(.thinking("A")), item(.assistantText("Part one.")),
                 item(.thinking("B")), item(.assistantText("Part two."))]
    check("kimi placement: a later part of the SAME stdout message anchors there, after the earlier one",
          placements(parts, [.text("Part one. Part two.")]) == ["A@0", "B@1"],
          placements(parts, [.text("Part one. Part two.")]).description)
}

// (e) The REAL CLIs, fed a scripted thought by the fake endpoint.
if let claude = binary("claude_code"), let server = FakeServer(think: true) {
    let home = anywhere.appendingPathComponent("sipai-thoughts-claude-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let cfg = home.appendingPathComponent("cfg", isDirectory: true)
    let cwd = home.appendingPathComponent("cwd", isDirectory: true)
    try? fm.createDirectory(at: cfg, withIntermediateDirectories: true)
    try? fm.createDirectory(at: cwd, withIntermediateDirectories: true)
    let e = ["CLAUDE_CONFIG_DIR": cfg.path,
             "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(server.port)",
             "ANTHROPIC_API_KEY": "sk-ant-harness-junk"]
    func messagesBody() -> [String: Any] {
        server.body(server.requests().last { ($0["body"] as? [String: Any])?["messages"] != nil })
    }
    let r = run(claude, ["-p", "What is new?", "--output-format", "stream-json", "--verbose"]
                + ChatOnlyArgv.claude(options: chat, snapshotFlagListed: true, thinkingDisplayAccepted: true),
                cwd: cwd, environment: e)
    let thinking = messagesBody()["thinking"] as? [String: Any]
    check("claude: the Chat only request asks for READABLE thinking (display: summarized)",
          thinking?["display"] as? String == "summarized", String(describing: thinking))
    let parsed = r.out.split(separator: "\n").flatMap {
        AgentEventParser.parse(line: String($0), fallbackCwd: cwd, includeThinking: true)
    }
    check("claude: the thought reaches stdout and parses as a .thinking",
          thoughts(parsed).contains { $0.contains("HARNESS-THOUGHT") }, String(r.out.prefix(200)))
    let transcripts = (fm.enumerator(at: cfg.appendingPathComponent("projects"), includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }) ?? []
    if let file = transcripts.first {
        check("claude: the transcript keeps the thought for a reopen",
              historyThoughts(AgentSessionScanner.readHistory(of: file, includeThinking: true))
                  .contains { $0.contains("HARNESS-THOUGHT") })
    } else {
        check("claude: the transcript keeps the thought for a reopen", false, "no transcript under \(cfg.path)")
    }
    server.clear()
    _ = run(claude, ["-p", "Again?", "--output-format", "stream-json", "--verbose"]
            + ChatOnlyArgv.claude(options: chat, snapshotFlagListed: true, thinkingDisplayAccepted: false),
            cwd: cwd, environment: e)
    check("claude: without the flag nothing asks for readable thinking — the probe's verdict is what adds it",
          (messagesBody()["thinking"] as? [String: Any])?["display"] == nil,
          String(describing: messagesBody()["thinking"]))
    server.stop()
    try? fm.removeItem(at: home)
} else {
    skip("claude over the fake endpoint, with a thought", "claude or python3 unavailable")
}

if let codex = binary("codex"), let server = FakeServer(think: true) {
    let home = codexHome(port: server.port)
    let cwd = home.appendingPathComponent("cwd", isDirectory: true)
    try? fm.createDirectory(at: cwd, withIntermediateDirectories: true)
    let personaFile = home.appendingPathComponent("persona.md")
    try? ChatOnlyPersona.ensureFile(at: personaFile)
    let r = run(codex, ["exec", "--json", "--skip-git-repo-check"]
                + ChatOnlyArgv.codex(options: chat, bornPlain: false, personaFile: personaFile.path)
                + ["What is new?"], cwd: cwd, environment: ["CODEX_HOME": home.path])
    let lines = r.out.split(separator: "\n").map(String.init)
    let asked = lines.flatMap { CodexEventParser.parse(line: $0, fallbackCwd: cwd, includeThinking: true).events }
    let notAsked = lines.flatMap { CodexEventParser.parse(line: $0, fallbackCwd: cwd).events }
    check("codex: a reasoning summary reaches stdout and parses as a .thinking",
          thoughts(asked).contains { $0.contains("HARNESS-THOUGHT") }, String(r.out.prefix(240)))
    check("codex: not asked, the same stdout carries no thought", thoughts(notAsked).isEmpty)
    let rollouts = (fm.enumerator(at: home.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }) ?? []
    if let rollout = rollouts.first {
        let items = CodexSessionScanner.readHistory(of: rollout, root: home.appendingPathComponent("sessions"),
                                                    includeThinking: true)
        check("codex: the rollout keeps the summary for a reopen",
              historyThoughts(items).contains { $0.contains("HARNESS-THOUGHT") }, kinds(items).description)
    } else {
        check("codex: the rollout keeps the summary for a reopen", false, "no rollout under \(home.path)")
    }
    server.stop()
    try? fm.removeItem(at: home)
} else {
    skip("codex over the fake endpoint, with a thought", "codex or python3 unavailable")
}

if let kimi = binary("kimi"), let server = FakeServer(think: true) {
    let home = kimiHome(port: server.port)
    // The fake model declares it thinks, as a reasoning model does.
    if let handle = try? FileHandle(forWritingTo: home.appendingPathComponent("config.toml")) {
        handle.seekToEndOfFile()
        handle.write(Data("\n[models.\"fake/thinking\"]\nprovider = \"fake\"\nmodel = \"fake-model\"\nmax_context_size = 262144\ncapabilities = [ \"tool_use\", \"thinking\" ]\n".utf8))
        try? handle.close()
    }
    let cwd = home.appendingPathComponent("cwd", isDirectory: true)
    try? fm.createDirectory(at: cwd, withIntermediateDirectories: true)
    let r = run(kimi, ["--prompt", "What is new?", "--output-format", "stream-json", "--model", "fake/thinking"],
                cwd: cwd, environment: ["KIMI_CODE_HOME": home.path])
    check("kimi: print-mode stdout carries NO thought — the reason SipAI reads it off the wire",
          r.status == 0 && !r.out.contains("HARNESS-THOUGHT"), String(r.out.prefix(200)))
    if let sid = kimiSessionId(r.out), let dir = kimiSessionDir(home: home, id: sid) {
        let wire = dir.appendingPathComponent("agents/main/wire.jsonl")
        check("kimi: the wire keeps the thought, and the reader reads it when asked",
              historyThoughts(KimiSessionScanner.readHistory(of: wire, includeThinking: true))
                  .contains { $0.contains("HARNESS-THOUGHT") })
        check("kimi: not asked, the reader reads none",
              historyThoughts(KimiSessionScanner.readHistory(of: wire)).isEmpty)
        // What the runner does at turn end: the REAL wire's turn against
        // the REAL stdout's rows.
        let stdoutRows: [KimiSessionScanner.LiveRow] = r.out.split(separator: "\n").flatMap {
            KimiEventParser.parse(line: String($0), fallbackCwd: cwd)
        }.map { event in
            switch event.kind {
            case .toolUse(let id, _, _): return .toolUse(id: id)
            case .toolResult: return .toolResult
            case .assistantText(let text): return .text(text)
            default: return .other
            }
        }
        let placements = KimiSessionScanner.thoughtPlacements(
            wireItems: KimiSessionScanner.readHistory(of: wire, maxTurns: 1, includeThinking: true),
            turnRows: stdoutRows, alreadyPlaced: 0, final: true)
        check("kimi: the real wire's thought lands before the real stdout's answer",
              placements.count == 1 && placements[0].at == 0 && placements[0].text.contains("HARNESS-THOUGHT"),
              placements.map { "\($0.at): \($0.text.prefix(40))" }.description)
    } else {
        check("kimi: the wire keeps the thought, and the reader reads it when asked", false,
              "no session: \(String(r.out.prefix(200)))")
    }
    server.stop()
    try? fm.removeItem(at: home)
} else {
    skip("kimi over the fake endpoint, with a thought", "kimi or python3 unavailable")
}

// ====================================================================
print("9. LIVE — one real Chat only turn, one Default turn and one web lookup per agent (SIPAI_CHATONLY_LIVE=1)")

/// A current question, so the lookup is the model's own call to make.
let liveWebQuestion = "What is the latest stable release of Python? Look it up on the web and cite the page."

if !liveTurns {
    skip("real turns", "set SIPAI_CHATONLY_LIVE=1 (spends tokens on each installed CLI)")
} else {
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sipai-chatonly-live-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    if let claude = binary("claude_code") {
        let first = run(claude, ["-p", "Reply with the single word OK.", "--output-format", "stream-json", "--verbose",
                                 "--model", "haiku", "--effort", "low"]
                        + ChatOnlyArgv.claude(options: chat, snapshotFlagListed: true), cwd: scratch, timeout: 300)
        func contextTokens(_ out: String) -> Int? {
            var last: Int? = nil
            for line in out.split(separator: "\n") where line.contains("\"type\":\"assistant\"") {
                guard let start = line.firstIndex(of: "{") else { continue }
                let o = object(String(line[start...]))
                let usage = ((o["message"] as? [String: Any])?["usage"] as? [String: Any]) ?? [:]
                let n = ((usage["input_tokens"] as? Int) ?? 0) + ((usage["cache_creation_input_tokens"] as? Int) ?? 0)
                    + ((usage["cache_read_input_tokens"] as? Int) ?? 0)
                if n > 0 { last = n }
            }
            return last
        }
        let chatTokens = contextTokens(first.out)
        check("claude live: the Chat only turn ran (exit 0)", first.status == 0, String(first.out.prefix(200)))
        check("claude live: context ≤ 3,000 tokens (measured 897 with the persona)", (chatTokens ?? 99_999) <= 3_000, "\(chatTokens ?? -1)")
        if let sid = sessionId(first.out) {
            let second = run(claude, ["-p", "And again, one word.", "--output-format", "stream-json", "--verbose",
                                      "--model", "haiku", "--effort", "low", "--resume", sid]
                             + ChatOnlyArgv.claude(options: plain, snapshotFlagListed: true), cwd: scratch, timeout: 300)
            let defaultTokens = contextTokens(second.out)
            check("claude live: the Default turn on the same session ran with the full prompt (> 5,000 tokens)",
                  second.status == 0 && (defaultTokens ?? 0) > 5_000, "\(defaultTokens ?? -1)")
        }
        // The web lookup: a web tool is CALLED and its result is not an
        // error (a refusal for want of an approver would be one).
        let web = run(claude, ["-p", liveWebQuestion, "--output-format", "stream-json", "--verbose",
                               "--model", "haiku", "--effort", "low"]
                      + ChatOnlyArgv.claude(options: chat, snapshotFlagListed: true), cwd: scratch, timeout: 300)
        var webCalls: [String] = []
        var webErrors: [String] = []
        for line in web.out.split(separator: "\n") {
            guard let start = line.firstIndex(of: "{") else { continue }
            let o = object(String(line[start...]))
            let content = ((o["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for block in content {
                if block["type"] as? String == "tool_use", let name = block["name"] as? String { webCalls.append(name) }
                if block["type"] as? String == "tool_result", block["is_error"] as? Bool == true {
                    let c = block["content"]
                    webErrors.append((c as? String) ?? String(describing: c))
                }
            }
        }
        check("claude live: a current question runs a web lookup in Chat only, and it is not refused",
              web.status == 0 && webCalls.contains { ["WebSearch", "WebFetch"].contains($0) } && webErrors.isEmpty,
              "calls \(webCalls) errors \(webErrors.map { String($0.prefix(100)) })")
        note("claude live web answer: " + String((web.out.split(separator: "\n").last { $0.contains("\"type\":\"result\"") }
            .map { (object(String($0))["result"] as? String) ?? "" } ?? "?").prefix(300)))
    }
    if let codex = binary("codex") {
        let first = run(codex, ["exec", "--json", "--skip-git-repo-check", "-c", "model_reasoning_effort=\"low\""]
                        + ChatOnlyArgv.codex(options: chat, bornPlain: false, personaFile: SipaiPaths.chatOnlyInstructionsFile.path)
                        + ["Reply with the single word OK."], cwd: scratch, timeout: 300)
        check("codex live: the Chat only turn ran (exit 0)", first.status == 0, String(first.out.prefix(200)))
        note("codex live usage: " + (first.out.split(separator: "\n").last { $0.contains("turn.completed") }.map(String.init) ?? "?"))
        if let tid = threadId(first.out) {
            try? ChatOnlyPersona.ensureFile(at: SipaiPaths.chatOnlyInstructionsFile)
            let second = run(codex, ["exec", "resume", "--json", "--skip-git-repo-check", "-c", "model_reasoning_effort=\"low\"", tid, "And again, one word."],
                             cwd: scratch, timeout: 300)
            check("codex live: the Default turn on the same thread ran (exit 0)", second.status == 0, String(second.out.prefix(200)))
            note("codex live default usage: " + (second.out.split(separator: "\n").last { $0.contains("turn.completed") }.map(String.init) ?? "?"))
        }
        let web = run(codex, ["exec", "--json", "--skip-git-repo-check", "-c", "model_reasoning_effort=\"low\""]
                      + ChatOnlyArgv.codex(options: chat, bornPlain: false, personaFile: SipaiPaths.chatOnlyInstructionsFile.path)
                      + [liveWebQuestion], cwd: scratch, timeout: 300)
        let searched = web.out.split(separator: "\n").contains { $0.contains("\"item.completed\"") && $0.contains("\"type\":\"web_search\"") }
        check("codex live: a current question runs a web search in Chat only", web.status == 0 && searched,
              String(web.out.prefix(200)))
        note("codex live web answer: " + String((web.out.split(separator: "\n").last { $0.contains("\"agent_message\"") }
            .map { ((object(String($0))["item"] as? [String: Any])?["text"] as? String) ?? "" } ?? "?").prefix(300)))
    }
    if let kimi = binary("kimi") {
        note("kimi live: the first turn goes through the server in the app; here the policy file is exercised on a resumed session")
        let first = run(kimi, ["--prompt", "Reply with the single word OK.", "--output-format", "stream-json"], cwd: scratch, timeout: 300)
        check("kimi live: an agent turn ran (exit 0)", first.status == 0, String(first.out.prefix(200)))
        if let sid = kimiSessionId(first.out), let dir = KimiSessionScanner.sessionDirectory(forId: sid) {
            let file = KimiToolPolicy.disabledFile(sessionDir: dir)
            let names = KimiToolPolicy.namesToDisable(
                sessionSnapshot: KimiToolPolicy.names(fromWire: dir.appendingPathComponent("agents/main/wire.jsonl")),
                storeSnapshot: nil)
            try? KimiToolPolicy.write(names: names, to: file)
            let second = run(kimi, ["--prompt", "And again, one word.", "--output-format", "stream-json", "--session", sid], cwd: scratch, timeout: 300)
            // The web lookup, under the same policy file: a page fetch
            // (a kimi with a search provider may search first).
            let web = run(kimi, ["--prompt", "Open https://www.python.org/downloads/ and tell me the newest Python version listed there.",
                                 "--output-format", "stream-json", "--session", sid], cwd: scratch, timeout: 300)
            try? KimiToolPolicy.restore(.absent, at: file)
            check("kimi live: the Chat only (policy file) turn ran (exit 0)", second.status == 0, String(second.out.prefix(200)))
            let fetched = web.out.contains("\"FetchURL\"") || web.out.contains("\"WebSearch\"")
            let failed = web.out.contains("Failed to fetch") || web.out.contains("Refusing to fetch")
            check("kimi live: a web lookup runs in Chat only, and the fetch succeeds", web.status == 0 && fetched && !failed,
                  String(web.out.prefix(300)))
            note("kimi live: probe session \(sid) is rooted in a temp folder (scratch to SipAI); delete it by hand if wanted")
        }
    }
}

// ====================================================================
print("9b. LIVE THOUGHTS — one real Chat only web lookup per agent (SIPAI_CHATONLY_LIVE_THOUGHTS=1)")

/// The rows the transcript would group, from a turn's parsed events.
func activityRows(_ events: [StreamEvent]) -> [ChatOnlyActivity.Row] {
    // Each call's result, as the transcript's pairing hands it over.
    var results: [String: String] = [:]
    for event in events {
        if case .toolResult(let id, let output, _) = event.kind, results[id] == nil { results[id] = output }
    }
    return [.turnStart(chatOnly: true)] + events.map { event -> ChatOnlyActivity.Row in
        switch event.kind {
        case .thinking(let text): return .thought(text)
        case .toolUse(let id, let name, let input):
            return .toolUse(name: name, title: name, input: input, resultText: results[id])
        case .toolResult: return .toolResult
        case .assistantText, .error, .interrupted, .compaction, .userMessage: return .boundary
        case .systemInit, .result: return .invisible
        }
    }
}
/// What the line would have said, step by step, and how it settled.
func describeLine(_ rows: [ChatOnlyActivity.Row]) -> String {
    let plan = ChatOnlyActivity.plan(rows, turnRunning: false)
    return plan.groups.map { group in
        let live = group.steps.compactMap(ChatOnlyActivity.livePhrase(for:))
            .map { "“\($0.prefix(70))”" }.joined(separator: " → ")
        return "[\(live)] ⇒ \(ChatOnlyActivity.summaryText(ChatOnlyActivity.summary(of: group.steps)))"
    }.joined(separator: " | ")
}

if !liveThoughts {
    skip("real thought turns", "set SIPAI_CHATONLY_LIVE_THOUGHTS=1 (spends tokens on each installed CLI)")
} else {
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sipai-chatonly-thoughts-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)

    if liveThoughtAgents.contains("claude_code"), let claude = binary("claude_code") {
        let accepted = ChatOnlyAvailability.acceptsThinkingDisplay(
            probeOutput: run(claude, ChatOnlyAvailability.thinkingDisplayProbeArguments, timeout: 30).out)
        let web = run(claude, ["-p", liveWebQuestion, "--output-format", "stream-json", "--verbose"]
                      + ChatOnlyArgv.claude(options: chat, snapshotFlagListed: true,
                                            thinkingDisplayAccepted: accepted),
                      cwd: scratch, timeout: 600)
        let events = web.out.split(separator: "\n").flatMap {
            AgentEventParser.parse(line: String($0), fallbackCwd: scratch, includeThinking: true)
        }
        let rows = activityRows(events)
        let plan = ChatOnlyActivity.plan(rows, turnRunning: false)
        check("claude live: the Chat only lookup ran (exit 0)", web.status == 0, String(web.out.prefix(200)))
        check("claude live: --thinking-display summarized brings the thoughts back READABLE",
              !thoughts(events).isEmpty, "\(thoughts(events).count) readable thoughts")
        check("claude live: the thoughts and lookups group into a line above the answer",
              !plan.groups.isEmpty, describeLine(rows))
        note("claude live line: " + describeLine(rows))
        for t in thoughts(events).prefix(3) { note("claude live thought: " + String(t.prefix(160)).replacingOccurrences(of: "\n", with: " ")) }
        // The run's transcript sits under a temp folder (scratch to SipAI);
        // remove it so nothing of the probe is left in the store.
        if let sid = sessionId(web.out) {
            let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
                let file = dir.appendingPathComponent("\(sid).jsonl")
                if fm.fileExists(atPath: file.path) {
                    check("claude live: the transcript keeps the thoughts for a reopen",
                          !historyThoughts(AgentSessionScanner.readHistory(of: file, includeThinking: true)).isEmpty)
                    try? fm.removeItem(at: file)
                    try? fm.removeItem(at: dir.appendingPathComponent(sid))
                }
            }
        }
    } else if !liveThoughtAgents.contains("claude_code") {
        skip("claude live thoughts", "not in SIPAI_CHATONLY_LIVE_AGENTS")
    } else {
        skip("claude live thoughts", "claude is not installed")
    }

    if liveThoughtAgents.contains("codex"), let codex = binary("codex") {
        try? ChatOnlyPersona.ensureFile(at: SipaiPaths.chatOnlyInstructionsFile)
        // The summaries switch rides the shipped Chat only argv
        // (`ChatOnlyArgv.codexThinkingSummaries`), not this call.
        let web = run(codex, ["exec", "--json", "--skip-git-repo-check",
                              "-c", "model_reasoning_effort=\"medium\""]
                      + ChatOnlyArgv.codex(options: chat, bornPlain: false,
                                           personaFile: SipaiPaths.chatOnlyInstructionsFile.path)
                      + [liveWebQuestion], cwd: scratch, timeout: 600)
        let lines = web.out.split(separator: "\n").map(String.init)
        let events = lines.flatMap { CodexEventParser.parse(line: $0, fallbackCwd: scratch, includeThinking: true).events }
        let reasoningItems = lines.filter { $0.contains("\"type\":\"reasoning\"") }.count
        check("codex live: the Chat only lookup ran (exit 0)", web.status == 0, String(web.out.prefix(200)))
        check("codex live: the shipped argv brings reasoning summaries back READABLE",
              !thoughts(events).isEmpty, "\(reasoningItems) reasoning item(s), \(thoughts(events).count) readable")
        let codexRows = activityRows(events)
        let codexSteps = ChatOnlyActivity.plan(codexRows, turnRunning: false).groups.flatMap(\.steps)
        check("codex live: every lookup in the line names what it looked up (code mode's result supplies it)",
              !codexSteps.isEmpty && !codexSteps.contains(.search(query: "")) && !codexSteps.contains(.read(url: "")),
              describeLine(codexRows))
        note("codex live line: " + describeLine(activityRows(events)))
        for t in thoughts(events).prefix(3) { note("codex live thought: " + String(t.prefix(160)).replacingOccurrences(of: "\n", with: " ")) }
    } else if !liveThoughtAgents.contains("codex") {
        skip("codex live thoughts", "not in SIPAI_CHATONLY_LIVE_AGENTS")
    } else {
        skip("codex live thoughts", "codex is not installed")
    }

    if liveThoughtAgents.contains("kimi"), let kimi = binary("kimi") {
        // A resumed session under the policy file — the app's path for
        // every kimi Chat only turn but a new session's first.
        let first = run(kimi, ["--prompt", "Reply with the single word OK.", "--output-format", "stream-json"],
                        cwd: scratch, timeout: 300)
        if let sid = kimiSessionId(first.out), let dir = KimiSessionScanner.sessionDirectory(forId: sid) {
            let file = KimiToolPolicy.disabledFile(sessionDir: dir)
            let wire = dir.appendingPathComponent("agents/main/wire.jsonl")
            let names = KimiToolPolicy.namesToDisable(
                sessionSnapshot: KimiToolPolicy.names(fromWire: wire), storeSnapshot: nil)
            try? KimiToolPolicy.write(names: names, to: file)
            let web = run(kimi, ["--prompt", "Open https://www.python.org/downloads/ and tell me the newest Python version listed there.",
                                 "--output-format", "stream-json", "--session", sid], cwd: scratch, timeout: 600)
            try? KimiToolPolicy.restore(.absent, at: file)
            let stdoutEvents = web.out.split(separator: "\n").flatMap {
                KimiEventParser.parse(line: String($0), fallbackCwd: scratch)
            }
            let turn = KimiSessionScanner.readHistory(of: wire, maxTurns: 1, includeThinking: true)
            let wireThoughts = historyThoughts(turn)
            let rows: [KimiSessionScanner.LiveRow] = stdoutEvents.map { event in
                switch event.kind {
                case .toolUse(let id, _, _): return .toolUse(id: id)
                case .toolResult: return .toolResult
                case .assistantText(let text): return .text(text)
                default: return .other
                }
            }
            let placements = KimiSessionScanner.thoughtPlacements(wireItems: turn, turnRows: rows,
                                                                  alreadyPlaced: 0, final: true)
            check("kimi live: the Chat only lookup ran (exit 0)", web.status == 0, String(web.out.prefix(200)))
            check("kimi live: stdout carried no thought, the wire did",
                  thoughts(stdoutEvents).isEmpty && !wireThoughts.isEmpty, "\(wireThoughts.count) on the wire")
            check("kimi live: every wire thought finds its place among the stdout rows",
                  placements.count == wireThoughts.count, "\(placements.count) of \(wireThoughts.count)")
            // The live turn as the runner leaves it: stdout's events with
            // the thoughts inserted where the placements say.
            var placed = stdoutEvents
            for p in placements { placed.insert(StreamEvent(kind: .thinking(text: p.text)), at: p.at) }
            let lineRows = activityRows(placed)
            check("kimi live: the thoughts and lookups group into a line above the answer",
                  !ChatOnlyActivity.plan(lineRows, turnRunning: false).groups.isEmpty, describeLine(lineRows))
            note("kimi live line: " + describeLine(lineRows))
            for t in wireThoughts.prefix(2) { note("kimi live thought: " + String(t.prefix(160)).replacingOccurrences(of: "\n", with: " ")) }
            note("kimi live: probe session \(sid) is rooted in a temp folder (scratch to SipAI)")
        } else {
            check("kimi live: a session to run the Chat only turn in", false, String(first.out.prefix(200)))
        }
    } else if !liveThoughtAgents.contains("kimi") {
        skip("kimi live thoughts", "not in SIPAI_CHATONLY_LIVE_AGENTS")
    } else {
        skip("kimi live thoughts", "kimi is not installed")
    }
}

// ====================================================================
print("")
print("\(checks) checks, \(failures) failures")
if failures > 0 {
    print("Files to look at: SipAI/Models/AgentLaunchOptions.swift (ChatOnlyArgv / ChatOnlyAvailability),")
    print("  Models/KimiToolPolicy.swift, Models/KimiWebTurn.swift, Models/AttachmentInline.swift,")
    print("  Models/AgentRunner.swift, Views/Chat/AgentComposer.swift, Views/Chat/AgentSessionView.swift")
}
exit(failures == 0 ? 0 : 1)
