import Foundation

// Usage: refusals <source-root> <harness-dir>
let root = CommandLine.arguments[1]
let harnessDir = CommandLine.arguments[2]
var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("  ok   \(name)") } else {
        failed += 1
        let d = detail()
        print("  FAIL \(name)" + (d.isEmpty ? "" : " — \(d)"))
    }
}
func source(_ path: String) -> String {
    (try? String(contentsOfFile: root + "/" + path, encoding: .utf8)) ?? ""
}
func json(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) // harness fixture: a literal dictionary always serialises
}

// Records in the shapes kimi 2.5 writes (measured: a 403 from the provider
// becomes `turn.ended reason: failed` with `error.code provider.auth_error`,
// `error.name APIStatusError`, `error.details.statusCode` 403 and the
// provider's sentence verbatim; each `llm.request` names `model` and
// `modelAlias`). Synthetic content.
func prompt(_ time: Double) -> String {
    json(["type": "turn.prompt", "agentId": "main", "promptId": "p-\(Int(time))", "turnId": 0,
          "input": [["type": "text", "text": "hello"]], "origin": ["kind": "user"], "time": time])
}
func request(model: String, alias: String, agent: String = "main") -> String {
    json(["type": "llm.request", "agentId": agent, "kind": "loop", "provider": "openai",
          "model": model, "modelAlias": alias, "time": 0])
}
func ended(_ reason: String, error: [String: Any]? = nil) -> String {
    var obj: [String: Any] = ["type": "turn.ended", "agentId": "main", "turnId": 0, "reason": reason,
                              "durationMs": 45, "time": 0]
    if let error { obj["error"] = error }
    return json(obj)
}
func refusal(_ message: String, code: String = "provider.auth_error", status: Int = 403) -> [String: Any] {
    ["code": code, "message": message, "name": "APIStatusError",
     "details": ["statusCode": status, "requestId": NSNull(), "traceId": NSNull()], "retryable": false]
}
let noK3 = "Your current subscription does not have access to k3."

// MARK: 1. Moonshot's sentence

print("1. Moonshot's sentence — the model a plan lacks")
check("names the model Moonshot refused",
      KimiPlanRefusal.refusedModel(in: noK3) == "k3"
      && KimiPlanRefusal.refusedModel(in: "Your current subscription does not have access to k3.1-pro-highspeed.")
          == "k3.1-pro-highspeed"
      && KimiPlanRefusal.refusedModel(in: "  " + noK3 + "\n") == "k3")
check("…and nothing for any other words: a context cap, a lost connection, an empty error",
      KimiPlanRefusal.refusedModel(in: "Your current plan supports only k3 up to 256K context.") == nil
      && KimiPlanRefusal.refusedModel(in: "Connection error.") == nil
      && KimiPlanRefusal.refusedModel(in: "") == nil
      && KimiPlanRefusal.refusedModel(in: "Your current subscription does not have access to .") == nil)

// MARK: 2. The record's verdict

print("2. The record — what the newest turn says about its models")
let refusedTurn = [prompt(1000), request(model: "k3", alias: "kimi-code/k3"),
                   ended("failed", error: refusal(noK3))].joined(separator: "\n")
check("a turn Moonshot refused for the plan marks the alias that asked for the model",
      KimiPlanRefusal.verdict(wireTail: refusedTurn, since: nil)
          == KimiPlanRefusal.Verdict(refused: ["kimi-code/k3"], answered: []))
check("…only for Moonshot's own refusal: a lost connection marks nothing",
      KimiPlanRefusal.verdict(wireTail: [prompt(1000), request(model: "k3", alias: "kimi-code/k3"),
                                         ended("failed", error: refusal("Connection error.",
                                                                        code: "provider.connection_error",
                                                                        status: 0))].joined(separator: "\n"),
                              since: nil) == KimiPlanRefusal.Verdict())
check("…nor the context cap (the plan has the model, up to 256K)",
      KimiPlanRefusal.verdict(wireTail: [prompt(1000), request(model: "k3", alias: "kimi-code/k3"),
                                         ended("failed", error: refusal("Your current plan supports only k3 up to 256K context."))]
                                .joined(separator: "\n"),
                              since: nil) == KimiPlanRefusal.Verdict())
check("…nor the same sentence with another status",
      KimiPlanRefusal.verdict(wireTail: [prompt(1000), request(model: "k3", alias: "kimi-code/k3"),
                                         ended("failed", error: refusal(noK3, status: 401))].joined(separator: "\n"),
                              since: nil) == KimiPlanRefusal.Verdict())
