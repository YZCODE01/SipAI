// An agent's sidebar section must not claim "(read only)" when it lists
// nothing to read.
//
// The bug, reported against 1.0.0: on a machine with no Claude Code CLI
// and no `~/.claude/projects`, the sidebar showed a section headed
// "Claude Code (read only)" whose only content was the line "Claude Code
// is not installed on this machine." The header promised sessions the
// section did not have and the body contradicted it one row down.
//
// The cause was three separate spellings of one question. The header
// suffix asked `isReady`, the body asked `isReady` / `hasAnyRows` /
// `isInstalled` in an if-chain, and the grouping menu asked
// `isInstalled || hasAnyRows`. Nothing made them agree, and the header's
// was the one that was wrong: it read the absence of a BINARY as the
// read-only tier, when read-only is a claim about ROWS.
//
// `AgentSectionTier` is now that one question. This harness pins its
// four verdicts, pins that the grouping menu still opens exactly where
// it used to, and then READS the two views to check they route through
// it rather than restating it — a third copy of a rule is how a harness
// comes to pass while the app is broken.
//
// The section itself is gone on such a machine: every agent now earns
// its sidebar section from `isAgentAvailable` (a CLI, or a session
// store), Claude Code included. So the tier's `.unavailable` case is
// reached only by a store that exists and holds nothing readable — an
// empty `~/.claude/projects`, or one whose sessions are all empty
// shells. It stays because that state is real, and because it is what
// the header must not call read-only.
//
// Nothing here is part of the app target: this directory sits outside
// SipAI/, so these files are never compiled into the product. The tier
// itself is extracted verbatim from the shipping source by run.sh.
//
//   ./run.sh [source-root]

import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    print(cond ? "  PASS  \(label)" : "  FAIL  \(label) \(detail)")
    if !cond { failures += 1 }
}

let sourceRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func source(_ relative: String) -> String {
    (try? String(contentsOfFile: sourceRoot + "/" + relative, encoding: .utf8)) ?? ""
}

// MARK: - 1. The four tiers

print("tier verdicts")

// A signed-in CLI is interactive whether or not it has ever been used —
// the "+ New session" row is the whole point of an empty one.
check("ready, with rows → interactive",
      AgentSectionTier.resolve(isReady: true, isInstalled: true, hasRows: true)
        == .interactive)
check("ready, no rows → interactive",
      AgentSectionTier.resolve(isReady: true, isInstalled: true, hasRows: false)
        == .interactive)

// The reported bug: nothing installed, nothing synced.
check("no CLI, no rows → unavailable",
      AgentSectionTier.resolve(isReady: false, isInstalled: false, hasRows: false)
        == .unavailable)

// The genuine read-only tier — a desktop app wrote sessions this machine
// has no CLI to drive.
check("no CLI, rows synced → readOnly",
      AgentSectionTier.resolve(isReady: false, isInstalled: false, hasRows: true)
        == .readOnly)

// Codex before `codex login`.
check("CLI present, auth missing, no rows → notConfigured",
      AgentSectionTier.resolve(isReady: false, isInstalled: true, hasRows: false)
        == .notConfigured)
check("CLI present, auth missing, rows → readOnly",
      AgentSectionTier.resolve(isReady: false, isInstalled: true, hasRows: true)
        == .readOnly)

// MARK: - 2. What the header may say

print("header suffix")

check("readOnly names the tier",
      AgentSectionTier.readOnly.namesTierInTitle)
check("unavailable does NOT name the tier",
      !AgentSectionTier.unavailable.namesTierInTitle,
      "— this is the reported bug: \"(read only)\" over an empty section")
check("notConfigured does NOT name the tier",
      !AgentSectionTier.notConfigured.namesTierInTitle,
      "— nothing to read; the body row names the sign-in step instead")
check("interactive does NOT name the tier",
      !AgentSectionTier.interactive.namesTierInTitle)

