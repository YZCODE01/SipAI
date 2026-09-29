// Drives the REAL Agent Guide rules — extracted verbatim from
// AgentGuide.swift by run.sh — against the cases the plan pinned, then
// READS the shipping sources for the wiring a headless run cannot
// reach. Behind SIPAI_AGENTGUIDE_LIVE=1 it also drives the real codex
// app-server session and kimi's real local server under throwaway
// homes (token-free, nothing of the user's touched) and asks the real
// claude who it is signed in as.
import Foundation

var passed = 0
var failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("  ok   \(name)") }
    else { failed += 1; print("  FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)") }
}
func section(_ title: String) { print("\n\(title)") }

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../.."
func source(_ relative: String) -> String {
    (try? String(contentsOfFile: root + "/" + relative, encoding: .utf8)) ?? ""
}
func codeOnly(_ text: String) -> String {
    text.split(separator: "\n").map { line -> String in
        if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
        return String(line)
    }.joined(separator: "\n")
}
let home = "/Users/probe"

// MARK: 1. Presence

section("1. Presence — one rule, five answers, in precedence order")
check("not installed wins whatever else is known",
      AgentPresence.resolve(installed: false, verdict: .plan(name: "Max"), hidden: true) == .notInstalled)
check("installed with no read yet is pending",
      AgentPresence.resolve(installed: true, verdict: nil, hidden: false) == .pending)
check("pending even when hidden — the first frame draws nothing for it",
      AgentPresence.resolve(installed: true, verdict: nil, hidden: true) == .pending)
check("a read that never settled reads as not signed in",
      AgentPresence.resolve(installed: true, verdict: .unknown, hidden: false) == .notSignedIn)
check("signed out is not signed in",
      AgentPresence.resolve(installed: true, verdict: .signedOut, hidden: false) == .notSignedIn)
check("hidden AND signed out reads as signed out — the ADD row is owed, the checkbox waits",
      AgentPresence.resolve(installed: true, verdict: .signedOut, hidden: true) == .notSignedIn)
check("a plan is listed", AgentPresence.resolve(installed: true, verdict: .plan(name: nil), hidden: false) == .listed)
check("an API key is listed", AgentPresence.resolve(installed: true, verdict: .apiKey, hidden: false) == .listed)
check("hidden and signed in is hidden", AgentPresence.resolve(installed: true, verdict: .apiKey, hidden: true) == .hiddenByUser)
check("only .listed answers isListed",
      AgentPresence.listed.isListed && !AgentPresence.hiddenByUser.isListed && !AgentPresence.pending.isListed)
check("carry keeps the last settled answer over a fresh unknown",
      AgentPresence.carry(previous: .plan(name: "Max"), fresh: .unknown) == .plan(name: "Max"))
check("carry takes a fresh settled answer", AgentPresence.carry(previous: .plan(name: nil), fresh: .signedOut) == .signedOut)
check("carry with nothing to carry stays unknown", AgentPresence.carry(previous: nil, fresh: .unknown) == .unknown)

// MARK: 2. The ADD row

section("2. The ADD row's label")
check("nothing owed when every agent is listed",
      AgentAddRow.label(presences: [.listed, .listed, .listed]) == nil)
check("nothing owed when the only non-listed agent is hidden",
      AgentAddRow.label(presences: [.listed, .hiddenByUser, .listed]) == nil)
check("ADD AGENTS when none is usable", AgentAddRow.label(presences: [.notInstalled, .notInstalled, .notInstalled]) == .addAgents)
check("ADD AGENTS when none is usable and one is signed out",
      AgentAddRow.label(presences: [.notInstalled, .notSignedIn, .notInstalled]) == .addAgents)
check("ADD MORE AGENTS when some are listed", AgentAddRow.label(presences: [.listed, .notInstalled, .listed]) == .addMoreAgents)
check("ADD MORE AGENTS when a listed agent stands beside a signed-out one",
      AgentAddRow.label(presences: [.listed, .notSignedIn, .listed]) == .addMoreAgents)
check("a hidden agent counts as usable", AgentAddRow.label(presences: [.hiddenByUser, .notInstalled, .hiddenByUser]) == .addMoreAgents)
check("nothing is drawn while any agent is pending",
      AgentAddRow.label(presences: [.pending, .notInstalled, .notInstalled]) == nil)

// MARK: 3. Parsers

