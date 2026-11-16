// Headless checks for the provider catalog and the config migration
// that goes with it (2026-08-15 audit).
//
// Two things are pinned here:
//
//   1. The CATALOG's own rules — what is offered, and the per-provider
//      flags that decide whether the add flow fetches a list, probes a
//      key, or asks for a typed id. Every one of those flags exists
//      because the flow was measured doing the wrong thing without it.
//   2. The MIGRATION that folds a retired provider key into its
//      successor, run against a throwaway config.json. It moves the
//      user's stored API key and re-points their models, so it is the
//      one piece here that can lose data.
//   3. NO COPY ON DISK: a request through the real `ProviderHTTP.session`
//      — a key in its header, a chat in its body — leaves nothing in the
//      web cache, and `WebCache` deletes what an earlier SipAI left there.
//
// Nothing in this directory is part of the app target.

import Foundation

// Section 10's throwaway cache. Set before anything touches
// `ProviderHTTP.session`, so a session built on the default
// configuration would cache into this folder, where section 10 looks.
let cacheFolder = FileManager.default.temporaryDirectory
    .appendingPathComponent("sipai-provider-cache-\(UUID().uuidString)", isDirectory: true)
URLCache.shared = URLCache(memoryCapacity: 4 << 20, diskCapacity: 64 << 20, directory: cacheFolder)

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

// ───────────────────────────────────────────────────────────── catalog

section("1. Retired rows are gone from every offer list")

let allKeys = Set(BuiltinProviderCatalog.all.map(\.key))

// GitHub Copilot: measured 2026-08-15, every token shape answers
// 401 "AuthenticateToken authentication failed" — a PAT cannot
// authenticate it and this app cannot mint a Copilot token. GitHub
// Models, the PAT-authenticated alternative, was retired 2026-07-30.
check("github is not offered", !allKeys.contains("github"))

// The six local servers: nothing about them is verifiable from the app
// and none can work while its server is down.
for key in ["ollama", "lmstudio", "vllm", "sglang", "jan", "gpt4all"] {
    check("\(key) is not offered", !allKeys.contains(key))
}

// Retired 2026-08-15: OpenRouter, Bedrock and Cloudflare by product
// decision (all three answered correctly), Qianfan because its listing
// is refused and no key was available to prove chat works either.
for key in ["openrouter", "bedrock", "cloudflare", "qianfan"] {
    check("\(key) is not offered", !allKeys.contains(key))
}

check("cloudSorted holds every catalog entry",
      Set(BuiltinProviderCatalog.cloudSorted.map(\.key)) == allKeys,
      "the two lists disagree, so a provider is reachable from one surface only")

check("no duplicate provider keys",
      Set(BuiltinProviderCatalog.all.map(\.key)).count == BuiltinProviderCatalog.all.count)

let names = BuiltinProviderCatalog.cloudSorted.map(\.name)
check("cloudSorted is alphabetical",
      names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })

section("2. GLM and Z.AI are one provider with two regions")

check("glm is no longer its own row", BuiltinProviderCatalog.find("glm") == nil)
if let zai = BuiltinProviderCatalog.find("zai") {
    let urls = Set(zai.regions.map(\.baseURL))
    check("zai offers both platforms", urls.count == 2
          && urls.contains("https://api.z.ai/api/paas/v4")
          && urls.contains("https://open.bigmodel.cn/api/paas/v4"),
          "regions: \(urls)")
    // A single-entry region list renders NO picker (the section needs
    // count > 1), which is what made the second endpoint unreachable
    // for Volcengine once already.
    check("zai's region picker will render", zai.regions.count > 1)
    check("zai says which key it wants", zai.keyFieldNote != nil)
} else {
    check("zai exists", false)
}

section("3. Providers with no model list skip the fetch")

