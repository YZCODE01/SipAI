// AgentGuide.swift
// SipAI macOS — whether an agent is LISTED, and everything Settings →
// Agent Guide can do about one that is not: install it, sign it in
// or out, delete it, hide it.
//
// One rule holds the whole feature together: an agent is either
// `listed` (installed, signed in, not hidden) and then everything
// about it works — its sidebar section, search, the usage coin, the
// update row and banner, its scheduled tasks — or it is not listed and
// then nothing about it exists to the app except its row here.
//
// Every rule in this file is a pure `nonisolated static func` of plain
// values so `Verification/AgentGuide/run.sh` can compile the file
// against a driver; the transports below the rules speak each CLI's
// own interface and nothing else — the vendor's installer script,
// OpenAI's signed release package and checksum file, codex's own
// app-server, kimi's own local server — and the actions at the end
// are the MainActor glue the pane drives.

import Foundation
import AppKit
import Combine
import CryptoKit

// MARK: - Presence

/// What the app may show of an agent right now. Only `.listed` answers
/// yes; the other cases differ only in what the Guide's row offers.
enum AgentPresence: Equatable {
    /// Installed, signed in, not hidden: the section, the sends, all
    /// of it.
    case listed
    /// Installed and signed in, unticked in the Guide. Nothing shown,
    /// nothing asked, tasks paused.
    case hiddenByUser
    /// Installed, no working login — or never run. The row offers
    /// Sign In; the ADD row is owed.
    case notSignedIn
    /// No binary on any search path. The row offers Install; the ADD
    /// row is owed.
    case notInstalled
    /// Installed, first account read not back yet. Neither a section
    /// nor the ADD row is drawn for it — the first frame after launch
    /// must not show "ADD AGENTS" over sections that arrive a moment
    /// later.
    case pending

    /// `verdict` is the CARRIED account verdict (`carry`): nil when no
    /// read has completed, `.unknown` when reads completed but none
    /// ever settled (a claude that was installed and never run has no
    /// `~/.claude.json`), which reads as not signed in — the honest
    /// answer, and the one whose Sign In is the fix.
    nonisolated static func resolve(installed: Bool,
                                    verdict: PlanAccountKind?,
                                    hidden: Bool) -> AgentPresence {
        guard installed else { return .notInstalled }
        guard let verdict else { return .pending }
        guard isSignedIn(verdict) else { return .notSignedIn }
        return hidden ? .hiddenByUser : .listed
    }

    nonisolated static func isSignedIn(_ kind: PlanAccountKind) -> Bool {
        switch kind {
        case .plan, .apiKey: return true
        case .signedOut, .unknown: return false
        }
    }

    /// The carried verdict: a fresh `.unknown` keeps the last settled
    /// answer, so a `~/.claude.json` caught mid-write cannot blink a
    /// section out for one tick. With nothing to carry, `.unknown`
    /// stands and resolves to not signed in.
    nonisolated static func carry(previous: PlanAccountKind?,
                                  fresh: PlanAccountKind) -> PlanAccountKind {
        if fresh != .unknown { return fresh }
        return previous ?? .unknown
    }

    var isListed: Bool { self == .listed }
}

// MARK: - The sidebar's ADD row

enum AgentAddRow {
    enum Label: Equatable {
        case addAgents
        case addMoreAgents
    }

    /// nil when nothing is owed: every agent is listed or hidden, or
    /// any is still pending (the first frame). "ADD AGENTS" when no
    /// agent is usable at all; "ADD MORE AGENTS" when some are.
    nonisolated static func label(presences: [AgentPresence]) -> Label? {
        if presences.contains(.pending) { return nil }
        let actionable = presences.filter { $0 == .notInstalled || $0 == .notSignedIn }
        guard !actionable.isEmpty else { return nil }
        let usable = presences.filter { $0 == .listed || $0 == .hiddenByUser }
        return usable.isEmpty ? .addAgents : .addMoreAgents
    }
}

// MARK: - Claude: `auth status --json`

/// `claude auth status --json` — measured on 2.1.277: `loggedIn`,
/// `authMethod` ("claude.ai"), `apiProvider` ("firstParty"),
/// `subscriptionType` ("max"), plus the e-mail and org, which are never
/// read into this type. With an API key in the child's environment the
/// same command answers `loggedIn: true, authMethod: "claude.ai"`
/// STILL — the OAuth login stands — but adds `apiKeySource:
/// "ANTHROPIC_API_KEY"` and nulls `subscriptionType`; its `--text`
/// form says "Auth token: claude.ai · not in use". The key is what
/// runs, so the source decides the verdict before the method does.
struct ClaudeAuthStatus: Equatable {
    let loggedIn: Bool
    let authMethod: String?
    let apiProvider: String?
    let subscriptionType: String?
    /// Where the API key in force comes from ("ANTHROPIC_API_KEY", an
    /// `apiKeyHelper`), nil when the login is what runs.
    let apiKeySource: String?

    nonisolated static func parse(_ data: Data) -> ClaudeAuthStatus? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let loggedIn = obj["loggedIn"] as? Bool else { return nil }
        return ClaudeAuthStatus(loggedIn: loggedIn,
                                authMethod: obj["authMethod"] as? String,
                                apiProvider: obj["apiProvider"] as? String,
                                subscriptionType: obj["subscriptionType"] as? String,
                                apiKeySource: obj["apiKeySource"] as? String)
    }

    /// An API key in force bills per token whatever login stands
    /// beside it; signed out is signed out; a claude.ai login is a plan
    /// named by its tier; a Console login is the API-billed account; a
    /// login through a cloud provider (`apiProvider` not first-party)
    /// bills that provider. Anything else is not judged.
    var verdict: PlanAccountKind {
        if let source = apiKeySource, !source.isEmpty { return .apiKey }
        guard loggedIn else { return .signedOut }
        switch authMethod?.lowercased() {
        case "claude.ai", "claudeai":
            return .plan(name: subscriptionType.map { $0.prefix(1).uppercased() + $0.dropFirst() })
        case "console":
            return .apiKey
        default:
            if let provider = apiProvider?.lowercased(), provider != "firstparty" {
                return .apiKey
            }
            return .unknown
        }
    }
}

// MARK: - Kimi: the local server's answers

/// `kimi web`'s envelope is `{"code":0,"msg":"success","data":…}`;
/// every shape below was measured on 2.0.1 under a throwaway home.
enum KimiServerAnswer {
    nonisolated static func data(in body: Data) -> [String: Any]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              (obj["code"] as? NSNumber)?.intValue == 0 else { return nil }
        return obj["data"] as? [String: Any]
    }

    struct LoginStart: Equatable {
        /// "pending", or "authenticated" when a login already stands.
        let status: String
        let flowId: String?
        let verificationUri: String?
        let verificationUriComplete: String?
        let userCode: String?
        /// Seconds between polls, kimi's own number (5).
        let interval: Int
        let expiresIn: Int
    }

    nonisolated static func loginStart(body: Data) -> LoginStart? {
        guard let d = data(in: body), let status = d["status"] as? String else { return nil }
        return LoginStart(status: status,
                          flowId: d["flow_id"] as? String,
                          verificationUri: d["verification_uri"] as? String,
                          verificationUriComplete: d["verification_uri_complete"] as? String,
                          userCode: d["user_code"] as? String,
                          interval: (d["interval"] as? NSNumber)?.intValue ?? 5,
                          expiresIn: (d["expires_in"] as? NSNumber)?.intValue ?? 1800)
    }

    struct LoginPoll: Equatable {
        let status: String
        let errorMessage: String?
    }

    nonisolated static func loginPoll(body: Data) -> LoginPoll? {
        guard let d = data(in: body), let status = d["status"] as? String else { return nil }
        return LoginPoll(status: status, errorMessage: d["error_message"] as? String)
    }

    /// `/oauth/userinfo`: an error envelope ("No token for …") is
    /// signed out; any other data is a membership. nil when the body
    /// is not the envelope at all.
    nonisolated static func userInfoVerdict(body: Data) -> PlanAccountKind? {
        guard let d = data(in: body) else { return nil }
        if let kind = d["kind"] as? String, kind == "error" { return .signedOut }
        return .plan(name: nil)
    }

    nonisolated static func region(body: Data) -> String? {
        data(in: body)?["region"] as? String
    }
}

/// kimi's config.toml, read for the two facts the Guide needs: the
/// `[providers.<id>]` tables that carry an `api_key` — the ones a
/// sign-out of a key-based kimi removes, through kimi's own `provider
/// remove` — and the API base kimi runs on when it runs on a key, which
/// the row names. The quoting rule is kimi's: an id with a slash is
/// written `[providers."moonshot-ai/x"]`, and so is a model alias.
enum KimiConfigProviders {
    private struct Tables {
        var defaultModel: String?
        var providers: [String] = []
        var keyed: Set<String> = []
        var baseURL: [String: String] = [:]
        var modelProvider: [String: String] = [:]
    }

    /// `<id>` of a `[<section>.<id>]` header, or nil for anything else —
    /// a sub-table of one included: `[providers."managed:kimi-code".oauth]`,
    /// the shape kimi writes for the managed provider's token, and a bare
    /// `[providers.x.oauth]` hold keys that are not the table's own.
    nonisolated private static func tableId(_ header: String, section: String) -> String? {
        guard header.hasPrefix(section + ".") else { return nil }
        var id = String(header.dropFirst(section.count + 1))
        if id.hasPrefix("\"") {
            guard let end = id.dropFirst().firstIndex(of: "\"") else { return nil }
            if id[id.index(after: end)...].contains(".") { return nil }
            id = String(id[id.index(after: id.startIndex)..<end])
        } else if id.contains(".") {
            return nil
        }
        return id
    }

    nonisolated private static func read(_ configText: String) -> Tables {
        var tables = Tables()
        var provider: String? = nil
        var model: String? = nil
        var topLevel = true
        for rawLine in configText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                topLevel = false
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .trimmingCharacters(in: .whitespaces)
                provider = tableId(header, section: "providers")
                model = tableId(header, section: "models")
                if let id = provider, !tables.providers.contains(id) { tables.providers.append(id) }
                continue
            }
            let stripped = line.split(separator: "#", maxSplits: 1).first.map(String.init) ?? line
            guard let eq = stripped.firstIndex(of: "=") else { continue }
            let key = stripped[stripped.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = stripped[stripped.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if topLevel {
                if key == "default_model", !value.isEmpty { tables.defaultModel = value }
            } else if let id = provider {
                if key == "api_key", !value.isEmpty { tables.keyed.insert(id) }
                if key == "base_url", !value.isEmpty { tables.baseURL[id] = value }
            } else if let alias = model, key == "provider", !value.isEmpty {
                tables.modelProvider[alias] = value
            }
        }
        return tables
    }

    nonisolated static func apiKeyProviderIds(configText: String) -> [String] {
        let tables = read(configText)
        return tables.providers.filter { tables.keyed.contains($0) }
    }

    /// The `base_url` of the provider kimi runs on a key: the provider of
    /// the model entry `default_model` names, when that provider carries
    /// a key — else the only provider that does. nil otherwise: with two
    /// keyed providers and no way to tell which one runs, the row names
    /// no platform rather than a guess.
    nonisolated static func keyedBaseURL(configText: String) -> String? {
        let tables = read(configText)
        if let alias = tables.defaultModel,
           let id = tables.modelProvider[alias], tables.keyed.contains(id) {
            return tables.baseURL[id]
        }
        let keyed = tables.providers.filter { tables.keyed.contains($0) }
        return keyed.count == 1 ? tables.baseURL[keyed[0]] : nil
    }
}