check("…nor an alias whose model is not the one refused",
      KimiPlanRefusal.verdict(wireTail: [prompt(1000), request(model: "kimi-for-coding", alias: "kimi-code/kimi-for-coding"),
                                         ended("failed", error: refusal(noK3))].joined(separator: "\n"),
                              since: nil) == KimiPlanRefusal.Verdict())
check("a turn that completed clears what its alias answered",
      KimiPlanRefusal.verdict(wireTail: [prompt(1000), request(model: "k3", alias: "kimi-code/k3"),
                                         ended("completed")].joined(separator: "\n"),
                              since: nil) == KimiPlanRefusal.Verdict(refused: [], answered: ["kimi-code/k3"]))
check("a subagent's request is not the turn's model",
      KimiPlanRefusal.verdict(wireTail: [prompt(1000), request(model: "k3", alias: "kimi-code/k3", agent: "agent-1"),
                                         ended("completed")].joined(separator: "\n"),
                              since: nil) == KimiPlanRefusal.Verdict())
let twoTurns = [refusedTurn, prompt(5000), request(model: "kimi-for-coding", alias: "kimi-code/kimi-for-coding"),
                ended("completed")].joined(separator: "\n")
check("the NEWEST ended turn speaks, never an earlier one",
      KimiPlanRefusal.verdict(wireTail: twoTurns, since: nil)
          == KimiPlanRefusal.Verdict(refused: [], answered: ["kimi-code/kimi-for-coding"]))
check("…and only a turn that began at or after the runner's own turn",
      KimiPlanRefusal.verdict(wireTail: twoTurns, since: Date(timeIntervalSince1970: 4)) != nil
      && KimiPlanRefusal.verdict(wireTail: twoTurns, since: Date(timeIntervalSince1970: 6)) == nil)
check("a turn still open, or one stopped, says nothing",
      KimiPlanRefusal.verdict(wireTail: [prompt(1000), request(model: "k3", alias: "kimi-code/k3")].joined(separator: "\n"),
                              since: nil) == nil
      && KimiPlanRefusal.verdict(wireTail: [prompt(1000), request(model: "k3", alias: "kimi-code/k3"),
                                            ended("cancelled")].joined(separator: "\n"), since: nil) == nil)
check("a line cut by the tail's start, or not JSON, is passed over",
      KimiPlanRefusal.verdict(wireTail: "ype\":\"turn.ended\",\"x\nnot json\n" + refusedTurn, since: nil)
          == KimiPlanRefusal.Verdict(refused: ["kimi-code/k3"], answered: []))

// MARK: 3. The real kimi's record

print("3. The installed kimi — its own record of Moonshot's refusal and of an answer (token-free)")
func kimiBinary() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    dirs += ["\(home)/.kimi-code/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
    return dirs.map { ($0 as NSString).appendingPathComponent("kimi") }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}
/// Starts a stand-in that prints `PORT=<n>`; returns it and the port.
func standIn(_ script: String, _ args: [String]) -> (Process, Int)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", "-I", script] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    var line = Data()
    while true {
        let byte = pipe.fileHandleForReading.readData(ofLength: 1)
        if byte.isEmpty || byte == Data([0x0A]) { break }
        line.append(byte)
    }
    let text = String(decoding: line, as: UTF8.self)
    guard text.hasPrefix("PORT="), let port = Int(text.dropFirst(5)) else { p.terminate(); return nil }
    return (p, port)
}
/// One `kimi --prompt` turn under a throwaway home whose only provider is
/// a key provider at `baseURL` running `k3`; the record kimi wrote.
func kimiTurn(_ kimi: String, baseURL: String, tmp: URL) -> String? {
    let home = tmp.appendingPathComponent("home"), work = tmp.appendingPathComponent("work")
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let config = """
        default_model = "kimi-code-plan-cn/k3"

        [providers.kimi-code-plan-cn]
        base_url = "\(baseURL)"
        type = "openai"
        api_key = "harness-key"

        [models."kimi-code-plan-cn/k3"]
        provider = "kimi-code-plan-cn"
        model = "k3"
        max_context_size = 262144

        """
    try? config.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: kimi)
    p.arguments = ["--prompt", "Reply with one word.", "--output-format", "stream-json"]
    p.currentDirectoryURL = work
    var env = ProcessInfo.processInfo.environment
    env["KIMI_CODE_HOME"] = home.path
    env["KIMI_DISABLE_TELEMETRY"] = "1"
    env["KIMI_CODE_NO_AUTO_UPDATE"] = "1"
    env["KIMI_CLI_NO_AUTO_UPDATE"] = "1"
    for key in env.keys where key.hasPrefix("DYLD_") { env[key] = nil }
    p.environment = env
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let deadline = Date().addingTimeInterval(90)
    while p.isRunning && Date() < deadline { usleep(100_000) }
    if p.isRunning { p.terminate() }
    let sessions = home.appendingPathComponent("sessions")
    guard let walker = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil) else { return nil }
    for case let url as URL in walker where url.path.hasSuffix("agents/main/wire.jsonl") {
        return try? String(contentsOf: url, encoding: .utf8)
    }
    return nil
}