// Empty today — every remaining provider publishes a list a valid key
// can read. The mechanism is kept for the next one that does not, so
// the rules below still have to hold for whatever gets added.
let noList = BuiltinProviderCatalog.all.filter { !$0.listsModels }
check("no provider currently claims to have no list",
      noList.isEmpty, "got \(Set(noList.map(\.key)))")
for p in noList {
    // The note replaces a list the user can no longer see; an empty
    // panel with an empty box is the dead end this is fixing.
    check("\(p.key) explains itself", BuiltinProviderCatalog.setupHints[p.key] != nil)
    check("\(p.key) seeds an example id", p.exampleModelId?.isEmpty == false)
}
check("noListNote never returns empty",
      !BuiltinProviderCatalog.noListNote(
        for: BuiltinProvider(key: "x", name: "X", baseURL: "https://x/v1",
                             apiStyle: "openai", envVar: "", authHeader: "Authorization",
                             authPrefix: "Bearer ")).isEmpty)

check("no hint names a provider that is gone",
      Set(BuiltinProviderCatalog.setupHints.keys).isSubset(of: allKeys),
      "orphans: \(Set(BuiltinProviderCatalog.setupHints.keys).subtracting(allKeys))")

section("4. Public model lists are marked, so the key gets probed")

let publicList = BuiltinProviderCatalog.all.filter(\.listsModelsWithoutAuth)
check("exactly the measured providers are marked",
      Set(publicList.map(\.key)) == ["nvidia", "huggingface", "venice"],
      "got \(Set(publicList.map(\.key)))")
for p in publicList {
    check("\(p.key) triggers the key check", ProviderKeyCheck.isNeeded(for: p))
    // A provider that publishes no list cannot also publish a public
    // one; the flow would skip the fetch and never reach the probe.
    check("\(p.key) still fetches a list", p.listsModels)
}
check("openai is not probed twice",
      !ProviderKeyCheck.isNeeded(for: BuiltinProviderCatalog.find("openai")!))

section("5. Perplexity lists at /v1/models and chats at the bare host")

if let px = BuiltinProviderCatalog.find("perplexity") {
    check("base URL stays bare (chat lives there)",
          px.baseURL == "https://api.perplexity.ai")
    check("the list is fetched from /v1/models",
          px.modelsURL == "https://api.perplexity.ai/v1/models", px.modelsURL)
} else {
    check("perplexity exists", false)
}

check("every other provider still lists at base + /models",
      BuiltinProviderCatalog.all
        .filter { $0.key != "perplexity" }
        .allSatisfy { $0.modelsURL == $0.baseURL + "/models" })

check("every models URL parses",
      BuiltinProviderCatalog.all.allSatisfy { URL(string: $0.modelsURL) != nil })

section("6. withBaseURL carries every field")

// The old implementation re-listed properties by hand, so each new
// field silently defaulted itself away on every region pick.
if let px = BuiltinProviderCatalog.find("perplexity") {
    let moved = px.withBaseURL("https://example.test/v1")
    check("baseURL changes", moved.baseURL == "https://example.test/v1")
    check("modelsPath survives", moved.modelsPath == px.modelsPath)
    check("exampleModelId survives", moved.exampleModelId == px.exampleModelId)
}
// No shipping provider sets listsModels today, so prove the copy with
// a synthetic one — the flag still has to survive a region pick when
// the next such provider arrives.
let synthetic = BuiltinProvider(
    key: "synthetic", name: "Synthetic", baseURL: "https://a.test/v1",
    apiStyle: "openai", envVar: "", authHeader: "Authorization",
    authPrefix: "Bearer ", listsModels: false, exampleModelId: "demo-1")
check("listsModels survives", synthetic.withBaseURL("https://b.test/v1").listsModels == false)
check("exampleModelId survives on a copy",
      synthetic.withBaseURL("https://b.test/v1").exampleModelId == "demo-1")