/// `kimi provider catalog list <id>` — measured on 2.0.1:
///
///     Moonshot AI (moonshotai)
///       kimi-k2.7-code-highspeed  ctx=262144 [tool_use,thinking,image_in]
///       kimi-k3  ctx=1048576 [tool_use,thinking,image_in]
///
/// The model ids are the first token of each INDENTED line, in kimi's
/// own order. `catalog add` without `--default-model` leaves
/// `default_model` unset and every turn then fails with "No model
/// configured" (measured), so the key sign-in passes the first listed
/// id — kimi's own flag, kimi's own writer; kimi qualifies a bare id
/// with the provider itself ("Default model set to moonshotai/…").
/// An id the provider does not list is REFUSED and nothing is written,
/// so the flag is only ever given a listed one.
enum KimiCatalogListing {
    nonisolated static func modelIds(from output: String) -> [String] {
        var ids: [String] = []
        for line in output.components(separatedBy: .newlines) {
            guard line.hasPrefix(" ") || line.hasPrefix("\t") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                  !first.isEmpty else { continue }
            let id = String(first)
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }
}

// MARK: - Install source

/// Where an installed binary came from, decided over PATHS: the link
/// SipAI spawns, its resolved target, the home folder, and — kimi —
/// its own install record's `active.source`.
enum AgentInstallSource: Equatable {
    /// The vendor's own native layout (claude's `~/.local/share/claude/
    /// versions/`, kimi's `<dir>/bin/kimi`).
    case native(directory: String)
    /// A codex SipAI installed from OpenAI's release package.
    case sipai(directory: String)
    /// A global npm package; `prefix` is the directory whose `lib/
    /// node_modules` holds it, and whose `bin/npm` removes it.
    case npm(prefix: String, package: String)
    /// A Homebrew cask; `prefix` is the Homebrew root.
    case brew(prefix: String, cask: String)
    /// A Homebrew formula — kimi's `kimi-code`, built from the npm
    /// package into the Cellar; `prefix` is the Homebrew root.
    case brewFormula(prefix: String, formula: String)
    /// Somewhere SipAI does not manage. No Delete button.
    case unknown(path: String)

    static let npmPackage: [String: String] = [
        "claude_code": "@anthropic-ai/claude-code",
        "codex": "@openai/codex",
        "kimi": "@moonshot-ai/kimi-code",
    ]
    /// Claude has TWO casks: `claude-code` tracks npm's `stable` tag and
    /// `claude-code@latest` its `latest` (each cask's livecheck reads
    /// that channel's version file). A marker for the first alone left
    /// the second undetected — no Delete offered for it.
    static let brewCasks: [String: [String]] = [
        "claude_code": ["claude-code", "claude-code@latest"],
        "codex": ["codex"],
    ]
    /// Homebrew's `kimi-code` formula runs `npm install` INTO the Cellar
    /// (`libexec/lib/node_modules/@moonshot-ai/kimi-code`) and links
    /// `bin/kimi` from there, so the resolved binary carries the Cellar
    /// marker AND the npm one. Read as npm, the "prefix" is the formula's
    /// `libexec`, whose `bin/npm` does not exist — a Delete that could
    /// only fail. The Cellar is checked FIRST.
    static let brewFormulae: [String: [String]] = [
        "kimi": ["kimi-code"],
    ]

    /// The live wrapper: the binary SipAI spawns, its resolved target,
    /// the home folder, kimi's install record. nil when not installed.
    nonisolated static func current(agentKey: String) -> AgentInstallSource? {
        guard let binary = AgentManager.binaryPath(for: agentKey) else { return nil }
        let resolved = URL(fileURLWithPath: binary).resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var kimiSource: String? = nil
        if agentKey == "kimi",
           let record = try? Data(contentsOf: AgentCLIRelease.nativeInstallRecordURL(home: KimiSessionScanner.home)) {
            kimiSource = AgentCLIRelease.installSource(fromRecord: record)
        }
        return detect(agentKey: agentKey, binaryPath: binary, resolvedPath: resolved,
                      home: home, kimiInstallSource: kimiSource,
                      kimiHome: KimiSessionScanner.home.path)
    }

    var isOwnedBySipAI: Bool {
        if case .sipai = self { return true }
        return false
    }

    /// The package manager whose install the CLI's OWN updater declines
    /// to update — the one that has to, and that SipAI never runs. nil
    /// where the updater handles the source itself (npm: claude's and
    /// codex's run the package manager; codex's cask: `codex update`
    /// runs `brew upgrade --cask codex`) or SipAI does (its own codex).
    /// Read out of each CLI's update code, 2026-09-28: claude 2.1.283 on
    /// a Homebrew install prints "Claude is managed by Homebrew.", the
    /// `brew upgrade` line, and exits 0 having run nothing — and the
    /// `claude-code` cask tracks npm's `stable` tag, so even a version
    /// claim against `latest` is against the wrong channel; kimi
    /// 2.1.1's `canAutoInstall("homebrew")` is false and its manual
    /// route is `brew upgrade kimi-code`. Such a row can only state the
    /// version and who manages it (`CLIUpdateStatus.managedElsewhere`).
    nonisolated func managedBy(agentKey: String) -> String? {
        switch (agentKey, self) {
        case ("claude_code", .brew), ("kimi", .brewFormula):
            return "Homebrew"
        default:
            return nil
        }
    }

    /// `kimiHome` is kimi's own home (`~/.kimi-code`, or `KIMI_CODE_HOME`
    /// when set); nil means the default under `home`.
    nonisolated static func detect(agentKey: String,
                                   binaryPath: String,
                                   resolvedPath: String,
                                   home: String,
                                   kimiInstallSource: String? = nil,
                                   kimiHome: String? = nil) -> AgentInstallSource {
        let candidates = [binaryPath, resolvedPath]
        // Homebrew before npm: a formula's tree holds an npm layout.
        for cask in brewCasks[agentKey] ?? [] {
            let marker = "/Caskroom/" + cask + "/"
            for path in candidates {
                if let range = path.range(of: marker) {
                    let prefix = String(path[path.startIndex..<range.lowerBound])
                    return .brew(prefix: prefix, cask: cask)
                }
            }
        }
        for formula in brewFormulae[agentKey] ?? [] {
            let marker = "/Cellar/" + formula + "/"
            for path in candidates {
                if let range = path.range(of: marker) {
                    let prefix = String(path[path.startIndex..<range.lowerBound])
                    return .brewFormula(prefix: prefix, formula: formula)
                }
            }
        }
        if let package = npmPackage[agentKey] {
            let marker = "/lib/node_modules/" + package + "/"
            for path in candidates {
                if let range = path.range(of: marker) {
                    let prefix = String(path[path.startIndex..<range.lowerBound])
                    return .npm(prefix: prefix, package: package)
                }
            }
        }
        switch agentKey {
        case "claude_code":
            let share = home + "/.local/share/claude"
            if resolvedPath.hasPrefix(share + "/versions/") {
                return .native(directory: share)
            }
        case "codex":
            let root = home + "/.local/share/sipai/codex"
            if resolvedPath.hasPrefix(root + "/") {
                return .sipai(directory: root)
            }
        case "kimi":
            // Native means kimi's OWN home and nothing else. The install
            // record says "native" but names no directory, and a copy of
            // the binary in a shared `bin` (`/usr/local/bin`, `~/.local/
            // bin`) would otherwise read as native THERE — and Delete
            // removes the whole `bin` of what it is handed.
            let bin = (resolvedPath as NSString).deletingLastPathComponent
            let directory = (bin as NSString).deletingLastPathComponent
            let expected = URL(fileURLWithPath: kimiHome ?? (home + "/.kimi-code"))
                .standardizedFileURL.path
            if (bin as NSString).lastPathComponent == "bin",
               (resolvedPath as NSString).lastPathComponent == "kimi",
               URL(fileURLWithPath: directory).standardizedFileURL.path == expected,
               kimiInstallSource == nil || kimiInstallSource == "native" {
                return .native(directory: directory)
            }
        default:
            break
        }
        return .unknown(path: resolvedPath)
    }
}

// MARK: - Delete plan

/// What Delete does, as a value the alert prints and the harness pins.
enum AgentDeletePlan {
    enum Step: Equatable {
        case remove(path: String)
        case run(binary: String, arguments: [String])
    }

    /// nil when the source is unknown — nothing is removed that SipAI
    /// cannot name. Never `--zap` (the cask's zap trashes the login and
    /// the sessions), never `--force`, never `~/.claude`, `~/.codex` or
    /// anything under `~/.kimi-code` but `bin/`. A formula is
    /// `brew uninstall <formula>` — the same word a Terminal would use.
    nonisolated static func make(agentKey: String,
                                 source: AgentInstallSource,
                                 home: String) -> [Step]? {
        switch (agentKey, source) {
        case ("claude_code", .native(let directory)):
            return [.remove(path: home + "/.local/bin/claude"), .remove(path: directory)]
        case ("codex", .sipai(let directory)):
            return [.remove(path: home + "/.local/bin/codex"), .remove(path: directory)]
        case ("kimi", .native(let directory)):
            return [.remove(path: directory + "/bin")]
        case (_, .npm(let prefix, let package)):
            return [.run(binary: prefix + "/bin/npm", arguments: ["uninstall", "-g", package])]
        case (_, .brew(let prefix, let cask)):
            return [.run(binary: prefix + "/bin/brew", arguments: ["uninstall", "--cask", cask])]
        case (_, .brewFormula(let prefix, let formula)):
            return [.run(binary: prefix + "/bin/brew", arguments: ["uninstall", formula])]
        default:
            return nil
        }
    }
}

// MARK: - Install route

/// How SipAI installs each agent. No input: the route does not depend
/// on what else the Mac has — no Homebrew, npm or node is ever needed.
enum AgentInstallRoute: Equatable {
    /// The vendor's own installer script, run through `/bin/bash`.
    case script(URL)
    /// OpenAI's signed release package, verified against OpenAI's
    /// checksum file (`CodexPackageInstall`).
    case package

    /// Kimi's install asks no site. Moonshot's two installers differ
    /// only in their download host, and both channels publish the same
    /// release manifest — the same binaries under the same checksums — so
    /// either installs the same program. What differs is the one-word
    /// `<home>/region` marker the script writes when there is none yet,
    /// which is kimi's default site only until the first sign-in; the
    /// Guide asks the site where it decides something, on Sign In.
    nonisolated static func route(agentKey: String) -> AgentInstallRoute? {
        switch agentKey {
        case "claude_code":
            return URL(string: "https://claude.ai/install.sh").map { .script($0) }
        case "kimi":
            return .script(KimiSite.mainlandCN.installer)
        case "codex":
            return .package
        default:
            return nil
        }
    }

    /// The PATH Moonshot's installer runs under for a Guide INSTALL of
    /// kimi (`AgentGuideActions.performInstall`).
    ///
    /// The script edits the shell's rc file only when
    /// `$KIMI_INSTALL_DIR/bin` is NOT already on its PATH — its
    /// `_update_path` returns on `":$PATH:"` containing it (read out of
    /// the script) — and the PATH a SipAI child gets always carries
    /// `~/.kimi-code/bin`: one of `AgentManager`'s built-in guesses,
    /// there whether or not kimi is installed. Under that PATH the
    /// installer wrote no line (measured both ways under a throwaway
    /// HOME): SipAI found kimi and Terminal did not, against the Install
    /// sheet's own sentence. So SipAI's guesses for kimi's directories
    /// are taken out — unless the login shell's PATH carries one, in
    /// which case Terminal already sees it and the installer's skip is
    /// right, as it would be for a Terminal install. Every other entry
    /// stays: the script needs curl, shasum and tar from the rest of
    /// the PATH. A kimi UPDATE takes the other route
    /// (`KIMI_NO_MODIFY_PATH`): PATH already reaches that install.
    nonisolated static func kimiInstallerEnvironment(childPATH: String,
                                                     loginShellPath: [String],
                                                     home: String) -> [String: String] {
        func normalized(_ path: String) -> String { (path as NSString).standardizingPath }
        let own = Set([home + "/.kimi-code/bin", home + "/.kimi/bin"].map(normalized))
        let shell = Set(loginShellPath.map(normalized))
        let kept = childPATH.split(separator: ":").map(String.init).filter { dir in
            let entry = normalized(dir)
            return !own.contains(entry) || shell.contains(entry)
        }
        return ["PATH": kept.joined(separator: ":")]
    }