if let kimi = kimiBinary() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kimi-plan-refusals-\(getpid())")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let began = Date()
    if let (server, port) = standIn(harnessDir + "/refusal.py", [tmp.appendingPathComponent("refusal.jsonl").path]) {
        let wire = kimiTurn(kimi, baseURL: "http://127.0.0.1:\(port)/coding/v1", tmp: tmp.appendingPathComponent("refused"))
        server.terminate()
        let verdict = wire.flatMap { KimiPlanRefusal.verdict(wireTail: $0, since: began) }
        check("kimi's own record of Moonshot's 403 marks the alias the turn ran under",
              verdict == KimiPlanRefusal.Verdict(refused: ["kimi-code-plan-cn/k3"], answered: []),
              "\(String(describing: verdict))\n" + (wire.map { String($0.suffix(600)) } ?? "no record"))
    } else {
        check("the refusal stand-in starts", false)
    }
    let fakeServer = harnessDir + "/../ChatOnlyMode/fake_server.py"
    let records = tmp.appendingPathComponent("fake-records")
    try? FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
    if let (server, port) = standIn(fakeServer, [records.path]) {
        let wire = kimiTurn(kimi, baseURL: "http://127.0.0.1:\(port)/v1", tmp: tmp.appendingPathComponent("answered"))
        server.terminate()
        let verdict = wire.flatMap { KimiPlanRefusal.verdict(wireTail: $0, since: began) }
        check("…and its record of a turn the model answered clears the alias",
              verdict == KimiPlanRefusal.Verdict(refused: [], answered: ["kimi-code-plan-cn/k3"]),
              "\(String(describing: verdict))\n" + (wire.map { String($0.suffix(600)) } ?? "no record"))
    } else {
        check("ChatOnlyMode's fake_server.py starts", false)
    }
} else {
    print("  skip: kimi is not installed")
}

// MARK: 4. The marks, per account

print("4. The marks — kept for the account they were learned on")
// A suite named by an ABSOLUTE path keeps its plist in that folder. Named by a
// bare word it is a file in the user's own ~/Library/Preferences, which the
// preferences daemon writes back, emptied, after this program has removed it:
// one stray file a run.
let prefsDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("sipai-kimi-plan-refusals-prefs-\(getpid())", isDirectory: true)
try? FileManager.default.createDirectory(at: prefsDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: prefsDir) }
let suiteName = prefsDir.appendingPathComponent("marks").path
let defaults = UserDefaults(suiteName: suiteName)! // harness: a fresh suite name always opens
defaults.removePersistentDomain(forName: suiteName)
KimiPlanRefusals.apply(KimiPlanRefusal.Verdict(refused: ["kimi-code/k3"], answered: []),
                       account: "plan", defaults: defaults)
check("a refusal marks the model for the account it happened on",
      KimiPlanRefusals.refused(account: "plan", defaults: defaults) == ["kimi-code/k3"])
// The marks reach the disk a moment after they are set.
defaults.synchronize()
let marksFile = suiteName + ".plist"
let written = Date().addingTimeInterval(5)
while !FileManager.default.fileExists(atPath: marksFile), Date() < written { usleep(50_000) }
let userPreferences = (try? FileManager.default.contentsOfDirectory(
    atPath: NSHomeDirectory() + "/Library/Preferences")) ?? []
let strays = userPreferences.filter { $0.contains("kimi-plan-refusals") && $0.contains("\(getpid())") }
check("the harness's marks are a file in its own temp folder, never one in ~/Library/Preferences",
      suiteName.hasPrefix(NSTemporaryDirectory()) && FileManager.default.fileExists(atPath: marksFile)
        && strays.isEmpty,
      "suite \(suiteName), written: \(FileManager.default.fileExists(atPath: marksFile)), strays: \(strays)")
check("…and for no other kind of sign-in, nor for one SipAI cannot read",
      KimiPlanRefusals.refused(account: "apiKey", defaults: defaults).isEmpty
      && KimiPlanRefusals.refused(account: nil, defaults: defaults).isEmpty)
KimiPlanRefusals.apply(KimiPlanRefusal.Verdict(refused: ["kimi-code/k3.1-pro"], answered: []),
                       account: "plan", defaults: defaults)