if let zai = BuiltinProviderCatalog.find("zai") {
    let moved = zai.withBaseURL("https://example.test/v4")
    check("keyFieldNote survives", moved.keyFieldNote == zai.keyFieldNote)
    check("regions survive", moved.regions == zai.regions)
}
if let nv = BuiltinProviderCatalog.find("nvidia") {
    check("listsModelsWithoutAuth survives",
          nv.withBaseURL("https://example.test/v1").listsModelsWithoutAuth)
}

section("7. Region-bound providers keep their pickers")

for key in ["qwen", "moonshot", "minimax", "volcengine", "zai"] {
    guard let p = BuiltinProviderCatalog.find(key) else {
        check("\(key) exists", false); continue
    }
    check("\(key) shows a region picker", p.regions.count > 1,
          "\(p.regions.count) region(s)")
    check("\(key) defaults to one of its own regions",
          p.regions.contains { $0.baseURL == p.baseURL })
}

section("7b. A keyless endpoint is one the key step must let through")

// The "Local Model Providers" section used to be what waived the key
// step. With it gone, the same servers arrive as LiteLLM or as a custom
// provider, and demanding a key they do not have makes them unaddable.
for url in ["http://127.0.0.1:11434/v1", "http://localhost:4000/v1",
            "http://192.168.1.40:1234/v1", "http://my-box.local:8000/v1"] {
    check("keyless: \(url)", BuiltinProviderCatalog.endpointNeedsNoKey(url))
}
for url in ["https://api.openai.com/v1", "https://api.z.ai/api/paas/v4",
            "https://gateway.ai.cloudflare.com/v1/tag/gw/compat"] {
    check("still needs a key: \(url)", !BuiltinProviderCatalog.endpointNeedsNoKey(url))
}
check("garbage is not mistaken for a local server",
      !BuiltinProviderCatalog.endpointNeedsNoKey("beijing"))
check("LiteLLM's own default is keyless",
      BuiltinProviderCatalog.endpointNeedsNoKey(
        BuiltinProviderCatalog.find("litellm")!.baseURL))
check("every OTHER built-in still asks for a key",
      BuiltinProviderCatalog.all
        .filter { $0.key != "litellm" }
        .allSatisfy { !BuiltinProviderCatalog.endpointNeedsNoKey($0.baseURL) })

// ─────────────────────────────────────────────────────────── migration

section("8. The glm → zai fold, over a throwaway config")

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sipai-provider-harness-\(ProcessInfo.processInfo.processIdentifier)")
SipaiPaths.dataDir = root
defer { try? FileManager.default.removeItem(at: root) }

func writeConfig(_ dict: [String: Any]) {
    SipaiPaths.ensureDataDir()
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
    try! data.write(to: SipaiPaths.configFile)
}

func readConfig() -> [String: Any] {
    let data = try! Data(contentsOf: SipaiPaths.configFile)
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}

// (a) glm alone → folded onto zai, key and models carried across.
writeConfig([
    "providers": [
        "glm": ["name": "GLM Models",
                "base_url": "https://open.bigmodel.cn/api/paas/v4",
                "api_style": "openai", "api_key": "SECRET-GLM",
                "auth_header": "Authorization", "auth_prefix": "Bearer ",
                "env_var": "GLM_API_KEY"],
        "openai": ["name": "OpenAI", "base_url": "https://api.openai.com/v1",
                   "api_style": "openai", "api_key": "SECRET-OPENAI",
                   "auth_header": "Authorization", "auth_prefix": "Bearer "],
    ],
    "models": [
        "glm-4.6": ["provider": "glm", "name": "glm-4.6"],
        "gpt-5":   ["provider": "openai", "name": "gpt-5"],
    ],
    "default_model": "glm-4.6",
])

_ = MainActor.assumeIsolated { ConfigManager() }
var out = readConfig()
var provs = out["providers"] as! [String: [String: Any]]
var mods = out["models"] as! [String: [String: Any]]