    /// The host the Install sheet names as the download's origin.
    var host: String {
        switch self {
        case .script(let url): return url.host ?? ""
        case .package: return "github.com/openai/codex"
        }
    }
}

// MARK: - Kimi's two sites

/// Kimi Code runs as two separate deployments, and a sign-in, a key and
/// an install each belong to one of them. Measured from kimi's own
/// region profiles (`packages/oauth/src/region.ts` in the kimi binary)
/// and from Moonshot's two installers:
///
/// | region | site | OAuth | API | installer channel |
/// |---|---|---|---|---|
/// | `mainland-cn` | www.kimi.com | auth.kimi.com | api.kimi.com/coding/v1 | code.kimi.com |
/// | `global` | www.kimi.ai | auth.kimi.ai | api.kimi.ai/coding/v1 | code.kimi.ai |
///
/// So the site is the FIRST thing the Guide asks on kimi's sign-in sheet.
/// Kimi decides its own region in this order: an environment
/// override, a saved login's host in `config.toml`, the `<home>/region`
/// marker its installer wrote (read only until the first login), then
/// `mainland-cn`. `GET /api/v1/oauth/region` on kimi's local server
/// answers exactly that, and the sign-in sheet presets it. Every host
/// here exists twice — never hard-code one site.
enum KimiSite: String, CaseIterable, Identifiable, Equatable {
    case mainlandCN = "mainland-cn"
    case global = "global"

    var id: String { rawValue }

    /// kimi's own region id (`/oauth/region`, the marker file). nil for
    /// anything else: an answer SipAI does not recognise presets nothing.
    nonisolated init?(region: String?) {
        guard let region,
              let site = KimiSite(rawValue: region.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        self = site
    }

    /// The site as users know it — the account, the membership, the
    /// Kimi Code console.
    nonisolated var domain: String {
        self == .global ? "kimi.ai" : "kimi.com"
    }

    /// The device-code page kimi's login hands back for this site.
    nonisolated var signInHost: String {
        self == .global ? "www.kimi.ai" : "www.kimi.com"
    }

    /// The installer channel. Moonshot's installer writes kimi's region
    /// marker from the channel it came from — and never over an existing
    /// one, so a reinstall keeps the site first chosen.
    nonisolated var channelHost: String {
        self == .global ? "code.kimi.ai" : "code.kimi.com"
    }

    nonisolated var installer: URL {
        URL(string: "https://\(channelHost)/kimi-code/install.sh")!
    }

    /// Kimi's own key providers on this site.
    nonisolated var keyProviders: [AgentSignIn.KimiKeyProvider] {
        AgentSignIn.kimiKeyProviders.filter { $0.site == self }
    }

    /// Both installers — the only scripts a kimi update may run: kimi's
    /// updater names the one of the site it is on.
    nonisolated static var installers: [URL] { allCases.map(\.installer) }
}

// MARK: - Sign-in routes

enum AgentSignIn {
    enum Method: String, Equatable {
        /// The provider's account, in the browser.
        case subscription
        /// Claude only: an Anthropic Console account (API billing), in
        /// the browser.
        case console
        /// A pasted key, through the tool's own key login.
        case apiKey
    }

    struct Route: Equatable {
        let agentKey: String
        let method: Method
        /// The host the notice names — a fact per route, never parsed
        /// from a URL at runtime. Codex's `authUrl` and kimi's
        /// verification URL are CHECKED against it before they open.
        let host: String
        var opensBrowser: Bool { method != .apiKey }
    }

    /// Kimi's device-code page per region (`--region` / `{region}`):
    /// kimi.com for mainland China, kimi.ai for the global region
    /// (`KimiSite`).
    nonisolated static func kimiHost(region: String) -> String {
        (KimiSite(region: region) ?? .mainlandCN).signInHost
    }

    /// Measured on 2.1.277 under a PTY: `claude auth login` prints
    /// "If the browser didn't open, visit: https://claude.com/cai/
    /// oauth/authorize?…" and `--console` prints "…https://platform
    /// .claude.com/oauth/authorize?…" — two hosts, one per route.
    static let claudeSubscriptionHost = "claude.com"
    static let claudeConsoleHost = "platform.claude.com"
    static let codexHost = "auth.openai.com"

    nonisolated static func claudeHost(method: Method) -> String {
        method == .console ? claudeConsoleHost : claudeSubscriptionHost
    }

    nonisolated static func routes(agentKey: String, kimiRegion: String = "mainland-cn") -> [Route] {
        switch agentKey {
        case "claude_code":
            return [Route(agentKey: agentKey, method: .subscription, host: claudeSubscriptionHost),
                    Route(agentKey: agentKey, method: .console, host: claudeConsoleHost)]
        case "codex":
            return [Route(agentKey: agentKey, method: .subscription, host: codexHost),
                    Route(agentKey: agentKey, method: .apiKey, host: "")]
        case "kimi":
            return [Route(agentKey: agentKey, method: .subscription,
                          host: kimiHost(region: kimiRegion)),
                    Route(agentKey: agentKey, method: .apiKey, host: "")]
        default:
            return []
        }
    }

    /// `claude auth login` with the route's flag; the default is the
    /// claude.ai subscription.
    nonisolated static func claudeArguments(method: Method) -> [String] {
        method == .console ? ["auth", "login", "--console"] : ["auth", "login"]
    }

    nonisolated static func hostMatches(_ url: URL, expected: String) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host == expected.lowercased()
    }

    /// The key-based providers kimi's own catalog lists (`kimi provider
    /// catalog list`), by kimi's ids, with the platform a key comes from,
    /// the site it belongs to, and the API base the catalog pairs it with
    /// — what a configured `base_url` is recognised by. A key works only
    /// on the platform that issued it, so the sheet lists the chosen
    /// site's two.
    struct KimiKeyProvider: Equatable, Identifiable {
        let id: String
        let name: String
        let platform: String
        let site: KimiSite
        let apiBase: String
    }
    static let kimiKeyProviders: [KimiKeyProvider] = [
        KimiKeyProvider(id: "moonshotai", name: "Moonshot AI", platform: "platform.moonshot.ai",
                        site: .global, apiBase: "https://api.moonshot.ai/v1"),
        KimiKeyProvider(id: "moonshotai-cn", name: "Moonshot AI (China)", platform: "platform.moonshot.cn",
                        site: .mainlandCN, apiBase: "https://api.moonshot.cn/v1"),
        KimiKeyProvider(id: "kimi-code-plan-global", name: "Kimi For Coding (kimi.ai)", platform: "kimi.ai",
                        site: .global, apiBase: "https://api.kimi.ai/coding/v1"),
        KimiKeyProvider(id: "kimi-code-plan-cn", name: "Kimi For Coding (kimi.com)", platform: "kimi.com",
                        site: .mainlandCN, apiBase: "https://api.kimi.com/coding/v1"),
    ]

    /// The catalog entry a configured `base_url` is — compared without
    /// case or a trailing slash. nil for a base the catalog does not
    /// pair with a key provider (a custom one).
    nonisolated static func kimiKeyProvider(forBaseURL url: String) -> KimiKeyProvider? {
        func normalized(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespaces).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let wanted = normalized(url)
        return kimiKeyProviders.first { normalized($0.apiBase) == wanted }
    }

    /// What the kimi row names beside a key: the platform it comes from
    /// — or, for a base the catalog does not know, its host.
    nonisolated static func kimiKeyPlatform(forBaseURL url: String) -> String {
        kimiKeyProvider(forBaseURL: url)?.platform
            ?? URL(string: url.trimmingCharacters(in: .whitespaces))?.host
            ?? url
    }

    /// The tool's output tail with the pasted key scrubbed — kimi takes
    /// the key as an argument, so its own echo of the command line
    /// could carry it into a failure display.
    nonisolated static func scrubbed(_ output: String, secret: String) -> String {
        guard !secret.isEmpty else { return output }
        return output.replacingOccurrences(of: secret, with: "••••")
    }
}

// MARK: - Terminal output, as words

/// A child on a PTY writes for a terminal: colours as CSI sequences
/// and — claude's sign-in URL — an OSC 8 hyperlink. A failure display
/// shows the words, not the control bytes. CSI is ESC `[`, parameter
/// and intermediate bytes, then one final byte 0x40–0x7E; OSC is ESC
/// `]` up to BEL or ESC `\`. Anything else after ESC is one byte.
enum TerminalText {
    private static let escape: Character = "\u{1B}"
    private static let bell: Character = "\u{07}"

    nonisolated static func strippingEscapes(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            guard c == escape else {
                out.append(c)
                i = text.index(after: i)
                continue
            }
            let next = text.index(after: i)
            guard next < text.endIndex else { break }
            switch text[next] {
            case "[":
                var j = text.index(after: next)
                while j < text.endIndex, let v = text[j].asciiValue, v < 0x40 || v > 0x7E {
                    j = text.index(after: j)
                }
                i = j < text.endIndex ? text.index(after: j) : j
            case "]":
                var j = text.index(after: next)
                while j < text.endIndex {
                    if text[j] == bell { j = text.index(after: j); break }
                    if text[j] == escape {
                        let after = text.index(after: j)
                        j = after < text.endIndex && text[after] == "\\" ? text.index(after: after) : after
                        break
                    }
                    j = text.index(after: j)
                }
                i = j
            default:
                i = text.index(after: next)
            }
        }
        return out
    }
}

// MARK: - Codex: OpenAI's release package

/// The pure half of installing codex from OpenAI's GitHub release —
/// what one of the vendors' installer scripts would do, since OpenAI
/// publishes none. Measured on 0.155.1: the package carries
/// `codex-package.json` (`entrypoint`, `resourcesDir`, `pathDir`),
/// `bin/codex` signed with OpenAI's Developer ID and the hardened
/// runtime, and runs through a symlinked launcher exactly as the
/// Homebrew cask links it. `codex update` on that layout answers
/// "Could not detect the Codex installation method", so a codex SipAI
/// installed is one SipAI updates — the same route at the new version.
enum CodexPackageInstall {
    static let packageCap = 512 * 1024 * 1024
    static let docsURL = "https://developers.openai.com/codex/cli/"

    /// `hw.machine` is the MACHINE; under Rosetta the process says
    /// x86_64 while the Mac is arm64 and the arm64 package is the
    /// right one — the check Anthropic's installer makes.
    nonisolated static func machineArchitecture() -> String {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0,
           translated == 1 {
            return "arm64"
        }
        var length = 0
        sysctlbyname("hw.machine", nil, &length, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(length, 1))
        sysctlbyname("hw.machine", &buffer, &length, nil, 0)
        return String(cString: buffer)
    }

    nonisolated static func asset(machine: String) -> String? {
        switch machine {
        case "arm64", "aarch64": return "codex-package-aarch64-apple-darwin.tar.gz"
        case "x86_64": return "codex-package-x86_64-apple-darwin.tar.gz"
        default: return nil
        }
    }

    nonisolated static func assetURL(version: String, asset: String) -> URL? {
        URL(string: "https://github.com/openai/codex/releases/download/rust-v\(version)/\(asset)")
    }

    nonisolated static func sumsURL(version: String) -> URL? {
        URL(string: "https://github.com/openai/codex/releases/download/rust-v\(version)/codex-package_SHA256SUMS")
    }