check("a second refusal adds to the first", KimiPlanRefusals.refused(account: "plan", defaults: defaults)
      == ["kimi-code/k3", "kimi-code/k3.1-pro"])
KimiPlanRefusals.apply(KimiPlanRefusal.Verdict(refused: [], answered: ["kimi-code/k3"]),
                       account: "plan", defaults: defaults)
check("the model answering a turn takes its mark away, and only its",
      KimiPlanRefusals.refused(account: "plan", defaults: defaults) == ["kimi-code/k3.1-pro"])
KimiPlanRefusals.apply(KimiPlanRefusal.Verdict(), account: "apiKey", defaults: defaults)
check("a turn on another kind of sign-in drops the other account's marks",
      KimiPlanRefusals.refused(account: "plan", defaults: defaults).isEmpty
      && defaults.object(forKey: KimiPlanRefusals.defaultsKey) == nil)
KimiPlanRefusals.apply(KimiPlanRefusal.Verdict(refused: ["kimi-code/k3"], answered: []), account: nil, defaults: defaults)
check("a verdict for an account SipAI cannot read is not kept",
      defaults.object(forKey: KimiPlanRefusals.defaultsKey) == nil)

// MARK: 4b. The menu's words

print("4b. The menu's words — a refused model's row, and Default when it is the default")
check("a refused model's row says the plan doesn't include it; any other row says nothing",
      KimiPlanRefusals.rowNote(forAlias: "kimi-code/k3", refused: ["kimi-code/k3"]) == "Your plan doesn't include this model"
      && KimiPlanRefusals.rowNote(forAlias: "kimi-code/kimi-for-coding", refused: ["kimi-code/k3"]) == nil)
check("Default keeps naming its model, and says so too when that model was refused",
      KimiPlanRefusals.defaultSubtitle(name: "Kimi K3", alias: "kimi-code/k3", refused: ["kimi-code/k3"])
          == "Kimi K3 — your plan doesn't include it"
      && KimiPlanRefusals.defaultSubtitle(name: "Kimi K3", alias: "kimi-code/k3", refused: []) == "Kimi K3")

// MARK: 5. Wiring

print("5. Wiring — the runner, the menu, Factory reset, the project")
let runner = source("SipAI/Models/AgentRunner.swift")
let runnerHook = source("SipAI/Models/AgentRunner+KimiPlanRefusals.swift")
let composer = source("SipAI/Views/Chat/AgentComposer.swift")
let reset = source("SipAI/Models/FactoryReset.swift")
let project = source("SipAI.xcodeproj/project.pbxproj")
check("a kimi turn's end reads its own record, from the moment the turn began",
      runner.contains("noteKimiPlanRefusals(turnBegan: turnBegan)")
      && runner.contains("let turnBegan: Date? = {")
      && runnerHook.contains("KimiPlanRefusal.verdict(wireTail: tail, since: turnBegan)")
      && runnerHook.contains("guard agentKey == \"kimi\""))
check("the model menu — the composer's chip and the task card share it — marks the refused rows",
      composer.contains("let refused = KimiPlanRefusals.refused(account: UsageMonitor.shared.accounts[\"kimi\"]?.kimiRefusalAccount)")
      && composer.contains("subtitle: KimiPlanRefusals.rowNote(forAlias: $0.slug, refused: refused))")
      && composer.contains("KimiPlanRefusals.defaultSubtitle(name: kimiCaps.displayName(forModel: alias),"))
check("Factory reset forgets the marks", reset.contains("        KimiPlanRefusals.defaultsKey,"))
check("both new files are in the app target",
      project.contains("/* KimiPlanRefusals.swift in Sources */")
      && project.contains("/* AgentRunner+KimiPlanRefusals.swift in Sources */"))

// MARK: 6. Strings

print("6. Strings — every new sentence has a 中文 value")
let catalogData = FileManager.default.contents(atPath: root + "/SipAI/Resources/Localizable.xcstrings") ?? Data()
let catalog = ((try? JSONSerialization.jsonObject(with: catalogData)) as? [String: Any])?["strings"] as? [String: Any] ?? [:]
func zh(_ key: String) -> String? {
    ((catalog[key] as? [String: Any])?["localizations"] as? [String: Any]).flatMap { $0["zh-Hans"] as? [String: Any] }
        .flatMap { $0["stringUnit"] as? [String: Any] }.flatMap { $0["value"] as? String }
}
for key in ["Your plan doesn't include this model", "%@ — your plan doesn't include it"] {
    check("\"\(key)\" is translated", zh(key).map { !$0.isEmpty } ?? false)
}

print("")
print("\(passed)/\(passed + failed) checks passed")
if failed > 0 { print("\(failed) check(s) FAILED."); exit(1) }
