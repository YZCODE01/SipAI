// ProviderCatalog.swift
// Built-in provider catalog + /models fetcher, shared by the onboarding
// wizard (OnboardingView) and the model setup window (ModelSetupSheet).

import Foundation

/// The URLSession behind every request that carries a provider API key
/// (chat calls, model-list fetches, model verification).
///
/// It exists for one rule: a redirect may not carry the key to another
/// host. `URLSession` strips the standard `Authorization` header when a
/// redirect crosses origins, but NOT custom headers — and most providers
/// here authenticate through a custom header (`x-api-key`, or whatever
/// `auth_header` is configured). A compromised or misconfigured provider
/// answering with a cross-host 3xx would otherwise receive the user's
/// key at the new host. Same-host redirects (path moves, http→https)
/// follow normally; a cross-host one is refused, so the 3xx itself
/// surfaces as the request's result.
enum ProviderHTTP {
    static let session: URLSession = URLSession(
        configuration: .default,
        delegate: SameHostRedirectPolicy(),
        delegateQueue: nil)

    private final class SameHostRedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            let original = task.originalRequest?.url?.host?.lowercased()
            let target = request.url?.host?.lowercased()
            completionHandler(original == target ? request : nil)
        }
    }
}

/// A regional endpoint choice for providers that host the same API in
/// several places.
struct ProviderRegion: Hashable {
    let name: String
    let baseURL: String
    /// Provider-side region identifier (e.g. "us-east-1"), shown in the
    /// label when present.
    var code: String? = nil

    var label: String {
        if let code { return "\(name)  (\(code))" }
        return name
    }
}

struct BuiltinProvider: Identifiable, Hashable {
    let key: String
    let name: String
    /// `var`, and the only mutable field, so `withBaseURL` can copy
    /// rather than re-list every property — a re-listing constructor
    /// silently DROPS whatever field was added since it was written,
    /// and every region pick goes through it.
    var baseURL: String
    let apiStyle: String
    let envVar: String
    let authHeader: String
    let authPrefix: String
    var regions: [ProviderRegion] = []
    /// When set, a manually typed region CODE expands through this
    /// (`{code}` placeholder), and an EMPTY `regions` list beside it
    /// means the URL is a path to complete rather than one to pick.
    ///
    /// Kept because the shape recurs, and because "Other…" still
    /// routes through `customRegionBaseURL`.
    var regionURLTemplate: String? = nil
    /// Path appended to `baseURL` to list models. Overridden by
    /// providers whose listing does NOT sit beside their chat route:
    /// Perplexity chats at the bare host (`/chat/completions`) and
    /// lists one level down (`/v1/models`).
    var modelsPath: String = "/models"
    /// False when the provider publishes no usable list at all, so the
    /// model id has to be typed. Those providers skip the fetch instead
    /// of failing it — see `BuiltinProviderCatalog.setupHints` for the
    /// sentence each one shows in its place.
    ///
    /// Kept because a provider with no listing endpoint is a recurring
    /// shape, and because a guaranteed-red error is the wrong way to
    /// say "type the id here".
    var listsModels: Bool = true
    /// True when `/models` answers 200 for an INVALID key. A successful
    /// fetch then proves nothing about the credentials, so the key is
    /// probed separately once a model is picked (`ProviderKeyCheck`).
    var listsModelsWithoutAuth: Bool = false
    /// Extra sentence under the API-key field, for providers where
    /// "your API key" is ambiguous (Cloudflare wants the UPSTREAM
    /// provider's key; Z.AI issues one key per platform).
    var keyFieldNote: String? = nil
    /// Seeded into the manual model-ID field when there is no list to
    /// pick from — a namespaced or console-only id is unguessable, and
    /// an empty box next to "no model list" is a dead end.
    var exampleModelId: String? = nil
    var id: String { key }

    /// Where the model list is fetched from.
    var modelsURL: String {
        baseURL.trimmingCharacters(in: .whitespaces) + modelsPath
    }

    /// The same provider pointed at a different endpoint — used when a
    /// region is picked so fetching and verification hit the endpoint
    /// that will actually be stored.
    func withBaseURL(_ url: String) -> BuiltinProvider {
        var copy = self
        copy.baseURL = url
        return copy
    }