    /// The 64-hex digest on the line naming exactly this asset.
    nonisolated static func expectedDigest(sums: String, asset: String) -> String? {
        for line in sums.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, parts.last == asset else { continue }
            let digest = parts[0].lowercased()
            guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { continue }
            return digest
        }
        return nil
    }

    struct Layout: Equatable {
        /// `~/.local/share/sipai/codex`
        let root: String
        /// `<root>/<version>`
        let versionDirectory: String
        /// `<root>/.<version>-staging` — dot-prefixed while incomplete.
        let staging: String
        /// `~/.local/bin/codex`
        let link: String
        let binDirectory: String
    }

    nonisolated static func layout(home: String, version: String) -> Layout {
        let root = home + "/.local/share/sipai/codex"
        return Layout(root: root,
                      versionDirectory: root + "/" + version,
                      staging: root + "/." + version + "-staging",
                      link: home + "/.local/bin/codex",
                      binDirectory: home + "/.local/bin")
    }

    /// `codex-package.json`: the version and the entrypoint, read —
    /// never assumed.
    nonisolated static func manifest(_ data: Data) -> (version: String, entrypoint: String)? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = obj["version"] as? String,
              let entrypoint = obj["entrypoint"] as? String,
              !version.isEmpty, !entrypoint.isEmpty, !entrypoint.hasPrefix("/"),
              !entrypoint.contains("..") else { return nil }
        return (version, entrypoint)
    }

    /// The Developer ID team the release package is signed under
    /// (OpenAI OpCo). The checksum list proves the bytes are the ones
    /// the release names, not who made them — list and archive come from
    /// the same place — and the archive arrives without a quarantine
    /// flag, so nothing else assesses the package before it runs. The
    /// signatures are the one thing here that say OpenAI made it.
    static let expectedTeamIdentifier = "2DC432GLL2"

    /// What every executable in the package must satisfy: a Developer ID
    /// Application certificate Apple issued to that team. Asked of
    /// `codesign` as a requirement, never read out of `codesign -dv`:
    /// that text prints the signer's own identifier before the team, and
    /// an ad-hoc signature whose identifier holds a line reading
    /// `TeamIdentifier=<OpenAI's>` satisfies a reader of the text.
    nonisolated static var signingRequirement: String {
        "=anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
            + " and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\""
    }

    /// nil when every Mach-O file in the extracted package meets the
    /// requirement above and the entrypoint is one of them; else the
    /// sentence to show. Run on the staged package before anything in it
    /// runs. Every file, not the entrypoint alone: codex runs helpers out
    /// of its package (`codex-path/rg`, `bin/codex-code-mode-host`, the
    /// voice host and its libraries), so a package whose entrypoint is
    /// genuine could still carry a swapped helper — and an entrypoint
    /// that is a script would run with no signature asked of it at all.
    /// A symbolic link is refused outright: OpenAI's package holds none,
    /// and one could send a helper outside the package, to a file
    /// nothing here checked.
    nonisolated static func signatureProblem(packageRoot root: String,
                                             entrypoint: String) async -> String? {
        func notSigned(_ relative: String) -> String {
            String(localized: "A file in the downloaded codex package (\(relative)) is not signed by OpenAI, so the package was discarded.",
                   comment: "Agent Guide: an executable in the extracted codex package failed the OpenAI Developer ID check; placeholder is its path inside the package")
        }
        guard let walker = FileManager.default.enumerator(atPath: root) else {
            return notSigned(entrypoint)
        }
        var executables: [String] = []
        while let relative = walker.nextObject() as? String {
            let type = walker.fileAttributes?[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                return String(localized: "The downloaded codex package holds a symbolic link (\(relative)), which OpenAI's package does not, so it was discarded.",
                              comment: "Agent Guide: the extracted codex package contained a symlink; placeholder is its path inside the package")
            }
            if type == .typeRegular, isMachO(atPath: root + "/" + relative) {
                executables.append(relative)
            }
        }
        guard executables.contains(entrypoint) else { return notSigned(entrypoint) }
        for relative in executables {
            let verify = await AgentCLIProbe.run(
                binary: "/usr/bin/codesign",
                arguments: ["--verify", "--strict", "-R", signingRequirement, root + "/" + relative],
                ceiling: AgentCLIProbe.versionCeiling,
                outputCap: 4096, onSpawn: { _ in })
            guard verify.exitCode == 0 else { return notSigned(relative) }
        }
        return nil
    }

    /// Whether the file opens with a Mach-O or universal-binary magic
    /// number, in either byte order.
    nonisolated static func isMachO(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let magic = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let known: Set<UInt32> = [0xfeedface, 0xfeedfacf, 0xcafebabe, 0xcafebabf]
        return known.contains(magic) || known.contains(magic.byteSwapped)
    }

    static let rcLine = "export PATH=\"$HOME/.local/bin:$PATH\""
    static let fishLine = "fish_add_path -g \"$HOME/.local/bin\""

    /// The login shell's rc file and the line for it — Moonshot's
    /// installer's rule (`.zshrc` for zsh, `.bashrc` then `.profile`
    /// for bash), fish's own `config.fish`; nil for a shell SipAI does
    /// not know, where no file is edited.
    nonisolated static func rcFile(shell: String, home: String,
                                   exists: (String) -> Bool) -> (path: String, line: String)? {
        switch (shell as NSString).lastPathComponent {
        case "zsh":
            return (home + "/.zshrc", rcLine)
        case "bash":
            if exists(home + "/.bashrc") { return (home + "/.bashrc", rcLine) }
            if exists(home + "/.profile") { return (home + "/.profile", rcLine) }
            return (home + "/.bashrc", rcLine)
        case "fish":
            return (home + "/.config/fish/config.fish", fishLine)
        default:
            return nil
        }
    }

    /// False when `~/.local/bin` is already on the captured PATH, or
    /// already named in the rc file (Moonshot's `grep -qsF`), or the
    /// capture is EMPTY — an empty capture means the shell has not
    /// been read yet, not that the directory is missing.
    nonisolated static func needsRCLine(loginShellPath: [String],
                                        rcText: String?,
                                        home: String) -> Bool {
        guard !loginShellPath.isEmpty else { return false }
        let bin = home + "/.local/bin"
        let normalized = loginShellPath.map { ($0 as NSString).standardizingPath }
        if normalized.contains(bin) { return false }
        if let rcText, rcText.contains(".local/bin") { return false }
        return true
    }
}

// MARK: - The structured account probe

/// "Who is this tool signed in as?", asked of the tool itself and
/// answered in a shape SipAI reads: `claude auth status --json` (no
/// transcript, under a second), codex's `account/read`, kimi's
/// `/oauth/userinfo`. `.unknown` means the tool did not answer — a
/// failed probe changes nothing.
enum AgentAccountProbe {
    static let claudeCeiling: TimeInterval = 15

    /// The probe reads the tool's LOGIN; a key the tool runs on is the
    /// FILE layer's fact. Kimi's `/oauth/userinfo` answers "No token"
    /// for a provider configured with an API key (measured — this is
    /// how a key-based kimi presents), and claude's `auth status` may
    /// report no login beside a key from a settings `apiKeyHelper`; a
    /// `.signedOut` there is not a sign-out. So a probe never downgrades
    /// a file-layer `.apiKey`: recorded as `.apiKey`, it keeps the
    /// section, and the status sentence says what runs.
    nonisolated static func reconcile(file: PlanAccountKind,
                                      probe: PlanAccountKind) -> PlanAccountKind {
        if probe == .signedOut, file == .apiKey { return .apiKey }
        return probe
    }

    /// A probe's answer: who the tool is signed in as, and — kimi only —
    /// the site kimi would sign in to (`KimiSite`), asked in the same
    /// server session: a saved login's site, else the site its installer
    /// came from, else kimi's default. nil when kimi did not say.
    struct Answer: Equatable {
        var kind: PlanAccountKind
        var kimiRegion: String? = nil
    }

    nonisolated static func run(agentKey: String, binary: String,
                                scratchDirectory: URL) async -> PlanAccountKind {
        await answer(agentKey: agentKey, binary: binary, scratchDirectory: scratchDirectory).kind
    }

    nonisolated static func answer(agentKey: String, binary: String,
                                   scratchDirectory: URL) async -> Answer {
        if agentKey == "kimi" {
            return await kimiAnswer(binary: binary, scratchDirectory: scratchDirectory)
        }
        return Answer(kind: await kind(agentKey: agentKey, binary: binary,
                                       scratchDirectory: scratchDirectory))
    }

    nonisolated private static func kimiAnswer(binary: String,
                                               scratchDirectory: URL) async -> Answer {
        switch await KimiWebServerCall.Session.start(binary: binary,
                                                     scratchDirectory: scratchDirectory) {
        case .failed:
            return Answer(kind: .unknown)
        case .started(let session):
            let who = await session.request(method: "GET", path: "/api/v1/oauth/userinfo")
            let site = await session.request(method: "GET", path: "/api/v1/oauth/region")
            await session.shutdown()
            var answer = Answer(kind: .unknown)
            if case .success(let body) = who,
               let verdict = KimiServerAnswer.userInfoVerdict(body: body) {
                answer.kind = verdict
            }
            if case .success(let body) = site {
                answer.kimiRegion = KimiServerAnswer.region(body: body)
            }
            return answer
        }
    }

    nonisolated private static func kind(agentKey: String, binary: String,
                                         scratchDirectory: URL) async -> PlanAccountKind {
        switch agentKey {
        case "claude_code":
            let result = await AgentCLIProbe.run(binary: binary,
                                                 arguments: ["auth", "status", "--json"],
                                                 ceiling: claudeCeiling,
                                                 outputCap: 64 * 1024,
                                                 currentDirectory: scratchDirectory.path,
                                                 onSpawn: { _ in })
            // The JSON object is the last thing printed; a warning
            // line above it must not defeat the parse.
            guard let start = result.output.firstIndex(of: "{"),
                  let status = ClaudeAuthStatus.parse(Data(result.output[start...].utf8))
            else { return .unknown }
            return status.verdict
        case "codex":
            let answer = await CodexAppServerCall.run(binary: binary,
                                                      request: CodexUsageProbe.accountRequest)
            return CodexUsageAnswer.accountKind(answer)
        default:
            return .unknown
        }
    }
}

// MARK: - A child on a PTY with a writable stdin

/// `claude auth login` is the one child that prints for a terminal and
/// may ask for a pasted code, so it gets a PTY on all three descriptors
/// — writing the master IS writing its stdin — and the same draining
/// loop every other child reader binds (`AgentRunner
/// .makeDrainingLineSource`, the third binding; never a fourth
/// spelling). `terminate()` SIGTERMs the child's own process group
/// (`Process` makes it a group leader), then SIGKILL goes to the pid
/// after the grace; nothing signals a group by hand.
final class InteractiveCLIProcess: @unchecked Sendable {
    private let process: Process
    private let masterFD: Int32
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var ended = false
    /// Owns the master descriptor (`closeOnDealloc`), so it is closed
    /// exactly when this object goes.
    fileprivate var masterHandle: FileHandle? = nil

    private init(process: Process, masterFD: Int32, source: DispatchSourceRead) {
        self.process = process
        self.masterFD = masterFD
        self.source = source
    }

    var isRunning: Bool { process.isRunning }

    nonisolated static func spawn(binary: String, arguments: [String],
                                  extraEnvironment: [String: String] = [:],
                                  onLine: @escaping (String) -> Void,
                                  onExit: @escaping (Int32?) -> Void) async -> InteractiveCLIProcess? {
        await ShellEnvironment.prepare()
        var environment = AgentRunner.buildEnvironment()
        for (name, value) in extraEnvironment { environment[name] = value }
        let stdio = AgentRunner.makeChildStdoutSource()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = arguments
        p.environment = environment
        p.standardInput = stdio.handleForChild
        p.standardOutput = stdio.handleForChild
        p.standardError = stdio.handleForChild
        let masterFD = stdio.readHandle.fileDescriptor
        p.terminationHandler = { proc in
            let code: Int32? = proc.isRunning ? nil : proc.terminationStatus
            onExit(code)
        }
        do {
            try p.run()
        } catch {
            // A spawn that fails leaves both ends of the PTY with us.
            stdio.cleanup()
            return nil
        }
        stdio.afterSpawn()
        let flags = fcntl(masterFD, F_GETFL, 0)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        let source = AgentRunner.makeDrainingLineSource(
            fd: masterFD,
            label: "sipai.guide.interactive.\(UUID().uuidString)",
            owner: nil,
            onLine: onLine,
            onEnd: { tail in
                if let last = String(data: tail, encoding: .utf8), !last.isEmpty { onLine(last) }
            })
        let child = InteractiveCLIProcess(process: p, masterFD: masterFD, source: source)
        // `stdio.readHandle` closes the master on dealloc; the child
        // keeps the handle alive for as long as it lives.
        child.masterHandle = stdio.readHandle
        source.resume()
        return child
    }