section("3. claude auth status --json")
let measured = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","analyticsDisabled":false,"projectsDirectory":"/Users/x/.claude/projects","configDirectory":"/Users/x/.claude","email":"someone@example.com","orgId":"o","orgName":"n","subscriptionType":"max"}"#
let status = ClaudeAuthStatus.parse(Data(measured.utf8))
check("the measured answer parses", status != nil)
check("a claude.ai login is a plan named by its tier", status?.verdict == .plan(name: "Max"))
check("the e-mail is not carried", Mirror(reflecting: status!).children.map { $0.label ?? "" }.contains("email") == false)
check("signed out is signed out",
      ClaudeAuthStatus.parse(Data(#"{"loggedIn":false}"#.utf8))?.verdict == .signedOut)
check("a Console login is the API-billed account",
      ClaudeAuthStatus.parse(Data(#"{"loggedIn":true,"authMethod":"console","apiProvider":"firstParty"}"#.utf8))?.verdict == .apiKey)
check("a cloud provider login bills that provider",
      ClaudeAuthStatus.parse(Data(#"{"loggedIn":true,"authMethod":"other","apiProvider":"bedrock"}"#.utf8))?.verdict == .apiKey)
check("an unknown method is not judged",
      ClaudeAuthStatus.parse(Data(#"{"loggedIn":true,"authMethod":"other","apiProvider":"firstParty"}"#.utf8))?.verdict == .unknown)
check("not JSON is nil", ClaudeAuthStatus.parse(Data("Warning: something".utf8)) == nil)
// Measured 2.1.277 with ANTHROPIC_API_KEY in the environment: the OAuth
// login still reads as present, `subscriptionType` is null, and
// `apiKeySource` names the key — which is what runs.
let keyed = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","apiKeySource":"ANTHROPIC_API_KEY","subscriptionType":null,"email":"someone@example.com"}"#
check("an API key in force outranks the login beside it",
      ClaudeAuthStatus.parse(Data(keyed.utf8))?.verdict == .apiKey)
check("an empty apiKeySource is no key",
      ClaudeAuthStatus.parse(Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","apiKeySource":"","subscriptionType":"pro"}"#.utf8))?.verdict == .plan(name: "Pro"))

section("3b. kimi's server envelopes (measured 2.0.1)")
let kimiStart = #"{"code":0,"msg":"success","data":{"flow_id":"oauth_748751c1","provider":"managed:kimi-code","verification_uri":"https://www.kimi.com/code/authorize_device","verification_uri_complete":"https://www.kimi.com/code/authorize_device?user_code=RQR7-4F1U","user_code":"RQR7-4F1U","expires_in":1800,"interval":5,"status":"pending","expires_at":"2026-09-20T12:05:50.663Z"},"request_id":"01M2Z9KP"}"#
let start = KimiServerAnswer.loginStart(body: Data(kimiStart.utf8))
check("the start answer parses", start != nil)
check("status, code, URL, interval", start?.status == "pending" && start?.userCode == "RQR7-4F1U"
      && start?.verificationUriComplete == "https://www.kimi.com/code/authorize_device?user_code=RQR7-4F1U" && start?.interval == 5)
check("an already-authenticated start reads as such",
      KimiServerAnswer.loginStart(body: Data(#"{"code":0,"msg":"success","data":{"status":"authenticated","flow_id":"x","provider":"managed:kimi-code"}}"#.utf8))?.status == "authenticated")
check("the poll parses", KimiServerAnswer.loginPoll(body: Data(#"{"code":0,"msg":"success","data":{"flow_id":"x","status":"pending","resolved_at":null,"error_message":null}}"#.utf8))
      == KimiServerAnswer.LoginPoll(status: "pending", errorMessage: nil))
check("userinfo's error envelope is signed out",
      KimiServerAnswer.userInfoVerdict(body: Data(#"{"code":0,"msg":"success","data":{"kind":"error","message":"No token for \"kimi-code\". Run /login to authenticate."}}"#.utf8)) == .signedOut)
check("userinfo with data is a membership",
      KimiServerAnswer.userInfoVerdict(body: Data(#"{"code":0,"msg":"success","data":{"kind":"user","name":"x"}}"#.utf8)) == .plan(name: nil))
check("a non-zero code is not the envelope", KimiServerAnswer.data(in: Data(#"{"code":50001,"msg":"Body cannot be empty","data":null}"#.utf8)) == nil)
check("the region parses", KimiServerAnswer.region(body: Data(#"{"code":0,"msg":"success","data":{"region":"mainland-cn"}}"#.utf8)) == "mainland-cn")

section("3c. kimi config.toml providers with a key")
let kimiConfig = """
default_model = "moonshot-ai/kimi-k3"

[providers.moonshot-ai]
type = "openai"
api_key = "sk-abc"

[providers."managed:kimi-code"]
type = "kimi"
[providers."managed:kimi-code".oauth]
key = "oauth/kimi-code"

[providers.empty]
api_key = ""

[models."moonshot-ai/kimi-k3"]
provider = "moonshot-ai"
"""
check("only the provider tables carrying a non-empty api_key",
      KimiConfigProviders.apiKeyProviderIds(configText: kimiConfig) == ["moonshot-ai"])
let subTabled = """
[providers."managed:kimi-code"]
type = "kimi"
[providers."managed:kimi-code".oauth]
api_key = "not-the-provider's"
[providers."moonshotai/keyed"]
api_key = "sk-1"
[providers."moonshotai/keyed".extra]
api_key = "sk-2"
[providers.bare.sub]
api_key = "sk-3"
"""
check("a quoted id's sub-table is not the provider, and a keyed one lists once",
      KimiConfigProviders.apiKeyProviderIds(configText: subTabled) == ["moonshotai/keyed"])
// The row names the platform the key kimi RUNS on: the provider of the
// model `default_model` names, else the only keyed provider.
let twoKeys = """
default_model = "moonshotai-cn/kimi-k2.6"

[providers.moonshotai]
base_url = "https://api.moonshot.ai/v1"
api_key = "sk-a"

[providers.moonshotai-cn]
base_url = "https://api.moonshot.cn/v1/"
api_key = "sk-c"

[models."moonshotai-cn/kimi-k2.6"]
provider = "moonshotai-cn"
"""
check("the key kimi runs on is the default model's provider's",
      KimiConfigProviders.keyedBaseURL(configText: twoKeys) == "https://api.moonshot.cn/v1/")
check("…and its platform is named by kimi's catalog (case and a trailing slash aside)",
      AgentSignIn.kimiKeyPlatform(forBaseURL: "HTTPS://api.moonshot.cn/v1/") == "platform.moonshot.cn"
      && AgentSignIn.kimiKeyPlatform(forBaseURL: "https://api.kimi.ai/coding/v1") == "kimi.ai")
check("a base the catalog does not know is named by its host",
      AgentSignIn.kimiKeyPlatform(forBaseURL: "https://gateway.example.com/v1") == "gateway.example.com")
check("two keyed providers and no default model: no guess",
      KimiConfigProviders.keyedBaseURL(configText: twoKeys.replacingOccurrences(of: "default_model = \"moonshotai-cn/kimi-k2.6\"", with: "")) == nil)
check("one keyed provider: that one, whatever the default model runs",
      KimiConfigProviders.keyedBaseURL(configText: """
default_model = "managed:kimi-code/kimi-for-coding"
[providers."managed:kimi-code"]
base_url = "https://api.kimi.com/coding/v1"
[providers."managed:kimi-code".oauth]
key = "oauth/kimi-code"
[providers.moonshotai]
base_url = "https://api.moonshot.ai/v1"
api_key = "sk-a"
""") == "https://api.moonshot.ai/v1")
check("a default_model inside a table is not the top-level one",
      KimiConfigProviders.keyedBaseURL(configText: "[thinking]\ndefault_model = \"x\"\n") == nil)

section("3d. kimi's catalog listing (measured 2.0.1)")
let listing = """
Moonshot AI (moonshotai)
  kimi-k2.7-code-highspeed  ctx=262144 [tool_use,thinking,image_in]
  kimi-k2.6  ctx=262144 [tool_use,thinking,image_in]
	kimi-k3  ctx=1048576 [tool_use,thinking,image_in]

"""
check("the model ids are the indented lines' first tokens, in order",
      KimiCatalogListing.modelIds(from: listing) == ["kimi-k2.7-code-highspeed", "kimi-k2.6", "kimi-k3"])
check("the header line is not an id", !KimiCatalogListing.modelIds(from: listing).contains("Moonshot"))
check("a refusal lists nothing", KimiCatalogListing.modelIds(from: "Provider \"nope\" not found in the catalog.").isEmpty)
check("a duplicate id is listed once",
      KimiCatalogListing.modelIds(from: "P (p)\n  a  ctx=1\n  a  ctx=1\n") == ["a"])

section("3e. Terminal output shown as words")
let esc = "\u{1B}"
check("CSI colours go", TerminalText.strippingEscapes("\(esc)[1m\(esc)[38;5;208mOpening\(esc)[0m browser") == "Opening browser")
check("an OSC 8 hyperlink ended by BEL keeps its text",
      TerminalText.strippingEscapes("visit \(esc)]8;;https://claude.com/x\u{07}https://claude.com/x\(esc)]8;;\u{07} now") == "visit https://claude.com/x now")
check("an OSC ended by ESC backslash goes whole",
      TerminalText.strippingEscapes("a\(esc)]0;title\(esc)\\b") == "ab")
check("a lone ESC at the end is dropped", TerminalText.strippingEscapes("done\(esc)") == "done")
check("a two-byte escape drops one byte", TerminalText.strippingEscapes("x\(esc)cy") == "xy")
check("plain text is untouched, non-ASCII included", TerminalText.strippingEscapes("登录 — ok ✓") == "登录 — ok ✓")

section("3f. A probe never downgrades a file-layer API key")
check("kimi's \"No token\" beside a key provider keeps the key",
      AgentAccountProbe.reconcile(file: .apiKey, probe: .signedOut) == .apiKey)
check("signed out beside no key is signed out",
      AgentAccountProbe.reconcile(file: .signedOut, probe: .signedOut) == .signedOut)
check("a membership the probe found beside a key is the membership",
      AgentAccountProbe.reconcile(file: .apiKey, probe: .plan(name: nil)) == .plan(name: nil))
check("a membership signed out in a terminal is signed out",
      AgentAccountProbe.reconcile(file: .plan(name: nil), probe: .signedOut) == .signedOut)
check("the probe's plan name wins over the file's",
      AgentAccountProbe.reconcile(file: .plan(name: nil), probe: .plan(name: "Max")) == .plan(name: "Max"))

// MARK: 4. Install source, delete plan, install route

section("4. Install source over synthetic layouts")
func detect(_ key: String, _ link: String, _ resolved: String, kimi: String? = nil,
            kimiHome: String? = nil) -> AgentInstallSource {
    AgentInstallSource.detect(agentKey: key, binaryPath: link, resolvedPath: resolved, home: home,
                              kimiInstallSource: kimi, kimiHome: kimiHome)
}
check("claude native", detect("claude_code", home + "/.local/bin/claude", home + "/.local/share/claude/versions/2.1.277")
      == .native(directory: home + "/.local/share/claude"))
check("claude npm under Homebrew's node", detect("claude_code", "/opt/homebrew/bin/claude", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js")
      == .npm(prefix: "/opt/homebrew", package: "@anthropic-ai/claude-code"))
check("claude npm under a user prefix", detect("claude_code", home + "/.npm-global/bin/claude", home + "/.npm-global/lib/node_modules/@anthropic-ai/claude-code/cli.js")
      == .npm(prefix: home + "/.npm-global", package: "@anthropic-ai/claude-code"))
check("claude brew cask", detect("claude_code", "/opt/homebrew/bin/claude", "/opt/homebrew/Caskroom/claude-code/2.1.267/claude")
      == .brew(prefix: "/opt/homebrew", cask: "claude-code"))
check("claude elsewhere is unknown", detect("claude_code", "/usr/local/bin/claude", "/usr/local/bin/claude") == .unknown(path: "/usr/local/bin/claude"))
check("codex SipAI-owned", detect("codex", home + "/.local/bin/codex", home + "/.local/share/sipai/codex/0.155.1/bin/codex")
      == .sipai(directory: home + "/.local/share/sipai/codex"))
check("codex npm (this Mac's layout)", detect("codex", "/opt/homebrew/bin/codex", "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex")
      == .npm(prefix: "/opt/homebrew", package: "@openai/codex"))
check("codex brew cask", detect("codex", "/opt/homebrew/bin/codex", "/opt/homebrew/Caskroom/codex/0.155.1/bin/codex")
      == .brew(prefix: "/opt/homebrew", cask: "codex"))
// Claude's second cask tracks npm's `latest` where `claude-code` tracks
// `stable` (each livecheck reads that channel's version file). Detected
// by its own name, so Delete names it and the update row knows Homebrew
// manages it.
check("claude brew cask @latest", detect("claude_code", "/opt/homebrew/bin/claude", "/opt/homebrew/Caskroom/claude-code@latest/2.1.283/claude")
      == .brew(prefix: "/opt/homebrew", cask: "claude-code@latest"))
// Native means kimi's OWN home and nothing else: the record says
// "native" but names no directory, and Delete removes the whole `bin`
// of whatever directory is answered — a copy of the binary in a shared
// bin would otherwise take `/usr/local/bin` or `~/.local/bin` with it.
check("kimi native by its record, in its home", detect("kimi", home + "/.kimi-code/bin/kimi", home + "/.kimi-code/bin/kimi", kimi: "native") == .native(directory: home + "/.kimi-code"))
check("kimi native by the default layout with no record", detect("kimi", home + "/.kimi-code/bin/kimi", home + "/.kimi-code/bin/kimi") == .native(directory: home + "/.kimi-code"))
check("kimi under a foreign directory with no record is unknown", detect("kimi", "/opt/kimi/bin/kimi", "/opt/kimi/bin/kimi") == .unknown(path: "/opt/kimi/bin/kimi"))
check("kimi under a foreign directory is unknown EVEN when the record says native", detect("kimi", "/opt/kimi/bin/kimi", "/opt/kimi/bin/kimi", kimi: "native") == .unknown(path: "/opt/kimi/bin/kimi"))
check("a kimi copy in a shared bin never reads as native", detect("kimi", "/usr/local/bin/kimi", "/usr/local/bin/kimi", kimi: "native") == .unknown(path: "/usr/local/bin/kimi"))
check("a moved home (KIMI_CODE_HOME) is honoured", detect("kimi", "/Volumes/Work/kimi/bin/kimi", "/Volumes/Work/kimi/bin/kimi", kimi: "native", kimiHome: "/Volumes/Work/kimi/") == .native(directory: "/Volumes/Work/kimi"))
check("a binary in kimi's home whose record names another route is not native", detect("kimi", home + "/.kimi-code/bin/kimi", home + "/.kimi-code/bin/kimi", kimi: "npm") == .unknown(path: home + "/.kimi-code/bin/kimi"))
check("kimi npm", detect("kimi", "/opt/homebrew/bin/kimi", "/opt/homebrew/lib/node_modules/@moonshot-ai/kimi-code/bin/kimi.js")
      == .npm(prefix: "/opt/homebrew", package: "@moonshot-ai/kimi-code"))
// Homebrew's kimi-code formula runs `npm install` INTO the Cellar and
// links bin/kimi from libexec (the formula: `libexec/"lib/node_modules/
// @moonshot-ai/kimi-code"`, `bin.install_symlink Dir[libexec/"bin/*"]`),
// so the resolved binary carries BOTH markers. Read as npm, the prefix
// is libexec, whose bin/npm does not exist — a Delete that could only
// fail. The Cellar is checked first.
check("kimi brew formula wins over the npm layout inside it",
      detect("kimi", "/opt/homebrew/bin/kimi", "/opt/homebrew/Cellar/kimi-code/2.1.1/libexec/lib/node_modules/@moonshot-ai/kimi-code/bin/kimi.js")
      == .brewFormula(prefix: "/opt/homebrew", formula: "kimi-code"))
check("…under an Intel prefix too",
      detect("kimi", "/usr/local/bin/kimi", "/usr/local/Cellar/kimi-code/2.1.1/libexec/lib/node_modules/@moonshot-ai/kimi-code/bin/kimi.js")
      == .brewFormula(prefix: "/usr/local", formula: "kimi-code"))
// Whose updater declines the install, read out of each CLI's update
// code: `claude update` on Homebrew prints "Claude is managed by
// Homebrew." and runs nothing; kimi's `canAutoInstall("homebrew")` is
// false. Codex's cask is `codex update`'s own (`brew upgrade --cask
// codex`), npm is every updater's own, SipAI's codex is SipAI's.
check("Homebrew's claude and kimi are managed by Homebrew",
      AgentInstallSource.brew(prefix: "/opt/homebrew", cask: "claude-code").managedBy(agentKey: "claude_code") == "Homebrew"
      && AgentInstallSource.brew(prefix: "/opt/homebrew", cask: "claude-code@latest").managedBy(agentKey: "claude_code") == "Homebrew"
      && AgentInstallSource.brewFormula(prefix: "/opt/homebrew", formula: "kimi-code").managedBy(agentKey: "kimi") == "Homebrew")
check("codex's cask, every npm install, SipAI's codex and the native installs are the updater's own",
      AgentInstallSource.brew(prefix: "/opt/homebrew", cask: "codex").managedBy(agentKey: "codex") == nil
      && AgentInstallSource.npm(prefix: "/opt/homebrew", package: "@anthropic-ai/claude-code").managedBy(agentKey: "claude_code") == nil
      && AgentInstallSource.npm(prefix: "/opt/homebrew", package: "@moonshot-ai/kimi-code").managedBy(agentKey: "kimi") == nil
      && AgentInstallSource.sipai(directory: home + "/.local/share/sipai/codex").managedBy(agentKey: "codex") == nil
      && AgentInstallSource.native(directory: home + "/.kimi-code").managedBy(agentKey: "kimi") == nil
      && AgentInstallSource.native(directory: home + "/.local/share/claude").managedBy(agentKey: "claude_code") == nil
      && AgentInstallSource.unknown(path: "/x/kimi").managedBy(agentKey: "kimi") == nil)

section("4b. Delete plans")
let claudeNative = AgentDeletePlan.make(agentKey: "claude_code", source: .native(directory: home + "/.local/share/claude"), home: home)
check("claude native removes the launcher and the versions tree, nothing under ~/.claude",
      claudeNative == [.remove(path: home + "/.local/bin/claude"), .remove(path: home + "/.local/share/claude")])
check("codex SipAI-owned removes the link and the SipAI tree",
      AgentDeletePlan.make(agentKey: "codex", source: .sipai(directory: home + "/.local/share/sipai/codex"), home: home)
      == [.remove(path: home + "/.local/bin/codex"), .remove(path: home + "/.local/share/sipai/codex")])
check("kimi native removes bin/ alone",
      AgentDeletePlan.make(agentKey: "kimi", source: .native(directory: home + "/.kimi-code"), home: home) == [.remove(path: home + "/.kimi-code/bin")])
check("npm runs the npm that OWNS the prefix",
      AgentDeletePlan.make(agentKey: "codex", source: .npm(prefix: "/opt/homebrew", package: "@openai/codex"), home: home)
      == [.run(binary: "/opt/homebrew/bin/npm", arguments: ["uninstall", "-g", "@openai/codex"])])
check("brew runs uninstall --cask with neither --zap nor --force",
      AgentDeletePlan.make(agentKey: "claude_code", source: .brew(prefix: "/opt/homebrew", cask: "claude-code"), home: home)
      == [.run(binary: "/opt/homebrew/bin/brew", arguments: ["uninstall", "--cask", "claude-code"])])
check("the @latest cask is removed under its own name",
      AgentDeletePlan.make(agentKey: "claude_code", source: .brew(prefix: "/opt/homebrew", cask: "claude-code@latest"), home: home)
      == [.run(binary: "/opt/homebrew/bin/brew", arguments: ["uninstall", "--cask", "claude-code@latest"])])
check("a formula runs uninstall without --cask — and without --zap or --force",
      AgentDeletePlan.make(agentKey: "kimi", source: .brewFormula(prefix: "/opt/homebrew", formula: "kimi-code"), home: home)
      == [.run(binary: "/opt/homebrew/bin/brew", arguments: ["uninstall", "kimi-code"])])
check("unknown has no plan", AgentDeletePlan.make(agentKey: "codex", source: .unknown(path: "/x"), home: home) == nil)
let everyPlan = [claudeNative!,
                 AgentDeletePlan.make(agentKey: "codex", source: .sipai(directory: home + "/.local/share/sipai/codex"), home: home)!,
                 AgentDeletePlan.make(agentKey: "kimi", source: .native(directory: home + "/.kimi-code"), home: home)!]
check("no plan removes a session store",
      !everyPlan.joined().contains { step in
          if case .remove(let path) = step { return path.hasSuffix("/.claude") || path.hasSuffix("/.codex") || path == home + "/.kimi-code" }
          return false
      })

section("4c. Install routes")
check("claude: Anthropic's installer", AgentInstallRoute.route(agentKey: "claude_code") == .script(URL(string: "https://claude.ai/install.sh")!))
// One kimi installer, whatever the site: Moonshot's two scripts differ only
// in their download host and both channels publish the same manifest (the
// same binaries, the same checksums) — the site is asked on Sign In.
check("kimi: Moonshot's installer, from the mainland channel — no site to pick",
      AgentInstallRoute.route(agentKey: "kimi") == .script(URL(string: "https://code.kimi.com/kimi-code/install.sh")!)
      && AgentInstallRoute.route(agentKey: "kimi") == .script(KimiSite.mainlandCN.installer))
check("codex: OpenAI's package", AgentInstallRoute.route(agentKey: "codex") == .package)
check("a fourth agent has none", AgentInstallRoute.route(agentKey: "other") == nil)
// Moonshot's installer edits the shell's rc file only when its bin is
// NOT already on PATH (`_update_path`: `case ":$PATH:" in
// *":${KIMI_INSTALL_DIR}/bin:"*) return`), and the PATH a SipAI child
// gets always carries ~/.kimi-code/bin — a built-in search path, there
// whether or not kimi is installed. Under it the installer wrote no
// line (measured): SipAI found kimi, Terminal did not. The Guide hands
// the installer Terminal's view of that directory.
let childPATH = "/usr/local/bin:/usr/bin:/opt/homebrew/bin:\(home)/.local/bin:\(home)/.kimi-code/bin:\(home)/.kimi/bin:/usr/sbin:/sbin:/bin"
check("kimi's install: SipAI's own guesses for kimi's bin leave the installer's PATH",
      AgentInstallRoute.kimiInstallerEnvironment(childPATH: childPATH, loginShellPath: ["/usr/bin", "/bin"], home: home)["PATH"]
      == "/usr/local/bin:/usr/bin:/opt/homebrew/bin:\(home)/.local/bin:/usr/sbin:/sbin:/bin")
check("…and stay when the login shell has them — Terminal sees kimi already, so the installer's skip is right",
      AgentInstallRoute.kimiInstallerEnvironment(childPATH: childPATH, loginShellPath: ["/usr/bin", home + "/.kimi-code/bin"], home: home)["PATH"]
      == "/usr/local/bin:/usr/bin:/opt/homebrew/bin:\(home)/.local/bin:\(home)/.kimi-code/bin:/usr/sbin:/sbin:/bin")
check("…an empty capture (the shell not read yet) still takes them out — never a skip on SipAI's guess",
      AgentInstallRoute.kimiInstallerEnvironment(childPATH: childPATH, loginShellPath: [], home: home)["PATH"]?.contains(".kimi") == false)
check("…and every other entry stays, in order",
      AgentInstallRoute.kimiInstallerEnvironment(childPATH: "/a:/b:/opt/homebrew/bin", loginShellPath: [], home: home)["PATH"] == "/a:/b:/opt/homebrew/bin")

// MARK: 5. Sign-in routes

section("5. Sign-in routes and hosts")
let claudeRoutes = AgentSignIn.routes(agentKey: "claude_code")
check("claude: two account routes, no key paste, one host each (measured under a PTY)",
      claudeRoutes.map(\.method) == [.subscription, .console]
      && claudeRoutes[0].host == "claude.com" && claudeRoutes[1].host == "platform.claude.com")
check("codex: ChatGPT or a key", AgentSignIn.routes(agentKey: "codex").map(\.method) == [.subscription, .apiKey]
      && AgentSignIn.routes(agentKey: "codex")[0].host == "auth.openai.com")
check("kimi: membership per region, or a key",
      AgentSignIn.routes(agentKey: "kimi", kimiRegion: "global")[0].host == "www.kimi.ai"
      && AgentSignIn.routes(agentKey: "kimi")[0].host == "www.kimi.com")
check("claude's argv per route", AgentSignIn.claudeArguments(method: .subscription) == ["auth", "login"]
      && AgentSignIn.claudeArguments(method: .console) == ["auth", "login", "--console"])
check("the measured codex authUrl matches its host",
      AgentSignIn.hostMatches(URL(string: "https://auth.openai.com/oauth/authorize?response_type=code&client_id=x")!, expected: "auth.openai.com"))
check("a lookalike host is refused", !AgentSignIn.hostMatches(URL(string: "https://auth.openai.com.evil.example/x")!, expected: "auth.openai.com"))
check("http is refused", !AgentSignIn.hostMatches(URL(string: "http://auth.openai.com/x")!, expected: "auth.openai.com"))
check("kimi's four key providers are kimi's own ids",
      AgentSignIn.kimiKeyProviders.map(\.id) == ["moonshotai", "moonshotai-cn", "kimi-code-plan-global", "kimi-code-plan-cn"])
check("the key is scrubbed from a tail", AgentSignIn.scrubbed("error: sk-abc123 rejected", secret: "sk-abc123") == "error: •••• rejected")

// MARK: 5b. Kimi's two sites

section("5b. Kimi's two sites — kimi.com (mainland-cn) and kimi.ai (global)")
check("kimi's region ids are read, the marker file's newline included",
      KimiSite(region: "mainland-cn") == .mainlandCN && KimiSite(region: "global\n") == .global)
check("an answer SipAI does not recognise presets nothing",
      KimiSite(region: "moon") == nil && KimiSite(region: nil) == nil && KimiSite(region: "") == nil)
check("each site's sign-in page, as kimi's own region profiles spell it",
      KimiSite.mainlandCN.signInHost == "www.kimi.com" && KimiSite.global.signInHost == "www.kimi.ai")
check("the route host follows the site; an unknown region is kimi's own default",
      AgentSignIn.kimiHost(region: "global") == "www.kimi.ai" && AgentSignIn.kimiHost(region: "x") == "www.kimi.com")
check("each site's installer channel",
      KimiSite.mainlandCN.installer.absoluteString == "https://code.kimi.com/kimi-code/install.sh"
      && KimiSite.global.installer.absoluteString == "https://code.kimi.ai/kimi-code/install.sh")
check("the update route accepts exactly the two sites' installers (kimi names its own site's)",
      Set(KimiSite.installers) == Set(AgentCLIRelease.measured(agentKey: "kimi")!.nativeInstallers))
check("a site lists only its own key providers",
      KimiSite.mainlandCN.keyProviders.map(\.id) == ["moonshotai-cn", "kimi-code-plan-cn"]
      && KimiSite.global.keyProviders.map(\.id) == ["moonshotai", "kimi-code-plan-global"])
check("every key provider's API base is on its own site",
      AgentSignIn.kimiKeyProviders.allSatisfy { p in
          let host = URL(string: p.apiBase)?.host ?? ""
          return p.site == .mainlandCN ? (host.hasSuffix(".cn") || host.hasSuffix("kimi.com"))
                                       : (host.hasSuffix(".ai"))
      })

// MARK: 6. Codex package

section("6. OpenAI's package: asset, digest, layout, rc line")
check("arm64 → aarch64 asset", CodexPackageInstall.asset(machine: "arm64") == "codex-package-aarch64-apple-darwin.tar.gz")
check("x86_64 asset", CodexPackageInstall.asset(machine: "x86_64") == "codex-package-x86_64-apple-darwin.tar.gz")
check("an unknown machine has none", CodexPackageInstall.asset(machine: "riscv") == nil)
check("this Mac's architecture is one of the two", ["arm64", "x86_64"].contains(CodexPackageInstall.machineArchitecture()))
check("the URLs follow the rust-v tag",
      CodexPackageInstall.assetURL(version: "0.155.1", asset: "a.tar.gz")?.absoluteString == "https://github.com/openai/codex/releases/download/rust-v0.155.1/a.tar.gz"
      && CodexPackageInstall.sumsURL(version: "0.155.1")?.absoluteString == "https://github.com/openai/codex/releases/download/rust-v0.155.1/codex-package_SHA256SUMS")
let sums = """
328e5a416bf64f96e3162439c8c39819c164f1a9cff983ca6f09eb3af90bd760  codex-app-server-package-aarch64-apple-darwin.tar.gz
e6e08717da9e35b72332eff753527fe79a9ae876081033c5c6820a8e5f58b943  codex-package-aarch64-apple-darwin.tar.gz
f53deb24650d288fddfd1724ef952f6ad9cb6119c75ecc12a6223b98fd97719a  codex-package-aarch64-pc-windows-msvc.tar.gz
"""
check("the digest on the asset's own line (measured 0.155.1)",
      CodexPackageInstall.expectedDigest(sums: sums, asset: "codex-package-aarch64-apple-darwin.tar.gz") == "e6e08717da9e35b72332eff753527fe79a9ae876081033c5c6820a8e5f58b943")
check("a similarly named asset does not match", CodexPackageInstall.expectedDigest(sums: sums, asset: "package-aarch64-apple-darwin.tar.gz") == nil)
check("a malformed digest is refused", CodexPackageInstall.expectedDigest(sums: "zz  x.tar.gz\n", asset: "x.tar.gz") == nil)
let layout = CodexPackageInstall.layout(home: home, version: "0.155.1")
check("the layout: root, version dir, dot-prefixed staging, the link",
      layout.root == home + "/.local/share/sipai/codex" && layout.versionDirectory == home + "/.local/share/sipai/codex/0.155.1"
      && layout.staging == home + "/.local/share/sipai/codex/.0.155.1-staging" && layout.link == home + "/.local/bin/codex")
let manifest = #"{"layoutVersion":1,"version":"0.155.1","target":"aarch64-apple-darwin","variant":"codex","entrypoint":"bin/codex","resourcesDir":"codex-resources","pathDir":"codex-path"}"#
check("the measured manifest parses", CodexPackageInstall.manifest(Data(manifest.utf8))?.entrypoint == "bin/codex")
check("an absolute or escaping entrypoint is refused",
      CodexPackageInstall.manifest(Data(#"{"version":"1","entrypoint":"/bin/sh"}"#.utf8)) == nil
      && CodexPackageInstall.manifest(Data(#"{"version":"1","entrypoint":"../x"}"#.utf8)) == nil)
let exists: (String) -> Bool = { $0.hasSuffix(".bashrc") }
check("zsh → .zshrc", CodexPackageInstall.rcFile(shell: "/bin/zsh", home: home, exists: exists)?.path == home + "/.zshrc")
check("bash → .bashrc when it exists", CodexPackageInstall.rcFile(shell: "/bin/bash", home: home, exists: exists)?.path == home + "/.bashrc")
check("bash → .profile when only that exists", CodexPackageInstall.rcFile(shell: "/bin/bash", home: home, exists: { $0.hasSuffix(".profile") })?.path == home + "/.profile")
check("fish → config.fish with fish_add_path", CodexPackageInstall.rcFile(shell: "/opt/homebrew/bin/fish", home: home, exists: exists)?.line == CodexPackageInstall.fishLine)
check("an unknown shell edits nothing", CodexPackageInstall.rcFile(shell: "/bin/tcsh", home: home, exists: exists) == nil)
check("an EMPTY capture never appends", !CodexPackageInstall.needsRCLine(loginShellPath: [], rcText: nil, home: home))
check("on the captured PATH → no line", !CodexPackageInstall.needsRCLine(loginShellPath: ["/usr/bin", home + "/.local/bin"], rcText: nil, home: home))
check("named in the rc file → no line", !CodexPackageInstall.needsRCLine(loginShellPath: ["/usr/bin"], rcText: "export PATH=\"$HOME/.local/bin:$PATH\"", home: home))
check("otherwise the line is owed", CodexPackageInstall.needsRCLine(loginShellPath: ["/usr/bin"], rcText: "# nothing", home: home))

// MARK: 6b. Signatures

section("6b. OpenAI's package: every executable signed by OpenAI's team, asked as a requirement")
let signScratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("sipai-guide-sig-\(UUID().uuidString)").path

/// A package directory holding `files` (relative path → source file to
/// copy, or nil for a shell script), each executable.
func makePackage(_ name: String, _ files: [String: String?]) -> String {
    let root = signScratch + "/" + name
    for (relative, source) in files {
        let path = root + "/" + relative
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if let source {
            try? FileManager.default.copyItem(atPath: source, toPath: path)
        } else {
            try? "#!/bin/sh\necho 'codex-cli 0.155.1'\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
        chmod(path, 0o755)
    }
    return root
}

/// Ad-hoc signs `path` with an identifier that carries a second line
/// reading like OpenAI's team — what a reader of `codesign -dv` text
/// would take for the team.
func forgeSignature(_ path: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    p.arguments = ["-s", "-", "-f", "-i", "com.example\nTeamIdentifier=\(CodexPackageInstall.expectedTeamIdentifier)", path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

func signatureProblem(_ root: String, entrypoint: String = "bin/codex") -> String? {
    let semaphore = DispatchSemaphore(value: 0)
    var answer: String?
    Task {
        answer = await CodexPackageInstall.signatureProblem(packageRoot: root, entrypoint: entrypoint)
        semaphore.signal()
    }
    semaphore.wait()
    return answer
}

check("a Mach-O file reads as one", CodexPackageInstall.isMachO(atPath: "/usr/bin/true"))
check("a script does not", !CodexPackageInstall.isMachO(atPath: "/etc/hosts"))

let forged = makePackage("forged", ["bin/codex": "/usr/bin/true"])
let forgedSigned = forgeSignature(forged + "/bin/codex")
check("the forged fixture is ad-hoc signed with a team line in its identifier", forgedSigned)
let forgedAnswer = signatureProblem(forged)
check("an ad-hoc signature that SAYS OpenAI's team is refused, naming the file",
      forgedAnswer?.contains("bin/codex") == true, forgedAnswer ?? "accepted")

let scripted = makePackage("script", ["bin/codex": nil])
let scriptAnswer = signatureProblem(scripted)
check("a script entrypoint is refused — it has no signature to ask for",
      scriptAnswer?.contains("bin/codex") == true, scriptAnswer ?? "accepted")

let linked = makePackage("linked", ["bin/codex": "/usr/bin/true"])
try? FileManager.default.createSymbolicLink(atPath: linked + "/bin/rg", withDestinationPath: "/usr/bin/true")
let linkAnswer = signatureProblem(linked)
check("a symbolic link anywhere in the package is refused, naming it",
      linkAnswer?.contains("symbolic link") == true && linkAnswer?.contains("bin/rg") == true,
      linkAnswer ?? "accepted")

// A genuine OpenAI-signed executable, if this Mac has one: any codex
// install carries `codex-path/rg`, signed by the same team.
let genuineCandidates = [
    "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-path/rg",
    "/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/codex-path/rg",
] + ((try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.local/share/sipai/codex")) ?? [])
    .filter { !$0.hasPrefix(".") }
    .map { NSHomeDirectory() + "/.local/share/sipai/codex/\($0)/codex-path/rg" }
if let genuine = genuineCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
    let clean = makePackage("genuine", ["bin/codex": genuine, "codex-path/rg": genuine])
    let cleanAnswer = signatureProblem(clean)
    check("a package signed by OpenAI's team throughout is accepted", cleanAnswer == nil, cleanAnswer ?? "")
    let swapped = makePackage("swapped", ["bin/codex": genuine, "codex-path/rg": "/usr/bin/true"])
    _ = forgeSignature(swapped + "/codex-path/rg")
    let swappedAnswer = signatureProblem(swapped)
    check("a genuine entrypoint beside a swapped helper is refused, naming the helper",
          swappedAnswer?.contains("codex-path/rg") == true, swappedAnswer ?? "accepted")
} else {
    print("  NOTE  no OpenAI-signed executable on this Mac — the accepting case is not run")
}
try? FileManager.default.removeItem(atPath: signScratch)

// MARK: 7. Scheduler

section("7. The scheduler idles a task whose agent is not listed")
let now = Date()
let slot = now.addingTimeInterval(-60)
let def = ScheduledTaskDefinition(enabled: true, schedule: TaskSchedule(slots: [slot]), catchUpMissed: true)
let seen = ScheduledTaskRunState(lastSlot: slot.addingTimeInterval(-3600), scheduleInForce: def.scheduleInForce)
check("listed: a due slot fires",
      ScheduledTaskScheduler.decide(def, state: seen, now: now, isRunning: false, agentListed: true) == .fire(slot: slot))
check("unlisted: the same due slot idles — nothing consumed",
      ScheduledTaskScheduler.decide(def, state: seen, now: now, isRunning: false, agentListed: false) == .idle)
check("unlisted: a first sighting adopts nothing either",
      ScheduledTaskScheduler.decide(def, state: nil, now: now, isRunning: false, agentListed: false) == .idle)
check("the default keeps every existing caller's meaning",
      ScheduledTaskScheduler.decide(def, state: nil, now: now, isRunning: false) == .adopt(slot: slot))
check("listed again after a long hide: the ordinary catch-up rule (missed beyond the window)",
      ScheduledTaskScheduler.decide(ScheduledTaskDefinition(schedule: TaskSchedule(slots: [now.addingTimeInterval(-3 * 86400)]), catchUpMissed: true),
                                    state: ScheduledTaskRunState(lastSlot: now.addingTimeInterval(-5 * 86400),
                                                                 scheduleInForce: def.scheduleInForce),
                                    now: now, isRunning: false, agentListed: true) == .skipMissed(slot: now.addingTimeInterval(-3 * 86400)))

// MARK: 8. The wiring, read off the sources

section("8. Wiring")
let onboarding = source("SipAI/Views/OnboardingView.swift")
check("OnboardingView is the welcome page alone",
      !onboarding.contains("ModelFetcher") && !onboarding.contains("case chooseProvider") && onboarding.contains("completeOnboarding(installedAgents:"))
let content = source("SipAI/Views/ContentView.swift")
check("ContentView's gate reads needsOnboarding", content.contains("showOnboarding ?? config.needsOnboarding"))
check("the window floor reads the same gate", source("SipAI/SipAIApp.swift").contains("configManager.needsOnboarding ? 720 : 640"))
check("ContentView closes an open page of an agent that stops being listed",
      content.contains(".onChange(of: agents.listedAgents)") && content.contains("appState.openAgentSessionId = nil"))
check("ContentView routes .openSettingsTab", content.contains("publisher(for: .openSettingsTab)"))
// Updates live in Settings → Updates, and an update on offer is shown
// by the badge there — nothing about a newer version routes to the
// Guide. (A banner once did, after the rows had moved back.)
check("no update notice routes to the Agent Guide",
      !content.contains("settingsTab = .agents") && !content.contains("CLIUpdateBanner"))
let sidebar = source("SipAI/Views/Sidebar/LeftSidebar.swift")
check("the sidebar appends each agent section on presence alone",
      sidebar.contains("agents.presence(for: \"claude_code\").isListed") && sidebar.contains("agents.presence(for: \"codex\").isListed")
      && sidebar.contains("agents.presence(for: \"kimi\").isListed") && !sidebar.contains("isAgentAvailable"))
check("the ADD row is the rule's label, uppercased in code, last in the column",
      sidebar.contains("AgentAddRow.label(presences:") && sidebar.contains(".textCase(.uppercase)")
      && sidebar.contains("                addAgentsRow\n            }\n        }\n        .frame(maxHeight: .infinity)"))
check("the ADD row opens the Agent Guide", sidebar.contains("SettingsView.Tab.agents.rawValue"))
let allSources = ["SipAI/Models", "SipAI/Views", "SipAI/Utilities", "SipAI/SipAIApp.swift"].flatMap { rel -> [String] in
    let path = root + "/" + rel
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
    if !isDir.boolValue { return [path] }
    return (FileManager.default.enumerator(atPath: path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".swift") }.map { path + "/" + $0 }
}
let everything = allSources.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }.joined(separator: "\n")
check("no file names AgentSectionTier", !everything.contains("AgentSectionTier"))
check("no file keeps a read-only bar", !everything.contains("readOnlyBar") && !everything.contains("readOnlyMessage") && !everything.contains("(read only)"))
check("no file keeps the retired detection APIs",
      !everything.contains("availableAgents") && !everything.contains("unseenAgents") && !everything.contains("codexAuthConfigured"))
let manager = source("SipAI/Models/AgentManager.swift")
check("AgentManager.setHidden is the one writer of hidden_agents",
      everything.components(separatedBy: "config.setHiddenAgents(").count == 2  // the manager's call, and nothing else
      && everything.components(separatedBy: "\"hidden_agents\"").count == 4     // ConfigManager: the read, the removal and the write
      && manager.contains("config.setHiddenAgents(Array(keys))") && manager.contains("recomputePresence()"))
check("the verdict pass reads every INSTALLED agent, the shown set only trims the icon",
      manager.contains("UsageMonitor.shared.refreshAccounts(installed: installed)")
      && manager.contains("UsageMonitor.shared.readAccountsNow(installed: installed)")
      && manager.contains("UsageMonitor.shared.setShown(Set(listed.map(\\.key)))"))
check("presence is recomputed from all three writers",
      manager.contains("accountsSink = UsageMonitor.shared.$accounts") && manager.contains("func setHidden(_ hidden: Bool, for key: String)"))
let sched = source("SipAI/Models/ScheduledTaskScheduler.swift")
check("the scheduler hands the listed set to decide and its fire backstop reads presence",
      sched.contains("agentListed: listed.contains(def.agent)") && sched.contains("agents.presence(for: taskAgent)") && sched.contains("is hidden in SipAI"))
check("global search seeds listed agents only", source("SipAI/Views/GlobalSearchPalette.swift").contains("listed.contains(session.agentKey)"))
let sessionView = source("SipAI/Views/Chat/AgentSessionView.swift")
check("the session view gates send and branch on presence",
      sessionView.contains("guard !typed.isEmpty || !attaching.isEmpty, agentIsListed else { return }") && sessionView.contains("guard case .existing = mode, agentIsListed"))
let settings = source("SipAI/Views/Settings/SettingsView.swift")
check("the Updates pane owns the agent-CLI rows and the switch that governs them",
      settings.contains("CLIUpdateRow(agent:") && settings.contains("Check these tools for new versions automatically")
      && settings.contains("cliUpdates.paneAppeared()"))
// The chat's two sections come first — Chat models, then Chat Prompt and
// Roles, whose prompt and roles reach chat turns alone — and the Guide
// right under them, the first of the agents' sections.
check("the Agent Guide tab sits third, under Chat models and Chat Prompt and Roles",
      settings.contains("case models, prompt, agents,"))
let pane = source("SipAI/Views/Settings/AgentGuidePane.swift")
// Install, sign in, sign out, delete and hide — and nothing about a
// NEWER version, which is the Updates pane's claim to make. The Guide
// prints the installed version, so it refreshes that and only that.
check("the Guide carries no update row, no release switch and asks no release endpoint",
      !pane.contains("struct CLIUpdateRow: View") && !pane.contains("CLIUpdateRow(agent:")
      && !pane.contains("Check these tools for new versions automatically")
      && !pane.contains("cliUpdates.paneAppeared()") && pane.contains("cliUpdates.guideAppeared()")
      && pane.contains("Updating these tools is in Settings → Updates."))
check("guideAppeared is local only — no release request from the Guide",
      source("SipAI/Models/AgentCLIUpdates.swift").contains("""
    func guideAppeared() {
        Task { await self.refreshLocal() }
    }
"""))
check("Delete and Sign out wait for a running turn; Install and Sign In do not",
      pane.contains(".disabled(isBusy || hasRunningTurn)") && pane.contains("Text(\"Install\", comment:") && pane.contains("Text(\"Sign In\", comment:"))
let guide = source("SipAI/Models/AgentGuide.swift")
check("codex's authUrl and kimi's verification URL are host-checked before they open",
      guide.contains("AgentSignIn.hostMatches(authUrl, expected: AgentSignIn.codexHost)") && guide.contains("AgentSignIn.hostMatches(complete, expected: expectedHost)"))
check("the pasted kimi key is scrubbed from any failure tail", guide.contains("AgentSignIn.scrubbed(result.output, secret: apiKey)"))
check("the codex package is verified before it is extracted", guide.contains("guard actual == expected else"))
check("the delete plan is executed, never improvised", guide.contains("for step in plan {"))
// The owned-codex update is started from the Updates ROW, so it must be
// reported there: the slot is held as an update (spinner + Cancel on
// the row), the verdict goes back through the monitor's finish, and
// nothing about the outcome is written into the Guide's own failures.
check("the owned-codex update holds the monitor's slot as an UPDATE and finishes through it",
      guide.contains("guard monitor.beginExternalUpdate(agentKey: key) else { return false }")
      && guide.contains("monitor.finishExternalUpdate(agentKey: key, before: before,")
      && !guide.contains("guard monitor.beginExternalAction(agentKey: key) else { return }\n            defer { monitor.endExternalAction(agentKey: key) }\n            self.progress[key] = Progress(phase: .downloading"))
// The slot is claimed BEFORE anything suspends, and the caller is told
// whether it was: the automatic update spends its one attempt per
// version only on a start that happened.
check("the owned-codex update claims the slot synchronously and answers whether it started",
      guide.contains("func updateOwnedCodex(latest: CLIVersion) -> Bool")
      && {
          guard let claim = guide.range(of: "guard monitor.beginExternalUpdate(agentKey: key) else { return false }"),
                let task = guide.range(of: "        Task {\n            let tail = await self.installCodexPackage(version: latest, key: key)")
          else { return false }
          return claim.lowerBound < task.lowerBound
      }())
// …and stops the TRANSFER: the package download is no child process,
// so the slot is handed a way to cancel it (measured: a cancelled task
// ends the download in under two seconds); before, both Cancels only
// set flags the route read once the whole body had arrived.
check("a Cancel from either pane reaches the codex package route, download included",
      guide.contains("|| AgentCLIUpdateMonitor.shared.externalActionCancelled(agentKey: key)")
      && guide.components(separatedBy: "if isCancelled(key) { return \"\" }").count == 4
      && guide.contains("AgentCLIUpdateMonitor.shared.adoptExternalCancellation(agentKey: key) { transfer.cancel() }"))
let monitorSource = source("SipAI/Models/AgentCLIUpdates.swift")
check("the slot runs the cancel hook it was handed, and forgets it when the action ends",
      monitorSource.contains("func adoptExternalCancellation(agentKey key: String, _ cancel: @escaping () -> Void)")
      && monitorSource.contains("if let hook = state[key]?.cancelHook {\n            state[key]?.cancelHook = nil\n            hook()")
      && monitorSource.components(separatedBy: "cancelHook = nil").count >= 4)
check("kimi's install hands the installer its PATH rule; claude's and codex's get SipAI's rc line",
      guide.contains("environment = AgentInstallRoute.kimiInstallerEnvironment(")
      && guide.contains("environment: environment, key: key)")
      && guide.contains("if key == \"codex\" || key == \"claude_code\" { await appendRCLineIfNeeded(key: key) }"))
check("beginExternalUpdate raises the row's spinner and publishes; finishExternalUpdate is the CLI updater's own verdict",
      monitorSource.contains("state[key]?.updating = true\n        state[key]?.failureTail = nil\n        publish()\n        return true")
      && monitorSource.contains("finishUpdate(key: key, verdict: verdict, tail: tail, exitCode: nil)"))
check("the Guide's pointer to Updates waits for a tool to exist",
      pane.contains("if !agents.installedAgents.isEmpty {\n                Text(\"Updating these tools is in Settings → Updates.\""))
// The intro is read on every Mac, so it describes no network setup.
// SipAI passes a tool only the proxy variables exported in the login
// shell and reads no system proxy setting: a sentence saying it hands
// over "the system proxy" is false, and a proxy sentence of any kind
// is noise for nearly everyone who opens the page. Only the sentences
// the pane SHOWS are held to this — an identifier (`ScrollViewProxy`)
// or a comment may say the word — so full-line comments go first and
// every "…" literal is read out of what remains. An interpolation that
// nests a quote splits a literal early, which can drop the nested
// value but never the sentence around it.
let paneSentences: String = {
    let code = pane.components(separatedBy: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
    guard let literal = try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#) else { return "" }
    let ns = code as NSString
    return literal.matches(in: code, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range) }.joined(separator: "\n").lowercased()
}()
check("the Guide says nothing about a proxy or a VPN",
      !paneSentences.isEmpty && !paneSentences.contains("proxy") && !paneSentences.contains("vpn"))
check("the rc line is guarded and only ever appended", guide.contains("CodexPackageInstall.needsRCLine(loginShellPath:") && guide.contains("seekToEnd()"))
// An argument is readable by every account on the Mac for as long as the
// command runs; an environment, only by the user's own.
check("a kimi API key rides the environment; the argument only for a kimi that asks for it",
      { guard let start = guide.range(of: "private func signInKimiKey(") else { return false }
        let body = guide[start.lowerBound...].prefix(4000)
        guard let env = body.range(of: "extraEnvironment: [\"KIMI_REGISTRY_API_KEY\": apiKey]"),
              let arg = body.range(of: "\"--api-key\", apiKey") else { return false }
        return env.lowerBound < arg.lowerBound
            && body[env.upperBound..<arg.lowerBound].contains("result.output.range(of: \"api key\", options: .caseInsensitive)") }())
let runner = source("SipAI/Models/AgentRunner.swift")
check("the two drain helpers are internal now, still spelled once",
      runner.contains("nonisolated static func makeDrainingLineSource(") && runner.contains("nonisolated static func makeChildStdoutSource()")
      && guide.contains("AgentRunner.makeDrainingLineSource(") && !guide.contains("DispatchSource.makeReadSource"))
let updatesSource = source("SipAI/Models/AgentCLIUpdates.swift")
check("hidden agents get no badge and no release check",
      updatesSource.contains("for agent in installedAgents where !hiddenAgents.contains(agent.key)") && updatesSource.contains("guard !hiddenAgents.contains(agent.key),"))

// Kimi's site: asked first, preset from kimi's own answer, never a literal.
let signInSheetBody: String = {
    guard let start = pane.range(of: "private var signInSheet: some View {"),
          let end = pane.range(of: "private func methodRow(", range: start.upperBound..<pane.endIndex)
    else { return "" }
    return String(pane[start.lowerBound..<end.lowerBound])
}()
let siteQuestion = signInSheetBody.range(of: "kimiSiteQuestion\n")
let methodQuestion = signInSheetBody.range(of: "How do you want to sign in?")
let siteQuestionBody: String = {
    guard let start = pane.range(of: "private var kimiSiteQuestion: some View {"),
          let end = pane.range(of: "private func kimiSiteLabel(", range: start.upperBound..<pane.endIndex)
    else { return "" }
    return String(pane[start.lowerBound..<end.lowerBound])
}()
check("kimi's sign-in sheet asks the site BEFORE the method",
      siteQuestion != nil && methodQuestion != nil && siteQuestion!.lowerBound < methodQuestion!.lowerBound
      && siteQuestionBody.contains("Which site is your account or key from?")
      && siteQuestionBody.contains("ForEach(KimiSite.allCases)"))
check("…preset from kimi's own region answer, never a hard-coded site",
      pane.contains("selectKimiSite(KimiSite(region: actions.kimiRegion))")
      && !codeOnly(pane).contains("\"mainland-cn\""))
check("…Continue waits for a site", signInSheetBody.contains("|| (key == \"kimi\" && kimiSite == nil)"))
check("…and the key's provider list is the chosen site's", signInSheetBody.contains("ForEach(site.keyProviders)"))
check("the sign-in route takes the site explicitly — no default site",
      guide.contains("apiKey: String = \"\", region: String,\n") && !guide.contains("region: String = \"mainland-cn\""))
check("kimi's probe asks its region in the same server session",
      guide.contains("path: \"/api/v1/oauth/region\"") && guide.contains("kimiRegion = region"))
check("Install asks no site: one installer, the site is asked on Sign In",
      pane.contains("actions.install(agentKey: key)") && !pane.contains("installSite")
      && !pane.contains("Which site do you use?")
      && pane.contains("\"SipAI downloads Moonshot's installer from code.kimi.com and runs it."))
check("signed in, the row names kimi's site or the key's platform",
      pane.contains("\"Membership (\\(site))\"") && pane.contains("\"API key (\\(platform))\"")
      && guide.contains("KimiConfigProviders.keyedBaseURL(configText: text)"))

// MARK: 9. Strings

section("9. Strings — every new sentence has a 中文 value")
let catalogPath = root + "/SipAI/Resources/Localizable.xcstrings"
var catalog: [String: Any] = [:]
if let data = FileManager.default.contents(atPath: catalogPath),
   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let strings = obj["strings"] as? [String: Any] {
    catalog = strings
}
func zh(_ key: String) -> String? {
    ((catalog[key] as? [String: Any])?["localizations"] as? [String: Any]).flatMap { $0["zh-Hans"] as? [String: Any] }
        .flatMap { $0["stringUnit"] as? [String: Any] }.flatMap { $0["value"] as? String }
}
for key in ["Agent Guide", "Add agents", "Add more agents", "About chats", "Not installed", "Installed · not signed in",
            "Signed in — %@", "Install", "Sign In", "Sign out", "Continue in your browser", "Delete %@ from this Mac?",
            "Nothing else on your Mac is changed.", "Mainland China (kimi.com)", "Global (kimi.ai)", "%@ is hidden in SipAI.",
            "Updating these tools is in Settings → Updates.", "The version could not be looked up, so nothing was downloaded.",
            "Only providers that are installed and signed in appear in the sidebar.",
            "Which site is your account or key from?",
            "kimi.com and kimi.ai are separate services — pick the one you signed up on.",
            "Kimi Code membership — opens %@ and shows a code to confirm there.",
            "Kimi Code membership — opens the site you pick and shows a code to confirm there.",
            "SipAI downloads Moonshot's installer from code.kimi.com and runs it. It installs to ~/.kimi-code/bin and adds that folder to your shell's PATH.",
            "Membership (%@)", "API key (%@)"] {
    check("\"\(key)\" is translated", zh(key).map { !$0.isEmpty } ?? false)
}
for prefix in ["SipAI runs each supported provider's own command-line tool", "You can install a tool below or in Terminal."] {
    let key = catalog.keys.first { $0.hasPrefix(prefix) }
    check("the intro paragraph \"\(prefix.prefix(40))…\" is translated", key.flatMap(zh).map { !$0.isEmpty } ?? false)
}
let learnMore = catalog.keys.first { $0.hasPrefix("The Chat section talks to AI models") }
check("the chat page's sentence carries its link in both languages",
      learnMore != nil && learnMore!.contains("(sipai://settings/models)") && (zh(learnMore!)?.contains("(sipai://settings/models)") ?? false))
let subscription = catalog.keys.first { $0.hasPrefix("If you would rather use a subscription plan for your conversations") }
check("the Chat-models paragraph carries its link in both languages",
      subscription != nil && subscription!.contains("(sipai://settings/agents)") && (zh(subscription!)?.contains("(sipai://settings/agents)") ?? false))
check("the reordered npm clause uses positional placeholders in Chinese",
      zh("the npm package %@ under %@")?.contains("%1$@") ?? false)
for stale in ["Kimi Code membership — opens kimi.com (or kimi.ai for the global region) and shows a code to confirm there.",
              "Which site do you use?",
              "SipAI downloads Moonshot's installer from %@ and runs it. It installs to ~/.kimi-code/bin and adds that folder to your shell's PATH.",
              "(read only)", "Skip — agent sessions only", "Agent command-line tools are updated from Agent Guide.",
              "Agent-only mode — pick an agent session from the sidebar, or add a chat model in Settings → Models.",
              "SipAI runs each provider's own command-line tool on this Mac — %@ — and shows that tool's sessions in the sidebar. Three things have to be true before a provider works here:",
              "If the provider needs a proxy or VPN where you are, the tool needs it too — SipAI hands the system proxy to every tool it starts.",
              "Only providers that are installed and signed in appear in the sidebar. Untick a provider to keep it installed and signed in but out of the way: its sessions leave the sidebar and search, and its scheduled tasks pause until you tick it again."] {
    check("stale key \"\(stale.prefix(40))\" is gone from the catalog", catalog[stale] == nil)
}
// The catalog holds every sentence SipAI writes for its user, and SipAI
// runs on every kind of network, so none of them is about proxies. The
// agents get the login shell's proxy variables without being told; a
// user who needs a proxy reads about it in the README's troubleshooting.
check("no user-facing sentence mentions a proxy or a VPN",
      !catalog.isEmpty && !catalog.keys.contains { $0.lowercased().contains("proxy") || $0.lowercased().contains("vpn") })
// The stall note NAMES how long the runner waited before showing it, so
// the constant and the sentence move together, in every language the
// sentence is translated into — or the transcript reports a wait it
// never made. The wait must be whole minutes for the sentence to say it.
let graceMinutes = runner.components(separatedBy: "\n")
    .first { $0.contains("static let firstOutputGrace: TimeInterval = ") }
    .flatMap { Int($0.components(separatedBy: "= ").last?.trimmingCharacters(in: .whitespaces) ?? "") }
    .flatMap { $0 > 0 && $0 % 60 == 0 ? $0 / 60 : nil }
let stallKey = catalog.keys.first { $0.hasPrefix("The turn is still running, but nothing has come back for ") }
check("the stall note names the runner's wait, in English and in Chinese",
      graceMinutes.map { minutes in
          sessionView.contains("nothing has come back for \(minutes) minutes.")
              && (stallKey?.contains("nothing has come back for \(minutes) minutes.") ?? false)
              && (stallKey.flatMap(zh)?.contains("\(minutes) 分钟") ?? false)
      } ?? false)

// MARK: 10. Live

if ProcessInfo.processInfo.environment["SIPAI_AGENTGUIDE_LIVE"] == "1" {
    section("10. Live — the real codex app-server, kimi's real server, claude's real status (SIPAI_AGENTGUIDE_LIVE=1)")
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        let fm = FileManager.default
        if let codex = AgentManager.binaryPath(for: "codex") {
            let codexHome = fm.temporaryDirectory.appendingPathComponent("sipai-guide-codex-\(UUID().uuidString)")
            try? fm.createDirectory(at: codexHome, withIntermediateDirectories: true)
            setenv("CODEX_HOME", codexHome.path, 1)
            defer { unsetenv("CODEX_HOME"); try? fm.removeItem(at: codexHome) }
            if let session = await CodexAppServerSession.start(binary: codex) {
                check("codex app-server: the handshake completes", true)
                let read = await session.request(method: "account/read", params: [:])
                check("signed out under a throwaway home", CodexUsageAnswer.accountKind(read) == .signedOut, "\(String(describing: read))")
                let started = await session.request(method: "account/login/start", params: ["type": "chatgpt"])
                let result = started?["result"] as? [String: Any]
                let authUrl = (result?["authUrl"] as? String).flatMap(URL.init(string:))
                check("login/start answers a loginId and an authUrl on auth.openai.com",
                      result?["loginId"] is String && authUrl.map { AgentSignIn.hostMatches($0, expected: AgentSignIn.codexHost) } == true,
                      "\(String(describing: started))")
                if let loginId = result?["loginId"] as? String {
                    let cancelled = await session.request(method: "account/login/cancel", params: ["loginId": loginId])
                    check("login/cancel accepts the real id", cancelled?["result"] != nil, "\(String(describing: cancelled))")
                }
                let key = await session.request(method: "account/login/start", params: ["type": "apiKey", "apiKey": "sk-probe-dummy-0123456789abcdefghijklmnop"])
                check("a key login answers {type: apiKey}", (key?["result"] as? [String: Any])?["type"] as? String == "apiKey")
                let completed = await session.awaitNotification(method: "account/login/completed", ceiling: 10,
                                                                 matching: CodexAppServerSession.loginCompletion(for: nil))
                check("…and the completed notification arrives", (completed?["params"] as? [String: Any])?["success"] as? Bool == true)
                let readAgain = await session.request(method: "account/read", params: [:])
                check("account/read now says apiKey", CodexUsageAnswer.accountKind(readAgain) == .apiKey)
                let logout = await session.request(method: "account/logout", params: [:])
                check("logout answers", logout?["result"] != nil)
                let readLast = await session.request(method: "account/read", params: [:])
                check("…and the account is gone", CodexUsageAnswer.accountKind(readLast) == .signedOut)
                await session.close()
                check("auth.json did not survive the logout", !fm.fileExists(atPath: codexHome.appendingPathComponent("auth.json").path))
            } else {
                check("codex app-server: the handshake completes", false, "no session")
            }
        } else {
            print("  SKIP codex is not installed")
        }

        if let kimi = AgentManager.binaryPath(for: "kimi") {
            let kimiHome = fm.temporaryDirectory.appendingPathComponent("sipai-guide-kimi-\(UUID().uuidString)")
            try? fm.createDirectory(at: kimiHome, withIntermediateDirectories: true)
            setenv("KIMI_CODE_HOME", kimiHome.path, 1)
            defer { unsetenv("KIMI_CODE_HOME"); try? fm.removeItem(at: kimiHome) }
            switch await KimiWebServerCall.Session.start(binary: kimi, scratchDirectory: kimiHome) {
            case .failed(let why):
                check("kimi's server starts", false, why)
            case .started(let session):
                check("kimi's server starts", true)
                let info = await session.request(method: "GET", path: "/api/v1/oauth/userinfo")
                if case .success(let body) = info {
                    check("userinfo under a throwaway home is signed out", KimiServerAnswer.userInfoVerdict(body: body) == .signedOut)
                } else { check("userinfo answers", false) }
                let start = await session.request(method: "POST", path: "/api/v1/oauth/login", body: ["region": "mainland-cn"])
                if case .success(let body) = start, let parsed = KimiServerAnswer.loginStart(body: body) {
                    check("login start is pending with a code and a kimi.com URL",
                          parsed.status == "pending" && parsed.userCode != nil
                          && parsed.verificationUriComplete.flatMap(URL.init(string:)).map { AgentSignIn.hostMatches($0, expected: "www.kimi.com") } == true)
                } else { check("login start answers", false, "\(start)") }
                let poll = await session.request(method: "GET", path: "/api/v1/oauth/login")
                if case .success(let body) = poll {
                    check("the poll says pending", KimiServerAnswer.loginPoll(body: body)?.status == "pending")
                } else { check("the poll answers", false) }
                let cancel = await session.request(method: "DELETE", path: "/api/v1/oauth/login")
                if case .success(let body) = cancel {
                    check("DELETE with no content-type cancels", KimiServerAnswer.data(in: body) != nil, String(decoding: body, as: UTF8.self))
                } else { check("DELETE answers", false, "\(cancel)") }
                let region = await session.request(method: "GET", path: "/api/v1/oauth/region")
                if case .success(let body) = region {
                    check("with no login and no marker, kimi's region is its default, mainland-cn",
                          KimiServerAnswer.region(body: body) == "mainland-cn", String(decoding: body, as: UTF8.self))
                } else { check("the region answers", false, "\(region)") }
                await session.shutdown()
                check("the server is gone after shutdown", true)
            }
            // The global site: the marker Moonshot's code.kimi.ai installer
            // writes is what kimi answers before any login, and a login
            // started for `global` hands back kimi.ai's device page.
            try? "global\n".write(to: kimiHome.appendingPathComponent("region"), atomically: true, encoding: .utf8)
            let probeAnswer = await AgentAccountProbe.answer(agentKey: "kimi", binary: kimi, scratchDirectory: kimiHome)
            check("the Guide's probe reads kimi's region beside who it is signed in as",
                  probeAnswer.kimiRegion == "global" && probeAnswer.kind == .signedOut, "\(probeAnswer)")
            switch await KimiWebServerCall.Session.start(binary: kimi, scratchDirectory: kimiHome) {
            case .failed(let why):
                check("kimi's server starts again", false, why)
            case .started(let session):
                let start = await session.request(method: "POST", path: "/api/v1/oauth/login", body: ["region": "global"])
                if case .success(let body) = start, let parsed = KimiServerAnswer.loginStart(body: body) {
                    check("a login started for kimi.ai hands back kimi.ai's device page",
                          parsed.status == "pending"
                          && parsed.verificationUriComplete.flatMap(URL.init(string:)).map { AgentSignIn.hostMatches($0, expected: KimiSite.global.signInHost) } == true,
                          parsed.verificationUriComplete ?? "")
                } else { check("a global login start answers", false, "\(start)") }
                _ = await session.request(method: "DELETE", path: "/api/v1/oauth/login")
                await session.shutdown()
            }
        } else {
            print("  SKIP kimi is not installed")
        }

        if let claude = AgentManager.binaryPath(for: "claude_code") {
            let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            func transcriptCount() -> Int {
                (fm.enumerator(atPath: projects.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".jsonl") }.count
            }
            let before = transcriptCount()
            let scratch = fm.temporaryDirectory.appendingPathComponent("sipai-guide-claude-\(UUID().uuidString)")
            try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let verdict = await AgentAccountProbe.run(agentKey: "claude_code", binary: claude, scratchDirectory: scratch)
            check("claude auth status --json answers a verdict (\(verdict))", verdict != .unknown)
            check("…and wrote no transcript", transcriptCount() == before)
            try? fm.removeItem(at: scratch)
        }
    }
    semaphore.wait()
}

print("\n\(passed)/\(passed + failed) checks passed")
if failed > 0 { print("\(failed) check(s) FAILED."); exit(1) }