// Stated the other way round, so the rule survives a rename of the
// property: the suffix is earned by ROWS, never by a missing binary.
let namesTier: [(Bool, Bool, Bool)] = [
    (false, false, false), (false, false, true),
    (false, true, false), (false, true, true),
    (true, true, false), (true, true, true),
]
check("suffix appears exactly when rows exist and cannot be driven",
      namesTier.allSatisfy { ready, installed, rows in
          AgentSectionTier.resolve(isReady: ready,
                                   isInstalled: installed,
                                   hasRows: rows).namesTierInTitle
              == (!ready && rows)
      })

// MARK: - 3. The grouping menu did not move

print("grouping menu")

// Grouping is a read operation and was already gated correctly, on
// `isInstalled || hasAnyRows`. Routing it through the tier must not
// change where it opens — pinned across every reachable combination.
check("offersGrouping == (isInstalled || hasRows), all combinations",
      namesTier.allSatisfy { ready, installed, rows in
          AgentSectionTier.resolve(isReady: ready,
                                   isInstalled: installed,
                                   hasRows: rows).offersGrouping
              == (installed || rows)
      })
check("unavailable offers no grouping",
      !AgentSectionTier.unavailable.offersGrouping)

// MARK: - 4. What the old rule did, kept as the record

print("the rule this replaced")

// The 1.0.0 header suffix was `!isReady`, nothing more. It agrees with
// the tier on the two states that have rows and is wrong on both states
// that do not — which is why the bug needed no unusual machine to
// reproduce, only a machine without the CLI.
let oldRuleDisagreements = namesTier.filter { ready, installed, rows in
    let old = !ready
    let new = AgentSectionTier.resolve(isReady: ready,
                                       isInstalled: installed,
                                       hasRows: rows).namesTierInTitle
    return old != new
}
check("old `!isReady` suffix was wrong on exactly the two row-less tiers",
      oldRuleDisagreements.count == 2
        && oldRuleDisagreements.allSatisfy { !$0.2 },
      "— disagreed on \(oldRuleDisagreements.count) states")

// MARK: - 5. The views route through the tier

print("AgentSessionsSection.swift")

let section = source("SipAI/Views/Sidebar/AgentSessionsSection.swift")
check("file readable", !section.isEmpty, "— \(sourceRoot)")

check("the tier is resolved in exactly one place",
      section.components(separatedBy: "AgentSectionTier.resolve(").count - 1 == 1)
check("the header suffix asks the tier",
      section.contains("tier.namesTierInTitle"))
check("the header no longer branches on isReady",
      !section.contains("isReady ? agentName"),
      "— that expression IS the bug")
check("the body switches on the tier",
      section.contains("switch tier {"))
check("an unavailable section renders the not-installed row",
      section.range(of: "case .unavailable:\\s*\\n\\s*notInstalledRow",
                    options: .regularExpression) != nil)
check("a read-only section still renders its list",
      section.range(of: "case .readOnly:\\s*\\n\\s*readOnlyHintRow\\s*\\n\\s*sessionList",
                    options: .regularExpression) != nil)
check("the grouping menu asks the tier",
      section.contains("if tier.offersGrouping {"))
check("the grouping menu no longer restates its own guard",
      !section.contains("if isInstalled || hasAnyRows {"))

// MARK: - 6. Which sections exist at all

print("LeftSidebar.swift")

let sidebar = source("SipAI/Views/Sidebar/LeftSidebar.swift")
check("file readable", !sidebar.isEmpty, "— \(sourceRoot)")

// EVERY agent earns its section the same way — a CLI on this machine or
// a session store on disk. Claude Code used to be exempt and render on
// every machine; that exemption is what put an agent's name, and a
// "(read only)" suffix, in the sidebar of a machine that had neither.
// An agent nothing here can reach is not a section.
for (label, key, id) in [("claude", "claude_code", "agentClaude"),
                         ("codex", "codex", "agentCodex"),
                         ("kimi", "kimi", "agentKimi")] {
    check("the \(label) section is earned by availability",
          sidebar.contains("if agents.isAgentAvailable(\"\(key)\") { present.append(.\(id)) }"))
}
check("no agent section is appended unconditionally",
      sidebar.contains("present.append(contentsOf: [.chats, .chatGroups])")
        && !sidebar.contains(".chats, .chatGroups, .agentClaude"),
      "— that literal IS the exemption")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