    /// Write to the child's stdin (a pasted code, with its newline).
    func write(_ text: String) {
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBufferPointer { buf in
                Darwin.write(masterFD, buf.baseAddress, buf.count)
            }
            if n <= 0 { break }
            written += n
        }
    }

    /// SIGTERM now, SIGKILL after the grace if ignored. Off the caller's
    /// thread, which must not sleep through the grace.
    func terminate() {
        lock.lock()
        let already = ended
        ended = true
        lock.unlock()
        guard !already, process.isRunning else { return }
        process.terminate()
        let p = process
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + AgentCLIProbe.terminateGrace
        ) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }
}

// MARK: - Codex: a long-lived app-server session

/// `codex app-server` held open across requests and NOTIFICATIONS —
/// the ChatGPT sign-in ends in an `account/login/completed`
/// notification whenever the browser finishes, minutes later. The
/// one-shot `CodexAppServerCall.run` exits at the answer; this keeps
/// stdin open until `close()`. Same environment, same pid-only stop.
final class CodexAppServerSession: @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let lock = NSLock()
    private var nextId = 10
    private var answers: [Int: [String: Any]] = [:]
    private var answerWaiters: [Int: [CheckedContinuation<[String: Any]?, Never>]] = [:]
    private struct NotificationWaiter {
        let matches: ([String: Any]) -> Bool
        let continuation: CheckedContinuation<[String: Any]?, Never>
    }
    private var notificationWaiters: [String: [NotificationWaiter]] = [:]
    private var notifications: [String: [[String: Any]]] = [:]
    private var closed = false
    private var buffer = Data()

    private init(process: Process, input: Pipe, output: Pipe) {
        self.process = process
        self.input = input
        self.output = output
    }

    /// Spawn and complete the handshake. nil when codex has no
    /// app-server or exited first.
    nonisolated static func start(binary: String) async -> CodexAppServerSession? {
        await ShellEnvironment.prepare()
        let environment = AgentRunner.buildEnvironment()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["app-server"]
        p.environment = environment
        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let session = CodexAppServerSession(process: p, input: input, output: output)
        session.startReader()
        session.send(CodexAppServerCall.handshake.joined(separator: "\n"))
        // `initialize`'s answer carries id 1; the handshake is not
        // complete until it lands.
        let hello = await session.awaitAnswer(id: 1, ceiling: CodexAppServerCall.ceiling)
        guard hello != nil else {
            await session.close()
            return nil
        }
        return session
    }

    /// One request; the answer object (`result` or `error`) or nil at
    /// the ceiling.
    func request(method: String, params: [String: Any],
                 ceiling: TimeInterval = CodexAppServerCall.ceiling) async -> [String: Any]? {
        // `withLock`: a bare `lock()` in an async function is the Swift 6
        // error-to-be (nothing here suspends while it is held).
        let id = lock.withLock { () -> Int in
            let id = nextId
            nextId += 1
            return id
        }
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ] as [String: Any]),
              let line = String(data: data, encoding: .utf8) else { return nil }
        send(line)
        return await awaitAnswer(id: id, ceiling: ceiling)
    }

    /// The next notification carrying `method` that `matches` (queued
    /// ones first). A login's completion is matched on its `loginId` —
    /// two attempts in one session (a cancelled ChatGPT login, then a
    /// key login) both complete under the same method name, and the
    /// first queued one is not necessarily this attempt's.
    func awaitNotification(method: String, ceiling: TimeInterval,
                           matching: @escaping ([String: Any]) -> Bool = { _ in true }) async -> [String: Any]? {
        let queuedMatch: [String: Any]? = lock.withLock {
            guard var queued = notifications[method],
                  let index = queued.firstIndex(where: matching) else { return nil }
            let found = queued.remove(at: index)
            notifications[method] = queued
            return found
        }
        if let queuedMatch { return queuedMatch }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any]?, Never>) in
            lock.withLock {
                notificationWaiters[method, default: []].append(
                    NotificationWaiter(matches: matching, continuation: continuation))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ceiling) { [weak self] in
                self?.timeOutNotification(method: method)
            }
        }
    }

    /// `account/login/completed` for one attempt: the notification's
    /// `loginId` (null for a key login) must equal the attempt's.
    nonisolated static func loginCompletion(for loginId: String?) -> ([String: Any]) -> Bool {
        { note in
            let params = note["params"] as? [String: Any]
            let id = params?["loginId"] as? String
            return id == loginId
        }
    }

    /// EOF on stdin ends a healthy app-server; the escalation is for
    /// one that does not go.
    func close() async {
        let already = lock.withLock { () -> Bool in
            let was = closed
            closed = true
            return was
        }
        guard !already else { return }
        try? input.fileHandleForWriting.close()
        let p = process
        let output = self.output
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let until = Date().addingTimeInterval(AgentCLIProbe.terminateGrace)
                while p.isRunning && Date() < until {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                AgentCLIProbe.stop(p)
                p.waitUntilExit()
                try? output.fileHandleForReading.close()
                continuation.resume()
            }
        }
        failAllWaiters()
    }

    deinit {
        if !closed {
            try? input.fileHandleForWriting.close()
            AgentCLIProbe.stop(process)
        }
    }

    // MARK: Internals

    private func send(_ line: String) {
        let fd = input.fileHandleForWriting.fileDescriptor
        let payload = Array((line + "\n").utf8)
        var written = 0
        while written < payload.count {
            let n = payload[written...].withUnsafeBufferPointer { buf in
                Darwin.write(fd, buf.baseAddress, buf.count)
            }
            if n <= 0 { break }
            written += n
        }
    }

    private func awaitAnswer(id: Int, ceiling: TimeInterval) async -> [String: Any]? {
        if let ready = lock.withLock({ answers.removeValue(forKey: id) }) {
            return ready
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any]?, Never>) in
            lock.withLock {
                answerWaiters[id, default: []].append(continuation)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ceiling) { [weak self] in
                self?.timeOutAnswer(id: id)
            }
        }
    }

    private func timeOutAnswer(id: Int) {
        lock.lock()
        let waiters = answerWaiters.removeValue(forKey: id) ?? []
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    private func timeOutNotification(method: String) {
        lock.lock()
        let waiters = notificationWaiters.removeValue(forKey: method) ?? []
        lock.unlock()
        for waiter in waiters { waiter.continuation.resume(returning: nil) }
    }

    private func failAllWaiters() {
        lock.lock()
        let answerLists = answerWaiters.values.flatMap { $0 }
        let noteLists = notificationWaiters.values.flatMap { $0 }
        answerWaiters = [:]
        notificationWaiters = [:]
        lock.unlock()
        for waiter in answerLists { waiter.resume(returning: nil) }
        for waiter in noteLists { waiter.continuation.resume(returning: nil) }
    }

    /// A raw read loop on its own thread — poll + read(2), errno
    /// captured with the result, EINTR a retry, EOF the end.
    private func startReader() {
        let fd = output.fileHandleForReading.fileDescriptor
        let thread = Thread { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 500)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 {
                    // Nothing to read: a live server is idle; a dead
                    // one with an empty pipe is done.
                    guard let self, self.process.isRunning else { break }
                    continue
                }
                let (count, err): (Int, Int32) = chunk.withUnsafeMutableBytes { raw in
                    let n = read(fd, raw.baseAddress, raw.count)
                    return (n, n < 0 ? errno : 0)
                }
                if count < 0 {
                    if err == EINTR || err == EAGAIN { continue }
                    break
                }
                if count == 0 { break }
                guard let self else { break }
                self.consume(chunk[0..<count])
            }
            self?.failAllWaiters()
        }
        thread.name = "sipai.guide.codex-app-server"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func consume(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        buffer.append(contentsOf: bytes)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
            else { continue }
            if let id = (obj["id"] as? NSNumber)?.intValue,
               obj["result"] != nil || obj["error"] != nil {
                lock.lock()
                let waiters = answerWaiters.removeValue(forKey: id) ?? []
                if waiters.isEmpty { answers[id] = obj }
                lock.unlock()
                for waiter in waiters { waiter.resume(returning: obj) }
            } else if let method = obj["method"] as? String, obj["id"] == nil {
                lock.lock()
                var remaining = notificationWaiters[method] ?? []
                var taker: NotificationWaiter? = nil
                if let index = remaining.firstIndex(where: { $0.matches(obj) }) {
                    taker = remaining.remove(at: index)
                }
                notificationWaiters[method] = remaining
                if taker == nil { notifications[method, default: []].append(obj) }
                lock.unlock()
                taker?.continuation.resume(returning: obj)
            }
        }
    }
}

// MARK: - Actions

/// What the Agent Guide's buttons do. One action in flight per agent;
/// progress and the tool's own words are published per agent for the
/// row to draw; every sentence the row shows is a catalog key made in
/// the view — this object publishes STATE, not prose.
@MainActor
final class AgentGuideActions: ObservableObject {
    static let shared = AgentGuideActions()

    enum Phase: Equatable {
        case probing
        case lookingUpVersion
        case downloading
        case installing
        /// A browser route waits for the user to Continue on the
        /// notice sheet; `BrowserStep` carries what it names.
        case awaitingBrowserConfirmation
        case waitingForBrowser
        case signingIn
        case signingOut
        case deleting
    }

    /// The notice sheet's facts: the host, the URL to open (codex,
    /// kimi — claude opens its own), the user code (kimi).
    struct BrowserStep: Equatable, Identifiable {
        let agentKey: String
        let host: String
        let url: URL?
        let userCode: String?
        var id: String { agentKey }
    }

    struct Progress: Equatable {
        var phase: Phase
        /// A tool-derived detail for the row (a version, a host).
        var detail: String? = nil
    }

    @Published private(set) var progress: [String: Progress] = [:]
    /// The tool's own words after a failure, per agent; cleared by the
    /// next action on that row. Verbatim — never translated.
    @Published private(set) var failures: [String: String] = [:]
    /// A browser route paused at the notice sheet.
    @Published private(set) var browserStep: BrowserStep? = nil
    /// The Guide's last structured probe answer per agent — refines
    /// the status sentence ("Signed in — Claude Max").
    @Published private(set) var probed: [String: PlanAccountKind] = [:]
    /// The Install action's own version lookup; the row names it.
    @Published private(set) var latestKnown: [String: CLIVersion] = [:]
    /// The site kimi would sign in to, as kimi's own local server answers
    /// it (`/oauth/region`, asked beside `/oauth/userinfo`): a saved
    /// login's site, else the site its installer came from, else kimi's
    /// default. The sign-in sheet presets its site question from it; nil
    /// — kimi did not answer — presets nothing.
    @Published private(set) var kimiRegion: String? = nil
    /// What the kimi row names beside "Signed in": the site a membership
    /// is on ("kimi.com" / "kimi.ai"), or the platform the key kimi runs
    /// on comes from ("platform.moonshot.cn"). nil names nothing.
    @Published private(set) var kimiAccountSite: String? = nil

    private weak var agents: AgentManager?
    private weak var config: ConfigManager?
    private var claudeChild: InteractiveCLIProcess? = nil
    private var codexSession: CodexAppServerSession? = nil
    private var codexLoginId: String? = nil
    private var kimiSession: KimiWebServerCall.Session? = nil
    private var pendingContinue: CheckedContinuation<Bool, Never>? = nil
    private var cancelRequested: Set<String> = []
    private var claudeOutput: [String: String] = [:]

    private init() {}

    func configure(agents: AgentManager, config: ConfigManager) {
        self.agents = agents
        self.config = config
    }

    func isBusy(_ key: String) -> Bool { progress[key] != nil }

    // MARK: Probe

    /// Ask every installed agent who it is signed in as; each answer
    /// lands in the usage monitor's verdict store under the current
    /// file fingerprint, so presence follows at once.
    func probeInstalled() {
        guard let agents else { return }
        for agent in agents.installedAgents where !isBusy(agent.key) {
            Task { await self.probe(agentKey: agent.key) }
        }
    }

    func probe(agentKey key: String) async {
        guard progress[key] == nil, let binary = AgentManager.binaryPath(for: key) else { return }
        progress[key] = Progress(phase: .probing)
        let scratch = await Task.detached(priority: .utility) { PlanUsageScratch.directory }.value
        let answer = await AgentAccountProbe.answer(agentKey: key, binary: binary,
                                                    scratchDirectory: scratch)
        if progress[key]?.phase == .probing { progress[key] = nil }
        await record(answer, agentKey: key)
    }