check("the glm entry is gone", provs["glm"] == nil)
check("the stored key moved to zai", provs["zai"]?["api_key"] as? String == "SECRET-GLM")
check("the endpoint travels untouched (it is now a region)",
      provs["zai"]?["base_url"] as? String == "https://open.bigmodel.cn/api/paas/v4")
check("the env var travels too", provs["zai"]?["env_var"] as? String == "GLM_API_KEY")
check("the name follows the catalog",
      provs["zai"]?["name"] as? String == "Z.AI (GLM)",
      provs["zai"]?["name"] as? String ?? "nil")
check("the model re-points at zai", mods["glm-4.6"]?["provider"] as? String == "zai")
check("the default model id is untouched", out["default_model"] as? String == "glm-4.6")
check("an unrelated provider is untouched",
      provs["openai"]?["api_key"] as? String == "SECRET-OPENAI")
check("the fold is stamped", (out["provider_defaults_migrated"] as? Int) ?? 0 >= 3)

// (b) A second load must be a no-op — the flag is what makes a later
//     deliberate choice safe from being re-migrated on every launch.
let afterFirst = provs["zai"]?["base_url"] as? String
_ = MainActor.assumeIsolated { ConfigManager() }
out = readConfig()
provs = out["providers"] as! [String: [String: Any]]
check("re-running the migration changes nothing",
      provs["zai"]?["base_url"] as? String == afterFirst)

// (c) BOTH keys configured → two real accounts. Merging would throw
//     one key away, so the fold must decline entirely.
writeConfig([
    "providers": [
        "glm": ["name": "GLM Models", "base_url": "https://open.bigmodel.cn/api/paas/v4",
                "api_style": "openai", "api_key": "SECRET-CN",
                "auth_header": "Authorization", "auth_prefix": "Bearer "],
        "zai": ["name": "Z.AI", "base_url": "https://api.z.ai/api/paas/v4",
                "api_style": "openai", "api_key": "SECRET-INTL",
                "auth_header": "Authorization", "auth_prefix": "Bearer "],
    ],
    "models": [
        "glm-4.6":      ["provider": "glm", "name": "glm-4.6"],
        "glm-4.6-intl": ["provider": "zai", "name": "glm-4.6-intl"],
    ],
])
_ = MainActor.assumeIsolated { ConfigManager() }
out = readConfig()
provs = out["providers"] as! [String: [String: Any]]
mods = out["models"] as! [String: [String: Any]]
check("both keys survive when both platforms are configured",
      provs["glm"]?["api_key"] as? String == "SECRET-CN"
      && provs["zai"]?["api_key"] as? String == "SECRET-INTL")
check("neither model is re-pointed",
      mods["glm-4.6"]?["provider"] as? String == "glm"
      && mods["glm-4.6-intl"]?["provider"] as? String == "zai")

// (d) A retired provider must keep RESOLVING even though it is no
//     longer offered — its models are still in the user's list.
section("9. Retired keys still resolve on the read side")

let readSideKeys = MainActor.assumeIsolated { Set(ConfigManager.builtInProviders.keys) }
for key in ["github", "ollama", "lmstudio", "vllm", "sglang", "jan", "gpt4all", "glm",
            "openrouter", "bedrock", "cloudflare", "qianfan"] {
    check("\(key) is still known to the read-side table",
          readSideKeys.contains(key),
          "a model pointing at it would lose its endpoint and auth")
}

// ───────────────────────────────────────────────── no copy on disk

section("10. A provider request leaves nothing on disk")

/// Every file under `folder`, whole, as bytes — the cache's database, its
/// write-ahead log and the response bodies kept beside it.
func bytesOnDisk(under folder: URL) -> [(String, Data)] {
    let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL } ?? []
    return files.compactMap { url in (try? Data(contentsOf: url)).map { (url.lastPathComponent, $0) } }
}
func kept(_ marker: String, under folder: URL) -> [String] {
    let needle = Data(marker.utf8)
    return bytesOnDisk(under: folder).filter { $0.1.range(of: needle) != nil }.map(\.0)
}

