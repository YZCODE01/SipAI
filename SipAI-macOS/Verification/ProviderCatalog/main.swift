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

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("provider catalog: OK")