    private func record(_ answer: AgentAccountProbe.Answer, agentKey key: String) async {
        if key == "kimi", let region = answer.kimiRegion { kimiRegion = region }
        record(verdict: answer.kind, agentKey: key)
        if key == "kimi" { await refreshKimiAccountSite() }
    }

    /// The site or platform the kimi row names, from the verdict in force:
    /// a membership's site from kimi's own region answer — once signed
    /// in, that is the login's site — and a key's platform from the
    /// `base_url` of the provider kimi runs it through. Read off the
    /// MainActor; the row never reads a file in a body pass.
    private func refreshKimiAccountSite() async {
        let kind = probed["kimi"] ?? UsageMonitor.shared.accounts["kimi"] ?? .unknown
        switch kind {
        case .plan:
            kimiAccountSite = KimiSite(region: kimiRegion)?.domain
        case .apiKey:
            let file = KimiSessionScanner.configFile
            let base = await Task.detached(priority: .utility) { () -> String? in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return KimiConfigProviders.keyedBaseURL(configText: text)
            }.value
            kimiAccountSite = base.map(AgentSignIn.kimiKeyPlatform(forBaseURL:))
        case .signedOut, .unknown:
            kimiAccountSite = nil
        }
    }

    private func record(verdict probeVerdict: PlanAccountKind, agentKey key: String) {
        guard probeVerdict != .unknown else { return }
        // Read once: the verdict is keyed to the fingerprint of the
        // same files it is reconciled against.
        let reading = PlanAccountDetector.read(agentKey: key)
        let verdict = AgentAccountProbe.reconcile(file: reading.verdict, probe: probeVerdict)
        probed[key] = verdict
        UsageMonitor.shared.noteProbeVerdict(agentKey: key, kind: verdict,
                                             fingerprint: reading.fingerprint)
        if let agents, let config { agents.reload(config: config) }
    }

    // MARK: Install

    func install(agentKey key: String) {
        guard progress[key] == nil else { return }
        Task { await self.performInstall(agentKey: key) }
    }

    private func performInstall(agentKey key: String) async {
        guard let route = AgentInstallRoute.route(agentKey: key),
              let release = AgentCLIRelease.measured(agentKey: key) else { return }
        let monitor = AgentCLIUpdateMonitor.shared
        guard monitor.beginExternalAction(agentKey: key) else { return }
        failures[key] = nil
        cancelRequested.remove(key)
        defer { monitor.endExternalAction(agentKey: key) }

        // The version to install: the row cannot know it (the release
        // check runs for installed agents only), so the click is
        // consent for one GET of the same measured endpoint. Claude's
        // script resolves "latest" itself and needs none.
        var version: CLIVersion? = nil
        if key != "claude_code" {
            progress[key] = Progress(phase: .lookingUpVersion)
            version = await fetchLatest(release)
            guard let version else {
                failures[key] = String(localized: "The version could not be looked up, so nothing was downloaded.",
                                       comment: "Agent Guide: the install could not learn the latest version")
                progress[key] = nil
                return
            }
            latestKnown[key] = version
        }
        if cancelRequested.contains(key) { progress[key] = nil; return }

        progress[key] = Progress(phase: .downloading, detail: version?.text)
        let tail: String
        switch route {
        case .script(let url):
            let arguments: (String) -> [String] = { script in
                if key == "kimi", let version { return [script, "--version", version.text] }
                return [script]
            }
            // Kimi's installer decides whether to edit the shell's rc file
            // by what is on its PATH, so it gets Terminal's view of its
            // own directory (`AgentInstallRoute.kimiInstallerEnvironment`).
            var environment: [String: String] = [:]
            if key == "kimi" {
                await ShellEnvironment.prepare()
                environment = AgentInstallRoute.kimiInstallerEnvironment(
                    childPATH: AgentRunner.buildEnvironment()["PATH"] ?? "",
                    loginShellPath: ShellEnvironment.loginShellPathDirectories(),
                    home: FileManager.default.homeDirectoryForCurrentUser.path)
            }
            progress[key] = Progress(phase: .installing, detail: version?.text)
            tail = await monitor.runInstallerScript(url, arguments: arguments,
                                                    environment: environment, key: key)
        case .package:
            guard let version else { return }
            tail = await installCodexPackage(version: version, key: key)
        }

        agents?.reloadNow()
        let installed = AgentManager.binaryPath(for: key) != nil
        if installed {
            failures[key] = nil
            await monitor.refreshLocal()
            monitor.relearnAfterUpdate(agentKey: key)
            if key == "codex" || key == "claude_code" { await appendRCLineIfNeeded(key: key) }
        } else if cancelRequested.contains(key) {
            failures[key] = nil
        } else {
            let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            failures[key] = trimmed.isEmpty
                ? String(localized: "The installer printed nothing and the tool is still not installed.",
                         comment: "Agent Guide: an install produced no output and no binary")
                : trimmed
        }
        progress[key] = nil
    }

    private func fetchLatest(_ release: AgentCLIRelease) async -> CLIVersion? {
        var request = URLRequest(url: release.latestURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count <= AgentCLIUpdateMonitor.releasePayloadCap else { return nil }
        return release.version(from: data)
    }

    /// OpenAI's package: checksum file, the asset streamed to a 0700
    /// temp file, sha256 compared, extracted with the system tar into
    /// the dot-prefixed staging directory, the manifest read, the
    /// entrypoint asked its version, then the rename and the link.
    private func installCodexPackage(version: CLIVersion, key: String) async -> String {
        let machine = CodexPackageInstall.machineArchitecture()
        guard let asset = CodexPackageInstall.asset(machine: machine),
              let assetURL = CodexPackageInstall.assetURL(version: version.text, asset: asset),
              let sumsURL = CodexPackageInstall.sumsURL(version: version.text) else {
            return String(localized: "No package is published for this Mac's architecture (\(machine)).",
                          comment: "Agent Guide: codex's release has no package for this CPU; placeholder is the architecture")
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let layout = CodexPackageInstall.layout(home: home, version: version.text)

        guard let sums = await fetchSmall(sumsURL, cap: AgentCLIUpdateMonitor.releasePayloadCap),
              let expected = CodexPackageInstall.expectedDigest(
                sums: String(decoding: sums, as: UTF8.self), asset: asset) else {
            return String(localized: "OpenAI's checksum file could not be fetched, so nothing was downloaded.",
                          comment: "Agent Guide: the codex package's checksum list did not download")
        }
        if isCancelled(key) { return "" }

        progress[key] = Progress(phase: .downloading, detail: version.text)
        guard let downloaded = await download(assetURL, cap: CodexPackageInstall.packageCap, key: key) else {
            // A Cancel stops the transfer itself; a stop is not a failure.
            if isCancelled(key) { return "" }
            return String(localized: "The package could not be downloaded from \(assetURL.absoluteString).",
                          comment: "Agent Guide: the codex package did not download; placeholder is its URL")
        }
        defer { try? fm.removeItem(at: downloaded.deletingLastPathComponent()) }
        if isCancelled(key) { return "" }

        let actual = await Task.detached(priority: .utility) { sha256Hex(of: downloaded) }.value
        guard actual == expected else {
            return String(localized: "The download did not match OpenAI's checksum and was discarded (expected \(expected), got \(actual ?? "nothing")).",
                          comment: "Agent Guide: the codex package failed its checksum; placeholders are the two digests")
        }

        progress[key] = Progress(phase: .installing, detail: version.text)
        try? fm.removeItem(atPath: layout.staging)
        guard (try? fm.createDirectory(atPath: layout.staging, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o755])) != nil else {
            return String(localized: "The install folder could not be created at \(layout.root).",
                          comment: "Agent Guide: the codex install directory could not be made; placeholder is its path")
        }
        let untar = await AgentCLIProbe.run(binary: "/usr/bin/tar",
                                            arguments: ["-xzf", downloaded.path, "-C", layout.staging],
                                            ceiling: AgentCLIProbe.updateCeiling,
                                            outputCap: AgentCLIProbe.outputTailCap,
                                            onSpawn: { process in
            Task { @MainActor in
                AgentCLIUpdateMonitor.shared.adoptExternalProcess(process, agentKey: key)
            }
        })
        guard untar.exitCode == 0 else {
            try? fm.removeItem(atPath: layout.staging)
            return untar.output
        }
        guard let manifestData = fm.contents(atPath: layout.staging + "/codex-package.json"),
              let manifest = CodexPackageInstall.manifest(manifestData),
              manifest.version == version.text,
              fm.isExecutableFile(atPath: layout.staging + "/" + manifest.entrypoint) else {
            try? fm.removeItem(atPath: layout.staging)
            return String(localized: "The package did not carry the expected manifest and was discarded.",
                          comment: "Agent Guide: the codex package's codex-package.json was missing or named another version")
        }
        // Who made it, before any of it runs: a Developer ID signature by
        // OpenAI's team on every executable in the package
        // (`CodexPackageInstall.signingRequirement`).
        if let problem = await CodexPackageInstall.signatureProblem(
            packageRoot: layout.staging, entrypoint: manifest.entrypoint) {
            try? fm.removeItem(atPath: layout.staging)
            return problem
        }
        let probe = await AgentCLIProbe.run(binary: layout.staging + "/" + manifest.entrypoint,
                                            arguments: ["--version"],
                                            ceiling: AgentCLIProbe.versionCeiling,
                                            outputCap: 4096, onSpawn: { _ in })
        guard let answered = CLIVersion.parse(probe.output), answered == version else {
            try? fm.removeItem(atPath: layout.staging)
            return String(localized: "The downloaded codex did not answer with version \(version.text) and was discarded.",
                          comment: "Agent Guide: the extracted codex binary reported another version; placeholder is the expected version")
        }
        try? fm.removeItem(atPath: layout.versionDirectory)
        do {
            try fm.moveItem(atPath: layout.staging, toPath: layout.versionDirectory)
        } catch {
            try? fm.removeItem(atPath: layout.staging)
            return error.localizedDescription
        }
        // The link: made under a temp name and renamed over, so a
        // Terminal mid-command never sees a missing `codex`.
        try? fm.createDirectory(atPath: layout.binDirectory, withIntermediateDirectories: true)
        let target = layout.versionDirectory + "/" + manifest.entrypoint
        let temporary = layout.link + ".sipai-" + UUID().uuidString
        do {
            try fm.createSymbolicLink(atPath: temporary, withDestinationPath: target)
            if rename(temporary, layout.link) != 0 {
                try? fm.removeItem(atPath: temporary)
                throw POSIXError(.EEXIST)
            }
        } catch {
            return String(localized: "The codex command could not be placed at \(layout.link): \(error.localizedDescription)",
                          comment: "Agent Guide: the symlink for codex could not be written; placeholders are the path and the error")
        }
        // Older SipAI-installed versions go once the new link answers.
        if let entries = try? fm.contentsOfDirectory(atPath: layout.root) {
            for entry in entries where entry != version.text && !entry.hasPrefix(".") {
                try? fm.removeItem(atPath: layout.root + "/" + entry)
            }
        }
        return probe.output
    }

    private func fetchSmall(_ url: URL, cap: Int) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https",
              data.count <= cap, !data.isEmpty else { return nil }
        return data
    }