/// The stand-in provider: started, its port read, stopped by closing
/// its stdin. nil when python3 or the script is missing.
func startStandIn() -> (port: Int, stop: () -> Void)? {
    guard let script = ProcessInfo.processInfo.environment["PROVIDER_CACHE_SERVER"],
          FileManager.default.fileExists(atPath: script),
          FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [script]
    let stdin = Pipe(), stdout = Pipe()
    p.standardInput = stdin
    p.standardOutput = stdout
    guard (try? p.run()) != nil else { return nil }
    var line = Data()
    while true {
        let byte = stdout.fileHandleForReading.readData(ofLength: 1)
        if byte.isEmpty || byte == Data("\n".utf8) { break }
        line.append(byte)
    }
    guard let port = Int(String(decoding: line, as: UTF8.self)) else { p.terminate(); return nil }
    return (port, { try? stdin.fileHandleForWriting.close(); p.waitUntilExit() })
}

/// A key in a header and a chat in a body, the two things a provider
/// request carries, each sent through `session` — at addresses of their
/// own (`/<run>/v1/…`): the cache is looked up by address, and the
/// control's answers must not be taken for the session's.
func sendBoth(through session: URLSession, port: Int, run: String, marker: String) async -> [URLRequest] {
    var get = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(run)/v1/models")!)
    get.setValue("Bearer \(marker)", forHTTPHeaderField: "Authorization")
    var post = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(run)/v1/chat/completions")!)
    post.httpMethod = "POST"
    post.setValue(marker, forHTTPHeaderField: "x-api-key")
    post.setValue("application/json", forHTTPHeaderField: "Content-Type")
    post.httpBody = try? JSONSerialization.data(withJSONObject: [
        "model": "harness-model",
        "messages": [["role": "user", "content": "a chat message \(marker)"]],
    ])
    for request in [get, post] { _ = try? await session.data(for: request) }
    // The cache writes on a queue of its own.
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    return [get, post]
}

/// Holds what a detached task hands back to the top level.
final class ResultBox<T>: @unchecked Sendable { var value: T? }

/// Runs `body` to its end from this file's top level, which stays
/// synchronous: an `await` here would make the whole top level an
/// asynchronous context, where sections 8 and 9's
/// `MainActor.assumeIsolated` may not be called.
func blocking<T>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await body()
        done.signal()
    }
    done.wait()
    return box.value!
}

if let standIn = startStandIn() {
    let port = standIn.port
    // The control: a session on the default configuration, the shape
    // `ProviderHTTP` had, keeps both. Without it the check below would
    // pass for a folder nothing could ever be written to.
    let control = "sk-control-\(UUID().uuidString)"
    let controlRequests = blocking {
        await sendBoth(through: URLSession(configuration: .default), port: port, run: "control", marker: control)
    }
    check("control: a default session keeps a provider request in the web cache, key included",
          URLCache.shared.cachedResponse(for: controlRequests[0]) != nil && !kept(control, under: cacheFolder).isEmpty,
          "nothing kept — the stand-in or the cache folder is not what this check needs")

    let marker = "sk-harness-\(UUID().uuidString)"
    let requests = blocking { await sendBoth(through: ProviderHTTP.session, port: port, run: "provider", marker: marker) }
    check("ProviderHTTP: no answer kept in the web cache",
          requests.allSatisfy { URLCache.shared.cachedResponse(for: $0) == nil })
    let found = kept(marker, under: cacheFolder)
    check("ProviderHTTP: the key and the chat it carried are nowhere on disk",
          found.isEmpty, "found in \(found.joined(separator: ", "))")
    check("ProviderHTTP: its session has no cache at all",
          ProviderHTTP.session.configuration.urlCache == nil)
    standIn.stop()
} else {
    print("  SKIP  no python3 or no cache_server.py — the stand-in provider could not start")
}

