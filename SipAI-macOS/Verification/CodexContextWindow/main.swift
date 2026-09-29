// Headless check of the codex context-window feature. See run.sh for
// scope and for what regresses silently.
//
// Nothing here is part of the app target.
import Foundation

var failures = 0
var checks = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    if ok {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

let args = CommandLine.arguments
let sourceRoot = args.count > 1 ? args[1] : "."

func source(_ path: String) -> String {
    (try? String(contentsOfFile: sourceRoot + "/" + path, encoding: .utf8)) ?? ""
}

/// The file with its `//` comments removed, so a structural check
/// finds what the code DOES rather than what a comment says it must
/// not do.
func codeOnly(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let slashes = line.range(of: "//") else { return line }
        return line[line.startIndex..<slashes.lowerBound]
    }.joined(separator: "\n")
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("cxwin-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

// MARK: - 1. The parsers — codex's arithmetic, over fixtures

print("1. Parsers — default / maximum / effective per model, config keys")

/// The measured cache (codex-cli 0.154.0): four models with a larger
/// window, two without, two hidden. Only the fields the parser reads.
let cacheJSON = """
{"fetched_at":"2026-09-10T03:34:26.359497Z","etag":"x","client_version":"0.154.0","models":[
{"slug":"gpt-6-astra","display_name":"GPT-6-Astra","priority":1,"visibility":"list","context_window":272000,"max_context_window":872000,"effective_context_window_percent":95,"supported_reasoning_levels":[{"effort":"low"},{"effort":"ultra"}],"service_tiers":[{"id":"priority","name":"Fast","description":"2x speed"}]},
{"slug":"gpt-reserve","display_name":"GPT-Reserve","priority":3,"visibility":"hide","context_window":272000,"max_context_window":872000,"effective_context_window_percent":95},
{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","priority":6,"visibility":"list","context_window":272000,"max_context_window":872000,"effective_context_window_percent":95},
{"slug":"gpt-5.5","display_name":"GPT-5.5","priority":12,"visibility":"list","context_window":272000,"max_context_window":272000,"effective_context_window_percent":95},
{"slug":"gpt-5.3-codex-spark","display_name":"GPT-5.3-Codex-Spark","priority":26,"visibility":"list","context_window":128000,"max_context_window":128000,"effective_context_window_percent":95},
{"slug":"codex-auto-review","display_name":"Codex Auto Review","priority":43,"visibility":"hide","context_window":272000,"max_context_window":872000,"effective_context_window_percent":95}
]}
"""
let cacheData = Data(cacheJSON.utf8)

let plain = CodexCatalog.parseModelsCache(cacheData, contextWindowOverride: nil)
func model(_ slug: String, in parsed: (visible: [CodexModel], hidden: Set<String>, stamp: CodexCatalogStamp?)) -> CodexModel? {
    parsed.visible.first { $0.slug == slug }
}
check("hidden models stay hidden (gpt-reserve, codex-auto-review)",
      plain.hidden == ["gpt-reserve", "codex-auto-review"] && plain.visible.count == 4)
check("default = 272,000 × 95 % = 258,400",
      model("gpt-6-astra", in: plain)?.defaultContextWindow == 258_400)
check("effective == default with nothing configured",
      model("gpt-6-astra", in: plain)?.contextWindow == 258_400)
check("maximum = 872,000 × 95 % = 828,400",
      model("gpt-6-astra", in: plain)?.maxContextWindow == 828_400)
check("the raw ceiling (872,000) is what a write would carry",
      model("gpt-6-astra", in: plain)?.maxContextWindowSetting == 872_000)
check("raw default and percentage ride out for the prose",
      model("gpt-6-astra", in: plain)?.defaultContextWindowSetting == 272_000
      && model("gpt-6-astra", in: plain)?.usablePercent == 95)
check("a cap equal to the default is 'no larger window' (gpt-5.5)",
      model("gpt-5.5", in: plain)?.maxContextWindow == nil
      && model("gpt-5.5", in: plain)?.maxContextWindowSetting == nil
      && model("gpt-5.5", in: plain)?.defaultContextWindow == 258_400)
check("a 128k model: 121,600 default, no larger window",
      model("gpt-5.3-codex-spark", in: plain)?.defaultContextWindow == 121_600
      && model("gpt-5.3-codex-spark", in: plain)?.maxContextWindow == nil)
check("the stamp: client version and fetch date",
      plain.stamp?.clientVersion == "0.154.0"
      && plain.stamp?.fetchedAt.map { Int($0.timeIntervalSince1970) } == 1789011266,
      "got \(String(describing: plain.stamp))")

let raised = CodexCatalog.parseModelsCache(cacheData, contextWindowOverride: 872_000)
check("configured 872,000 → 828,400 effective on the four",
      model("gpt-6-astra", in: raised)?.contextWindow == 828_400
      && model("gpt-5.6-sol", in: raised)?.contextWindow == 828_400)
check("configured 872,000 → gpt-5.5 stays clamped at 258,400",
      model("gpt-5.5", in: raised)?.contextWindow == 258_400)
check("default and maximum are unchanged by the override",
      model("gpt-6-astra", in: raised)?.defaultContextWindow == 258_400
      && model("gpt-6-astra", in: raised)?.maxContextWindow == 828_400)
let over = CodexCatalog.parseModelsCache(cacheData, contextWindowOverride: 1_000_000)
check("configured 1,000,000 → clamped to the maximum, still 828,400",
      model("gpt-6-astra", in: over)?.contextWindow == 828_400)
let custom = CodexCatalog.parseModelsCache(cacheData, contextWindowOverride: 500_000)
check("configured 500,000 → 475,000 where allowed, clamped where not",
      model("gpt-6-astra", in: custom)?.contextWindow == 475_000
      && model("gpt-5.5", in: custom)?.contextWindow == 258_400
      && model("gpt-5.3-codex-spark", in: custom)?.contextWindow == 121_600)

// An entry stating only a maximum runs at that maximum (codex:
// `context_window.or(max_context_window)`): a default, no larger window.
let capOnly = CodexCatalog.parseModelsCache(Data("""
{"models":[{"slug":"x","display_name":"X","priority":1,"visibility":"list","max_context_window":400000,"effective_context_window_percent":95}]}
""".utf8), contextWindowOverride: nil)
check("an entry with only max_context_window defaults to it, with no larger window",
      model("x", in: capOnly)?.defaultContextWindow == 380_000
      && model("x", in: capOnly)?.contextWindow == 380_000
      && model("x", in: capOnly)?.maxContextWindow == nil)

check("fetched_at with a six-digit fraction parses",
      CodexCatalog.parseFetchedAt("2026-09-10T03:34:26.359497Z") != nil)
check("fetched_at without a fraction parses",
      CodexCatalog.parseFetchedAt("2026-09-10T03:34:26Z") != nil)
check("fetched_at garbage is nil, not a crash",
      CodexCatalog.parseFetchedAt("yesterday") == nil)

let cfgDefault = CodexCatalog.parseConfigDefaults("""
model = "gpt-6-astra"
model_reasoning_effort = "xhigh"

[projects."/x"]
trust_level = "trusted"
""")
check("config with no window: nil, model read",
      cfgDefault.contextWindow == nil && cfgDefault.model == "gpt-6-astra"
      && cfgDefault.autoCompactLimit == nil)
let cfgSet = CodexCatalog.parseConfigDefaults("""
model = "gpt-6-astra"
model_context_window = 872000
model_auto_compact_token_limit = 700_000
[tui]
x = 1
""")
check("config window read as an integer",
      cfgSet.contextWindow == 872_000)
check("an auto-compact limit is read too (with TOML underscores)",
      cfgSet.autoCompactLimit == 700_000)
let cfgNested = CodexCatalog.parseConfigDefaults("""
model = "gpt-6-astra"
[profiles.big]
model_context_window = 872000
""")
check("a window under a [section] is NOT the global one",
      cfgNested.contextWindow == nil)

// MARK: - 2. The write — codex's own writer, over a throwaway home

print("")
print("2. config/value/write — the real client against the real codex")

/// codex on PATH, the ordinary way; the app's own search paths are
/// not in play here.
func findCodex() -> String? {
    let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":").map(String.init)
        + ["/opt/homebrew/bin", "/usr/local/bin"]
    for dir in dirs {
        let candidate = dir + "/codex"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

// The request itself, with no process: a number, and a JSON null.
check("request: an integer value is a JSON number",
      CodexConfigWrite.request(keyPath: "model_context_window", value: 872_000)?
        .contains(#""value":872000"#) == true)
check("request: nil is a JSON null (codex reads null as 'remove the key')",
      CodexConfigWrite.request(keyPath: "model_context_window", value: nil)?
        .contains(#""value":null"#) == true)
check("request: replace, on config/value/write, under the awaited id",
      CodexConfigWrite.request(keyPath: "model_context_window", value: 1).map {
          $0.contains(#""mergeStrategy":"replace""#)
          && $0.contains(#""method":"config\/value\/write""#) || $0.contains(#""method":"config/value/write""#)
          && $0.contains(#""id":2"#)
      } == true)

// The outcome reader, over the answers codex was measured to give.
let okAnswer: [String: Any] = ["id": 2, "result": ["status": "ok", "version": "sha256:abc",
                                                    "filePath": "/x/config.toml",
                                                    "overriddenMetadata": NSNull()]]
check("outcome: ok → written with version and path",
      CodexConfigWrite.outcome(from: okAnswer)
        == .written(version: "sha256:abc", filePath: "/x/config.toml", overriddenBy: nil))
let overriddenAnswer: [String: Any] = ["id": 2, "result": ["status": "okOverridden",
                                                            "version": "v", "filePath": "/x",
                                                            "overriddenMetadata": ["message": "managed layer wins"]]]
check("outcome: okOverridden carries codex's message",
      CodexConfigWrite.outcome(from: overriddenAnswer)
        == .written(version: "v", filePath: "/x", overriddenBy: "managed layer wins"))
let refusedAnswer: [String: Any] = ["id": 2, "error": ["code": -32600,
                                                        "message": "Invalid configuration: expected i64",
                                                        "data": ["config_write_error_code": "configValidationError"]]]
check("outcome: an error → refused with codex's code and message",
      CodexConfigWrite.outcome(from: refusedAnswer)
        == .refused(code: "configValidationError", message: "Invalid configuration: expected i64"))
check("outcome: no answer → unavailable",
      CodexConfigWrite.outcome(from: nil) == .unavailable)

if let codex = findCodex() {
    let home = tmp.appendingPathComponent("codex-home", isDirectory: true)
    try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let configURL = home.appendingPathComponent("config.toml")
    let original = """
    model = "gpt-6-astra"
    model_reasoning_effort = "xhigh"

    [projects."/tmp/x"]
    trust_level = "trusted"

    """
    try! original.write(to: configURL, atomically: true, encoding: .utf8)
    AgentRunner.extraEnvironment["CODEX_HOME"] = home.path

    let began = Date()
    let wrote = await CodexConfigWrite.run(binary: codex, keyPath: "model_context_window",
                                           value: 872_000)
    let elapsed = Date().timeIntervalSince(began)
    var written = false
    if case .written(let version, let path, let overridden) = wrote {
        written = version?.hasPrefix("sha256:") == true
            && (path ?? "").hasSuffix("config.toml") && overridden == nil
    }
    check("codex wrote model_context_window = 872000", written,
          "got \(wrote) in \(String(format: "%.1f", elapsed)) s")
    let after = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    let addedLine = after.contains("model_context_window = 872000")
    let aboveSection = (after.range(of: "model_context_window = 872000")?.lowerBound ?? after.endIndex)
        < (after.range(of: "[projects.")?.lowerBound ?? after.startIndex)
    check("the line landed in the top-level block, above the first [section]",
          addedLine && aboveSection, "file now:\n\(after)")
    let restIntact = after.replacingOccurrences(of: "model_context_window = 872000\n", with: "") == original
    check("every other byte of the file is untouched", restIntact)

    let cleared = await CodexConfigWrite.run(binary: codex, keyPath: "model_context_window",
                                             value: nil)
    var clearedOK = false
    if case .written = cleared { clearedOK = true }
    check("a null value is accepted", clearedOK, "got \(cleared)")
    let restored = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    check("…and REMOVES the key: the file is byte-identical to the original",
          restored == original, "file now:\n\(restored)")

    // Codex validates against its own schema; the app never has to.
    // (`run` takes an Int?, so the wrong type is sent through the
    // client directly.)
    let badRequest = #"{"jsonrpc":"2.0","id":2,"method":"config/value/write","params":{"keyPath":"model_context_window","value":"abc","mergeStrategy":"replace"}}"#
    let bad = CodexConfigWrite.outcome(from: await CodexAppServerCall.run(binary: codex, request: badRequest))
    var refusedByCodex = false
    if case .refused(let code, let message) = bad {
        refusedByCodex = code == "configValidationError" && message.contains("i64")
    }
    check("a non-integer is refused by codex (configValidationError, expects i64)",
          refusedByCodex, "got \(bad)")
    check("…and the file is still the original", (try? String(contentsOf: configURL, encoding: .utf8)) == original)

    AgentRunner.extraEnvironment["CODEX_HOME"] = nil
} else {
    print("  skip codex app-server — no codex on PATH")
}

// A binary that is not codex: no answer, promptly, nothing left running.
let began = Date()
let notCodex = await CodexConfigWrite.run(binary: "/bin/cat", keyPath: "model_context_window",
                                          value: nil)
check("a non-codex binary answers unavailable, promptly",
      notCodex == .unavailable && Date().timeIntervalSince(began) < CodexAppServerCall.ceiling,
      "got \(notCodex) in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")

// MARK: - 3. The wiring — read from the shipping views

print("")
print("3. Wiring — what a headless run cannot reach")

let composer = codeOnly(source("SipAI/Views/Chat/AgentComposer.swift"))
let sessionView = codeOnly(source("SipAI/Views/Chat/AgentSessionView.swift"))
let content = codeOnly(source("SipAI/Views/ContentView.swift"))
let settings = codeOnly(source("SipAI/Views/Settings/SettingsView.swift"))
let launch = codeOnly(source("SipAI/Models/AgentLaunchOptions.swift"))

check("the chip's hint carries the glyph accessory",
      composer.contains("hintAccessory: contextWindowHelpGlyph"))
check("the glyph is codex-only and needs a known window",
      composer.contains("guard isCodex, let window = contextWindowTokens, window > 0 else { return nil }"))
check("the glyph opens the Help topic",
      composer.contains("HelpTopic.codexContextWindow.open()"))
check("the bubble is hit-testable only with an accessory",
      composer.contains(".allowsHitTesting(hintAccessory != nil)"))
check("the bubble is held while the cursor is over it",
      composer.contains("bubbleHovered = inside") && composer.contains("if hovered || bubbleHovered {"))
check("the glyph folds the bubble BEFORE opening the sheet (no hover-exit arrives under one)",
      composer.contains("collapse()\n                HelpTopic.codexContextWindow.open()")
      && composer.contains("hintAccessory(collapseHint)"))
check("a write during an in-flight harvest is re-read when that harvest lands",
      launch.contains("if loading {\n            pendingReload = true")
      && launch.contains("if self.pendingReload {"))
check("the snippet shows a number the catalog or the user stated, never an invented one",
      settings.contains("catalog.maxContextWindowSetting ?? catalog.configuredContextWindow\n")
      && !settings.contains("?? 872_000"))
check("the session view observes the catalog (else the chip never moves after a write)",
      sessionView.contains("@ObservedObject private var codexCatalog = CodexCatalog.shared")
      && sessionView.contains("codexCatalog.contextWindow(forModel: selection?.isEmpty == false"))
// Settings is a mode of the main window: the topic is held by ContentView
// and handed to the Help page it makes, so the card opens expanded.
check("ContentView receives .openHelpTopic and opens Settings on Help",
      content.contains("publisher(for: .openHelpTopic)")
      && content.contains("settingsHelpTopic = topic\n            appState.openSettings(.help)")
      && content.contains("SettingsView(section: section, initialHelpTopic: settingsHelpTopic)"))
check("the topic names its card and the card carries that id",
      settings.contains("case .codexContextWindow: return 11")
      && settings.contains("FAQ(id: HelpTopic.codexContextWindow.faqId")
      && settings.contains(".id(item.id)"))
check("a deep-linked topic opens expanded and is scrolled to",
      settings.contains("_expanded = State(initialValue: initialTopic.map { [$0.faqId] } ?? [])")
      && settings.contains("scrollTo(topic.faqId)"))
check("the card writes THROUGH the catalog, never TOML of its own",
      settings.contains("catalog.setContextWindow(")
      && !settings.contains("config.toml\", atomically")
      && !launch.contains("model_context_window = \\("))
check("the catalog's write goes through codex (CodexConfigWrite) and re-reads unconditionally",
      launch.contains("CodexConfigWrite.run(binary: binary,")
      && launch.contains("writing = false\n        loadedFingerprint = nil\n"))
check("every sentence on the card takes the agent's label",
      settings.contains("config.agentLabel(for: \"codex\"")
      && !settings.contains("\"Why does Codex"))
check("the card's numbers reach Text through verbatim, never a markdown literal",
      !settings.contains("Text(\"\\(") )

// Strings: every new key, with a zh-Hans value.
let catalogText = source("SipAI/Resources/Localizable.xcstrings")
if let data = catalogText.data(using: .utf8),
   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
   let strings = obj["strings"] as? [String: Any] {
    let keys = [
        "Why %@? Opens Help",
        "Why does %@ show a 258k context window, and how do I get the larger one?",
        "Use the maximum", "Back to default", "Writing…", "Copy", "Copied", "Maximum",
        "no larger window",
        "Right now: the default. Nothing is set in config.toml, so every model runs at its default window.",
        "%@ declined the change: %@",
        "Written, but %@ reports it will not take effect: %@",
    ]
    var allThere = true
    var missing: [String] = []
    for key in keys {
        let zh = ((strings[key] as? [String: Any])?["localizations"] as? [String: Any])
            .flatMap { $0["zh-Hans"] as? [String: Any] }
            .flatMap { $0["stringUnit"] as? [String: Any] }
            .flatMap { $0["value"] as? String }
        if zh == nil || zh!.isEmpty { allThere = false; missing.append(key) }
    }
    check("every new string carries a zh-Hans value", allThere, "missing: \(missing)")
} else {
    check("Localizable.xcstrings parses", false)
}

/// The newest rollout under a throwaway home. Synchronous on purpose:
/// a directory enumerator's iterator is not available from an async
/// context.
func newestRollout(under root: URL) -> URL? {
    var newest: (URL, Date)? = nil
    guard let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
    for case let url as URL in walker where url.lastPathComponent.hasPrefix("rollout-") {
        let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        if newest == nil || at > newest!.1 { newest = (url, at) }
    }
    return newest?.0
}

// MARK: - 4. Live (opt in) — the config route on a real turn

if ProcessInfo.processInfo.environment["SIPAI_CXWIN_LIVE"] == "1" {
    print("")
    print("4. Live — model_context_window in config.toml, read back off a real rollout")
    let realHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    let auth = realHome.appendingPathComponent("auth.json")
    if let codex = findCodex(), FileManager.default.fileExists(atPath: auth.path) {
        let realConfig = (try? String(contentsOf: realHome.appendingPathComponent("config.toml"),
                                      encoding: .utf8)) ?? ""
        let modelSlug = CodexCatalog.parseConfigDefaults(realConfig).model ?? "gpt-5.6-sol"

        func turn(window: Int?) async -> (recorded: Int, exit: Int32, model: String) {
            let home = tmp.appendingPathComponent("live-\(window.map(String.init) ?? "default")", isDirectory: true)
            try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try! FileManager.default.copyItem(at: auth, to: home.appendingPathComponent("auth.json"))
            var config = "model = \"\(modelSlug)\"\nmodel_reasoning_effort = \"low\"\n"
            if let window { config += "model_context_window = \(window)\n" }
            try! config.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            let cwd = home.appendingPathComponent("cwd", isDirectory: true)
            try! FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

            let p = Process()
            p.executableURL = URL(fileURLWithPath: codex)
            p.arguments = ["exec", "--skip-git-repo-check", "--json", "Reply with the single word OK."]
            p.currentDirectoryURL = cwd
            var env = AgentRunner.buildEnvironment()
            env["CODEX_HOME"] = home.path
            p.environment = env
            p.standardInput = FileHandle.nullDevice
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try! p.run()
            let output = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            _ = output
            // The newest rollout under the throwaway home.
            guard let rollout = newestRollout(under: home.appendingPathComponent("sessions"))
            else { return (0, p.terminationStatus, modelSlug) }
            let info = CodexSessionScanner.lastContextInfo(of: rollout)
            return (info.window, p.terminationStatus, modelSlug)
        }

        let raised = await turn(window: 872_000)
        check("config.toml model_context_window = 872000 → the rollout records 828,400 (\(raised.model))",
              raised.recorded == 828_400, "recorded \(raised.recorded), exit \(raised.exit)")
        let plain = await turn(window: nil)
        check("no key → the rollout records the default 258,400",
              plain.recorded == 258_400, "recorded \(plain.recorded), exit \(plain.exit)")
    } else {
        print("  skip — no codex on PATH or no ~/.codex/auth.json")
    }
}

print("")
print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