    /// Streamed to disk (a 120 MB body has no business in memory), in
    /// a 0700 directory of its own, https end to end, capped — and
    /// STOPPABLE. The transfer is no child process, so the monitor's
    /// slot is handed a way to cancel it (`adoptExternalCancellation`)
    /// beside the children it can signal; cancelling the task cancels
    /// the transfer (measured: the call threw `cancelled` 1.6 s into a
    /// 120 MB download). Without it the Guide's Cancel and the row's set
    /// flags the route read only once the whole body had arrived.
    private func download(_ url: URL, cap: Int, key: String) async -> URL? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 600)
        request.httpMethod = "GET"
        let transfer = Task { try await URLSession.shared.download(for: request) }
        AgentCLIUpdateMonitor.shared.adoptExternalCancellation(agentKey: key) { transfer.cancel() }
        guard let (temporary, response) = try? await transfer.value,
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https" else { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("sipai-package-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])) != nil else {
            try? fm.removeItem(at: temporary)
            return nil
        }
        let staged = dir.appendingPathComponent(url.lastPathComponent)
        guard (try? fm.moveItem(at: temporary, to: staged)) != nil,
              let size = (try? fm.attributesOfItem(atPath: staged.path))?[.size] as? NSNumber,
              size.intValue <= cap, size.intValue > 0 else {
            try? fm.removeItem(at: dir)
            return nil
        }
        return staged
    }

    /// One guarded line in the login shell's rc file, only when the
    /// shell's captured PATH lacks `~/.local/bin` and the file does not
    /// already name it — what both vendors' installers do for their
    /// own binaries. An empty capture skips the edit.
    private func appendRCLineIfNeeded(key: String) async {
        await ShellEnvironment.prepare()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        guard let rc = CodexPackageInstall.rcFile(shell: ShellEnvironment.loginShell, home: home,
                                                  exists: { fm.fileExists(atPath: $0) }) else { return }
        let text = try? String(contentsOfFile: rc.path, encoding: .utf8)
        guard CodexPackageInstall.needsRCLine(loginShellPath: ShellEnvironment.loginShellPathDirectories(),
                                              rcText: text, home: home) else { return }
        let existing = text ?? ""
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let addition = separator + "\n# Added by SipAI so Terminal finds the tools it installs\n" + rc.line + "\n"
        guard let data = addition.data(using: .utf8) else { return }
        try? fm.createDirectory(atPath: (rc.path as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: rc.path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            fm.createFile(atPath: rc.path, contents: data)
        }
    }

    /// Update a codex SipAI installed: the same package route at the
    /// version the row names (`codex update` declines that layout —
    /// measured), then the old version directory goes once the new
    /// link answers.
    ///
    /// Started from the Updates row or by the automatic update, so it is
    /// reported where the row is: the slot is held as an update
    /// (`beginExternalUpdate` puts the row's spinner up and its Cancel
    /// through), and the verdict goes back through `finishExternalUpdate`
    /// — the version moving, judged against what the row showed before —
    /// which is what prints "Update did not complete" and the tail, or
    /// nothing for a stop. The Guide's card shows only that the tool is
    /// busy, with Cancel; an outcome written into `failures` here would
    /// sit in a pane the click did not happen in.
    /// True when the update started; false when the tool is busy here
    /// (a probe, a sign-in) or the monitor's slot is held — the caller
    /// decides what an unstarted update means (the automatic update
    /// keeps its one attempt for later).
    @discardableResult
    func updateOwnedCodex(latest: CLIVersion) -> Bool {
        let key = "codex"
        guard progress[key] == nil else { return false }
        let monitor = AgentCLIUpdateMonitor.shared
        // The reading the row judged "behind". Captured first:
        // `refreshLocal` below moves it once the link repoints. The slot
        // is claimed before anything suspends, like `update()`'s.
        let before = monitor.installed[key]
        guard monitor.beginExternalUpdate(agentKey: key) else { return false }
        failures[key] = nil
        cancelRequested.remove(key)
        progress[key] = Progress(phase: .downloading, detail: latest.text)
        Task {
            let tail = await self.installCodexPackage(version: latest, key: key)
            await monitor.refreshLocal()
            let after = await AgentCLIProbe.installedVersion(agentKey: key,
                                                             fingerprint: AgentCLIProbe.fingerprint(agentKey: key))
            self.progress[key] = nil
            monitor.finishExternalUpdate(agentKey: key, before: before,
                                         after: after, tail: tail)
        }
        return true
    }

    // MARK: Sign in

    /// Begin a sign-in. Browser routes pause at the notice sheet
    /// (`browserStep`) until `continueBrowser` or `cancelSignIn`; the
    /// key route runs at once.
    /// `region` is the kimi site the user picked (`KimiSite.rawValue`),
    /// passed explicitly every time — a default would sign a kimi.ai
    /// account in on kimi.com. Ignored for the others.
    func signIn(agentKey key: String, method: AgentSignIn.Method,
                apiKey: String = "", region: String,
                kimiProviderId: String = "moonshotai") {
        // One browser notice at a time: the pending Continue is a
        // single slot, and a second sign-in would strand the first's.
        guard progress[key] == nil, pendingContinue == nil else { return }
        failures[key] = nil
        cancelRequested.remove(key)
        Task {
            await self.performSignIn(agentKey: key, method: method, apiKey: apiKey,
                                     region: region, kimiProviderId: kimiProviderId)
        }
    }

    /// The notice sheet's Continue / Cancel.
    func continueBrowser() {
        pendingContinue?.resume(returning: true)
        pendingContinue = nil
    }

    func cancelBrowser() {
        pendingContinue?.resume(returning: false)
        pendingContinue = nil
    }

    private func awaitBrowserConfirmation(_ step: BrowserStep) async -> Bool {
        browserStep = step
        progress[step.agentKey] = Progress(phase: .awaitingBrowserConfirmation, detail: step.host)
        let confirmed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingContinue = continuation
        }
        browserStep = nil
        return confirmed
    }

    private func performSignIn(agentKey key: String, method: AgentSignIn.Method,
                               apiKey: String, region: String, kimiProviderId: String) async {
        guard let binary = AgentManager.binaryPath(for: key) else { return }
        progress[key] = Progress(phase: .signingIn)
        defer {
            progress[key] = nil
            // Only this agent's handles: a codex key login ending while
            // claude's browser flow is still up must not drop the child
            // that flow's Cancel needs.
            switch key {
            case "claude_code": claudeChild = nil
            case "codex": codexSession = nil; codexLoginId = nil
            case "kimi": kimiSession = nil
            default: break
            }
        }
        switch key {
        case "claude_code":
            await signInClaude(binary: binary, method: method)
        case "codex":
            if method == .apiKey {
                await signInCodexKey(binary: binary, apiKey: apiKey)
            } else {
                await signInCodexChatGPT(binary: binary)
            }
        case "kimi":
            if method == .apiKey {
                await signInKimiKey(binary: binary, apiKey: apiKey, providerId: kimiProviderId)
            } else {
                await signInKimiMembership(binary: binary, region: region)
            }
        default:
            break
        }
        if !cancelRequested.contains(key) {
            await probeAfterAction(agentKey: key, binary: binary)
        }
    }

    private func probeAfterAction(agentKey key: String, binary: String) async {
        let scratch = await Task.detached(priority: .utility) { PlanUsageScratch.directory }.value
        let answer = await AgentAccountProbe.answer(agentKey: key, binary: binary,
                                                    scratchDirectory: scratch)
        await record(answer, agentKey: key)
        if answer.kind == .unknown, let agents, let config { agents.reload(config: config) }
    }

    /// `claude auth login [--console]` on a PTY. Claude opens the
    /// browser ITSELF, so the notice comes first; then the child runs
    /// until it exits (its own "Login successful" is a hint for the
    /// row, never the verdict — the probe after it is).
    private func signInClaude(binary: String, method: AgentSignIn.Method) async {
        let key = "claude_code"
        let host = AgentSignIn.claudeHost(method: method)
        let step = BrowserStep(agentKey: key, host: host, url: nil, userCode: nil)
        guard await awaitBrowserConfirmation(step) else { return }
        progress[key] = Progress(phase: .waitingForBrowser, detail: host)
        claudeOutput[key] = ""
        let exit = await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            let ceilingTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.signInCeiling * 1_000_000_000))
                self?.claudeChild?.terminate()
            }
            Task { @MainActor [weak self] in
                let child = await InteractiveCLIProcess.spawn(
                    binary: binary,
                    arguments: AgentSignIn.claudeArguments(method: method),
                    extraEnvironment: ["TERM": "xterm-256color"],
                    onLine: { line in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            var kept = (self.claudeOutput[key] ?? "") + line + "\n"
                            if kept.count > 16 * 1024 { kept = String(kept.suffix(8 * 1024)) }
                            self.claudeOutput[key] = kept
                        }
                    },
                    onExit: { code in
                        ceilingTask.cancel()
                        continuation.resume(returning: code)
                    })
                guard let child else {
                    ceilingTask.cancel()
                    continuation.resume(returning: nil)
                    return
                }
                self?.claudeChild = child
                if self?.cancelRequested.contains(key) == true { child.terminate() }
            }
        }
        if exit != 0, !cancelRequested.contains(key) {
            var said = TerminalText.strippingEscapes(claudeOutput[key] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // The terminal echoes the pasted sign-in code back; it is a
            // credential and must not sit in the failure text on screen.
            if let code = submittedClaudeCode, !code.isEmpty {
                said = said.replacingOccurrences(of: code, with: "••••")
            }
            failures[key] = said.isEmpty
                ? String(localized: "The sign-in did not complete.",
                         comment: "Agent Guide: the tool's login exited without signing in and printed nothing")
                : said
        }
        claudeOutput[key] = nil
        submittedClaudeCode = nil
    }

    /// The code the user pasted into the running claude sign-in, kept
    /// only to scrub its echo out of a failure text.
    private var submittedClaudeCode: String?

    /// A pasted code, when claude asks for one ("Paste code here if
    /// prompted").
    func submitClaudeCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        submittedClaudeCode = trimmed
        claudeChild?.write(trimmed + "\n")
    }

    static let signInCeiling: TimeInterval = 10 * 60

    private func signInCodexChatGPT(binary: String) async {
        let key = "codex"
        guard let session = await CodexAppServerSession.start(binary: binary) else {
            failures[key] = Self.noAppServer
            return
        }
        codexSession = session
        let started = await session.request(method: "account/login/start",
                                            params: ["type": "chatgpt"])
        guard let result = started?["result"] as? [String: Any],
              let loginId = result["loginId"] as? String,
              let authUrl = (result["authUrl"] as? String).flatMap(URL.init(string:)) else {
            failures[key] = Self.refusal(started)
            await session.close()
            return
        }
        guard AgentSignIn.hostMatches(authUrl, expected: AgentSignIn.codexHost) else {
            failures[key] = String(localized: "The sign-in address was not on \(AgentSignIn.codexHost) and was not opened.",
                                   comment: "Agent Guide: codex handed back a login URL on an unexpected host; placeholder is the expected host")
            _ = await session.request(method: "account/login/cancel", params: ["loginId": loginId])
            await session.close()
            return
        }
        codexLoginId = loginId
        let step = BrowserStep(agentKey: key, host: AgentSignIn.codexHost, url: authUrl, userCode: nil)
        guard await awaitBrowserConfirmation(step) else {
            _ = await session.request(method: "account/login/cancel", params: ["loginId": loginId])
            await session.close()
            return
        }
        progress[key] = Progress(phase: .waitingForBrowser, detail: AgentSignIn.codexHost)
        NSWorkspace.shared.open(authUrl)
        let completed = await session.awaitNotification(
            method: "account/login/completed", ceiling: Self.signInCeiling,
            matching: CodexAppServerSession.loginCompletion(for: loginId))
        if let params = completed?["params"] as? [String: Any] {
            if (params["success"] as? Bool) != true {
                let error = params["error"] as? String ?? ""
                failures[key] = error.isEmpty ? String(localized: "The sign-in did not complete.",
                                                       comment: "Agent Guide: the tool's login exited without signing in and printed nothing") : error
            }
        } else if !cancelRequested.contains(key) {
            failures[key] = String(localized: "The browser sign-in was not completed in time.",
                                   comment: "Agent Guide: no login completion arrived inside the ceiling")
        }
        await session.close()
    }

    private func signInCodexKey(binary: String, apiKey: String) async {
        let key = "codex"
        guard let session = await CodexAppServerSession.start(binary: binary) else {
            failures[key] = Self.noAppServer
            return
        }
        let started = await session.request(method: "account/login/start",
                                            params: ["type": "apiKey", "apiKey": apiKey])
        if started?["result"] == nil {
            failures[key] = AgentSignIn.scrubbed(Self.refusal(started), secret: apiKey)
        }
        await session.close()
    }

    private func signInKimiMembership(binary: String, region: String) async {
        let key = "kimi"
        let scratch = await Task.detached(priority: .utility) { PlanUsageScratch.directory }.value
        let session: KimiWebServerCall.Session
        switch await KimiWebServerCall.Session.start(binary: binary, scratchDirectory: scratch) {
        case .failed(let why):
            failures[key] = why
            return
        case .started(let started):
            session = started
        }
        kimiSession = session
        let startAnswer = await session.request(method: "POST", path: "/api/v1/oauth/login",
                                                body: ["region": region])
        guard case .success(let body) = startAnswer,
              let start = KimiServerAnswer.loginStart(body: body) else {
            failures[key] = Self.serverDidNotAnswer(startAnswer)
            await session.shutdown()
            return
        }
        if start.status == "authenticated" {
            await session.shutdown()
            return
        }
        let expectedHost = AgentSignIn.kimiHost(region: region)
        guard let complete = start.verificationUriComplete.flatMap(URL.init(string:)),
              AgentSignIn.hostMatches(complete, expected: expectedHost) else {
            failures[key] = String(localized: "The sign-in address was not on \(expectedHost) and was not opened.",
                                   comment: "Agent Guide: codex handed back a login URL on an unexpected host; placeholder is the expected host")
            _ = await session.request(method: "DELETE", path: "/api/v1/oauth/login")
            await session.shutdown()
            return
        }
        let step = BrowserStep(agentKey: key, host: expectedHost, url: complete, userCode: start.userCode)
        guard await awaitBrowserConfirmation(step) else {
            _ = await session.request(method: "DELETE", path: "/api/v1/oauth/login")
            await session.shutdown()
            return
        }
        progress[key] = Progress(phase: .waitingForBrowser, detail: expectedHost)
        NSWorkspace.shared.open(complete)
        let deadline = Date().addingTimeInterval(min(Self.signInCeiling, TimeInterval(start.expiresIn)))
        var outcome: String? = nil
        while Date() < deadline, !cancelRequested.contains(key) {
            // The interval is the server's number: clamped, since a huge
            // one would overflow the multiplication and trap.
            try? await Task.sleep(nanoseconds: UInt64(min(max(start.interval, 2), 60)) * 1_000_000_000)
            if cancelRequested.contains(key) { break }
            let poll = await session.request(method: "GET", path: "/api/v1/oauth/login")
            guard case .success(let pollBody) = poll,
                  let state = KimiServerAnswer.loginPoll(body: pollBody) else { continue }
            if state.status == "authenticated" { outcome = nil; break }
            if let error = state.errorMessage, !error.isEmpty { outcome = error; break }
            if state.status != "pending" { outcome = state.status; break }
        }
        if cancelRequested.contains(key) {
            _ = await session.request(method: "DELETE", path: "/api/v1/oauth/login")
        } else if let outcome {
            failures[key] = outcome
        } else if Date() >= deadline {
            failures[key] = String(localized: "The browser sign-in was not completed in time.",
                                   comment: "Agent Guide: no login completion arrived inside the ceiling")
        }
        await session.shutdown()
    }

    /// `kimi provider catalog add <id> --default-model <first listed id>`
    /// with the key in `KIMI_REGISTRY_API_KEY`: kimi's own config writer.
    /// The key rides the ENVIRONMENT, which kimi reads when `--api-key`
    /// is absent: an argument is readable by every account on the Mac
    /// (`ps`) for as long as the command runs, an environment only by
    /// the user's own. A kimi too old to read it says an API key is
    /// missing, and only then is the argument used. The key is never
    /// logged and is scrubbed from the output tail before display. The
    /// default model comes from `catalog list <id>` first
    /// (`KimiCatalogListing`): without one the add succeeds and every
    /// turn fails "No model configured"; both commands fetch the same
    /// catalog, so a listing that fails is reported and nothing is
    /// written.
    private func signInKimiKey(binary: String, apiKey rawKey: String, providerId: String) async {
        let key = "kimi"
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let listing = await AgentCLIProbe.run(binary: binary,
                                              arguments: ["provider", "catalog", "list", providerId],
                                              ceiling: 60,
                                              outputCap: AgentCLIProbe.outputTailCap,
                                              onSpawn: { _ in })
        guard listing.exitCode == 0,
              let defaultModel = KimiCatalogListing.modelIds(from: listing.output).first else {
            let said = listing.output.trimmingCharacters(in: .whitespacesAndNewlines)
            failures[key] = said.isEmpty
                ? String(localized: "The provider's model list could not be fetched, so nothing was written.",
                         comment: "Agent Guide: kimi's catalog listing failed before the key sign-in")
                : said
            return
        }
        var result = await AgentCLIProbe.run(binary: binary,
                                             arguments: ["provider", "catalog", "add", providerId,
                                                         "--default-model", defaultModel],
                                             ceiling: 120,
                                             outputCap: AgentCLIProbe.outputTailCap,
                                             extraEnvironment: ["KIMI_REGISTRY_API_KEY": apiKey],
                                             onSpawn: { _ in })
        if result.exitCode != 0,
           result.output.range(of: "api key", options: .caseInsensitive) != nil
            || result.output.contains("--api-key") {
            result = await AgentCLIProbe.run(binary: binary,
                                             arguments: ["provider", "catalog", "add", providerId,
                                                         "--api-key", apiKey,
                                                         "--default-model", defaultModel],
                                             ceiling: 120,
                                             outputCap: AgentCLIProbe.outputTailCap,
                                             onSpawn: { _ in })
        }
        if result.exitCode != 0 {
            let said = AgentSignIn.scrubbed(result.output, secret: apiKey)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            failures[key] = said.isEmpty
                ? String(localized: "The sign-in did not complete.",
                         comment: "Agent Guide: the tool's login exited without signing in and printed nothing")
                : said
        }
    }

    /// Cancel a sign-in in flight: the claude child is stopped, codex's
    /// login cancelled through its own RPC, kimi's through its DELETE.
    func cancelSignIn(agentKey key: String) {
        cancelRequested.insert(key)
        if browserStep?.agentKey == key { cancelBrowser() }
        switch key {
        case "claude_code":
            claudeChild?.terminate()
        case "codex":
            if let session = codexSession, let loginId = codexLoginId {
                Task {
                    _ = await session.request(method: "account/login/cancel",
                                              params: ["loginId": loginId], ceiling: 5)
                    await session.close()
                }
            }
        default:
            // The kimi poll loop sees the flag at its next tick and
            // sends the DELETE itself.
            break
        }
    }

    /// Cancel an install or a delete: the monitor's slot stops the
    /// child the same way the update route does.
    func cancelInstall(agentKey key: String) {
        cancelRequested.insert(key)
        AgentCLIUpdateMonitor.shared.cancelUpdate(agentKey: key)
    }

    /// Whether Cancel has landed for this agent — from the Guide's card
    /// (which sets both flags) or from the Updates row's Cancel on the
    /// owned-codex route, which reaches only the monitor's slot. A
    /// checkpoint that read the Guide's set alone would carry a
    /// cancelled download on into the install and then report the
    /// killed `tar` as a FAILURE, where a stop is not one.
    private func isCancelled(_ key: String) -> Bool {
        cancelRequested.contains(key)
            || AgentCLIUpdateMonitor.shared.externalActionCancelled(agentKey: key)
    }

    // MARK: Sign out

    func signOut(agentKey key: String) {
        guard progress[key] == nil else { return }
        failures[key] = nil
        Task { await self.performSignOut(agentKey: key) }
    }

    private func performSignOut(agentKey key: String) async {
        guard let binary = AgentManager.binaryPath(for: key) else { return }
        progress[key] = Progress(phase: .signingOut)
        defer { progress[key] = nil }
        switch key {
        case "claude_code":
            let result = await AgentCLIProbe.run(binary: binary, arguments: ["auth", "logout"],
                                                 ceiling: 30, outputCap: 16 * 1024,
                                                 onSpawn: { _ in })
            if result.exitCode != 0 { failures[key] = result.output }
        case "codex":
            guard let session = await CodexAppServerSession.start(binary: binary) else {
                failures[key] = Self.noAppServer
                return
            }
            let answer = await session.request(method: "account/logout", params: [:])
            if answer?["result"] == nil { failures[key] = Self.refusal(answer) }
            await session.close()
        case "kimi":
            // A membership signs out through kimi's server; a key-based
            // provider is removed through kimi's own `provider remove`
            // (which takes the model aliases that referenced it — the
            // alert says so).
            let configText = try? String(contentsOf: KimiSessionScanner.configFile, encoding: .utf8)
            let keyProviders = configText.map(KimiConfigProviders.apiKeyProviderIds(configText:)) ?? []
            for id in keyProviders {
                let result = await AgentCLIProbe.run(binary: binary,
                                                     arguments: ["provider", "remove", id],
                                                     ceiling: 60, outputCap: 16 * 1024,
                                                     onSpawn: { _ in })
                if result.exitCode != 0 { failures[key] = result.output }
            }
            let scratch = await Task.detached(priority: .utility) { PlanUsageScratch.directory }.value
            if case .started(let session) = await KimiWebServerCall.Session.start(
                binary: binary, scratchDirectory: scratch) {
                _ = await session.request(method: "POST", path: "/api/v1/oauth/logout", body: [:])
                await session.shutdown()
            }
        default:
            break
        }
        await probeAfterAction(agentKey: key, binary: binary)
    }

    // MARK: Delete

    func delete(agentKey key: String, plan: [AgentDeletePlan.Step]) {
        guard progress[key] == nil else { return }
        failures[key] = nil
        cancelRequested.remove(key)
        Task { await self.performDelete(agentKey: key, plan: plan) }
    }

    private func performDelete(agentKey key: String, plan: [AgentDeletePlan.Step]) async {
        let monitor = AgentCLIUpdateMonitor.shared
        guard monitor.beginExternalAction(agentKey: key) else { return }
        progress[key] = Progress(phase: .deleting)
        defer {
            monitor.endExternalAction(agentKey: key)
            progress[key] = nil
        }
        var tail = ""
        for step in plan {
            if cancelRequested.contains(key) { break }
            switch step {
            case .remove(let path):
                let fm = FileManager.default
                if fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
                    do { try fm.removeItem(atPath: path) } catch { tail += error.localizedDescription + "\n" }
                }
            case .run(let binary, let arguments):
                let result = await AgentCLIProbe.run(binary: binary, arguments: arguments,
                                                     ceiling: AgentCLIProbe.updateCeiling,
                                                     outputCap: AgentCLIProbe.outputTailCap,
                                                     onSpawn: { process in
                    Task { @MainActor in
                        AgentCLIUpdateMonitor.shared.adoptExternalProcess(process, agentKey: key)
                    }
                })
                tail += result.output
            }
        }
        agents?.reloadNow()
        if AgentManager.binaryPath(for: key) == nil {
            failures[key] = nil
            monitor.forgetAgent(agentKey: key)
            UsageMonitor.shared.noteBinaryChanged(agentKey: key)
            probed[key] = nil
        } else if !cancelRequested.contains(key) {
            let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            failures[key] = trimmed.isEmpty
                ? String(localized: "The tool is still installed after the removal ran.",
                         comment: "Agent Guide: the delete plan ran and the binary is still found")
                : trimmed
        }
    }

    // MARK: Sentences the tool did not say

    private static var noAppServer: String {
        String(localized: "The tool's app server could not be started.",
               comment: "Agent Guide: codex's app-server did not start or complete its handshake")
    }

    private static func refusal(_ answer: [String: Any]?) -> String {
        if let error = answer?["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        return String(localized: "The tool did not answer.",
                      comment: "Agent Guide: a request to the tool's own server got no answer inside the ceiling")
    }

    private static func serverDidNotAnswer(_ answer: Result<Data, Error>) -> String {
        if case .failure(let error) = answer { return error.localizedDescription }
        return String(localized: "The tool did not answer.",
                      comment: "Agent Guide: a request to the tool's own server got no answer inside the ceiling")
    }
}

/// SHA-256 of a file, streamed. nil when the file cannot be read.
nonisolated func sha256Hex(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        guard let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