    /// What a hand-typed "Other…" region entry resolves to. A bare
    /// region code expands through `regionURLTemplate`; anything that
    /// already looks like a URL is taken as-is. Empty in, empty out —
    /// the caller reads that as "chosen but not filled in yet".
    func customRegionBaseURL(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        if let regionURLTemplate, !trimmed.contains("://") {
            return regionURLTemplate.replacingOccurrences(of: "{code}",
                                                          with: trimmed)
        }
        return trimmed
    }

    func toProviderConfig(apiKey: String?) -> ProviderConfig {
        ProviderConfig(
            key: key,
            name: name,
            baseURL: baseURL,
            apiStyle: apiStyle,
            apiKey: apiKey,
            envVar: envVar.isEmpty ? nil : envVar,
            authHeader: authHeader,
            authPrefix: authPrefix
        )
    }
}

enum BuiltinProviderCatalog {
    static let top: [BuiltinProvider] = [
        .init(key: "openai",    name: "OpenAI",          baseURL: "https://api.openai.com/v1",                              apiStyle: "openai",    envVar: "OPENAI_API_KEY",    authHeader: "Authorization", authPrefix: "Bearer "),
        .init(key: "anthropic", name: "Anthropic",       baseURL: "https://api.anthropic.com/v1",                           apiStyle: "anthropic", envVar: "ANTHROPIC_API_KEY", authHeader: "x-api-key",     authPrefix: ""),
        .init(key: "google",    name: "Google (Gemini)", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", apiStyle: "openai",    envVar: "GOOGLE_API_KEY",    authHeader: "Authorization", authPrefix: "Bearer "),
    ]

    // Cloud providers
    static let others: [BuiltinProvider] = [
        .init(key: "deepseek",   name: "DeepSeek",              baseURL: "https://api.deepseek.com/v1",                          apiStyle: "openai", envVar: "DEEPSEEK_API_KEY",   authHeader: "Authorization", authPrefix: "Bearer "),
        .init(key: "groq",       name: "Groq",                  baseURL: "https://api.groq.com/openai/v1",                       apiStyle: "openai", envVar: "GROQ_API_KEY",       authHeader: "Authorization", authPrefix: "Bearer "),
        .init(key: "mistral",    name: "Mistral",               baseURL: "https://api.mistral.ai/v1",                            apiStyle: "openai", envVar: "MISTRAL_API_KEY",    authHeader: "Authorization", authPrefix: "Bearer "),
        .init(key: "xai",        name: "xAI (Grok)",            baseURL: "https://api.x.ai/v1",                                  apiStyle: "openai", envVar: "XAI_API_KEY",        authHeader: "Authorization", authPrefix: "Bearer "),
        // Same two-platform shape as Moonshot: minimax.io serves the
        // international account, minimax.chat the mainland one. Both
        // hosts answer, so the default stays where it was — the picker
        // is the escape hatch for a key the other side issued.
        .init(key: "minimax",    name: "MiniMax",               baseURL: "https://api.minimax.chat/v1",                          apiStyle: "openai", envVar: "MINIMAX_API_KEY",    authHeader: "Authorization", authPrefix: "Bearer ",
              regions: [
                  ProviderRegion(name: "China (minimax.chat)",       baseURL: "https://api.minimax.chat/v1"),
                  ProviderRegion(name: "International (minimax.io)", baseURL: "https://api.minimaxi.com/v1"),
              ]),
        // Two independent platforms, and a key is bound to the one that
        // issued it — the .cn endpoint answers a platform.moonshot.ai key
        // with HTTP 401 "Invalid Authentication", a dead end without the
        // picker. International is the default, since the CN platform
        // needs a mainland-China account.
        .init(key: "moonshot",   name: "Moonshot AI (Kimi)",    baseURL: "https://api.moonshot.ai/v1",                           apiStyle: "openai", envVar: "MOONSHOT_API_KEY",   authHeader: "Authorization", authPrefix: "Bearer ",
              regions: [
                  ProviderRegion(name: "International (platform.moonshot.ai)", baseURL: "https://api.moonshot.ai/v1"),
                  ProviderRegion(name: "China (platform.moonshot.cn)",         baseURL: "https://api.moonshot.cn/v1"),
              ]),
        // International (Singapore) endpoint by default — the CN
        // endpoint 401s international Model Studio keys. Keys are
        // region-bound, hence the picker.
        .init(key: "qwen",       name: "Qwen / Model Studio",   baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", apiStyle: "openai", envVar: "DASHSCOPE_API_KEY",  authHeader: "Authorization", authPrefix: "Bearer ",
              regions: [
                  ProviderRegion(name: "Singapore",         baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
                  ProviderRegion(name: "China (Beijing)",   baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
                  ProviderRegion(name: "US (Virginia)",     baseURL: "https://dashscope-us.aliyuncs.com/compatible-mode/v1"),
                  ProviderRegion(name: "China (Hong Kong)", baseURL: "https://cn-hongkong.dashscope.aliyuncs.com/compatible-mode/v1"),
              ]),
        .init(key: "together",   name: "Together AI",           baseURL: "https://api.together.xyz/v1",                          apiStyle: "openai", envVar: "TOGETHER_API_KEY",   authHeader: "Authorization", authPrefix: "Bearer "),
        // Perplexity's two routes live at DIFFERENT prefixes:
        // `POST /chat/completions` answers 401 while
        // `/v1/chat/completions` 404s, and the list is the other way
        // round (`/v1/models` 401, `/models` 404). So the base URL is
        // the bare host and only the listing is redirected.
        .init(key: "perplexity", name: "Perplexity",            baseURL: "https://api.perplexity.ai",                            apiStyle: "openai", envVar: "PERPLEXITY_API_KEY", authHeader: "Authorization", authPrefix: "Bearer ",
              modelsPath: "/v1/models", exampleModelId: "sonar"),
        // These three (and Venice, below) answer /models with the
        // full catalogue for an INVALID key. See
        // `listsModelsWithoutAuth`.
        .init(key: "nvidia",     name: "NVIDIA",                baseURL: "https://integrate.api.nvidia.com/v1",                  apiStyle: "openai", envVar: "NVIDIA_API_KEY",     authHeader: "Authorization", authPrefix: "Bearer ",
              listsModelsWithoutAuth: true),
        .init(key: "huggingface",name: "Hugging Face",          baseURL: "https://router.huggingface.co/v1",                     apiStyle: "openai", envVar: "HF_TOKEN",           authHeader: "Authorization", authPrefix: "Bearer ",
              listsModelsWithoutAuth: true),
        // Self-hosted: the default is only where LiteLLM lands if you
        // followed its quickstart. Everyone else reaches their own host
        // through the API-key step's "Endpoint" field, which is why
        // that field is offered for EVERY provider and not just the
        // multi-region ones.
        .init(key: "litellm",    name: "LiteLLM",               baseURL: "http://localhost:4000/v1",                             apiStyle: "openai", envVar: "LITELLM_API_KEY",    authHeader: "Authorization", authPrefix: "Bearer "),
        .init(key: "vercel",     name: "Vercel AI Gateway",     baseURL: "https://ai-gateway.vercel.sh/v1",                      apiStyle: "openai", envVar: "AI_GATEWAY_API_KEY", authHeader: "Authorization", authPrefix: "Bearer "),
        // Public list too (the full catalogue for an INVALID key).
        .init(key: "venice",     name: "Venice AI",             baseURL: "https://api.venice.ai/api/v1",                         apiStyle: "openai", envVar: "VENICE_API_KEY",     authHeader: "Authorization", authPrefix: "Bearer ",
              listsModelsWithoutAuth: true),
        // Two regions, not one. A single-entry list renders NO picker
        // (the section needs count > 1), and Volcengine keys are
        // region-bound exactly like Qwen's and Moonshot's.
        .init(key: "volcengine", name: "Volcengine (Doubao)",   baseURL: "https://ark.cn-beijing.volces.com/api/v3",             apiStyle: "openai", envVar: "VOLCENGINE_API_KEY", authHeader: "Authorization", authPrefix: "Bearer ",
              regions: [
                  ProviderRegion(name: "China (Beijing)",              baseURL: "https://ark.cn-beijing.volces.com/api/v3"),
                  ProviderRegion(name: "International (ap-southeast)", baseURL: "https://ark.ap-southeast.volces.com/api/v3"),
              ]),
        .init(key: "xiaomi",     name: "Xiaomi",                baseURL: "https://api.xiaomimimo.com/v1",                        apiStyle: "openai", envVar: "XIAOMI_API_KEY",     authHeader: "Authorization", authPrefix: "Bearer "),
        // ONE vendor, two platforms — the same shape as Moonshot and
        // MiniMax. A key is bound to the platform that issued it,
        // which is exactly what the region picker is for. Config
        // entries under the old `glm` key are folded into this one by
        // `ConfigManager.migrateStaleProviderDefaults`.
        .init(key: "zai",        name: "Z.AI (GLM)",            baseURL: "https://api.z.ai/api/paas/v4",                         apiStyle: "openai", envVar: "ZAI_API_KEY",        authHeader: "Authorization", authPrefix: "Bearer ",
              regions: [
                  ProviderRegion(name: "International (z.ai)",        baseURL: "https://api.z.ai/api/paas/v4"),
                  ProviderRegion(name: "China (open.bigmodel.cn)",    baseURL: "https://open.bigmodel.cn/api/paas/v4"),
              ],
              keyFieldNote: "z.ai and open.bigmodel.cn issue separate keys — pick the platform yours came from above."),
    ]

    // No "Local Model Providers" section (Ollama, LM Studio, vLLM,
    // SGLang, Jan, GPT4All): nothing about a local server is verifiable
    // from the app — it can only report that a port is closed.
    //
    // Nothing is taken away from an install that already has one: those
    // config entries stay readable through `ConfigManager
    // .builtInProviders` (the read-side table, deliberately a superset
    // of what is OFFERED here), so their models keep chatting and keep
    // their names. Only the "add" surfaces stop listing them. A local
    // server can still be reached through "Custom (name & URL)".

    static var all: [BuiltinProvider] { top + others }

    /// Cloud providers in DISPLAY order — alphabetical by name.
    ///
    /// `top` / `others` group the source; neither is an order to show.
    /// Every picker reads this instead of sorting for itself: the
    /// onboarding provider step, the model-setup sheet, and
    /// onboarding's inline "Add another model" flow.
    static var cloudSorted: [BuiltinProvider] {
        (top + others).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func find(_ key: String) -> BuiltinProvider? {
        all.first { $0.key == key }
    }

    /// The name to SHOW for a provider, translated where the company has
    /// a Chinese name of its own.
    ///
    /// `BuiltinProvider.name` itself stays canonical English, and must:
    /// `ConfigManager.upsertProvider` PERSISTS it into config.json, so a
    /// translated name written there would follow the user back into
    /// English mode with nothing to undo it — the stored name wins over
    /// the catalog for a configured provider. The translation therefore
    /// lives at the point of DISPLAY and never reaches storage.
    ///
    /// Only the company/platform half is translated. A model or brand
    /// token in parentheses (Kimi, GLM, Doubao) is left alone, and every
    /// provider without a Chinese name falls through untouched.
    static func localizedName(forKey key: String, fallback: String) -> String {
        switch key {
        case "deepseek":
            return String(localized: "DeepSeek",
                          comment: "Provider name; Chinese uses the company's own name")
        case "moonshot":
            return String(localized: "Moonshot AI (Kimi)",
                          comment: "Provider name; Chinese uses the company's own name, model token kept")
        case "qwen":
            return String(localized: "Qwen / Model Studio",
                          comment: "Provider name; Chinese uses the Alibaba brand names")
        case "volcengine":
            return String(localized: "Volcengine (Doubao)",
                          comment: "Provider name; Chinese uses the company's own name, model token kept")
        case "xiaomi":
            return String(localized: "Xiaomi",
                          comment: "Provider name; Chinese uses the company's own name")
        case "zai":
            return String(localized: "Z.AI (GLM)",
                          comment: "Provider name; Chinese uses the company's own name, model token kept")
        default:
            return fallback
        }
    }

    /// Convenience for a catalog row in hand.
    static func localizedName(_ p: BuiltinProvider) -> String {
        localizedName(forKey: p.key, fallback: p.name)
    }

    /// Convenience for the "no provider picked yet" call sites, which
    /// carry their own placeholder.
    static func localizedName(_ p: BuiltinProvider?, fallback: String) -> String {
        guard let p else { return fallback }
        return localizedName(forKey: p.key, fallback: p.name)
    }

    /// True when `string` parses as a usable http(s) endpoint — scheme
    /// and host present. Raw "Other…" text is stored verbatim as the
    /// base URL when no region template expands it, so "beijing" must
    /// be refused here instead of failing every later request with an
    /// opaque unsupported-URL error.
    static func isValidHTTPBaseURL(_ string: String) -> Bool {
        guard let comps = URLComponents(string: string),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else { return false }
        return true
    }

    /// True when an endpoint needs no API key at all.
    ///
    /// Plain HTTP means a local or LAN server — Ollama, LM Studio, a
    /// LiteLLM proxy — and those authenticate nothing. Such servers
    /// arrive through LiteLLM or "Custom (name & URL)", and demanding
    /// a key they do not have would make them unaddable.
    ///
    /// The rule is the SCHEME, not the hostname: a LAN box on
    /// `http://192.168.1.40:11434/v1` is as keyless as `localhost`, and
    /// anything reached over TLS is a hosted service that wants a key.
    static func endpointNeedsNoKey(_ url: String) -> Bool {
        URLComponents(string: url.trimmingCharacters(in: .whitespaces))?
            .scheme?.lowercased() == "http"
    }

    /// Derive a config key for a custom provider that can never clobber
    /// somebody else's entry: an empty derivation (all-symbol name)
    /// falls back to "custom", and a key already taken by a built-in
    /// provider (a proxy named "OpenAI" must not overwrite the real
    /// OpenAI entry and drop its api_key) or by an unrelated config
    /// entry gets a numeric suffix ("openai-2"). Re-adding the same
    /// custom provider (same name) keeps its key and updates in place.
    ///
    /// Shared by both surfaces that add a custom provider — onboarding
    /// and the model-setup sheet. It lived once in each, byte-identical.
    @MainActor
    static func uniqueCustomProviderKey(for name: String,
                                        config: ConfigManager) -> String {
        var base = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        if base.isEmpty { base = "custom" }
        func taken(_ key: String) -> Bool {
            if find(key) != nil { return true }
            guard let existing = config.provider(for: key) else { return false }
            // Same display name = this custom flow's own earlier entry.
            return existing.name.caseInsensitiveCompare(name) != .orderedSame
        }
        if !taken(base) { return base }
        var n = 2
        while taken("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Why THIS provider cannot show a list, in the user's terms.
    ///
    /// Two readers, one sentence each. For a `listsModels: false`
    /// provider it is shown UP FRONT, in place of the fetch that was
    /// never going to work; for everyone else it is appended to a fetch
    /// FAILURE, so a dead end arrives with its fix.
    ///
    /// Empty is the healthy state — every provider in the catalog
    /// publishes a model list that a valid key can read.
    ///
    /// The mechanism stays because "this provider is odd in a way the
    /// user cannot guess" recurs constantly here. Add a line the moment
    /// a provider needs one, and pair it with `listsModels: false` when
    /// the oddity is that there is no list at all.
    static let setupHints: [String: String] = [:]

    /// The sentence shown in place of a model list, for a provider that
    /// has none. Falls back to a generic line so a future
    /// `listsModels: false` entry can never render an empty panel.
    static func noListNote(for provider: BuiltinProvider) -> String {
        setupHints[provider.key]
            ?? String(localized: "\(provider.name) publishes no model list — enter a model id manually.",
                      comment: "Model setup: fallback note for a provider with no /models endpoint")
    }
}

// MARK: - Model fetcher

enum ModelFetcher {
    /// The fetched ids plus, when the call went WRONG, a human-readable
    /// reason ("HTTP 401: Incorrect API key…"). `failure` is nil for a
    /// healthy response, even one listing zero chat models — the
    /// distinction is what lets the UI say "your key was rejected"
    /// instead of a useless "no models returned".
    struct FetchResult {
        let ids: [String]
        let failure: String?
    }

    static func fetch(provider: BuiltinProvider, apiKey: String) async -> [String] {
        await fetchDetailed(provider: provider, apiKey: apiKey).ids
    }

    static func fetchDetailed(provider: BuiltinProvider, apiKey: String) async -> FetchResult {
        // `modelsURL`, not base + "/models" — Perplexity's list sits one
        // prefix away from its chat route.
        guard let url = URL(string: provider.modelsURL) else {
            return FetchResult(ids: [], failure: "Invalid base URL: \(provider.baseURL)")
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "GET"
        if !apiKey.isEmpty {
            req.setValue(provider.authPrefix + apiKey, forHTTPHeaderField: provider.authHeader)
        }
        if provider.apiStyle == "anthropic" {
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        do {
            let (data, resp) = try await ProviderHTTP.session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return FetchResult(ids: [], failure: "No HTTP response from \(url.host ?? "server").")
            }
            if http.statusCode >= 400 {
                var snippet = (String(data: data, encoding: .utf8) ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if snippet.count > 220 { snippet = String(snippet.prefix(220)) + "…" }
                return FetchResult(ids: [], failure: "HTTP \(http.statusCode): \(snippet)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return FetchResult(ids: [], failure: "The response was not JSON.")
            }
            if let arr = json["data"] as? [[String: Any]] {
                return FetchResult(ids: newestFirstChatModels(arr), failure: nil)
            }
            return FetchResult(ids: [], failure: nil)
        } catch {
            return FetchResult(ids: [], failure: error.localizedDescription)
        }
    }

    // "code-" is deliberately absent: it caught real
    // chat models like xAI's grok-code-fast-1, and the legacy
    // completions it targeted are already covered by "davinci".
    private static let nonChatPatterns = [
        "embed", "whisper", "dall-e", "tts", "moderation", "davinci", "babbage",
        "text-", "audio", "realtime", "image", "canary", "search",
        "similarity", "edit", "insert", "transcri", "translat",
    ]

    private static func isChatModel(_ id: String) -> Bool {
        let l = id.lowercased()
        return !nonChatPatterns.contains(where: { l.contains($0) })
    }

    private static let isoPlain = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Chat models, newest first. OpenAI-style /models lists carry a
    /// `created` epoch per model; Anthropic's carries an ISO-8601
    /// `created_at`. Entries without a parsable date sort after dated
    /// ones, in numeric-aware descending id order — so a dateless
    /// "gpt-5…" still lands above "gpt-4…".
    static func newestFirstChatModels(_ arr: [[String: Any]]) -> [String] {
        var rows: [(id: String, created: Double)] = []
        for item in arr {
            guard let id = item["id"] as? String, isChatModel(id) else { continue }
            var created = 0.0
            if let n = item["created"] as? NSNumber {
                created = n.doubleValue
            } else if let s = item["created_at"] as? String {
                let d = isoPlain.date(from: s) ?? isoFractional.date(from: s)
                created = d?.timeIntervalSince1970 ?? 0
            }
            rows.append((id, created))
        }
        return rows.sorted {
            if $0.created != $1.created { return $0.created > $1.created }
            return $0.id.compare($1.id, options: [.numeric, .caseInsensitive])
                == .orderedDescending
        }.map(\.id)
    }
}

// MARK: - Manual model-ID verification

/// Probes a model with a minimal request ("hi", 1 token) before a
/// manually typed ID is saved, which is what keeps typos from becoming
/// dead config entries.
enum ModelVerifier {
    enum Verdict {
        case ok
        /// The provider explicitly does not know this model.
        case notFound(String)
        /// Anything else — network trouble, auth, quota. The caller may
        /// offer "add anyway", since the model might still be real.
        case error(String)
    }

    static func verify(provider: BuiltinProvider, apiStyle: String,
                       apiKey: String, modelId: String) async -> Verdict {
        let base = provider.baseURL.trimmingCharacters(in: .whitespaces)
        var headers = [
            "Content-Type": "application/json",
            provider.authHeader: provider.authPrefix + apiKey,
        ]
        let endpoint: String
        let bodies: [[String: Any]]
        // 16 tokens, not 1: reasoning models burn the budget before
        // emitting anything and answer 400 "output limit reached" —
        // which is also why that reply counts as OK below.
        if apiStyle == "anthropic" {
            endpoint = base + "/messages"
            headers["anthropic-version"] = "2023-06-01"
            bodies = [
                ["model": modelId, "max_tokens": 16,
                 "messages": [["role": "user", "content": "hi"]]],
            ]
        } else {
            endpoint = base + "/chat/completions"
            // max_completion_tokens first (newer OpenAI models require
            // it), then a max_tokens retry — strict OpenAI-compatible
            // servers reject unknown fields, which would misreport a
            // perfectly valid model as unverifiable.
            bodies = [
                ["model": modelId, "max_completion_tokens": 16,
                 "messages": [["role": "user", "content": "hi"]]],
                ["model": modelId, "max_tokens": 16,
                 "messages": [["role": "user", "content": "hi"]]],
            ]
        }
        guard let url = URL(string: endpoint) else {
            return .error("Invalid base URL: \(base)")
        }

        let notFoundMarkers = [
            "not found", "does not exist", "unknown model", "invalid model",
            "no such model", "model_not_found", "invalid_model", "not available",
        ]
        var last: Verdict = .error("No request attempted.")
        for body in bodies {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.httpMethod = "POST"
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, resp) = try await ProviderHTTP.session.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    return .error("No HTTP response.")
                }
                if http.statusCode < 400 { return .ok }
                let errBody = (String(data: data, encoding: .utf8) ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                let low = errBody.lowercased()
                if http.statusCode == 404
                    || notFoundMarkers.contains(where: { low.contains($0) }) {
                    return .notFound(String(errBody.prefix(200)))
                }
                // "Ran out of budget" complaints mean the model exists
                // and RAN — the probe just starved it. That is a pass.
                let limitMarkers = ["output limit", "higher max_tokens",
                                    "must be at least", "minimum value"]
                if limitMarkers.contains(where: { low.contains($0) }) {
                    return .ok
                }
                last = .error("HTTP \(http.statusCode): \(String(errBody.prefix(200)))")
                // Fall through to the next body variant, if any.
            } catch {
                return .error(error.localizedDescription)
            }
        }
        return last
    }
}

// MARK: - Key check for providers with a public model list

/// Some providers (NVIDIA, Hugging Face, Venice) serve `/models` to an
/// INVALID key — 200 plus the full catalogue for a junk bearer. On
/// those providers a fetch that fills the list is not evidence that
/// anything was set up correctly, and the first proof the key is wrong
/// arrives one screen later, in a failed chat.
///
/// So the model the user actually picks is probed once, with the same
/// 16-token request `ModelVerifier` already makes.
enum ProviderKeyCheck {
    /// Whether this provider needs the probe at all.
    static func isNeeded(for provider: BuiltinProvider) -> Bool {
        provider.listsModelsWithoutAuth
    }

    /// A sentence to show when the key was REJECTED, else nil.
    ///
    /// Deliberately one-directional: only an auth-shaped rejection
    /// speaks up. A `notFound` is about the model, not the key; a
    /// timeout or a proxy hiccup is about the network; and crying wolf
    /// over a working key is worse than the silence this replaces,
    /// because the whole point is that the fetch already lied once.
    static func rejectionMessage(provider: BuiltinProvider, apiStyle: String,
                                 apiKey: String, modelId: String) async -> String? {
        guard !apiKey.isEmpty else { return nil }
        let verdict = await ModelVerifier.verify(provider: provider, apiStyle: apiStyle,
                                                 apiKey: apiKey, modelId: modelId)
        guard case .error(let detail) = verdict, looksLikeAuthFailure(detail) else {
            return nil
        }
        return String(localized: "\(provider.name) lists its models publicly, so the key was not checked until now — and it was rejected: \(detail)",
                      comment: "Model setup: the provider's public model list hid a bad API key")
    }

    private static func looksLikeAuthFailure(_ detail: String) -> Bool {
        let low = detail.lowercased()
        if low.contains("http 401") || low.contains("http 403") { return true }
        return ["invalid api key", "invalid_api_key", "incorrect api key",
                "unauthorized", "authentication", "invalid username",
                "permission_denied", "access denied"]
            .contains { low.contains($0) }
    }
}