section("11. What an earlier SipAI left in the web cache is deleted")

// The files URLCache keeps for an app, as an earlier SipAI left them,
// beside a folder that is not the cache's.
let leftovers = FileManager.default.temporaryDirectory
    .appendingPathComponent("sipai-leftovers-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: leftovers.appendingPathComponent("fsCachedData"),
                                         withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: leftovers.appendingPathComponent("WebKit"),
                                         withIntermediateDirectories: true)
for name in ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData/0A1B", "WebKit/keep"] {
    FileManager.default.createFile(atPath: leftovers.appendingPathComponent(name).path,
                                   contents: Data("Authorization: Bearer sk-old".utf8))
}
WebCache.removeLeftovers(in: leftovers)
let after = Set((try? FileManager.default.contentsOfDirectory(atPath: leftovers.path)) ?? [])
check("the cache's database, its log and its kept bodies are deleted",
      after.isDisjoint(with: ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData"]),
      after.sorted().joined(separator: ", "))
check("…and nothing else in the folder", after == ["WebKit"]
      && FileManager.default.fileExists(atPath: leftovers.appendingPathComponent("WebKit/keep").path))
WebCache.removeLeftovers(in: leftovers)
check("…and a second run finds nothing to do", Set((try? FileManager.default.contentsOfDirectory(atPath: leftovers.path)) ?? []) == ["WebKit"])

// At launch, before anything opens the cache: the first thing the app
// does. Read off the source — the app itself is not compiled here.
let sourceRoot = ProcessInfo.processInfo.environment["SIPAI_SOURCE_ROOT"] ?? ""
let app = (try? String(contentsOfFile: sourceRoot + "/SipAI/SipAIApp.swift", encoding: .utf8)) ?? ""
let appInit = app.range(of: "    init() {").map { String(app[$0.upperBound...].prefix(400)) } ?? ""
let firstCall = appInit.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet.whitespaces) }
    .first { !$0.isEmpty && !$0.hasPrefix("//") } ?? ""
check("the app deletes them first thing at launch", firstCall == "WebCache.removeLeftovers()", firstCall)
let reset = (try? String(contentsOfFile: sourceRoot + "/SipAI/Models/FactoryReset.swift", encoding: .utf8)) ?? ""
check("Factory reset empties the web cache too", reset.contains("WebCache.clear()"))
try? FileManager.default.removeItem(at: leftovers)
try? FileManager.default.removeItem(at: cacheFolder)

// ── 12. One Anthropic API version, spelled once ─────────────────────
// A chat, a model's maximum, the model list and the key check each set
// `anthropic-version`; a second spelling is how one of them stays on an
// old version when the rest move.
print("\n12. one Anthropic API version")
check("the version is Anthropic's newest, 2026-10-21", ProviderHTTP.anthropicVersion == "2026-10-21",
      ProviderHTTP.anthropicVersion)
let models = sourceRoot + "/SipAI/Models"
var versionSites: [String] = []
var literalSites: [String] = []
for name in (try? FileManager.default.contentsOfDirectory(atPath: models)) ?? [] where name.hasSuffix(".swift") {
    let text = (try? String(contentsOfFile: models + "/" + name, encoding: .utf8)) ?? ""
    for (i, line) in text.components(separatedBy: "\n").enumerated() where line.contains("\"anthropic-version\"") {
        versionSites.append("\(name):\(i + 1)")
        if !line.contains("ProviderHTTP.anthropicVersion") { literalSites.append("\(name):\(i + 1)") }
    }
}
check("every request that sets it (\(versionSites.count)) takes ProviderHTTP.anthropicVersion",
      versionSites.count >= 4 && literalSites.isEmpty,
      "set at \(versionSites); not from the constant: \(literalSites)")

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("provider catalog: OK")
