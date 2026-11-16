// Skills harness: the folder table, the scan and its rows, every file
// operation and its refusals, byte-preserving edits, the "once" rule, the
// wire text per agent, the three transcript readers, and the task file's
// `skills:` key — all against the real sources, over a throwaway tree.
// Nothing under the user's own home is read or written.

import Foundation

var passed = 0
var failed = 0

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
        print("  PASS \(name)")
    } else {
        failed += 1
        let d = detail()
        print("  FAIL \(name)" + (d.isEmpty ? "" : " — \(d)"))
    }
}

func section(_ title: String) { print("\n" + title) }

let fm = FileManager.default
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sipai-skills-harness-\(UUID().uuidString)", isDirectory: true)
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)

/// The tally, the scratch tree removed, and out. Every way out of the
/// harness is this one: `exit` runs no `defer`, and a tree left behind
/// by each run is thousands of files a run.
func finish() -> Never {
    print("\n\(passed)/\(passed + failed) checks passed")
    try? fm.removeItem(at: scratch)
    exit(failed == 0 ? 0 : 1)
}
// The canonical spelling, `/private` included, so paths compare.
let root = URL(fileURLWithPath: SkillScan.realPath(scratch.path)!, isDirectory: true)
let home = root.appendingPathComponent("home", isDirectory: true)
let env = SkillEnvironment.resolve([:], home: home)

func write(_ path: URL, _ text: String) {
    try! fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: path)
}

func skill(_ dir: URL, name: String, description: String, extra: String = "", body: String = "Body.\n") {
    write(dir.appendingPathComponent("SKILL.md"),
          "---\nname: \(name)\ndescription: \(description)\n\(extra)---\n\n\(body)")
}

func link(_ at: URL, to target: URL) {
    try! fm.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! fm.createSymbolicLink(atPath: at.path, withDestinationPath: target.path)
}

func isLink(_ path: String) -> Bool {
    (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
}

// MARK: - 1. Folders

section("1. Folders")
do {
    let custom = SkillEnvironment.resolve(["CLAUDE_CONFIG_DIR": "/x/claude", "CODEX_HOME": "/x/codex",
                                           "KIMI_CODE_HOME": "/x/kimi"], home: home)
    check("CLAUDE_CONFIG_DIR moves claude's folder",
          SkillRoots.ownFolder(agent: SkillAgent.claude, scope: .global, env: custom, projectRoot: nil)?.path
            == "/x/claude/skills")
    check("CODEX_HOME moves codex's folder",
          SkillRoots.ownFolder(agent: SkillAgent.codex, scope: .global, env: custom, projectRoot: nil)?.path
            == "/x/codex/skills")
    check("KIMI_CODE_HOME moves kimi's folder",
          SkillRoots.ownFolder(agent: SkillAgent.kimi, scope: .global, env: custom, projectRoot: nil)?.path
            == "/x/kimi/skills")
    let proj = URL(fileURLWithPath: "/p/proj")
    check("folder skills: .claude/.codex/.kimi-code under the project root",
          SkillRoots.ownFolder(agent: SkillAgent.claude, scope: .folder, env: env, projectRoot: proj)?.path
            == "/p/proj/.claude/skills"
          && SkillRoots.ownFolder(agent: SkillAgent.codex, scope: .folder, env: env, projectRoot: proj)?.path
               == "/p/proj/.codex/skills"
          && SkillRoots.ownFolder(agent: SkillAgent.kimi, scope: .folder, env: env, projectRoot: proj)?.path
               == "/p/proj/.kimi-code/skills")
    check("the library sits at the agents' depth",
          SkillRoots.library(scope: .global, env: env, projectRoot: nil).path == home.path + "/.sipai/skills"
          && SkillRoots.library(scope: .folder, env: env, projectRoot: proj).path == "/p/proj/.sipai/skills")
    let gitRoot = SkillRoots.projectRoot(of: URL(fileURLWithPath: "/r/a/b"),
                                         fileExists: { $0 == "/r/.git" })
    check("project root = nearest .git ancestor", gitRoot.path == "/r")
    let noGit = SkillRoots.projectRoot(of: URL(fileURLWithPath: "/r/a/b"), fileExists: { _ in false })
    check("no .git: the folder itself", noGit.path == "/r/a/b")
}

// MARK: - 2. Scan and rows

section("2. Scan and rows")
let project = root.appendingPathComponent("work/proj", isDirectory: true)
try! fm.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
let lib = SkillRoots.library(scope: .global, env: env, projectRoot: nil)
// A key SkillAgent names: never nil.
let claudeDir = SkillRoots.ownFolder(agent: SkillAgent.claude, scope: .global,
                                  env: env, projectRoot: nil)!
// A key SkillAgent names: never nil.
let codexDir = SkillRoots.ownFolder(agent: SkillAgent.codex, scope: .global,
                                  env: env, projectRoot: nil)!
// A key SkillAgent names: never nil.
let kimiDir = SkillRoots.ownFolder(agent: SkillAgent.kimi, scope: .global,
                                  env: env, projectRoot: nil)!
let projCommon = SkillRoots.common(scope: .folder, env: env, projectRoot: project)

// shared: library skill linked into claude and codex
skill(lib.appendingPathComponent("review-pr"), name: "review-pr", description: "Review a PR.")
link(claudeDir.appendingPathComponent("review-pr"), to: lib.appendingPathComponent("review-pr"))
link(codexDir.appendingPathComponent("review-pr"), to: lib.appendingPathComponent("review-pr"))
// claude-only skill, its own folder
skill(claudeDir.appendingPathComponent("commit-msg"), name: "commit-msg", description: "Write a commit message.",
      extra: "disable-model-invocation: true\nallowed-tools: Bash(git *)\n")
// not in use: library skill nobody links
skill(lib.appendingPathComponent("spare"), name: "spare", description: "Nobody has it.")
// common folder in the project: codex + kimi
skill(projCommon.appendingPathComponent("triage"), name: "triage", description: "Search.")
// broken link in kimi's folder
link(kimiDir.appendingPathComponent("gone"), to: root.appendingPathComponent("nowhere/gone"))
// clash: two real folders, one name, both reach codex
skill(codexDir.appendingPathComponent("dupe"), name: "dupe", description: "First.")
skill(project.appendingPathComponent(".codex/skills/dupe"), name: "dupe", description: "Second.")
// codex built-in
skill(env.codexHome.appendingPathComponent("skills/.system/imagegen"), name: "imagegen", description: "Built in.")
// a dot-prefixed staging folder is never a skill
skill(lib.appendingPathComponent(".half.sipai-new-1234"), name: "half", description: "Staged.")

let roots = SkillRoots.scanRoots(env: env, folder: project)
let found = SkillScan.read(roots: roots)
let rows = SkillGrouping.rows(entries: SkillScan.entries(from: found), library: found, roots: roots)
func row(_ name: String) -> SkillRow? { rows.first { $0.name == name } }
let listed = SkillAgent.all

check("a shared skill is one row with two agents, drawn under each with the other named",
      row("review-pr")?.agents == [SkillAgent.claude, SkillAgent.codex]
      && row("review-pr").map { SkillListing.sharedWith($0, besides: SkillAgent.claude, listed: listed) } == [SkillAgent.codex]
      && row("review-pr").map { SkillListing.sharedWith($0, besides: SkillAgent.codex, listed: listed) } == [SkillAgent.claude]
      && SkillListing.rows(of: SkillAgent.claude, in: rows).contains { $0.name == "review-pr" }
      && SkillListing.rows(of: SkillAgent.codex, in: rows).contains { $0.name == "review-pr" })
check("its home is the library", row("review-pr")?.home == .library)
check("an agent's own skill is drawn under that agent alone, with no one named beside it",
      SkillListing.rows(of: SkillAgent.claude, in: rows).contains { $0.name == "commit-msg" }
      && !SkillListing.rows(of: SkillAgent.codex, in: rows).contains { $0.name == "commit-msg" }
      && row("commit-msg").map { SkillListing.sharedWith($0, besides: SkillAgent.claude, listed: listed) } == []
      && row("commit-msg")?.home == .agentFolder(SkillAgent.claude))
check("a library skill nobody has is Not in use", SkillListing.unused(rows, listed: listed).map(\.name) == ["spare"])
check("a common-folder skill is Codex's and Kimi's",
      row("triage")?.agents == [SkillAgent.codex, SkillAgent.kimi]
      && row("triage")?.home == .common && row("triage")?.scope == .folder)
check("a broken link is a row with the problem",
      rows.contains { $0.problems.contains(.brokenLink) && $0.name == "gone" })
check("two folders of one name reaching codex clash",
      rows.filter { $0.name == "dupe" }.count == 2
      && rows.filter { $0.name == "dupe" }.allSatisfy { $0.problems.contains(.clash) })
check("codex's built-in folder is read-only", row("imagegen")?.isReadOnly == true)
check("a dot-prefixed staging folder is never listed", row("half") == nil)
check("frontmatter: only-when-called and allowed tools",
      row("commit-msg")?.frontmatter.disableModelInvocation == true
      && row("commit-msg")?.frontmatter.allowedTools == "Bash(git *)")
check("file state: only when called", row("commit-msg").flatMap { $0.entries[SkillAgent.claude] }
        .map { SkillGrouping.fileState(of: $0) } == .userInvocableOnly)
check("the share hint names listed agents only",
      row("review-pr").map { SkillListing.sharedWith($0, besides: SkillAgent.claude, listed: [SkillAgent.claude]) } == [])
check("the hint: a linked skill names the others, and no folder",
      row("review-pr").flatMap { SkillListing.hint($0, under: SkillAgent.claude, listed: listed) }
        == SkillShareHint(sharedWith: [SkillAgent.codex], inCommonFolder: false))
check("…a common-folder skill names the other of its two readers, and the common folder",
      row("triage").flatMap { SkillListing.hint($0, under: SkillAgent.codex, listed: listed) }
        == SkillShareHint(sharedWith: [SkillAgent.kimi], inCommonFolder: true)
      && row("triage").flatMap { SkillListing.hint($0, under: SkillAgent.kimi, listed: listed) }
        == SkillShareHint(sharedWith: [SkillAgent.codex], inCommonFolder: true))
check("…with its other reader not listed it still says where it is, and names nobody",
      row("triage").flatMap { SkillListing.hint($0, under: SkillAgent.codex, listed: [SkillAgent.claude, SkillAgent.codex]) }
        == SkillShareHint(sharedWith: [], inCommonFolder: true))
check("…and an agent's own skill, in its own folder, has no hint",
      row("commit-msg").map { SkillListing.hint($0, under: SkillAgent.claude, listed: listed) } == .some(nil)
      && row("review-pr").map { SkillListing.hint($0, under: SkillAgent.claude, listed: [SkillAgent.claude]) } == .some(nil))
check("Share With offers every other listed agent, ticked where it has the skill already",
      row("review-pr").map { SkillListing.shareTargets($0, from: SkillAgent.claude, listed: listed) }
        == [SkillShareTarget(agent: SkillAgent.codex, has: true), SkillShareTarget(agent: SkillAgent.kimi, has: false)])
check("…and nobody for a skill an agent manages itself, or a link to nothing",
      row("imagegen").map { SkillListing.shareTargets($0, from: SkillAgent.codex, listed: listed) } == []
      && rows.first { $0.problems.contains(.brokenLink) }
        .map { SkillListing.shareTargets($0, from: SkillAgent.kimi, listed: listed) } == [])
check("a library skill no agent has can go to any listed agent",
      row("spare").map { SkillListing.shareTargets($0, from: nil, listed: listed).map(\.agent) } == listed)
check("an agent that has ANOTHER skill of the name is told apart from one that has this one",
      rows.first { $0.name == "dupe" }.map { SkillListing.nameTaken(by: SkillAgent.codex, for: $0, in: rows) } == true
      && row("review-pr").map { SkillListing.nameTaken(by: SkillAgent.codex, for: $0, in: rows) } == false)

// Claude's own account of each skill's state, in the shape its
// `get_skills_dialog` answers: filed by where the skill came from, a
// claude.ai skill named with a namespace and shown bare.
do {
    let dialog: [[String: Any]] = [
        ["name": "commit-msg", "display_name": "commit-msg", "source": "user", "state": "off"],
        ["name": "anthropic-skills:docs", "display_name": "docs", "source": "claude.ai sync", "state": "off"],
        ["name": "figma:figma-use", "display_name": "figma:figma-use", "source": "plugin",
         "state": "user-invocable-only", "locked_by": "plugin"],
        ["name": "odd", "source": "user", "state": "something-new"],
    ]
    let states = ClaudeSkillDialog.states(dialog)
    func entry(_ name: String, kind: SkillRootKind, scope: SkillScope = .global, label: String? = nil) -> SkillEntry {
        SkillEntry(agent: SkillAgent.claude, name: name, description: "", scope: scope, rootKind: kind,
                   entryPath: "", realPath: nil, isLink: false, frontmatter: SkillFrontmatter(),
                   sourceLabel: label)
    }
    check("claude's dialog: a user skill's state",
          ClaudeSkillDialog.state(of: entry("commit-msg", kind: .own), in: states) == .off)
    check("…a claude.ai skill is found by the name its folder carries",
          ClaudeSkillDialog.state(of: entry("docs", kind: .readOnly, label: "claude.ai"), in: states) == .off)
    check("…a plugin skill by its namespaced name",
          ClaudeSkillDialog.state(of: entry("figma:figma-use", kind: .readOnly, label: "Plugin"), in: states) == .userInvocableOnly)
    check("…a project skill is not a user skill of the same name",
          ClaudeSkillDialog.state(of: entry("commit-msg", kind: .own, scope: .folder), in: states) == nil)
    check("…a state this app does not know is no state", states["user|odd"] == nil)
}

// MARK: - 3. File operations

section("3. File operations")
let ops = SkillFileOps(env: env, projectRoot: project)
do {
    // Give kimi the shared skill: one link in kimi's folder.
    let r = row("review-pr")!
    let plan = SkillPlanner.plan(row: r, agent: SkillAgent.kimi, include: true, env: env, projectRoot: project)!
    check("giving a library skill is one link", plan.steps.count == 1 && !plan.movesFiles)
    try ops.run(plan, projectRoot: project)
    let at = kimiDir.appendingPathComponent("review-pr").path
    check("…the link is there and points at the library",
          isLink(at) && SkillScan.realPath(at) == SkillScan.realPath(lib.appendingPathComponent("review-pr").path))
    // Take it away again.
    let rows2 = SkillGrouping.rows(entries: SkillScan.entries(from: SkillScan.read(roots: roots)),
                                   library: SkillScan.read(roots: roots), roots: roots)
    let r2 = rows2.first { $0.name == "review-pr" }!
    let back = SkillPlanner.plan(row: r2, agent: SkillAgent.kimi, include: false, env: env, projectRoot: project)!
    check("taking a linked skill is one unlink", back.steps == [.unlink(at: at)])
    try ops.run(back, projectRoot: project)
    check("…the link is gone, the library copy stays",
          !fm.fileExists(atPath: at) && fm.fileExists(atPath: lib.appendingPathComponent("review-pr/SKILL.md").path))
} catch {
    check("share and unshare", false, "\(error)")
}

do {
    // Share claude's own skill with codex: it moves into the library.
    let r = row("commit-msg")!
    let plan = SkillPlanner.plan(row: r, agent: SkillAgent.codex, include: true, env: env, projectRoot: project)!
    check("sharing an agent's own skill moves it", plan.movesFiles)
    try ops.run(plan, projectRoot: project)
    let moved = lib.appendingPathComponent("commit-msg")
    check("…its folder is in the library", fm.fileExists(atPath: moved.appendingPathComponent("SKILL.md").path))
    check("…claude keeps it through a link where it was",
          isLink(claudeDir.appendingPathComponent("commit-msg").path))
    check("…codex has a link too", isLink(codexDir.appendingPathComponent("commit-msg").path))
} catch {
    check("move into the library", false, "\(error)")
}

do {
    // Untick kimi on the common-folder skill: it leaves the common folder
    // and codex keeps it through a link.
    let scanned = SkillScan.read(roots: roots)
    let r = SkillGrouping.rows(entries: SkillScan.entries(from: scanned), library: scanned, roots: roots)
        .first { $0.name == "triage" }!
    let plan = SkillPlanner.plan(row: r, agent: SkillAgent.kimi, include: false, env: env, projectRoot: project)!
    check("unticking one of a common folder's two moves it", plan.movesFiles)
    try ops.run(plan, projectRoot: project)
    let projLib = SkillRoots.library(scope: .folder, env: env, projectRoot: project)
    check("…into the folder's library", fm.fileExists(atPath: projLib.appendingPathComponent("triage/SKILL.md").path))
    check("…and codex keeps it in its own folder",
          isLink(project.appendingPathComponent(".codex/skills/triage").path))
    check("…and the common folder no longer holds it",
          !fm.fileExists(atPath: projCommon.appendingPathComponent("triage").path))
} catch {
    check("split a common-folder skill", false, "\(error)")
}

do {
    // The last agent: keep or trash is the caller's.
    let scanned = SkillScan.read(roots: roots)
    let r = SkillGrouping.rows(entries: SkillScan.entries(from: scanned), library: scanned, roots: roots)
        .first { $0.name == "dupe" && $0.realPath?.contains("/home/") == true }!
    let plan = SkillPlanner.plan(row: r, agent: SkillAgent.codex, include: false, env: env, projectRoot: project)!
    check("unticking the last agent asks keep-or-trash", plan.needsKeepOrTrash)
    let trash = SkillPlanner.plan(row: r, agent: SkillAgent.codex, include: false, env: env,
                                  projectRoot: project, keepWhenLast: false)!
    check("…and trash is a trash step", trash.steps.contains { if case .trash = $0 { return true }; return false })
}

section("3b. Refusals")
do {
    // An unlink of a real folder is refused: lstat must prove a link.
    let real = claudeDir.appendingPathComponent("real-one")
    skill(real, name: "real-one", description: "Real.")
    do {
        try ops.run(SkillSharePlan(steps: [.unlink(at: real.path)]), projectRoot: project)
        check("unlinking a real folder is refused", false, "it ran")
    } catch let e as SkillOpError {
        check("unlinking a real folder is refused", e == .notALink(real.path), "\(e)")
    }
    check("…and the folder is still there", fm.fileExists(atPath: real.appendingPathComponent("SKILL.md").path))
    // A move out of somewhere SipAI does not write is refused.
    let outside = root.appendingPathComponent("elsewhere/x")
    skill(outside, name: "x", description: "x")
    do {
        try ops.run(SkillSharePlan(steps: [.move(from: outside.path, to: lib.appendingPathComponent("x").path)]),
                    projectRoot: project)
        check("a move from outside the managed folders is refused", false, "it ran")
    } catch {
        check("a move from outside the managed folders is refused", true)
    }
    check("…and nothing moved", fm.fileExists(atPath: outside.appendingPathComponent("SKILL.md").path))
    // A trash outside them too.
    do {
        try ops.run(SkillSharePlan(steps: [.trash(outside.path)]), projectRoot: project)
        check("trashing outside the managed folders is refused", false, "it ran")
    } catch {
        check("trashing outside the managed folders is refused", fm.fileExists(atPath: outside.path))
    }
    // Names.
    for bad in ["", "Bad", "two--hyphens", "-lead", "trail-", "dots.no", "../up", String(repeating: "a", count: 65)] {
        check("name refused: \"\(bad.prefix(12))\"", !SkillName.isValid(bad))
    }
    for good in ["a", "review-pr", "x1-y2"] { check("name accepted: \(good)", SkillName.isValid(good)) }
    check("suggestion makes a name", SkillName.suggestion("My Skill (v2)!") == "my-skill-v2")
    do {
        _ = try ops.create(name: "Bad Name", description: "d", body: "b", onlyWhenCalled: false,
                           scope: .global, agents: [SkillAgent.claude], env: env, projectRoot: nil)
        check("create refuses a bad name", false)
    } catch let e as SkillOpError {
        check("create refuses a bad name", e == .invalidName("Bad Name"))
    }
    do {
        _ = try ops.create(name: "review-pr", description: "d", body: "b", onlyWhenCalled: false,
                           scope: .global, agents: [SkillAgent.claude], env: env, projectRoot: nil)
        check("create refuses a taken name", false)
    } catch let e as SkillOpError {
        if case .exists = e { check("create refuses a taken name", true) }
        else { check("create refuses a taken name", false, "\(e)") }
    }
} catch {
    check("refusals", false, "\(error)")
}

section("3c. Create, import, edit, delete")
do {
    let dest = try ops.create(name: "new-one", description: "Brand new.", body: "Do the thing.\n",
                              onlyWhenCalled: true, scope: .global,
                              agents: [SkillAgent.claude, SkillAgent.codex], env: env, projectRoot: nil)
    let text = try String(contentsOfFile: dest + "/SKILL.md", encoding: .utf8)
    let parsed = SkillFrontmatter.parse(text)
    check("create writes the library copy", parsed.name == "new-one" && parsed.description == "Brand new.")
    check("…only when called, for claude and kimi", parsed.disableModelInvocation)
    check("…and codex's policy file says so",
          !SkillCodexPolicy.allowsImplicitInvocation(yaml: try? String(contentsOfFile: dest + "/agents/openai.yaml", encoding: .utf8)))
    check("…linked into the ticked agents",
          isLink(claudeDir.appendingPathComponent("new-one").path) && isLink(codexDir.appendingPathComponent("new-one").path)
          && !fm.fileExists(atPath: kimiDir.appendingPathComponent("new-one").path))
    check("…no staging folder left behind (beside the one planted above)",
          ((try? fm.contentsOfDirectory(atPath: lib.path)) ?? [])
            .allSatisfy { !$0.contains("sipai-new") || $0 == ".half.sipai-new-1234" })

    // Edit: unknown keys and every other byte kept.
    let file = lib.appendingPathComponent("review-pr/SKILL.md")
    write(file, "---\nname: review-pr\ndescription: Old.\nmetadata:\n  owner: team\nlicense: MIT\n---\n\nOld body.\n")
    let before = try String(contentsOf: file, encoding: .utf8)
    try ops.edit(realPath: lib.appendingPathComponent("review-pr").path, expected: before,
                 description: "New words.", body: "New body.\n", onlyWhenCalled: false)
    let after = try String(contentsOf: file, encoding: .utf8)
    check("edit keeps keys it does not own", after.contains("metadata:\n  owner: team\n") && after.contains("license: MIT\n"))
    check("…and changes what it was asked to", SkillFrontmatter.parse(after).description == "New words."
          && SkillFrontmatter.parse(after).body.contains("New body."))
    do {
        try ops.edit(realPath: lib.appendingPathComponent("review-pr").path, expected: before,
                     description: "x", body: "y", onlyWhenCalled: false)
        check("an edit against a changed file is refused", false)
    } catch let e as SkillOpError {
        check("an edit against a changed file is refused", e == .changedOnDisk)
    }
    let unchanged = SkillFileEdit.updated(after, description: nil, body: nil, onlyWhenCalled: false)
    check("an edit that changes nothing is byte-identical", unchanged == after)

    // Codex's policy file: other keys kept, a flow-style file refused.
    let yaml = "interface:\n  display_name: \"X\"\npolicy:\n  allow_implicit_invocation: true\n"
    let off = try SkillFileEdit.codexPolicy(yaml, onlyWhenCalled: true)
    check("policy edit keeps the rest", off?.contains("display_name: \"X\"") == true
          && !SkillCodexPolicy.allowsImplicitInvocation(yaml: off))
    do {
        _ = try SkillFileEdit.codexPolicy("policy: {allow_implicit_invocation: true}\n", onlyWhenCalled: true)
        check("flow-style YAML is refused", false)
    } catch {
        check("flow-style YAML is refused", true)
    }

    // Import: a folder copied in, its links kept as links.
    let source = root.appendingPathComponent("downloads/fancy")
    skill(source, name: "fancy", description: "From elsewhere.")
    write(source.appendingPathComponent("scripts/run.sh"), "#!/bin/sh\necho hi\n")
    check("scripts are counted", SkillFileOps.scriptCount(in: source) == 1)
    _ = try ops.importFolder(source, name: "fancy", scope: .global, agents: [SkillAgent.kimi],
                             env: env, projectRoot: nil)
    check("import copies into the library and links",
          fm.fileExists(atPath: lib.appendingPathComponent("fancy/scripts/run.sh").path)
          && isLink(kimiDir.appendingPathComponent("fancy").path)
          && fm.fileExists(atPath: source.appendingPathComponent("SKILL.md").path))

    // Delete: links go, the folder to the Trash.
    let scanned = SkillScan.read(roots: roots)
    let fancy = SkillGrouping.rows(entries: SkillScan.entries(from: scanned), library: scanned, roots: roots)
        .first { $0.name == "fancy" }!
    let plan = SkillPlanner.deletePlan(row: fancy)!
    check("delete plans the links and the folder",
          plan.steps.contains(.unlink(at: kimiDir.appendingPathComponent("fancy").path))
          && plan.steps.contains { if case .trash = $0 { return true }; return false })
    let broken = SkillGrouping.rows(entries: SkillScan.entries(from: scanned), library: scanned, roots: roots)
        .first { $0.problems.contains(.brokenLink) }!
    check("a broken link deletes as an unlink alone",
          SkillPlanner.deletePlan(row: broken)?.steps == [.unlink(at: kimiDir.appendingPathComponent("gone").path)])
} catch {
    check("create/import/edit/delete", false, "\(error)")
}

section("3d. The last link, a plan checked whole, an import through a link")
func scannedRows() -> [SkillRow] {
    let scanned = SkillScan.read(roots: roots)
    return SkillGrouping.rows(entries: SkillScan.entries(from: scanned), library: scanned, roots: roots)
}
do {
    // A library skill one agent has: unticking it leaves nobody with it.
    _ = try ops.create(name: "solo", description: "One agent.", body: "b", onlyWhenCalled: false,
                       scope: .global, agents: [SkillAgent.claude], env: env, projectRoot: nil)
    let solo = scannedRows().first { $0.name == "solo" }!
    let at = claudeDir.appendingPathComponent("solo").path
    let keep = SkillPlanner.plan(row: solo, agent: SkillAgent.claude, include: false, env: env, projectRoot: project)!
    check("unticking the last agent of a library skill asks keep-or-trash",
          keep.needsKeepOrTrash && keep.steps == [.unlink(at: at)])
    let bin = SkillPlanner.plan(row: solo, agent: SkillAgent.claude, include: false, env: env,
                                projectRoot: project, keepWhenLast: false)!
    check("…trash is the link, then the library folder",
          bin.steps == [.unlink(at: at), .trash(solo.realPath!)])
    let shared = scannedRows().first { $0.name == "review-pr" }!
    check("…and an agent that is not the last is never asked",
          SkillPlanner.plan(row: shared, agent: SkillAgent.codex, include: false, env: env,
                            projectRoot: project)?.needsKeepOrTrash == false)
    try ops.run(keep, projectRoot: project)
    check("…kept: the link goes, the skill is Not in use",
          !fm.fileExists(atPath: at)
          && SkillListing.unused(scannedRows(), listed: listed).contains { $0.name == "solo" })

    // A share whose LAST step cannot land must not have moved anything.
    skill(claudeDir.appendingPathComponent("mine"), name: "mine", description: "Claude's own.")
    write(codexDir.appendingPathComponent("mine/README.md"), "Something else is already here.\n")
    let mine = scannedRows().first { $0.name == "mine" }!
    let share = SkillPlanner.plan(row: mine, agent: SkillAgent.codex, include: true, env: env, projectRoot: project)!
    do {
        try ops.run(share, projectRoot: project)
        check("a share whose link cannot be placed is refused", false, "it ran")
    } catch let e as SkillOpError {
        check("a share whose link cannot be placed is refused",
              e == .exists(codexDir.appendingPathComponent("mine").path), "\(e)")
    }
    check("…before anything moved: the skill is still its agent's own folder",
          !isLink(claudeDir.appendingPathComponent("mine").path)
          && fm.fileExists(atPath: claudeDir.appendingPathComponent("mine/SKILL.md").path)
          && !fm.fileExists(atPath: lib.appendingPathComponent("mine").path))

    // A folder chosen through a link is copied, not linked.
    let real = root.appendingPathComponent("downloads/real-one")
    skill(real, name: "linked-in", description: "Behind a link.")
    let through = root.appendingPathComponent("downloads/link-to-it")
    link(through, to: real)
    let dest = try ops.importFolder(through, name: "linked-in", scope: .global, agents: [],
                                    env: env, projectRoot: nil)
    check("an import through a link copies the folder itself",
          !isLink(dest) && fm.fileExists(atPath: dest + "/SKILL.md"))
} catch {
    check("last link / preflight / import", false, "\(error)")
}

section("3e. Edits that keep what they do not change")
do {
    // A description with quotes and a backslash comes back as written.
    let words = "Say \"hi\": a \\ path"
    let dest = try ops.create(name: "quoted", description: words, body: "Body.\n", onlyWhenCalled: false,
                              scope: .global, agents: [], env: env, projectRoot: nil)
    let file = dest + "/SKILL.md"
    let written = try String(contentsOfFile: file, encoding: .utf8)
    check("a quoted description reads back as it was written",
          SkillFrontmatter.parse(written).description == words, SkillFrontmatter.parse(written).description)
    check("…a single-quoted one too",
          SkillFrontmatter.parse("---\ndescription: 'it''s fine'\n---\n").description == "it's fine")
    try ops.edit(realPath: dest, expected: written, description: SkillFrontmatter.parse(written).description,
                 body: SkillFrontmatter.parse(written).body, onlyWhenCalled: false)
    check("…and a save that changes nothing writes the same bytes",
          (try String(contentsOfFile: file, encoding: .utf8)) == written)

    // A folded description and the file's own spacing survive a save
    // that leaves them alone, and an edit of the body alone.
    let folded = "---\nname: folded\ndescription: >\n  line one\n  line two\nlicense: MIT\n---\nBody right under.\n\n\n"
    let foldedDir = lib.appendingPathComponent("folded")
    write(foldedDir.appendingPathComponent("SKILL.md"), folded)
    let parsed = SkillFrontmatter.parse(folded)
    try ops.edit(realPath: foldedDir.path, expected: folded, description: parsed.description,
                 body: parsed.body.trimmingCharacters(in: .newlines), onlyWhenCalled: false)
    check("a save that changes nothing keeps a folded description and the spacing",
          (try String(contentsOf: foldedDir.appendingPathComponent("SKILL.md"), encoding: .utf8)) == folded)
    try ops.edit(realPath: foldedDir.path, expected: folded, description: parsed.description,
                 body: "New body.", onlyWhenCalled: false)
    let bodyOnly = try String(contentsOf: foldedDir.appendingPathComponent("SKILL.md"), encoding: .utf8)
    check("an edit of the body alone leaves the description's own lines",
          bodyOnly.contains("description: >\n  line one\n  line two\n") && bodyOnly.contains("New body."))

    // A policy file SipAI does not edit refuses a change to IT, never a
    // change that leaves it alone.
    let bracedDir = lib.appendingPathComponent("braced")
    skill(bracedDir, name: "braced", description: "Old.")
    let braces = "interface:\n  default_prompt: \"use {curly} braces\"\n"
    write(bracedDir.appendingPathComponent("agents/openai.yaml"), braces)
    let bracedText = try String(contentsOf: bracedDir.appendingPathComponent("SKILL.md"), encoding: .utf8)
    try ops.edit(realPath: bracedDir.path, expected: bracedText, description: "New.", body: "Body.",
                 onlyWhenCalled: false)
    let bracedAfter = try String(contentsOf: bracedDir.appendingPathComponent("SKILL.md"), encoding: .utf8)
    let policyAfter = try String(contentsOf: bracedDir.appendingPathComponent("agents/openai.yaml"), encoding: .utf8)
    check("an edit that leaves the policy alone is not refused over its form",
          SkillFrontmatter.parse(bracedAfter).description == "New." && policyAfter == braces)
    do {
        try ops.setOnlyWhenCalled(realPath: bracedDir.path, true)
        check("…a change to the policy itself still is", false, "it ran")
    } catch let e as SkillOpError {
        check("…a change to the policy itself still is", e == .unsupportedYAML, "\(e)")
    }

    // No frontmatter, nothing to put in one: the file gains none.
    let plain = "Just instructions.\n"
    check("a file without frontmatter gains none from a change that needs none",
          SkillFileEdit.updated(plain, description: nil, body: nil, onlyWhenCalled: false) == plain
          && SkillFileEdit.updated(plain, description: nil, body: "Other.", onlyWhenCalled: nil) == "Other.\n")
} catch {
    check("edits", false, "\(error)")
}

section("3g. Edits that must not corrupt, and folders that are not SipAI's")
do {
    // A block description with a paragraph break: the whole value goes.
    let block = "---\nname: para\ndescription: |\n  First paragraph.\n\n  Second paragraph.\nlicense: MIT\n---\n\nBody.\n"
    check("a block description is read across its blank line",
          SkillFrontmatter.parse(block).description == "First paragraph.\n\nSecond paragraph.")
    let rewritten = SkillFileEdit.updated(block, description: "New: words", body: nil, onlyWhenCalled: nil)
    check("…and rewritten whole — nothing of the old value is left under the new line",
          rewritten == "---\nname: para\ndescription: \"New: words\"\nlicense: MIT\n---\n\nBody.\n", rewritten)
    check("a plain description carried over indented lines is read as one",
          SkillFrontmatter.parse("---\ndescription: Use this skill when\n  the user asks.\nname: x\n---\n").description
            == "Use this skill when the user asks.")
    // A byte-order mark, and a key spelled with a space before its colon.
    let marked = "\u{FEFF}---\nname: bom\ndescription : Old.\n---\n\nBody.\n"
    check("a file opening with a byte-order mark still has its frontmatter",
          SkillFrontmatter.parse(marked).hasFrontmatter && SkillFrontmatter.parse(marked).description == "Old.")
    let remarked = SkillFileEdit.updated(marked, description: "New.", body: nil, onlyWhenCalled: nil)
    check("…an edit keeps the mark and rewrites the ONE description line",
          remarked == "\u{FEFF}---\nname: bom\ndescription: New.\n---\n\nBody.\n", remarked.debugDescription)

    // Codex's policy block with a list under another key.
    let nested = "policy:\n  products:\n    - codex\n    - chatgpt\n"
    let on = try SkillFileEdit.codexPolicy(nested, onlyWhenCalled: true)
    check("the policy key is written at the block's own indent, not inside a list below it",
          on == "policy:\n  allow_implicit_invocation: false\n  products:\n    - codex\n    - chatgpt\n", on ?? "nil")
    let off = try SkillFileEdit.codexPolicy(on, onlyWhenCalled: false)
    check("…and removed without orphaning what else the block holds", off == nested, off ?? "nil")
    check("…a block that held that key alone goes with it",
          try SkillFileEdit.codexPolicy("interface:\n  x: 1\npolicy:\n  allow_implicit_invocation: false\n", onlyWhenCalled: false)
            == "interface:\n  x: 1\n")

    // An import takes the name it was given.
    let src = root.appendingPathComponent("downloads/imagegen")
    skill(src, name: "imagegen", description: "Make images.")
    let copied = try ops.importFolder(src, name: "my-imagegen", scope: .global, agents: [], env: env, projectRoot: nil)
    check("an imported skill is named what it was imported as",
          SkillFrontmatter.parse(try String(contentsOfFile: copied + "/SKILL.md", encoding: .utf8)).name == "my-imagegen"
          && scannedRows().contains { $0.name == "my-imagegen" })
    check("…the source keeps its own name",
          SkillFrontmatter.parse(try String(contentsOf: src.appendingPathComponent("SKILL.md"), encoding: .utf8)).name == "imagegen")

    // A link into an agent's built-in folder is that folder's skill.
    link(kimiDir.appendingPathComponent("imagegen"), to: env.codexHome.appendingPathComponent("skills/.system/imagegen"))
    let viaLink = scannedRows().first { $0.entries[SkillAgent.kimi]?.name == "imagegen" }
    check("a link into a built-in folder is not the user's own skill",
          viaLink?.isReadOnly == true && viaLink?.isManaged == false, "\(String(describing: viaLink?.home))")
    let builtIn = env.codexHome.appendingPathComponent("skills/.system/imagegen")
    let builtInText = try String(contentsOf: builtIn.appendingPathComponent("SKILL.md"), encoding: .utf8)
    do {
        try ops.edit(realPath: SkillScan.realPath(builtIn.path)!, expected: builtInText, description: "Changed.",
                     body: "Changed.", onlyWhenCalled: false)
        check("…and its files are never rewritten", false, "the edit ran")
    } catch let e as SkillOpError {
        let after = try String(contentsOf: builtIn.appendingPathComponent("SKILL.md"), encoding: .utf8)
        check("…and its files are never rewritten", e == .readOnly && after == builtInText)
    }
    // A folder of the user's, linked in from somewhere else.
    let own = root.appendingPathComponent("dotfiles/skills/mine-elsewhere")
    skill(own, name: "mine-elsewhere", description: "Kept in my own repo.")
    link(claudeDir.appendingPathComponent("mine-elsewhere"), to: own)
    let linkedRow = scannedRows().first { $0.name == "mine-elsewhere" }
    check("a folder linked in from elsewhere is listed, and is not SipAI's to edit",
          linkedRow?.home == .elsewhere && linkedRow?.isManaged == false)
    do {
        try ops.setOnlyWhenCalled(realPath: SkillScan.realPath(own.path)!, true)
        check("…an edit of it is refused", false, "it ran")
    } catch let e as SkillOpError {
        check("…an edit of it is refused", e == .readOnly)
    }
    // A SKILL.md that is itself a link, and a policy file that is not text.
    let linkedFile = lib.appendingPathComponent("file-link")
    try fm.createDirectory(at: linkedFile, withIntermediateDirectories: true)
    write(root.appendingPathComponent("elsewhere/REAL.md"), "---\nname: file-link\ndescription: d\n---\n\nB.\n")
    try fm.createSymbolicLink(at: linkedFile.appendingPathComponent("SKILL.md"),
                              withDestinationURL: root.appendingPathComponent("elsewhere/REAL.md"))
    do {
        try ops.setOnlyWhenCalled(realPath: linkedFile.path, true)
        check("a SKILL.md that is a link is never replaced by a copy", false, "it ran")
    } catch let e as SkillOpError {
        check("a SKILL.md that is a link is never replaced by a copy",
              e == .readOnly && isLink(linkedFile.appendingPathComponent("SKILL.md").path))
    }
    let binary = lib.appendingPathComponent("binary-policy")
    skill(binary, name: "binary-policy", description: "d")
    try fm.createDirectory(at: binary.appendingPathComponent("agents"), withIntermediateDirectories: true)
    try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: binary.appendingPathComponent("agents/openai.yaml"))
    do {
        try ops.setOnlyWhenCalled(realPath: binary.path, true)
        check("a policy file that is not text is not taken for a missing one", false, "it ran")
    } catch let e as SkillOpError {
        let after = try Data(contentsOf: binary.appendingPathComponent("agents/openai.yaml"))
        check("a policy file that is not text is not taken for a missing one",
              e == .unsupportedYAML && after == Data([0xFF, 0xFE, 0x00, 0xD8]))
    }

    // Two skills of one name: each is addressed by its own path.
    var snap = SkillSnapshot(folder: nil, projectRoot: nil, rows: [])
    snap.codexPaths = ["dupe": "/first/dupe/SKILL.md"]
    snap.codexListed = ["/first/dupe/SKILL.md", "/second/dupe/SKILL.md"]
    func codexEntry(_ real: String?) -> SkillEntry {
        SkillEntry(agent: SkillAgent.codex, name: "dupe", description: "", scope: .global, rootKind: .own,
                   entryPath: real ?? "", realPath: real, isLink: false, frontmatter: SkillFrontmatter())
    }
    check("two codex skills of one name each resolve to their own path",
          snap.codexPath(for: codexEntry("/first/dupe")) == "/first/dupe/SKILL.md"
          && snap.codexPath(for: codexEntry("/second/dupe")) == "/second/dupe/SKILL.md")
    check("…a skill codex did not list falls back to the name's, then to its own",
          snap.codexPath(for: codexEntry("/third/dupe")) == "/first/dupe/SKILL.md"
          && SkillSnapshot(folder: nil, projectRoot: nil, rows: []).codexPath(for: codexEntry("/third/dupe")) == "/third/dupe/SKILL.md")
} catch {
    check("edits and folders", false, "\(error)")
}

section("3h. Two agents, one folder; a home that is a repository")
do {
    // Codex's skills folder IS claude's (one linked to the other).
    let home2 = root.appendingPathComponent("home2", isDirectory: true)
    let env2 = SkillEnvironment.resolve([:], home: home2)
    // A key SkillAgent names: never nil.
    let claude2 = SkillRoots.ownFolder(agent: SkillAgent.claude, scope: .global,
                                      env: env2, projectRoot: nil)!
    // A key SkillAgent names: never nil.
    let codex2 = SkillRoots.ownFolder(agent: SkillAgent.codex, scope: .global,
                                      env: env2, projectRoot: nil)!
    skill(claude2.appendingPathComponent("both"), name: "both", description: "One folder, two agents.")
    link(codex2, to: claude2)
    let roots2 = SkillRoots.scanRoots(env: env2, folder: nil)
    let found2 = SkillScan.read(roots: roots2)
    let both = SkillGrouping.rows(entries: SkillScan.entries(from: found2), library: found2, roots: roots2)
        .first { $0.name == "both" }!
    check("one folder read by two agents is one row with both", both.agents == [SkillAgent.claude, SkillAgent.codex])
    let untick = SkillPlanner.plan(row: both, agent: SkillAgent.codex, include: false, env: env2, projectRoot: nil)
    check("…unticking one of them is refused, naming the other, with no step planned",
          untick?.blockedBy == [SkillAgent.claude] && untick?.steps.isEmpty == true)

    // A home kept in git: a folder under it has no scope of its own, but
    // what lies between home and the folder is still read.
    let home3 = root.appendingPathComponent("home3", isDirectory: true)
    let env3 = SkillEnvironment.resolve([:], home: home3)
    try fm.createDirectory(at: home3.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let work = home3.appendingPathComponent("work/notes", isDirectory: true)
    skill(work.appendingPathComponent(".claude/skills/local"), name: "local", description: "This folder's.")
    let roots3 = SkillRoots.scanRoots(env: env3, folder: work)
    let found3 = SkillScan.read(roots: roots3)
    let rows3 = SkillGrouping.rows(entries: SkillScan.entries(from: found3), library: found3, roots: roots3)
    check("under a home that is a repository, a folder's own skills are still listed",
          rows3.contains { $0.name == "local" && $0.agents == [SkillAgent.claude] && $0.scope == .folder })
    check("…and the home's own folders are not read twice as the project's",
          roots3.filter { $0.url.path == claude2.path.replacingOccurrences(of: "home2", with: "home3") }.count == 1)
}

section("3i. Sharing with an agent that reads a SKILL.md its own way")
// Every shape measured on claude 2.1.287, codex 0.160.0 and kimi 2.1.1
// (each CLI handed one at a time): what SipAI finds wrong with it, and
// which agents skip the skill over it. SIPAI_SKILLS_LIVE=1 loads each of
// these, raw and as SipAI fixes it, into the installed CLIs (live.py).
let longName = String(repeating: "a", count: 70)
func shape(_ name: String, _ description: String) -> String {
    "---\nname: \(name)\ndescription: \(description)\n---\n\nDo the thing.\n"
}
let shapes: [(name: String, text: String, problems: [SkillFormatProblem])] = [
    ("ok-basic", shape("ok-basic", "A plain skill."), []),
    ("no-header", "# No header\n\nDo the thing without any header.\n", [.noHeader]),
    ("no-description", "---\nname: no-description\n---\n\nDo the thing.\n", [.noDescription]),
    ("no-name", "---\ndescription: Has no name line.\n---\n\nDo the thing.\n", [.noName]),
    ("empty-header", "---\n---\n\nAn empty header block.\n", [.noName, .noDescription]),
    ("bom", "\u{FEFF}" + shape("bom", "Starts with a byte-order mark."), [.byteOrderMark]),
    ("colon", shape("colon", "Use when: the user asks for it"), [.needsQuotes("description")]),
    ("colon-end", shape("colon-end", "Use it when:"), [.needsQuotes("description")]),
    ("colon-carried", "---\nname: colon-carried\ndescription: First line\n  then: a colon\n---\n\nDo the thing.\n",
     [.needsQuotes("description")]),
    ("colon-other", "---\nname: colon-other\ndescription: Fine.\nargument-hint: file: the path\n---\n\nDo the thing.\n",
     [.needsQuotes("argument-hint")]),
    ("at", shape("at", "@mention starts it"), [.needsQuotes("description")]),
    ("tick", shape("tick", "`code` starts it"), [.needsQuotes("description")]),
    ("star", shape("star", "*stars* start it"), [.needsQuotes("description")]),
    ("dash", shape("dash", "- a dash starts it"), [.needsQuotes("description")]),
    ("brace", shape("brace", "{curly} starts it"), [.needsQuotes("description")]),
    ("square", shape("square", "[square] starts it"), [.needsQuotes("description")]),
    ("comma", shape("comma", ", comma starts it"), [.needsQuotes("description")]),
    ("question", shape("question", "? question starts it"), [.needsQuotes("description")]),
    ("percent", shape("percent", "%pct starts it"), [.needsQuotes("description")]),
    ("pipe", shape("pipe", "|pipe starts it"), [.needsQuotes("description")]),
    ("bang", shape("bang", "!bang starts it"), [.needsQuotes("description")]),
    ("single-open", shape("single-open", "'unbalanced quote"), [.needsQuotes("description")]),
    ("double-open", shape("double-open", "\"unbalanced dquote"), [.needsQuotes("description")]),
    ("number-name", shape("2024", "A name YAML reads as a number."), [.needsQuotes("name")]),
    ("tab-block", "---\nname: tab-block\ndescription: >\n\tTabbed line.\n---\n\nDo the thing.\n",
     [.needsQuotes("description")]),
    ("list-description", "---\nname: list-description\ndescription:\n  - a list\n  - not a string\n---\n\nDo the thing.\n",
     [.listDescription("a list. not a string")]),
    ("repeated", "---\nname: repeated\ndescription: One.\ndescription: Two.\n---\n\nDo the thing.\n",
     [.repeatedKey("description")]),
    ("long-name", shape(longName, "A seventy-character name."), [.nameTooLong]),
    // Read alike by all three.
    ("folded", "---\nname: folded\ndescription: >\n  First line of a folded\n  description.\n---\n\nDo the thing.\n", []),
    ("quoted", shape("quoted", "\"It's: fine, quoted\""), []),
    ("crlf", "---\r\nname: crlf\r\ndescription: Windows line endings.\r\n---\r\n\r\nDo the thing.\r\n", []),
    ("anchor", shape("anchor", "&amp starts it"), []),
    ("comment", shape("comment", "Tags #one and #two"), []),
    ("flow-tools", "---\nname: flow-tools\ndescription: A list of tools.\nallowed-tools: [Read, Grep]\n---\n\nDo the thing.\n", []),
    ("plain", shape("plain", "Plain words, commas, (parens) and 100% sure"), []),
    ("url", shape("url", "See https://example.com/a:b for the rules"), []),
    // Faults a header carries away from its name and its description:
    // a line that is no key, a value quotes mend, a nested block YAML
    // refuses. Each judged against kimi's own parser before it was
    // pinned here, and handed to the three CLIs by the live run.
    ("margin-words", "---\nname: margin-words\ndescription: Draft release notes from the commits\nsince the last tag.\n---\n\nDo the thing.\n",
     [.unreadableLine("since the last tag.")]),
    ("no-space-key", "---\nname:no-space-key\ndescription: A name with no space after its colon.\n---\n\nDo the thing.\n",
     [.unreadableLine("name:no-space-key"), .noName]),
    ("tab-carried", "---\nname: tab-carried\ndescription: First line\n\tsecond line\n---\n\nDo the thing.\n",
     [.needsQuotes("description")]),
    ("comment-split", "---\nname: comment-split\ndescription: First words\n  # a comment\n  more words\n---\n\nDo the thing.\n",
     [.needsQuotes("description")]),
    ("block-shallow", "---\nname: block-shallow\ndescription: |-\n      deeper\n    Use when asked\n---\n\nDo the thing.\n",
     [.needsQuotes("description")]),
    ("bad-escape", shape("bad-escape", "\"Matches \\d+ digits\""), [.needsQuotes("description")]),
    ("alias-nothing", shape("alias-nothing", "*nothing"), [.needsQuotes("description")]),
    ("bracket-close", shape("bracket-close", "] closes nothing"), [.needsQuotes("description")]),
    ("date-name", shape("2024-01-15", "A name YAML reads as a date."), [.needsQuotes("name")]),
    ("arg-hint", "---\nname: arg-hint\ndescription: Fine.\nargument-hint: [pr-number] [priority]\n---\n\nDo the thing.\n",
     [.needsQuotes("argument-hint")]),
    ("nested-tab", "---\nname: nested-tab\ndescription: Fine.\nmetadata:\n\tauthor: me\n---\n\nDo the thing.\n",
     [.unreadableLine("author: me")]),
    ("nested-colon", "---\nname: nested-colon\ndescription: Fine.\nmetadata:\n  short-description: Use when: asked\n---\n\nDo the thing.\n",
     [.strictLine("short-description: Use when: asked")]),
    ("nested-tick", "---\nname: nested-tick\ndescription: Fine.\nmetadata:\n  tools:\n    - `git status`\n    - Read\n---\n\nDo the thing.\n",
     [.unreadableLine("- `git status`")]),
    ("nested-setback", "---\nname: nested-setback\ndescription: Fine.\nmetadata:\n    - one\n  sub: two\n---\n\nDo the thing.\n",
     [.unreadableLine("sub: two")]),
    ("nested-twice", "---\nname: nested-twice\ndescription: Fine.\nmetadata:\n  author: me\n  author: you\n---\n\nDo the thing.\n",
     [.strictLine("author: you")]),
    ("flow-run-on", "---\nname: flow-run-on\ndescription: Fine.\nmetadata: [\"one\" two,\n  three]\n---\n\nDo the thing.\n",
     [.unreadableLine("[\"one\" two,")]),
    ("type-other", "---\nname: type-other\ndescription: Fine.\ntype: skill\n---\n\nDo the thing.\n", [.unsupportedType]),
    ("list-name", "---\nname: [list, name]\ndescription: A name that is a list.\n---\n\nDo the thing.\n", [.notText("name")]),
    ("unclosed-header", "---\nname: unclosed-header\ndescription: The header never closes.\n\nDo the thing.\n", [.unclosedHeader]),
    // Valid, and each once misread — as a fault, or with a fix that
    // rewrote it into one.
    ("comment-nested", "---\nname: comment-nested\ndescription: Fine.\nmetadata:\n  # about the author\n  author: me\n---\n\nDo the thing.\n", []),
    ("comment-after", "---\nname: comment-after\ndescription: Fine text\n  # note: this is a comment\n---\n\nDo the thing.\n", []),
    ("quoted-margin", "---\nname: quoted-margin\ndescription: \"Draft the notes,\nthen ask before posting.\"\n---\n\nDo the thing.\n", []),
    ("quoted-below", "---\nname: quoted-below\ndescription:\n  \"Use when: asked\"\n---\n\nDo the thing.\n", []),
    ("quoted-key", "---\n\"name\": quoted-key\ndescription: A key in quotes.\n---\n\nDo the thing.\n", []),
    ("flow-apostrophe", "---\nname: flow-apostrophe\ndescription: Fine.\nargument-hint: [user's name]\n---\n\nDo the thing.\n", []),
    ("str-tag", shape("str-tag", "!!str some words"), []),
    ("zero-list", "---\nname: zero-list\ndescription: Fine.\nallowed-tools:\n- Read\n- Grep\n---\n\nDo the thing.\n", []),
    ("fence-space", "--- \nname: fence-space\ndescription: A space after the fence.\n---\n\nDo the thing.\n", []),
    ("escaped", shape("escaped", "\"\\u53D1\\u5E03: notes\""), []),
    ("block-comment-end", "---\nname: block-comment-end\ndescription: >-\n   deeper\n # a comment\n---\n\nDo the thing.\n", []),
    ("odd-case", shape("odd-case", "tRue"), []),
    ("merge-twice", "---\nname: merge-twice\ndescription: Fine.\nbase: &b {a: 1}\nmetadata:\n  <<: *b\n  <<: *b\n---\n\nDo the thing.\n", []),
    // White space only one reader stops at. Codex hands the header to a
    // YAML 1.1 reader as it stands: a tab may not stand where an indent
    // could, a line separator ends the line, and the first key set in
    // alone is a block of its own. Kimi trims the header first, takes a
    // tab for white space and a line separator for text — and so loads
    // each of those, and not a header set in whole. Measured on both
    // CLIs over 118 shapes before these were pinned.
    ("tab-line", "---\nname: tab-line\n\t\ndescription: A line holding only a tab.\n---\n\nDo the thing.\n", [.tabLine]),
    ("tab-comment", "---\nname: tab-comment\n\t# a comment\ndescription: A tab before a comment.\n---\n\nDo the thing.\n", [.tabLine]),
    ("tab-after-quote", "---\nname: \"tab-after-quote\"\n  \t\ndescription: Spaces, then a tab, under a quoted value.\n---\n\nDo the thing.\n",
     [.tabLine]),
    ("tab-block-end", "---\nname: tab-block-end\ndescription: |\n  A block of text.\n \t\nlicense: MIT\n---\n\nDo the thing.\n", [.tabLine]),
    ("tab-nested", "---\nname: tab-nested\ndescription: Fine.\nmetadata:\n  author: me\n\t# a note\n  version: 1\n---\n\nDo the thing.\n", [.tabLine]),
    ("tab-block-cut", "---\nname: tab-block-cut\ndescription: |\n  First part.\n\t\n  Second part.\n---\n\nDo the thing.\n",
     [.needsQuotes("description")]),
    ("tab-nested-block", "---\nname: tab-nested-block\ndescription: Fine.\nmetadata:\n  note: |\n    text\n\t\n    more\n---\n\nDo the thing.\n",
     [.unreadableLine("more"), .tabLine]),
    ("separator", "---\nname: separator\ndescription: First words\u{2028}more words\n---\n\nDo the thing.\n", [.lineSeparator]),
    ("separator-comment", "---\nname: separator-comment\n# a note\u{2028}that runs on\ndescription: Fine.\n---\n\nDo the thing.\n", [.lineSeparator]),
    ("separator-nested", "---\nname: separator-nested\ndescription: Fine.\nmetadata:\n  note: one\u{85}two\n---\n\nDo the thing.\n", [.lineSeparator]),
    ("indent-first", "---\n  name: indent-first\ndescription: Only the first key is set in.\n---\n\nDo the thing.\n",
     [.indentedHeader(kimi: false, codex: true)]),
    ("indent-all", "---\n  name: indent-all\n  description: Every key is set in.\n  license: MIT\n---\n\nDo the thing.\n",
     [.indentedHeader(kimi: true, codex: false)]),
    ("indent-tabs", "---\n\tname: indent-tabs\n\tdescription: A tab sets every key in.\n---\n\nDo the thing.\n",
     [.indentedHeader(kimi: true, codex: true)]),
    ("indent-colon", "---\n  name: indent-colon\n  description: Use when: asked\n---\n\nDo the thing.\n",
     [.indentedHeader(kimi: true, codex: false), .needsQuotes("description")]),
    // A description written as a list. Every agent but Claude skips it
    // (codex: "invalid type: sequence, expected a string"); a flat list
    // of text SipAI writes as the one sentence its items make, and a
    // map, a list of keys or a list in a list stays the user's.
    ("list-flow", "---\nname: list-flow\ndescription: [Draft release notes, Use after tagging]\n---\n\nDo the thing.\n",
     [.listDescription("Draft release notes. Use after tagging")]),
    ("list-zero", "---\nname: list-zero\ndescription:\n- Draft the notes\n- Use after tagging\nlicense: MIT\n---\n\nDo the thing.\n",
     [.listDescription("Draft the notes. Use after tagging")]),
    ("list-quoted", "---\nname: list-quoted\ndescription:\n  - \"Use when: asked\"\n  - 'It''s done.'  # a note\n  - last\n---\n\nDo the thing.\n",
     [.listDescription("Use when: asked. It's done. last")]),
    ("list-carried", "---\nname: list-carried\ndescription:\n  - Draft release notes from the commits\n    since the last tag\n\n  # and then\n  - Use after tagging\n---\n\nDo the thing.\n",
     [.listDescription("Draft release notes from the commits since the last tag. Use after tagging")]),
    ("map-description", "---\nname: map-description\ndescription:\n  short: A short one\n  long: A long one\n---\n\nDo the thing.\n",
     [.notText("description")]),
    ("list-of-keys", "---\nname: list-of-keys\ndescription:\n  - Use when: asked\n  - plain\n---\n\nDo the thing.\n",
     [.notText("description")]),
    ("list-in-list", "---\nname: list-in-list\ndescription:\n  - - inner\n  - plain\n---\n\nDo the thing.\n",
     [.notText("description")]),
    // …and what both read, each once called a fault here.
    ("comment-margin", "---\nname: comment-margin\ndescription: Fine.\nmetadata:\n  author: me\n# a note at the margin\n  version: 1\n---\n\nDo the thing.\n", []),
    ("comment-before-nested", "---\nname: comment-before-nested\ndescription: Fine.\nmetadata:\n# a note at the margin\n  author: me\n---\n\nDo the thing.\n", []),
    ("comment-before-value", "---\nname: comment-before-value\ndescription:\n# a note at the margin\n  \"Use when: asked\"\n---\n\nDo the thing.\n", []),
    ("indent-under-comment", "---\n# every key set in, under a comment\n  name: indent-under-comment\n  description: Fine.\n---\n\nDo the thing.\n", []),
    ("tab-after-plain", "---\nname: tab-after-plain\n  \t\ndescription: Spaces, then a tab, under plain words.\n---\n\nDo the thing.\n", []),
    ("tab-in-quotes", "---\nname: tab-in-quotes\ndescription: \"First words\n\t\n  more words\"\n---\n\nDo the thing.\n", []),
    ("separator-quoted", "---\nname: separator-quoted\ndescription: \"First words\u{2028}more words\"\n---\n\nDo the thing.\n", []),
    ("separator-end", "---\nname: separator-end\ndescription: The line ends on one\u{2028}\n---\n\nDo the thing.\n", []),
]
for s in shapes {
    let found = SkillFormat.problems(in: s.text)
    check("format: \(s.name) — \(s.problems.isEmpty ? "nothing wrong" : "\(s.problems)")",
          found == s.problems, "\(found)")
}
check("the measured table: claude skips none, codex the header, a mark, a description, quotes, a repeat, a long name; kimi a name instead of a mark or a long name",
      [SkillFormatProblem.noHeader, .byteOrderMark, .noName, .noDescription, .needsQuotes("x"), .repeatedKey("x"), .nameTooLong]
        .map { (SkillFormat.skips($0, agent: SkillAgent.claude), SkillFormat.skips($0, agent: SkillAgent.codex),
                SkillFormat.skips($0, agent: SkillAgent.kimi)) }
        .elementsEqual([(false, true, true), (false, true, false), (false, false, true), (false, true, true),
                        (false, true, true), (false, true, true), (false, true, false)], by: ==))
check("…a list for text, an open header and a line YAML refuses are both's; a nested line only a strict reader refuses and a type kimi does not run are kimi's alone — and none is SipAI's to fix",
      [SkillFormatProblem.notText("x"), .unclosedHeader, .unreadableLine("x"), .strictLine("x"), .unsupportedType]
        .map { (SkillFormat.skips($0, agent: SkillAgent.claude), SkillFormat.skips($0, agent: SkillAgent.codex),
                SkillFormat.skips($0, agent: SkillAgent.kimi), SkillFormat.fixable($0)) }
        .elementsEqual([(false, true, true, false), (false, true, true, false), (false, true, true, false),
                        (false, false, true, false), (false, false, true, false)], by: ==))
check("…a description that is a flat list of text is both's as any list is, and SipAI's to fix",
      SkillFormat.skips(.listDescription("x"), agent: SkillAgent.codex) && SkillFormat.skips(.listDescription("x"), agent: SkillAgent.kimi)
      && !SkillFormat.skips(.listDescription("x"), agent: SkillAgent.claude) && SkillFormat.fixable(.listDescription("x")))
check("…a tab where an indent could stand, a line separator and a first key set in alone are codex's; a header set in whole is kimi's, a tab doing it both's — and each is SipAI's to fix",
      [SkillFormatProblem.tabLine, .lineSeparator, .indentedHeader(kimi: false, codex: true),
       .indentedHeader(kimi: true, codex: false), .indentedHeader(kimi: true, codex: true)]
        .map { (SkillFormat.skips($0, agent: SkillAgent.claude), SkillFormat.skips($0, agent: SkillAgent.codex),
                SkillFormat.skips($0, agent: SkillAgent.kimi), SkillFormat.fixable($0)) }
        .elementsEqual([(false, true, false, true), (false, true, false, true), (false, true, false, true),
                        (false, false, true, true), (false, true, true, true)], by: ==))

/// A shape made loadable by codex and kimi both, as two shares in a row
/// would leave it.
func fixedForAll(_ text: String, folder: String) -> String {
    var t = text
    for agent in [SkillAgent.kimi, SkillAgent.codex] {
        let check = SkillShareCheck.make(skillText: t, codexYaml: nil, folderName: folder, target: agent,
                                         writable: true, nameTaken: false)
        if check.refusal == nil { t = SkillFormat.applying(check.fixes, to: t) }
    }
    return t
}
for s in shapes where s.problems.allSatisfy(SkillFormat.fixable) && !s.problems.isEmpty {
    let fixed = fixedForAll(s.text, folder: s.name)
    let left = SkillFormat.problems(in: fixed).filter {
        SkillFormat.skips($0, agent: SkillAgent.codex) || SkillFormat.skips($0, agent: SkillAgent.kimi)
    }
    check("fixed: \(s.name) is nothing any agent skips", left.isEmpty, "\(left)\n\(fixed)")
}
check("a fix keeps every byte it does not change: the body, the other keys, the line ends",
      fixedForAll("---\r\nname: x\r\ndescription: Use when: asked\r\nlicense: MIT\r\n---\r\n\r\nBody: kept.\r\n", folder: "x")
        == "---\r\nname: x\r\ndescription: \"Use when: asked\"\r\nlicense: MIT\r\n---\r\n\r\nBody: kept.\r\n")
check("a header is added with the folder's name and the body's first line, the body left whole",
      fixedForAll("# Release notes\n\nDraft them.\n", folder: "release-notes")
        == "---\nname: release-notes\ndescription: Release notes\n---\n\n# Release notes\n\nDraft them.\n")
check("a name goes at the top, a description at the bottom of the header",
      fixedForAll("---\nlicense: MIT\n---\n\nDo it.\n", folder: "plain-one")
        == "---\nname: plain-one\nlicense: MIT\ndescription: Do it.\n---\n\nDo it.\n")
check("a map where the description should be is the user's to change: refused, the file as it was — and so is a list of keys, a list in a list, a list for the NAME",
      ["map-description", "list-of-keys", "list-in-list"].allSatisfy { name in
          SkillShareCheck.make(skillText: shapes.first { $0.name == name }!.text, codexYaml: nil,
                               folderName: name, target: SkillAgent.kimi, writable: true,
                               nameTaken: false).refusal == .cannotFix(.notText("description"))
          && fixedForAll(shapes.first { $0.name == name }!.text, folder: name) == shapes.first { $0.name == name }!.text
      }
      && SkillShareCheck.make(skillText: shapes.first { $0.name == "list-name" }!.text, codexYaml: nil,
                              folderName: "list-name", target: SkillAgent.codex, writable: true,
                              nameTaken: false).refusal == .cannotFix(.notText("name")))
check("a description that is a flat list of text is written as the one sentence its items make — the user's words, never the body's — for the agents that skip a list, and left alone for Claude",
      SkillShareCheck.make(skillText: shapes.first { $0.name == "list-description" }!.text, codexYaml: nil,
                           folderName: "list-description", target: SkillAgent.codex, writable: true,
                           nameTaken: false).fixes == [.joinDescription("a list. not a string")]
      && SkillShareCheck.make(skillText: shapes.first { $0.name == "list-description" }!.text, codexYaml: nil,
                              folderName: "list-description", target: SkillAgent.claude, writable: true,
                              nameTaken: false).fixes.isEmpty
      && fixedForAll(shapes.first { $0.name == "list-description" }!.text, folder: "list-description")
        == "---\nname: list-description\ndescription: a list. not a string\n---\n\nDo the thing.\n")
check("…a list at the key's own indent, one in brackets, an item in quotes or carried onto a second line: each the same one line, quoted where the sentence needs it, every other line kept",
      fixedForAll(shapes.first { $0.name == "list-zero" }!.text, folder: "list-zero")
        == "---\nname: list-zero\ndescription: Draft the notes. Use after tagging\nlicense: MIT\n---\n\nDo the thing.\n"
      && fixedForAll(shapes.first { $0.name == "list-flow" }!.text, folder: "list-flow")
        == "---\nname: list-flow\ndescription: Draft release notes. Use after tagging\n---\n\nDo the thing.\n"
      && fixedForAll(shapes.first { $0.name == "list-quoted" }!.text, folder: "list-quoted")
        == "---\nname: list-quoted\ndescription: \"Use when: asked. It's done. last\"\n---\n\nDo the thing.\n"
      && fixedForAll(shapes.first { $0.name == "list-carried" }!.text, folder: "list-carried")
        == "---\nname: list-carried\ndescription: Draft release notes from the commits since the last tag. Use after tagging\n---\n\nDo the thing.\n")
check("items are joined with a full stop only where one is missing: none after an item's own punctuation, one past a closing bracket, the full-width one after Chinese text",
      SkillFormat.joined(["a", "b.", "c"]) == "a. b. c"
      && SkillFormat.joined(["Is it done?", "notes (draft)", "end"]) == "Is it done? notes (draft). end"
      && SkillFormat.joined(["起草发布说明", "打标签后使用"]) == "起草发布说明。打标签后使用"
      && SkillFormat.joined(["起草发布说明。", "Use after tagging"]) == "起草发布说明。Use after tagging"
      && SkillFormat.joined(["only one"]) == "only one")
check("only what is certainly a list of text is joined: a number, an empty item, a blank line inside an item, a list run over two lines in brackets are left as they are",
      SkillFormat.listSentence(rest: "", more: ["  - 2024", "  - notes"]) == nil
      && SkillFormat.listSentence(rest: "", more: ["  -", "  - notes"]) == nil
      && SkillFormat.listSentence(rest: "", more: ["  - notes", "", "    carried on", "  - more"]) == nil
      && SkillFormat.listSentence(rest: "[one,", more: ["  two]"]) == nil
      && SkillFormat.listSentence(rest: "[one, [two]]", more: []) == nil
      && SkillFormat.listSentence(rest: "", more: ["  - notes", "\t- more"]) == nil
      && SkillFormat.listSentence(rest: "[one, two,]", more: []) == "one. two"
      && SkillFormat.listSentence(rest: "# a comment", more: ["  - notes", "", "  - more"]) == "notes. more")
check("a fix never turns a nested block into a sentence: a comment over one is no value",
      SkillFormat.problems(in: "---\nname: x\ndescription: y\nhooks:\n  # Run lint after edits\n  PostToolUse:\n    - matcher: \"Edit|Write\"\n---\n\nB.\n").isEmpty)
check("a value mended for an agent is the words that were written: the comment between them gone, an escape YAML does not know kept as its two characters, brackets as brackets",
      fixedForAll(shapes.first { $0.name == "comment-split" }!.text, folder: "comment-split")
        == "---\nname: comment-split\ndescription: First words more words\n---\n\nDo the thing.\n"
      && fixedForAll(shapes.first { $0.name == "bad-escape" }!.text, folder: "bad-escape")
        == "---\nname: bad-escape\ndescription: Matches \\d+ digits\n---\n\nDo the thing.\n"
      && fixedForAll(shapes.first { $0.name == "arg-hint" }!.text, folder: "arg-hint")
        == "---\nname: arg-hint\ndescription: Fine.\nargument-hint: \"[pr-number] [priority]\"\n---\n\nDo the thing.\n")
check("a quote left open is mended on its own line, never run on into the keys below it",
      fixedForAll("---\nname: x\ndescription: \"Does one thing\nargument-hint: \"[file]\"\n---\n\nB.\n", folder: "x")
        == "---\nname: x\ndescription: \"\\\"Does one thing\"\nargument-hint: \"[file]\"\n---\n\nB.\n")
check("a name added goes among the header's keys: one written inside a quoted value is that value's words",
      fixedForAll("---\ndescription: 'Said once\nname: not a key\nand closed'\n---\n\nB.\n", folder: "real-name")
        == "---\nname: real-name\ndescription: 'Said once\nname: not a key\nand closed'\n---\n\nB.\n")
check("a header-less file that opens on a blank line, with CRLF: the description is its first words",
      fixedForAll("\r\n# Release notes\r\n\r\nDraft them.\r\n", folder: "release-notes")
        == "---\r\nname: release-notes\r\ndescription: Release notes\r\n---\r\n\r\n\r\n# Release notes\r\n\r\nDraft them.\r\n")
func shared(_ name: String, with agent: String) -> SkillShareCheck {
    SkillShareCheck.make(skillText: shapes.first { $0.name == name }!.text, codexYaml: nil, folderName: name,
                         target: agent, writable: true, nameTaken: false)
}
check("a tab line is codex's fault alone: nothing is changed for kimi, and for codex the tab goes and nothing else",
      shared("tab-line", with: SkillAgent.kimi).fixes.isEmpty
      && shared("tab-line", with: SkillAgent.codex).fixes == [.clearTabLines]
      && fixedForAll(shapes.first { $0.name == "tab-line" }!.text, folder: "tab-line")
        == "---\nname: tab-line\n\ndescription: A line holding only a tab.\n---\n\nDo the thing.\n"
      && fixedForAll(shapes.first { $0.name == "tab-nested" }!.text, folder: "tab-nested")
        == "---\nname: tab-nested\ndescription: Fine.\nmetadata:\n  author: me\n# a note\n  version: 1\n---\n\nDo the thing.\n"
      && fixedForAll(shapes.first { $0.name == "tab-block-end" }!.text, folder: "tab-block-end")
        == "---\nname: tab-block-end\ndescription: |\n  A block of text.\n\nlicense: MIT\n---\n\nDo the thing.\n")
check("a tab that cuts a block of text in two is both's: the quotes fix makes one line of it, and no tab is left to clear",
      shared("tab-block-cut", with: SkillAgent.kimi).fixes == [.quote(["description"])]
      && fixedForAll(shapes.first { $0.name == "tab-block-cut" }!.text, folder: "tab-block-cut")
        == "---\nname: tab-block-cut\ndescription: First part. Second part.\n---\n\nDo the thing.\n")
check("a line separator is made a space for codex — in a value, in a comment, under a nested key — and left for kimi, which reads it",
      shared("separator", with: SkillAgent.kimi).fixes.isEmpty
      && shared("separator", with: SkillAgent.codex).fixes == [.replaceLineSeparators]
      && fixedForAll(shapes.first { $0.name == "separator" }!.text, folder: "separator")
        == "---\nname: separator\ndescription: First words more words\n---\n\nDo the thing.\n"
      && fixedForAll(shapes.first { $0.name == "separator-comment" }!.text, folder: "separator-comment")
        == "---\nname: separator-comment\n# a note that runs on\ndescription: Fine.\n---\n\nDo the thing.\n"
      && fixedForAll(shapes.first { $0.name == "separator-nested" }!.text, folder: "separator-nested")
        == "---\nname: separator-nested\ndescription: Fine.\nmetadata:\n  note: one two\n---\n\nDo the thing.\n")
check("…one a space would make a key, an item or a comment of is left alone, and so is one that only ends its line",
      SkillFormat.problems(in: "---\nname: x\ndescription: one\u{2028}two: three\n---\n") == [.needsQuotes("description")]
      && SkillFormat.problems(in: "---\nname: x\ndescription: one\u{2028}# two\n---\n").isEmpty
      && SkillFormat.problems(in: "---\nname: x\ndescription: one\u{2028}  two\n---\n").isEmpty
      && SkillFormat.problems(in: "---\nname: x\ndescription: one:\u{2028}two\n---\n").isEmpty)
check("a header set in whole is read as the block it is — its name its name — and moved to the margin for kimi; for codex, which loads it, nothing is changed",
      SkillFrontmatter.parse(shapes.first { $0.name == "indent-all" }!.text).name == "indent-all"
      && SkillFrontmatter.parse(shapes.first { $0.name == "indent-all" }!.text).description == "Every key is set in."
      && shared("indent-all", with: SkillAgent.codex).fixes.isEmpty
      && shared("indent-all", with: SkillAgent.kimi).fixes == [.straightenHeader]
      && fixedForAll(shapes.first { $0.name == "indent-all" }!.text, folder: "indent-all")
        == "---\nname: indent-all\ndescription: Every key is set in.\nlicense: MIT\n---\n\nDo the thing.\n")
check("…a fix that looks for a key finds it there: the header goes to the margin first, then the quotes",
      shared("indent-colon", with: SkillAgent.kimi).fixes == [.straightenHeader, .quote(["description"])]
      && shared("indent-colon", with: SkillAgent.codex).fixes == [.straightenHeader, .quote(["description"])]
      && fixedForAll(shapes.first { $0.name == "indent-colon" }!.text, folder: "indent-colon")
        == "---\nname: indent-colon\ndescription: \"Use when: asked\"\n---\n\nDo the thing.\n")
check("the first key alone set in is codex's fault alone, and only that line moves",
      shared("indent-first", with: SkillAgent.kimi).fixes.isEmpty
      && shared("indent-first", with: SkillAgent.codex).fixes == [.straightenHeader]
      && fixedForAll(shapes.first { $0.name == "indent-first" }!.text, folder: "indent-first")
        == "---\nname: indent-first\ndescription: Only the first key is set in.\n---\n\nDo the thing.\n")
check("an edit of a header set in whole finds its keys: the description is replaced, not written a second time at the margin",
      SkillFileEdit.updated(shapes.first { $0.name == "indent-all" }!.text, description: "New words.", body: nil, onlyWhenCalled: nil)
        == "---\nname: indent-all\ndescription: New words.\nlicense: MIT\n---\n\nDo the thing.\n"
      && SkillFileEdit.renamed(shapes.first { $0.name == "indent-all" }!.text, to: "other")
        == "---\nname: other\ndescription: Every key is set in.\nlicense: MIT\n---\n\nDo the thing.\n")
check("…and one that changes nothing leaves it as it was, indent and all",
      SkillFileEdit.updated(shapes.first { $0.name == "indent-all" }!.text, description: nil, body: nil, onlyWhenCalled: nil)
        == shapes.first { $0.name == "indent-all" }!.text
      && SkillFileEdit.updated(shapes.first { $0.name == "indent-all" }!.text, description: nil, body: nil, onlyWhenCalled: false)
        == shapes.first { $0.name == "indent-all" }!.text
      && SkillFileEdit.renamed(shapes.first { $0.name == "indent-all" }!.text, to: "indent-all")
        == shapes.first { $0.name == "indent-all" }!.text
      && SkillFormat.applying([], to: shapes.first { $0.name == "indent-tabs" }!.text) == shapes.first { $0.name == "indent-tabs" }!.text)
check("a comment at the margin inside a nested block is a comment: the block's keys below it are still the block's, and an edit of another key leaves them be",
      SkillFormat.headerKeys(in: shapes.first { $0.name == "comment-margin" }!.text) == ["name", "description", "metadata"]
      && SkillFileEdit.updated(shapes.first { $0.name == "comment-margin" }!.text, description: "New.", body: nil, onlyWhenCalled: nil)
        == "---\nname: comment-margin\ndescription: New.\nmetadata:\n  author: me\n# a note at the margin\n  version: 1\n---\n\nDo the thing.\n")
check("…while text ends at one: words under a comment at the margin are still words under nothing",
      SkillFormat.problems(in: "---\nname: x\ndescription: First words\n# a note\n  more words\n---\n") == [.unreadableLine("more words")]
      && SkillFormat.problems(in: "---\nname: x\ndescription: |\n  First words\n# a note\n  more words\n---\n") == [.unreadableLine("more words")])
check("a rule at the top of a body is no description",
      SkillFormat.description(fromBody: "---\n\n***\nWords at last.\n") == "Words at last.")
check("the mark goes only for codex, which cannot read past it",
      SkillShareCheck.make(skillText: "\u{FEFF}" + shape("m", "d"), codexYaml: nil, folderName: "m",
                           target: SkillAgent.kimi, writable: true, nameTaken: false).fixes.isEmpty
      && SkillShareCheck.make(skillText: "\u{FEFF}" + shape("m", "d"), codexYaml: nil, folderName: "m",
                              target: SkillAgent.codex, writable: true, nameTaken: false).fixes == [.removeByteOrderMark])
check("a value YAML would read as a number or a yes/no is written quoted; a name stays plain",
      SkillFileEdit.yamlScalar("2024") == "\"2024\"" && SkillFileEdit.yamlScalar("true") == "\"true\""
      && SkillFileEdit.yamlScalar("1.5") == "\"1.5\"" && SkillFileEdit.yamlScalar("review-pr") == "review-pr"
      && SkillFileEdit.yamlScalar("v2 notes") == "v2 notes")
check("…a date, a `0x` or `0b` number, infinity and a yes too — whatever kimi's parser would not take for text",
      ["2024-01-15", "0b101", "0x1F", ".inf", "-.INF", ".NaN", "1_000", "2024-01-15 10:00:00", "Yes", "off", "~"]
        .allSatisfy { SkillFileEdit.yamlScalar($0) == "\"\($0)\"" }
      && ["+.5", "1_", "v1.2.3", "0 things", "null and void"].allSatisfy { SkillFileEdit.yamlScalar($0) == $0 })
check("…and what is text to that parser is not called a fault: an odd case, a sign before a bare point",
      !SkillFormat.readsAsNonText("tRue") && !SkillFormat.readsAsNonText("nUll") && !SkillFormat.readsAsNonText("+.5")
      && !SkillFormat.readsAsNonText("1_") && SkillFormat.readsAsNonText("TRUE") && SkillFormat.readsAsNonText("0o17"))
check("a character no YAML file holds raw goes in as its escape, and comes back",
      SkillFileEdit.yamlScalar("bell\u{07}here") == "\"bell\\x07here\""
      && SkillFrontmatter.unquoted(SkillFileEdit.yamlScalar("bell\u{07} sep\u{2028}here \"q\" back\\slash"))
        == "bell\u{07} sep\u{2028}here \"q\" back\\slash")
check("a quoted value's escapes are read: the \\u a Python tool writes for anything not ASCII, a tab, a quote",
      SkillFrontmatter.parse("---\nname: x\ndescription: \"\\u53D1\\u5E03\\u8BF4\\u660E: \\u8D77\\u8349\\t\\\"ok\\\" caf\\xE9\"\n---\n").description
        == "发布说明: 起草\t\"ok\" café")
check("…and one YAML does not define keeps its backslash",
      SkillFrontmatter.unquoted("\"C:\\dir \\d+\"") == "C:\\dir \\d+")

// Edits follow a value to where it really ends, and find their key among
// the header's keys alone.
do {
    let quoted = "---\nname: x\ndescription: \"Draft the notes,\nthen ask before posting.\"\nlicense: MIT\n---\n\nB.\n"
    check("an edit takes a quoted description down to its closing quote, on a line that is not indented",
          SkillFrontmatter.parse(quoted).description == "Draft the notes, then ask before posting."
          && SkillFileEdit.updated(quoted, description: "New words.", body: nil, onlyWhenCalled: nil)
            == "---\nname: x\ndescription: New words.\nlicense: MIT\n---\n\nB.\n")
    let listed = "---\nname:\n- a\n- b\ndescription:\n- a list\n- not text\nlicense: MIT\n---\n\nB.\n"
    check("…and a list written at the key's own indent goes with its key",
          SkillFileEdit.updated(listed, description: "New.", body: nil, onlyWhenCalled: nil)
            == "---\nname:\n- a\n- b\ndescription: New.\nlicense: MIT\n---\n\nB.\n"
          && SkillFileEdit.renamed(listed, to: "z")
            == "---\nname: z\ndescription:\n- a list\n- not text\nlicense: MIT\n---\n\nB.\n")
    let spaced = "--- \nname: x\ndescription: y\n---\n\nB.\n"
    check("a fence with a space after it is the header's, to the reader and to every edit: no second header",
          SkillFrontmatter.parse(spaced).name == "x" && SkillFrontmatter.parse(spaced).hasFrontmatter
          && SkillFileEdit.updated(spaced, description: "New.", body: nil, onlyWhenCalled: nil)
            == "--- \nname: x\ndescription: New.\n---\n\nB.\n"
          && SkillFileEdit.renamed(spaced, to: "z") == "--- \nname: z\ndescription: y\n---\n\nB.\n"
          && SkillFileEdit.updated(spaced, description: nil, body: nil, onlyWhenCalled: true)
            == "--- \nname: x\ndescription: y\ndisable-model-invocation: true\n---\n\nB.\n")
    let mixed = "---\r\nname: x\ndescription: old\nlicense: MIT\r\n---\nBody one.\r\nBody two.\n"
    check("a file that mixes line ends keeps each line's own: nothing asked, nothing written",
          SkillFileEdit.updated(mixed, description: nil, body: nil, onlyWhenCalled: nil) == mixed
          && SkillFormat.applying([], to: mixed) == mixed
          && SkillFileEdit.renamed(mixed, to: "x") == mixed)
    check("…and one word changed changes one line",
          SkillFileEdit.updated(mixed, description: "new", body: nil, onlyWhenCalled: nil)
            == "---\r\nname: x\ndescription: new\nlicense: MIT\r\n---\nBody one.\r\nBody two.\n"
          && SkillFileEdit.renamed(mixed, to: "z")
            == "---\r\nname: z\r\ndescription: old\nlicense: MIT\r\n---\nBody one.\r\nBody two.\n")
    let commented = "---\nname: x\ndescription: text # a note\ndisable-model-invocation: true # only me\ncontext: fork # own task\nuser-invocable: false # hidden\n---\n\nB.\n"
    let read = SkillFrontmatter.parse(commented)
    check("a comment after a value is no part of it: the description, only-when-called, fork, user-invocable",
          read.description == "text" && read.disableModelInvocation && read.runsForked && !read.userInvocable)
    check("…so only-when-called said with a comment still goes over to codex",
          SkillShareCheck.make(skillText: commented, codexYaml: nil, folderName: "x", target: SkillAgent.codex,
                               writable: true, nameTaken: false).fixes == [.onlyWhenCalledForCodex])
    check("a description on the line below its key is read",
          SkillFrontmatter.parse("---\nname: x\ndescription:\n  plain words here\n---\n").description == "plain words here")
    let camel = "---\nname: x\ndescription: y\ndisableModelInvocation: true\n---\n\nB.\n"
    check("only-when-called can be switched off in every spelling it is read in",
          SkillFrontmatter.parse(camel).disableModelInvocation
          && SkillFileEdit.updated(camel, description: nil, body: nil, onlyWhenCalled: false)
            == "---\nname: x\ndescription: y\n---\n\nB.\n")
    let yes = "---\nname: x\ndescription: y\ndisable-model-invocation: yes # mine\n---\n\nB.\n"
    check("…and said already, in whatever spelling, its line is left as it is",
          SkillFileEdit.updated(yes, description: nil, body: nil, onlyWhenCalled: true) == yes)
    check("a key in quotes is the key: a copy renamed has one name",
          SkillFileEdit.renamed("---\n\"name\": imagegen\ndescription: d\n---\n", to: "my-imagegen")
            == "---\nname: my-imagegen\ndescription: d\n---\n")
    check("a no-header file given a header keeps every line of its text",
          SkillFileEdit.updated("\n# Title\n\nBody.\n\n", description: "D.", body: nil, onlyWhenCalled: nil)
            == "---\ndescription: D.\n---\n\n\n# Title\n\nBody.\n\n")
    check("a new body typed with CRLF is lines, not CRs",
          SkillFileEdit.updated("---\r\nname: x\r\n---\r\n\r\nOld.\r\n", description: nil, body: "One.\r\nTwo.", onlyWhenCalled: nil)
            == "---\r\nname: x\r\n---\r\n\r\nOne.\r\nTwo.\r\n")
    // Codex's policy file.
    check("codex's policy is read past a comment at the margin, and without the one after its value",
          !SkillCodexPolicy.allowsImplicitInvocation(yaml: "policy:\n# note\n  allow_implicit_invocation: false\n")
          && !SkillCodexPolicy.allowsImplicitInvocation(yaml: "policy:\n  allow_implicit_invocation: false # mine\n")
          && SkillCodexPolicy.allowsImplicitInvocation(yaml: "policy:\n  allow_implicit_invocation: true # mine\n"))
    check("…written under one, the key is set once, not added beside itself",
          (try? SkillFileEdit.codexPolicy("policy:\n# note\n  allow_implicit_invocation: true\n", onlyWhenCalled: true))
            == "policy:\n# note\n  allow_implicit_invocation: false\n")
    check("…and a CRLF file keeps its line ends",
          (try? SkillFileEdit.codexPolicy("interface:\r\n  display_name: X\r\npolicy:\r\n  products:\r\n    - codex\r\n", onlyWhenCalled: true))
            == "interface:\r\n  display_name: X\r\npolicy:\r\n  allow_implicit_invocation: false\r\n  products:\r\n    - codex\r\n")
    check("codex's own file is named before a share to another agent, CRLF or not",
          SkillFormat.ignored(by: SkillAgent.kimi, keys: [], body: "", codexYaml: "interface:\r\n  display_name: X\r\n")
            == [SkillCodexPolicy.relativePath])
}
check("…so a skill SipAI creates under such a name is one codex and kimi load",
      SkillFormat.problems(in: SkillFileEdit.newSkill(name: "2024", description: "42", body: "B.",
                                                      onlyWhenCalled: false)).isEmpty)
check("a long description read off the body stops at 240 characters, as kimi's own does",
      SkillFormat.description(fromBody: String(repeating: "word ", count: 100))?.count == 240)

do {
    func make(_ text: String?, target: String, writable: Bool = true, taken: Bool = false,
              yaml: String? = nil, carry: Bool = true) -> SkillShareCheck {
        SkillShareCheck.make(skillText: text, codexYaml: yaml, folderName: "f", target: target,
                             writable: writable, nameTaken: taken, carrySettings: carry)
    }
    let colon = shape("c", "Use when: asked")
    check("claude needs nothing fixed", make(colon, target: SkillAgent.claude).fixes.isEmpty
          && make("Just text.\n", target: SkillAgent.claude).fixes.isEmpty)
    check("another skill of the name refuses the share", make(colon, target: SkillAgent.kimi, taken: true).refusal == .nameTaken)
    check("a key given twice is the user's to fix",
          make(shapes.first { $0.name == "repeated" }!.text, target: SkillAgent.kimi).refusal
            == .cannotFix(.repeatedKey("description")))
    check("a long name refuses codex and not kimi",
          make(shape(longName, "d"), target: SkillAgent.codex).refusal == .cannotFix(.nameTooLong)
          && make(shape(longName, "d"), target: SkillAgent.kimi).refusal == nil)
    check("a body with no text gives no description to add",
          make("---\nname: x\n---\n\n", target: SkillAgent.codex).refusal == .cannotFix(.noDescription))
    check("a fix in files that are not SipAI's refuses the share, naming what is wrong",
          make(colon, target: SkillAgent.kimi, writable: false).refusal == .notSipAIs(.needsQuotes("description")))
    check("…and a skill needing nothing goes, its files or not", make(shape("ok", "Fine."), target: SkillAgent.kimi,
                                                                      writable: false).refusal == nil)
    let onlyCalled = "---\nname: oc\ndescription: d\ndisable-model-invocation: true\n---\n\nB.\n"
    check("only-when-called goes to codex in codex's file",
          make(onlyCalled, target: SkillAgent.codex).fixes == [.onlyWhenCalledForCodex])
    check("…codex's own goes to claude and kimi in SKILL.md",
          make(shape("oc", "d"), target: SkillAgent.kimi, yaml: "policy:\n  allow_implicit_invocation: false\n").fixes
            == [.onlyWhenCalledInSkill])
    check("…a policy file SipAI cannot edit leaves the setting behind, said so",
          make(onlyCalled, target: SkillAgent.codex, yaml: "policy: {allow_implicit_invocation: true}\n").ignored
            .contains("disable-model-invocation"))
    // A share is one click now, so the setting a share could NOT carry is
    // the check's own to report: the page says it once the share is done.
    let lostToCodex = make(onlyCalled, target: SkillAgent.codex, yaml: "policy: {allow_implicit_invocation: true}\n")
    let lostUnwritable = make(onlyCalled, target: SkillAgent.codex, writable: false)
    let lostToClaude = make(shape("oc", "d"), target: SkillAgent.claude, writable: false,
                            yaml: "policy:\n  allow_implicit_invocation: false\n")
    check("…a share that cannot carry only-when-called still goes, and says the setting was lost",
          lostToCodex.lostOnlyWhenCalled && lostToCodex.refusal == nil
          && lostUnwritable.lostOnlyWhenCalled && lostUnwritable.refusal == nil
          && lostToClaude.lostOnlyWhenCalled && lostToClaude.refusal == nil)
    check("…one that carries it, or has none to carry, loses nothing",
          !make(onlyCalled, target: SkillAgent.codex).lostOnlyWhenCalled
          && !make(shape("ok", "Fine."), target: SkillAgent.codex, writable: false).lostOnlyWhenCalled
          && !make(onlyCalled, target: SkillAgent.kimi, writable: false).lostOnlyWhenCalled
          && !make(onlyCalled, target: SkillAgent.codex, carry: false).lostOnlyWhenCalled)
    check("…and a repair carries no setting over",
          make(onlyCalled, target: SkillAgent.codex, carry: false).fixes.isEmpty)
    let claudeOnly = "---\nname: x\ndescription: d\nallowed-tools: Bash(git *)\ncontext: fork\n---\n\nRun !`git status` first.\n"
    check("what only claude acts on is named before a share to codex or kimi",
          make(claudeOnly, target: SkillAgent.kimi).ignored == ["allowed-tools", "context", "!`…`"]
          && make(claudeOnly, target: SkillAgent.codex).ignored == ["allowed-tools", "context", "!`…`"]
          && make(claudeOnly, target: SkillAgent.claude).ignored.isEmpty)
    check("…kimi's own keys before a share to the others, codex's own file before a share to the others",
          make("---\nname: x\ndescription: d\ntype: flow\n---\n\nB.\n", target: SkillAgent.claude).ignored == ["type"]
          && make(shape("x", "d"), target: SkillAgent.kimi, yaml: "interface:\n  display_name: X\n").ignored
            == [SkillCodexPolicy.relativePath]
          && make(shape("x", "d"), target: SkillAgent.kimi, yaml: "policy:\n  allow_implicit_invocation: true\n").ignored.isEmpty)
}

do {
    // A share, end to end, the way the catalog makes one: every step's
    // check first, the fixes next, the links last.
    let handMade = claudeDir.appendingPathComponent("hand-made")
    let handText = "---\nname: hand-made\nargument-hint: file: the path\n---\n\n# Hand made\n\nDo it.\n"
    write(handMade.appendingPathComponent("SKILL.md"), handText)
    let row = scannedRows().first { $0.name == "hand-made" }!
    check("a skill kimi skips is known as such before it is shared",
          row.notLoaded(by: SkillAgent.kimi) == nil
          && row.formatProblems == [.needsQuotes("argument-hint"), .noDescription])
    let plan = SkillPlanner.plan(row: row, agent: SkillAgent.kimi, include: true, env: env, projectRoot: project)!
    let review = ops.shareCheck(realPath: row.realPath!, target: SkillAgent.kimi, nameTaken: false)
    check("…its share check fixes both, from the text it read",
          review.fixes == [.quote(["argument-hint"]), .addDescription("Hand made")] && review.skillText == handText)
    try ops.preflight(plan)
    try ops.conform(realPath: row.realPath!, expected: review.skillText!, fixes: review.fixes)
    try ops.run(plan, projectRoot: project)
    let shared = try String(contentsOf: lib.appendingPathComponent("hand-made/SKILL.md"), encoding: .utf8)
    check("…the shared copy is in the library, fixed, and kimi has it",
          shared == "---\nname: hand-made\nargument-hint: \"file: the path\"\ndescription: Hand made\n---\n\n# Hand made\n\nDo it.\n"
          && isLink(kimiDir.appendingPathComponent("hand-made").path)
          && isLink(claudeDir.appendingPathComponent("hand-made").path))
    let after = scannedRows().first { $0.name == "hand-made" }!
    check("…and now nothing in it is one kimi skips", after.notLoaded(by: SkillAgent.kimi) == nil
          && after.formatProblems.isEmpty && after.agents == [SkillAgent.claude, SkillAgent.kimi])

    // Kimi, already holding a skill it skips, is told so.
    let kimiOwn = kimiDir.appendingPathComponent("kimi-own")
    write(kimiOwn.appendingPathComponent("SKILL.md"), "---\ndescription: No name line.\n---\n\nB.\n")
    let kimiRow = scannedRows().first { $0.entries[SkillAgent.kimi]?.entryPath == kimiOwn.path }!
    check("a skill in kimi's folder that kimi skips says why", kimiRow.notLoaded(by: SkillAgent.kimi) == .format(.noName))
    let repair = ops.shareCheck(realPath: kimiRow.realPath!, target: SkillAgent.kimi, nameTaken: false, carrySettings: false)
    try ops.conform(realPath: kimiRow.realPath!, expected: repair.skillText!, fixes: repair.fixes)
    check("…and a fix gives it the folder's name", scannedRows().first { $0.name == "kimi-own" }?
            .notLoaded(by: SkillAgent.kimi) == nil)
    // Codex's own word is what says codex skipped one; the rules never
    // speak for codex.
    var codexRow = kimiRow
    codexRow.entries = [SkillAgent.codex: kimiRow.entries[SkillAgent.kimi]!]
    check("codex's skip is codex's own word, never a guess from the rules",
          codexRow.notLoaded(by: SkillAgent.codex) == nil)
    codexRow.loadErrors[SkillAgent.codex] = "missing field `description`"
    check("…which is passed on as it said it", codexRow.notLoaded(by: SkillAgent.codex) == .agentSaid("missing field `description`"))

    // A fix made against a file that changed since it was checked.
    let moving = lib.appendingPathComponent("moving")
    write(moving.appendingPathComponent("SKILL.md"), "---\nname: moving\n---\n\nFirst.\n")
    let stale = ops.shareCheck(realPath: moving.path, target: SkillAgent.codex, nameTaken: false)
    write(moving.appendingPathComponent("SKILL.md"), "---\nname: moving\n---\n\nSecond.\n")
    do {
        try ops.conform(realPath: moving.path, expected: stale.skillText!, fixes: stale.fixes)
        check("a fix against a file that changed since its check is refused", false, "it ran")
    } catch let e as SkillOpError {
        check("a fix against a file that changed since its check is refused",
              e == .changedSinceChecked
              && (try? String(contentsOf: moving.appendingPathComponent("SKILL.md"), encoding: .utf8))
                == "---\nname: moving\n---\n\nSecond.\n")
    }

    // Only-when-called, carried to codex in codex's own file.
    let quiet = claudeDir.appendingPathComponent("quiet")
    write(quiet.appendingPathComponent("SKILL.md"), "---\nname: quiet\ndescription: d\ndisable-model-invocation: true\n---\n\nB.\n")
    let quietCheck = ops.shareCheck(realPath: quiet.path, target: SkillAgent.codex, nameTaken: false)
    try ops.conform(realPath: quiet.path, expected: quietCheck.skillText!, fixes: quietCheck.fixes)
    check("only-when-called reaches codex's own file",
          !SkillCodexPolicy.allowsImplicitInvocation(yaml: try? String(contentsOf: quiet.appendingPathComponent("agents/openai.yaml"), encoding: .utf8)))

    // A byte-order mark: Foundation's UTF-8 read drops it, SipAI's keeps it.
    let marked = lib.appendingPathComponent("marked")
    try fm.createDirectory(at: marked, withIntermediateDirectories: true)
    try Data([0xEF, 0xBB, 0xBF] + Array("---\nname: marked\ndescription: d\n---\n\nB.\n".utf8))
        .write(to: marked.appendingPathComponent("SKILL.md"))
    check("Foundation's UTF-8 read drops a byte-order mark (why SipAI does not use it)",
          (try? String(contentsOfFile: marked.appendingPathComponent("SKILL.md").path, encoding: .utf8))?
            .hasPrefix("\u{FEFF}") == false)
    check("…SipAI's keeps it, so codex's check sees it",
          SkillFileOps.readText(marked.appendingPathComponent("SKILL.md").path)?.hasPrefix("\u{FEFF}") == true
          && ops.shareCheck(realPath: marked.path, target: SkillAgent.codex, nameTaken: false).fixes == [.removeByteOrderMark])
    let markedText = SkillFileOps.readText(marked.appendingPathComponent("SKILL.md").path)!
    try ops.edit(realPath: marked.path, expected: markedText, description: "New.", body: "B.", onlyWhenCalled: false)
    check("…and an edit keeps it, as the editor's rule says",
          (try Data(contentsOf: marked.appendingPathComponent("SKILL.md"))).starts(with: [0xEF, 0xBB, 0xBF]))

    // Taking a skill from one agent leaves it with the others; from the
    // last, it goes to the Trash.
    let twice = scannedRows().first { $0.name == "hand-made" }!
    let fromKimi = SkillPlanner.plan(row: twice, agent: SkillAgent.kimi, include: false, env: env,
                                     projectRoot: project, keepWhenLast: false)!
    check("delete from one agent: its link alone", fromKimi.steps == [.unlink(at: kimiDir.appendingPathComponent("hand-made").path)])
    try ops.run(fromKimi, projectRoot: project)
    let once = scannedRows().first { $0.name == "hand-made" }!
    check("…the other keeps it, and its hint names nobody now",
          once.agents == [SkillAgent.claude]
          && SkillListing.sharedWith(once, besides: SkillAgent.claude, listed: listed).isEmpty)
    let fromClaude = SkillPlanner.plan(row: once, agent: SkillAgent.claude, include: false, env: env,
                                       projectRoot: project, keepWhenLast: false)!
    check("delete from the last agent: the link, then the folder to the Trash",
          fromClaude.needsKeepOrTrash
          && fromClaude.steps == [.unlink(at: claudeDir.appendingPathComponent("hand-made").path), .trash(once.realPath!)])
} catch {
    check("share, fix, delete", false, "\(error)")
}

// The shapes, raw and fixed, for the live section to hand the CLIs.
if let dir = ProcessInfo.processInfo.environment["SIPAI_SKILLS_SHAPES_DIR"] {
    var expect: [String: Any] = [:]
    for s in shapes {
        let raw = URL(fileURLWithPath: dir).appendingPathComponent("raw/\(s.name)/SKILL.md")
        try! fm.createDirectory(at: raw.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(s.text.utf8).write(to: raw)
        let fixable = s.problems.allSatisfy(SkillFormat.fixable)
        if fixable {
            let fixed = URL(fileURLWithPath: dir).appendingPathComponent("fixed/\(s.name)/SKILL.md")
            try! fm.createDirectory(at: fixed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(fixedForAll(s.text, folder: s.name).utf8).write(to: fixed)
        }
        expect[s.name] = [
            "codex": s.problems.contains { SkillFormat.skips($0, agent: SkillAgent.codex) },
            "kimi": s.problems.contains { SkillFormat.skips($0, agent: SkillAgent.kimi) },
            "fixable": fixable,
        ]
    }
    let data = try! JSONSerialization.data(withJSONObject: expect, options: [.sortedKeys])
    try! data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("expect.json"))
}

section("3k. The names Claude Code offers a skill under")
// Claude's own name test, read out of its bundle and measured on claude
// 2.1.309 (a throwaway config, claude's own `initialize` listing, no
// model call; SIPAI_SKILLS_LIVE=1 measures it again): a skill whose
// folder's name holds any of these is not offered.
let claudeRefused: [(what: String, name: String)] = [
    ("<", "a<b"), (">", "a>b"), ("zero-width space", "zw\u{200B}x"),
    ("zero-width non-joiner", "zw\u{200C}x"), ("zero-width joiner", "zw\u{200D}x"),
    ("left-to-right mark", "l\u{200E}x"), ("right-to-left override", "b\u{202E}x"),
    ("left-to-right isolate", "i\u{2066}x"), ("soft hyphen", "s\u{00AD}x"),
    ("byte-order mark", "b\u{FEFF}x"), ("word joiner", "w\u{2060}x"),
    ("no-break space", "n\u{00A0}x"), ("ideographic space", "i\u{3000}x"), ("en space", "e\u{2002}x"),
    ("Ogham space", "o\u{1680}x"), ("medium mathematical space", "m\u{205F}x"),
    ("narrow no-break space", "n\u{202F}x"), ("line separator", "l\u{2028}x"),
    ("paragraph separator", "p\u{2029}x"), ("tab", "t\tx"), ("a control character", "c\u{0001}x"),
    ("next line", "n\u{0085}x"), ("Arabic letter mark", "a\u{061C}x"),
    ("Mongolian vowel separator", "m\u{180E}x"), ("Hangul filler", "h\u{3164}x"),
    ("Hangul choseong filler", "h\u{115F}x"), ("Hangul jungseong filler", "h\u{1160}x"),
    ("halfwidth Hangul filler", "h\u{FFA0}x"), ("Khmer inherent vowel", "k\u{17B4}x"),
    ("braille blank", "b\u{2800}x"), ("object replacement", "o\u{FFFC}x"),
    ("combining grapheme joiner", "c\u{034F}x"), ("variation selector 1", "v\u{FE00}x"),
    ("variation selector 16", "v\u{FE0F}x"), ("variation selector 17", "v\u{E0100}x"),
    ("tag character", "t\u{E0041}x"), ("private use", "p\u{E000}x"),
    // The rest of its test: a space at either end or doubled, a colon at
    // the start, the other default-ignorable marks and fillers, an
    // emoji's selector or joiner where no emoji follows, and a stray or
    // piled-up combining mark.
    ("a space at the start", " lead"), ("a space at the end", "trail "), ("two spaces in a row", "dou  ble"),
    ("a colon at the start", ":lead"), ("Khmer vowel inherent AA", "k\u{17B5}x"),
    ("Mongolian free variation selector", "m\u{180B}x"), ("musical null notehead", "n\u{1D159}x"),
    ("a text-style selector after a letter", "a\u{FE0F}x"), ("a joiner between Latin letters", "ab\u{200D}cd"),
    ("a joiner after an emoji with no emoji after it", "he\u{2764}\u{FE0F}\u{200D}x"),
    ("a non-joiner at the end of an Arabic word", "\u{0645}\u{06CC}\u{200C}"),
    ("a bare keycap", "1\u{20E3}x"), ("a text-style selector before a skin tone", "x\u{1F44D}\u{FE0F}\u{1F3FB}"),
    ("a combining mark at the start", "\u{0301}leadmark"), ("a Hangul vowel at the start", "\u{1161}x"),
    ("nine combining marks in a row", "z\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306}\u{0307}\u{0308}\u{0309}x"),
    ("a soft-dotted i with a combining dot", "i\u{0307}x"), ("a dotless i with a mark", "\u{0131}\u{0301}x"),
]
// Offered: a plain space inside, an emoji with its text-style selector,
// a keycap, a skin tone, a joined emoji sequence, a flag, a joiner or
// non-joiner inside an Indic or Arabic word, a letter with up to eight
// marks, a colon inside or at the end, and letters of any script.
let claudeOffered = ["plain-name", "sp ace", "em\u{1F600}x", "ca\u{0301}x", "\u{6280}\u{80FD}", "caf\u{00E9}",
                     "he\u{2764}\u{FE0F}x", "gear\u{2699}\u{FE0F}", "\u{00A9}\u{FE0F}x", "1\u{FE0F}\u{20E3}x", "#\u{FE0F}\u{20E3}x",
                     "k\u{1F44D}\u{1F3FB}", "fam\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}x", "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}x",
                     "\u{1F1EB}\u{1F1F7}x", "\u{1F1EB} x", "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}x",
                     "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}", "\u{0915}\u{094D}\u{200D}\u{0937}",
                     "x\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306}\u{0307}\u{0308}", "1\u{0301}x", "a\u{064E}x",
                     "\u{0627}\u{064E}x", "\u{0915}\u{093E}", "\u{1112}\u{1161}\u{11AB}x", "a:b", "lead:", "col: on",
                     "mid dle", "under_score", "dot.name", "\u{05E9}\u{05DC}\u{05D5}\u{05DD}", "\u{0E2A}\u{0E27}\u{0E31}\u{0E2A}\u{0E14}\u{0E35}"]
check("Claude refuses every folder name measured as not offered (\(claudeRefused.count))",
      claudeRefused.allSatisfy { ClaudeSkillNames.refusesFolderName($0.name) },
      claudeRefused.filter { !ClaudeSkillNames.refusesFolderName($0.name) }.map(\.what).joined(separator: ", "))
check("…and offers every folder name measured as offered (\(claudeOffered.count))",
      !claudeOffered.contains(where: ClaudeSkillNames.refusesFolderName),
      claudeOffered.filter(ClaudeSkillNames.refusesFolderName).joined(separator: ", "))
check("a name: Claude ignores gives way to the folder's name; any other is the name",
      ClaudeSkillNames.offered(frontmatterName: "dirty\u{202E}name", folder: "clean-folder") == "clean-folder"
        && ClaudeSkillNames.offered(frontmatterName: "trail ", folder: "clean-folder") == "clean-folder"
        && ClaudeSkillNames.offered(frontmatterName: "dou  ble", folder: "clean-folder") == "clean-folder"
        && ClaudeSkillNames.offered(frontmatterName: "review", folder: "folder") == "review"
        && ClaudeSkillNames.offered(frontmatterName: "he\u{2764}\u{FE0F}x", folder: "folder") == "he\u{2764}\u{FE0F}x"
        && ClaudeSkillNames.offered(frontmatterName: nil, folder: "folder") == "folder")
check("…a name: over 256 UTF-16 units is ignored, one of 256 kept, and a colon at its start is a folder rule only",
      ClaudeSkillNames.offered(frontmatterName: String(repeating: "l", count: 257), folder: "f") == "f"
        && ClaudeSkillNames.offered(frontmatterName: String(repeating: "m", count: 256), folder: "f") == String(repeating: "m", count: 256)
        && ClaudeSkillNames.offered(frontmatterName: ":lead", folder: "f") == ":lead"
        && ClaudeSkillNames.offered(frontmatterName: "lead:", folder: "f") == "lead:")
check("a subfolder's namesake is <subfolder>:<name>",
      ClaudeSkillNames.namesake("review", in: "packages/web") == "packages/web:review")
check("Claude is handed a subfolder below the session's folder, the whole path where none is known",
      SkillTrigger.claudeAddDirs([
          SkillTrigger(name: "packages/web:review", subfolder: "/abs/work/packages/web", claudeAddDir: "packages/web"),
          SkillTrigger(name: "onlyhere", subfolder: "/abs/work/packages/web", claudeAddDir: "packages/web"),
          SkillTrigger(name: "older", subfolder: "/abs/elsewhere")]) == ["packages/web", "/abs/elsewhere"])

// Read off a scan: a skill in Claude's own folder under a folder name it
// refuses is listed, dimmed with why — never offered as if it loaded —
// and one whose name: it ignores is Claude's under its folder's name,
// while an agent that reads the name keeps it.
let namesHome = root.appendingPathComponent("names-home", isDirectory: true)
let namesEnv = SkillEnvironment.resolve([:], home: namesHome)
// A key SkillAgent names: never nil.
let namesClaude = SkillRoots.ownFolder(agent: SkillAgent.claude, scope: .global,
                                  env: namesEnv, projectRoot: nil)!
// A key SkillAgent names: never nil.
let namesCodex = SkillRoots.ownFolder(agent: SkillAgent.codex, scope: .global,
                                  env: namesEnv, projectRoot: nil)!
let namesLib = SkillRoots.library(scope: .global, env: namesEnv, projectRoot: nil)
skill(namesClaude.appendingPathComponent("hidden\u{200B}mark"), name: "hidden-mark", description: "A zero-width space in its folder.")
skill(namesLib.appendingPathComponent("plain-folder"), name: "odd\u{00A0}name", description: "A no-break space in its name.")
link(namesClaude.appendingPathComponent("plain-folder"), to: namesLib.appendingPathComponent("plain-folder"))
link(namesCodex.appendingPathComponent("plain-folder"), to: namesLib.appendingPathComponent("plain-folder"))
let namesWork = root.appendingPathComponent("names-work", isDirectory: true)
try! fm.createDirectory(at: namesWork, withIntermediateDirectories: true)
let namesRoots = SkillRoots.scanRoots(env: namesEnv, folder: namesWork)
let namesFound = SkillScan.read(roots: namesRoots)
let namesRows = SkillGrouping.rows(entries: SkillScan.entries(from: namesFound), library: namesFound, roots: namesRoots)
let hiddenRow = namesRows.first { $0.entries[SkillAgent.claude]?.entryPath.hasSuffix("hidden\u{200B}mark") == true }
check("a skill in a folder Claude refuses is listed under Claude as not loaded, and why",
      hiddenRow?.notLoaded(by: SkillAgent.claude) == .folderName
        && SkillFormat.notLoadedSentence("Claude Code", .folderName).contains("hidden or direction-changing"),
      String(describing: hiddenRow?.notLoaded(by: SkillAgent.claude)))
let oddRow = namesRows.first { $0.realPath?.hasSuffix("plain-folder") == true }
check("a name: Claude ignores: Claude calls it by its folder's name, Codex by its name",
      oddRow?.entries[SkillAgent.claude]?.name == "plain-folder"
        && oddRow?.entries[SkillAgent.codex]?.name == "odd\u{00A0}name"
        && oddRow?.notLoaded(by: SkillAgent.claude) == nil,
      "claude \(String(describing: oddRow?.entries[SkillAgent.claude]?.name)), codex \(String(describing: oddRow?.entries[SkillAgent.codex]?.name))")
let refusedShare = SkillShareCheck.make(skillText: shape("x", "A skill."), codexYaml: nil, folderName: "a<b",
                                        target: SkillAgent.claude, writable: true, nameTaken: false)
let codexShare = SkillShareCheck.make(skillText: shape("x", "A skill."), codexYaml: nil, folderName: "a<b",
                                      target: SkillAgent.codex, writable: true, nameTaken: false)
check("sharing such a skill with Claude is refused with words — the link SipAI makes takes that name",
      refusedShare.refusal == .folderName && codexShare.refusal == nil,
      "claude \(String(describing: refusedShare.refusal)), codex \(String(describing: codexShare.refusal))")

section("3j. A plan is made from what the folders hold now, and reaches every link")
// Each in a home of its own under the throwaway tree. No step that bins
// anything is run: plans are read, and the rest carried out.
do {
    struct World {
        let home: URL
        let env: SkillEnvironment
        init(_ name: String) {
            home = root.appendingPathComponent("worlds/\(name)/home", isDirectory: true)
            try! fm.createDirectory(at: home, withIntermediateDirectories: true)
            env = SkillEnvironment.resolve([:], home: home)
        }
        var lib: URL { SkillRoots.library(scope: .global, env: env, projectRoot: nil) }
        // Called with SkillAgent keys alone: never nil.
        func own(_ agent: String) -> URL {
            SkillRoots.ownFolder(agent: agent, scope: .global, env: env, projectRoot: nil)!
        }
        var common: URL { SkillRoots.common(scope: .global, env: env, projectRoot: nil) }
        var ops: SkillFileOps { SkillFileOps(env: env, projectRoot: nil) }
        func rows(folder: URL? = nil) -> [SkillRow] {
            let roots = SkillRoots.scanRoots(env: env, folder: folder)
            let found = SkillScan.read(roots: roots)
            return SkillGrouping.rows(entries: SkillScan.entries(from: found), library: found, roots: roots)
        }
        func row(_ name: String) -> SkillRow? { rows().first { $0.name == name } }
        func remove(_ row: SkillRow, from agent: String, present: Set<String> = Set(SkillAgent.all)) -> SkillSharePlan? {
            SkillPlanner.plan(row: row, agent: agent, include: false, env: env, projectRoot: nil, keepWhenLast: false,
                              present: present)
        }
        func share(_ row: SkillRow, with agent: String) -> SkillSharePlan? {
            SkillPlanner.plan(row: row, agent: agent, include: true, env: env, projectRoot: nil)
        }
    }
    let C = SkillAgent.claude, X = SkillAgent.codex, K = SkillAgent.kimi

    // A row read before another agent was given the skill.
    let stale = World("stale")
    skill(stale.lib.appendingPathComponent("foo"), name: "foo", description: "d")
    link(stale.own(C).appendingPathComponent("foo"), to: stale.lib.appendingPathComponent("foo"))
    let before = stale.row("foo")!
    check("a row just read is what the folders hold", SkillPlanner.isCurrent(before, env: stale.env, folder: nil))
    check("…and from it, taking the skill from its one agent would bin the folder",
          stale.remove(before, from: C)?.steps == [.unlink(at: stale.own(C).appendingPathComponent("foo").path),
                                                   .trash(stale.lib.appendingPathComponent("foo").path)])
    try stale.ops.run(stale.share(stale.row("foo")!, with: X)!, projectRoot: nil)
    check("given to another agent since, that row is no longer current — and the folder it would have binned is that agent's",
          !SkillPlanner.isCurrent(before, env: stale.env, folder: nil)
          && SkillPlanner.isCurrent(stale.row("foo")!, env: stale.env, folder: nil)
          && stale.remove(stale.row("foo")!, from: C)?.steps == [.unlink(at: stale.own(C).appendingPathComponent("foo").path)])
    let unusedRow = { () -> SkillRow in
        skill(stale.lib.appendingPathComponent("bar"), name: "bar", description: "d")
        return stale.row("bar")!
    }()
    try stale.ops.run(stale.share(unusedRow, with: C)!, projectRoot: nil)
    check("a Not in use row read before the skill was given out is not current either",
          !SkillPlanner.isCurrent(unusedRow, env: stale.env, folder: nil))
    try fm.removeItem(at: stale.lib.appendingPathComponent("bar"))
    check("…nor one whose folder has gone", !SkillPlanner.isCurrent(stale.row("foo").map { r in
              var gone = r; gone.entries = [:]; return gone } ?? before, env: stale.env, folder: nil)
          && !SkillPlanner.isCurrent(unusedRow, env: stale.env, folder: nil))

    // A link another agent's link passes through.
    let chain = World("chain")
    skill(chain.lib.appendingPathComponent("chain"), name: "chain", description: "d")
    link(chain.own(C).appendingPathComponent("chain"), to: chain.lib.appendingPathComponent("chain"))
    link(chain.own(K).appendingPathComponent("chain"), to: chain.own(C).appendingPathComponent("chain"))
    let through = chain.remove(chain.row("chain")!, from: C)!
    check("a link another agent's link goes through: that one is pointed at the real folder first",
          through.steps == [.repoint(at: chain.own(K).appendingPathComponent("chain").path,
                                     target: chain.lib.appendingPathComponent("chain").path),
                            .unlink(at: chain.own(C).appendingPathComponent("chain").path)]
          && through.keeps == [K])
    try chain.ops.run(through, projectRoot: nil)
    check("…so the agent said to keep the skill keeps it",
          chain.row("chain")?.agents == [K] && chain.row("chain")?.problems.isEmpty == true
          && SkillScan.realPath(chain.own(K).appendingPathComponent("chain").path) == chain.lib.appendingPathComponent("chain").path)

    // A folder a step would write in, that cannot be written in.
    let locked = World("locked")
    write(locked.own(C).appendingPathComponent("mine/SKILL.md"), "---\nname: mine\ndescription: Use when: asked\n---\n\nBody.\n")
    try fm.createDirectory(at: locked.own(X), withIntermediateDirectories: true)
    chmod(locked.own(X).path, 0o555)
    let toLocked = locked.share(locked.row("mine")!, with: X)!
    do {
        try locked.ops.preflight(toLocked)
        check("a share into a folder that cannot be written in is refused before anything moves", false, "preflight passed")
    } catch let error as SkillOpError {
        check("a share into a folder that cannot be written in is refused before anything moves",
              error == .notWritable(locked.own(X).path)
              && !isLink(locked.own(C).appendingPathComponent("mine").path)
              && !fm.fileExists(atPath: locked.lib.appendingPathComponent("mine").path), "\(error)")
    }
    chmod(locked.own(X).path, 0o755)
    check("…and goes through once it can be", (try? locked.ops.preflight(toLocked)) != nil)

    // Two agents whose skills folders are one folder on disk.
    let twins = World("twins")
    try fm.createDirectory(at: twins.own(C), withIntermediateDirectories: true)
    try fm.createDirectory(at: twins.own(X).deletingLastPathComponent(), withIntermediateDirectories: true)
    link(twins.own(X), to: twins.own(C))
    let made = try? twins.ops.create(name: "new-one", description: "d", body: "B.", onlyWhenCalled: false,
                                     scope: .global, agents: [C, X, K], env: twins.env, projectRoot: nil)
    check("a new skill for two agents whose folders are one folder takes one link between them, and the third agent its own",
          made != nil && twins.row("new-one")?.agents == [C, X, K]
          && isLink(twins.own(K).appendingPathComponent("new-one").path))

    // The folders SipAI manages, and the ones it only reads.
    let nested = World("nested")
    skill(nested.lib.appendingPathComponent("pack/inner"), name: "inner", description: "d")
    link(nested.own(C).appendingPathComponent("inner"), to: nested.lib.appendingPathComponent("pack/inner"))
    let inner = nested.row("inner")!
    check("a folder nested deeper in the library than a skill sits is not one SipAI bins: only the link goes",
          inner.home == .elsewhere && !inner.isManaged
          && nested.remove(inner, from: C)?.steps == [.unlink(at: nested.own(C).appendingPathComponent("inner").path)])
    let dotfiles = root.appendingPathComponent("worlds/nested/dotfiles/mine", isDirectory: true)
    skill(dotfiles, name: "mine", description: "d")
    link(nested.lib.appendingPathComponent("mine"), to: dotfiles)
    check("a link someone put in the library is no library skill: it is drawn nowhere, and nothing offers to bin its folder",
          nested.row("mine") == nil)
    let repo = root.appendingPathComponent("worlds/between/repo", isDirectory: true)
    let sub = repo.appendingPathComponent("pkg/app", isDirectory: true)
    try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
    let between = World("between")
    skill(repo.appendingPathComponent("pkg/.claude/skills/local"), name: "local", description: "d")
    let local = between.rows(folder: sub).first { $0.name == "local" }
    check("a skill in a folder between the project's root and the working folder is the agent's to read and not SipAI's to move",
          local?.agents == [C] && local?.home == .elsewhere && local?.isManaged == false
          && local.flatMap { SkillPlanner.plan(row: $0, agent: C, include: false, env: between.env, projectRoot: repo,
                                               keepWhenLast: false) } == nil)
    check("…though another agent can be given a link to it",
          local.flatMap { SkillPlanner.plan(row: $0, agent: K, include: true, env: between.env, projectRoot: repo) }?
            .steps.count == 1)

    // The common folder's other reader: on this Mac, or not.
    let hidden = World("hidden")
    skill(hidden.common.appendingPathComponent("tri"), name: "tri", description: "d")
    let absent = hidden.remove(hidden.row("tri")!, from: X, present: [C, X])
    check("taken from Codex out of the folder Codex and Kimi both read, with no Kimi on the Mac: Codex is its last agent, and nothing is made for a tool that is not there",
          absent?.steps == [.trash(hidden.common.appendingPathComponent("tri").path)] && absent?.keeps == [])
    let installed = hidden.remove(hidden.row("tri")!, from: X)
    check("…with Kimi installed, it is moved out and linked for Kimi, which the plan names as keeping it",
          installed?.movesFiles == true && installed?.keeps == [K]
          && installed?.steps.last == .link(at: hidden.own(K).appendingPathComponent("tri").path,
                                            target: hidden.lib.appendingPathComponent("tri").path))
    try hidden.ops.run(installed!, projectRoot: nil)
    let tri = hidden.rows()
    check("taken from Codex out of the folder Codex and Kimi both read, with Kimi not listed: it is Not in use, not nowhere",
          tri.first?.agents == [K] && SkillListing.rows(of: X, in: tri).isEmpty
          && SkillListing.unused(tri, listed: [C, X]).map(\.name) == ["tri"]
          && SkillListing.unused(tri, listed: [C, X, K]).isEmpty)

    // Files that are links, and folders that became one.
    let links = World("links")
    let outside = root.appendingPathComponent("worlds/links/outside", isDirectory: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    skill(links.lib.appendingPathComponent("file-linked"), name: "file-linked", description: "d")
    write(outside.appendingPathComponent("shared.yaml"), "interface:\n  display_name: Shared\n")
    link(links.lib.appendingPathComponent("file-linked/agents/openai.yaml"), to: outside.appendingPathComponent("shared.yaml"))
    do {
        try links.ops.setOnlyWhenCalled(realPath: links.lib.appendingPathComponent("file-linked").path, true)
        check("Codex's policy file that is a link is not written through, nor over", false, "it ran")
    } catch let error as SkillOpError {
        check("Codex's policy file that is a link is not written through, nor over",
              error == .unsupportedYAML && isLink(links.lib.appendingPathComponent("file-linked/agents/openai.yaml").path)
              && (try? String(contentsOf: outside.appendingPathComponent("shared.yaml"), encoding: .utf8))
                == "interface:\n  display_name: Shared\n", "\(error)")
    }
    skill(links.lib.appendingPathComponent("dir-linked"), name: "dir-linked", description: "d")
    link(links.lib.appendingPathComponent("dir-linked/agents"), to: outside)
    check("…nor one in an agents folder that is a link",
          (try? links.ops.setOnlyWhenCalled(realPath: links.lib.appendingPathComponent("dir-linked").path, true)) == nil
          && !fm.fileExists(atPath: outside.appendingPathComponent("openai.yaml").path))
    skill(links.own(C).appendingPathComponent("moved"), name: "moved", description: "Old.")
    let movedPath = links.own(C).appendingPathComponent("moved").path
    let movedText = SkillFileOps.readText(movedPath + "/SKILL.md")!
    try fm.moveItem(atPath: movedPath, toPath: outside.appendingPathComponent("moved").path)
    link(URL(fileURLWithPath: movedPath), to: outside.appendingPathComponent("moved"))
    check("an edit for a folder that has become a link since it was read lands nowhere",
          (try? links.ops.edit(realPath: movedPath, expected: movedText, description: "New.", body: "Body.",
                               onlyWhenCalled: nil)) == nil
          && SkillFileOps.readText(outside.appendingPathComponent("moved/SKILL.md").path) == movedText)

    // An edit that leaves the box as it found it.
    let quiet = World("quiet")
    let codexOnly = quiet.lib.appendingPathComponent("codex-only")
    skill(codexOnly, name: "codex-only", description: "Old.")
    write(codexOnly.appendingPathComponent("agents/openai.yaml"), "policy:\n  allow_implicit_invocation: false\n")
    let codexOnlyText = SkillFileOps.readText(codexOnly.appendingPathComponent("SKILL.md").path)!
    try quiet.ops.edit(realPath: codexOnly.path, expected: codexOnlyText, description: "New.", body: "Body.", onlyWhenCalled: nil)
    check("a description edited, the only-when-called box untouched: what Codex's file says is not copied into SKILL.md",
          SkillFileOps.readText(codexOnly.appendingPathComponent("SKILL.md").path)
            == "---\nname: codex-only\ndescription: New.\n---\n\nBody.\n")
    let skillOnly = quiet.lib.appendingPathComponent("skill-only")
    skill(skillOnly, name: "skill-only", description: "Old.", extra: "disable-model-invocation: true\n")
    let skillOnlyText = SkillFileOps.readText(skillOnly.appendingPathComponent("SKILL.md").path)!
    try quiet.ops.edit(realPath: skillOnly.path, expected: skillOnlyText, description: "New.", body: "Body.", onlyWhenCalled: nil)
    check("…nor what SKILL.md says written into a file of Codex's that was not there",
          !fm.fileExists(atPath: skillOnly.appendingPathComponent("agents/openai.yaml").path))
    try quiet.ops.edit(realPath: codexOnly.path, expected: SkillFileOps.readText(codexOnly.appendingPathComponent("SKILL.md").path)!,
                       description: "New.", body: "Body.", onlyWhenCalled: true)
    check("…and the box changed is written for every agent, as before",
          SkillFrontmatter.parse(SkillFileOps.readText(codexOnly.appendingPathComponent("SKILL.md").path)!).disableModelInvocation)

    // A copy named anew keeps its byte-order mark.
    let marks = World("marks")
    let source = root.appendingPathComponent("worlds/marks/source/marked", isDirectory: true)
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try Data([0xEF, 0xBB, 0xBF] + Array("---\nname: marked\ndescription: d\n---\n\nB.\n".utf8)).write(to: source.appendingPathComponent("SKILL.md"))
    _ = try marks.ops.importFolder(source, name: "renamed", scope: .global, agents: [C], env: marks.env, projectRoot: nil)
    check("a copy renamed on the way in keeps its byte-order mark",
          (try Data(contentsOf: marks.lib.appendingPathComponent("renamed/SKILL.md"))).starts(with: [0xEF, 0xBB, 0xBF])
          && marks.row("renamed") != nil)

    // An unpacked archive's links.
    let unpacked = root.appendingPathComponent("worlds/archive/scratch", isDirectory: true)
    let secret = root.appendingPathComponent("worlds/archive/secret.txt")
    write(secret, "not the skill's\n")
    try fm.createDirectory(at: unpacked.appendingPathComponent("sk"), withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: unpacked.appendingPathComponent("sk/SKILL.md").path, withDestinationPath: secret.path)
    check("a link in an unpacked archive that points out of it is found",
          SkillFileOps.linksLeaving(unpacked).map { ($0 as NSString).lastPathComponent } == ["SKILL.md"])
    try fm.removeItem(at: unpacked.appendingPathComponent("sk/SKILL.md"))
    write(unpacked.appendingPathComponent("sk/real.md"), "---\nname: sk\ndescription: d\n---\n")
    try fm.createSymbolicLink(atPath: unpacked.appendingPathComponent("sk/SKILL.md").path, withDestinationPath: "real.md")
    try fm.createSymbolicLink(atPath: unpacked.appendingPathComponent("sk/up").path, withDestinationPath: "../../secret.txt")
    check("…a relative one that climbs out too, and one that stays inside is left alone",
          SkillFileOps.linksLeaving(unpacked).map { ($0 as NSString).lastPathComponent } == ["up"])

    // A name that would arrive as a clash.
    let named: [SkillRow] = [
        SkillRow(id: "ro:codex:Built-in:imagegen", name: "imagegen", description: "", scope: .global,
                 home: .readOnly("Built-in"), realPath: "/x/imagegen",
                 entries: [X: SkillEntry(agent: X, name: "imagegen", description: "", scope: .global, rootKind: .readOnly,
                                         entryPath: "/x/imagegen", realPath: "/x/imagegen", isLink: false,
                                         frontmatter: SkillFrontmatter())],
                 frontmatter: SkillFrontmatter()),
        SkillRow(id: "/lib/spare", name: "spare", description: "", scope: .global, home: .library, realPath: "/lib/spare",
                 entries: [:], frontmatter: SkillFrontmatter()),
    ]
    check("a name an agent it goes to already has — a built-in's too — is taken; for an agent that has none it is free",
          SkillNameCheck.isTaken("imagegen", scope: .global, agents: [X], in: named)
          && SkillNameCheck.isTaken("imagegen", scope: .folder, agents: [C, X], in: named)
          && !SkillNameCheck.isTaken("imagegen", scope: .global, agents: [C], in: named))
    check("…and so is the name of a library skill no agent has, in its own scope",
          SkillNameCheck.isTaken("Spare", scope: .global, agents: [C], in: named)
          && !SkillNameCheck.isTaken("spare", scope: .folder, agents: [C], in: named))
} catch {
    check("plans and what the folders hold", false, "\(error)")
}

section("3f. Claude's listing, answered and refused")
do {
    func line(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }
    var both = ClaudeSkillListing()
    both.note(line(#"{"type":"system","subtype":"init"}"#))
    both.note(line(#"{"type":"control_response","response":{"subtype":"success","request_id":"sipai-skills-commands","response":{"commands":[{"name":"alpha","description":"A (user)"}]}}}"#))
    check("one answer is not the whole listing", !both.isComplete && both.listed)
    both.note(line(#"{"type":"control_response","response":{"subtype":"success","request_id":"sipai-skills-dialog","response":{"skills":[{"name":"alpha","source":"user","state":"on"}]}}}"#))
    check("both answers complete it", both.isComplete && both.statesKnown
          && both.commands.count == 1 && both.dialog.count == 1)
    // What a claude that does not know the second request says.
    var older = ClaudeSkillListing()
    older.note(line(#"{"type":"control_response","response":{"subtype":"success","request_id":"sipai-skills-commands","response":{"commands":[{"name":"alpha"}]}}}"#))
    older.note(line(#"{"type":"control_response","response":{"subtype":"error","request_id":"sipai-skills-dialog","error":"Unsupported control request subtype: get_skills_dialog"}}"#))
    check("a refused request is an answer: the read ends, the other half stands",
          older.isComplete && older.listed && !older.statesKnown && older.commands.count == 1 && older.dialog.isEmpty)
    var stranger = ClaudeSkillListing()
    stranger.note(line(#"{"type":"control_response","response":{"subtype":"success","request_id":"someone-else","response":{}}}"#))
    check("another request's answer is not ours", !stranger.isComplete && !stranger.listed)
}

// MARK: - 4. The once rule

section("4. Preloading")
check("nothing held: every pick loads",
      SkillPreload.toLoad(picks: ["a", "b"], evidence: []) == ["a", "b"])
check("a held pick does not load again",
      SkillPreload.toLoad(picks: ["a", "b"], evidence: [.loaded(["a"])]) == ["b"])
check("a compaction drops what was held",
      SkillPreload.toLoad(picks: ["a", "b"], evidence: [.loaded(["a", "b"]), .compaction]) == ["a", "b"])
check("a load after the compaction counts",
      SkillPreload.toLoad(picks: ["a", "b"], evidence: [.loaded(["a"]), .compaction, .loaded(["b"])]) == ["a"])
check("names compare without case", SkillPreload.toLoad(picks: ["Alpha"], evidence: [.loaded(["alpha"])]).isEmpty)
let marks: [SkillTranscriptMark] = [
    .user(text: "/review-pr the auth module", loadedSkills: []),
    .user(text: "do X", loadedSkills: ["beta"]),
    .tool(name: "Skill", input: ["skill": "gamma"]),
]
check("evidence: typed, sent and model-made loads (claude)",
      SkillEvidenceReader.evidence(marks, agent: SkillAgent.claude) == [.loaded(["review-pr"]), .loaded(["beta"]), .loaded(["gamma"])])
check("codex reads $name anywhere, not $HOME",
      SkillEvidenceReader.typedSkills(in: "use $review-pr and echo $HOME", agent: SkillAgent.codex) == ["review-pr"])
// Kimi: a message its front end started a skill from is drawn as its
// WORDS with the skill under them, so a row that still reads
// `/skill:name words` went through the headless run — text to the model,
// not a load. Only the bare command, drawn as typed either way, counts.
check("kimi reads a bare /skill:name; one with words after it is the headless run's text, and no load",
      SkillEvidenceReader.typedSkills(in: "/skill:xi", agent: SkillAgent.kimi) == ["xi"]
      && SkillEvidenceReader.typedSkills(in: "/skill:xi now", agent: SkillAgent.kimi).isEmpty
      && SkillEvidenceReader.typedSkills(in: "/skill:xi\nnow", agent: SkillAgent.kimi).isEmpty)
check("a pasted path is not a command",
      SkillEvidenceReader.typedSkills(in: "/Users/me/notes.md", agent: SkillAgent.claude).isEmpty)
let choices = [
    SkillChoice(name: "a", description: "", scope: .global, sourceLabel: nil, unavailable: nil, codexPath: "/p/a/SKILL.md"),
    SkillChoice(name: "off", description: "", scope: .global, sourceLabel: nil, unavailable: "Switched off.", codexPath: nil),
]
let statuses = SkillPickReport.statuses(picks: ["a", "off", "gone"], choices: choices, held: ["a"], missing: "missing")
check("status: loaded, off, missing",
      statuses["a"] == .loaded && statuses["off"] == .unavailable("Switched off.") && statuses["gone"] == .unavailable("missing"))
// A subfolder's skill is listed only once its subfolder has been read:
// while those reads are under way, a pick the list does not hold yet is
// not one known to be missing.
let reading = SkillPickReport.statuses(picks: ["a", "off", "gone"], choices: choices, held: ["a"],
                                       missing: "missing", stillReading: true)
check("…while the subfolders are still being read, a pick not listed yet is not called missing",
      reading["gone"] == .nextMessage && reading["a"] == .loaded && reading["off"] == .unavailable("Switched off."))
check("status before the read: nothing is called unavailable",
      SkillPickReport.statuses(picks: ["zz"], choices: nil, held: [], missing: "m")["zz"] == .nextMessage)
check("triggers skip held and unloadable picks, keep codex's path",
      SkillPickReport.triggers(picks: ["a", "off", "gone"], choices: choices, evidence: [], sendsUnread: false)
        == [SkillTrigger(name: "a", path: "/p/a/SKILL.md")])
check("before the folder is read: claude is sent the names, codex waits for the paths",
      SkillPickReport.triggers(picks: ["a"], choices: nil, evidence: [], sendsUnread: true) == [SkillTrigger(name: "a")]
      && SkillPickReport.triggers(picks: ["a"], choices: nil, evidence: [], sendsUnread: false).isEmpty)
check("a sentence ending in $name. names the skill, not the full stop",
      SkillEvidenceReader.typedSkills(in: "Use $alpha.", agent: SkillAgent.codex) == ["alpha"])
// A live row is drawn when Send is pressed. It counts as a load once the
// agent has answered it — never for a send that did not run.
let neverRan: [SkillTranscriptMark] = [.user(text: "do X", loadedSkills: ["a"])]
check("a send the agent never answered is not a load",
      SkillEvidenceReader.evidence(SkillEvidenceReader.delivered(neverRan, turnInFlight: false),
                                   agent: SkillAgent.claude).isEmpty)
check("…while its turn is still running it is being delivered",
      SkillEvidenceReader.evidence(SkillEvidenceReader.delivered(neverRan, turnInFlight: true),
                                   agent: SkillAgent.claude) == [.loaded(["a"])])
let stoppedThenSent: [SkillTranscriptMark] = [
    .user(text: "first", loadedSkills: ["a"]),            // stopped before anything came back
    .user(text: "second", loadedSkills: ["a"]), .answered,
    .user(text: "third", loadedSkills: []),               // the newest, unanswered
]
check("…an answered send is, and an unanswered one before it is dropped",
      SkillEvidenceReader.evidence(SkillEvidenceReader.delivered(stoppedThenSent, turnInFlight: false),
                                   agent: SkillAgent.claude) == [.loaded(["a"])])
check("…a tool call answers too",
      SkillEvidenceReader.evidence(
        SkillEvidenceReader.delivered([.user(text: "x", loadedSkills: ["a"]), .tool(name: "Bash", input: [:])],
                                      turnInFlight: false), agent: SkillAgent.claude) == [.loaded(["a"])])

// After a compaction: Claude re-attaches only what its own process loaded
// and Codex drops a skill, so their picks go again. Kimi keeps the user's
// own messages — a skill they started among them — while they fit its
// budget for them, and its record says when they did not (measured): kept
// whole, a Kimi pick is not sent again; trimmed, it is, like anyone's.
func due(_ marks: [SkillTranscriptMark], _ agent: String, picks: [String] = ["a"]) -> [String] {
    SkillPreload.toLoad(picks: picks, evidence: SkillEvidenceReader.evidence(marks, agent: agent))
}
let summarised: [SkillTranscriptMark] = [.user(text: "x", loadedSkills: ["a"]), .compaction(keepsUserLoads: false)]
let summarisedKept: [SkillTranscriptMark] = [.user(text: "x", loadedSkills: ["a"]), .compaction(keepsUserLoads: true)]
check("a compaction: claude and codex send a held pick again",
      due(summarised, SkillAgent.claude) == ["a"] && due(summarised, SkillAgent.codex) == ["a"])
check("…kimi does not, when its record says it kept the user's messages whole",
      due(summarisedKept, SkillAgent.kimi).isEmpty)
check("…and does when kimi had to trim them — sent again, not left cut short under a chip saying Loaded",
      due(summarised, SkillAgent.kimi) == ["a"])
check("…a skill the MODEL loaded itself is gone after any kimi summary, kept or not",
      due([.tool(name: "Skill", input: ["skill": "a"]), .compaction(keepsUserLoads: true)], SkillAgent.kimi) == ["a"])
check("…what the user loaded before a kept summary is still held after a second one, and a trimmed one ends it",
      due([.user(text: "x", loadedSkills: ["a"]), .compaction(keepsUserLoads: true),
           .user(text: "y", loadedSkills: ["b"]), .compaction(keepsUserLoads: true)],
          SkillAgent.kimi, picks: ["a", "b"]).isEmpty
      && due([.user(text: "x", loadedSkills: ["a"]), .compaction(keepsUserLoads: true),
              .compaction(keepsUserLoads: false), .user(text: "y", loadedSkills: ["b"])],
             SkillAgent.kimi, picks: ["a", "b"]) == ["a"])
// Kimi's own record of a summary, in the three shapes it writes (2.1.1).
check("kimi's record: kept whole, trimmed (a head is counted), and the older shape with no count",
      KimiSessionScanner.compactionKeepsUserMessages(["type": "context.apply_compaction", "compactedCount": 6,
                                                      "keptUserMessageCount": 2, "summary": "s"])
      && !KimiSessionScanner.compactionKeepsUserMessages(["type": "context.apply_compaction", "compactedCount": 21,
                                                          "keptUserMessageCount": 9, "keptHeadUserMessageCount": 1])
      && !KimiSessionScanner.compactionKeepsUserMessages(["type": "context.apply_compaction", "count": 4, "summary": "s"])
      && !KimiSessionScanner.compactionKeepsUserMessages(["type": "context.apply_compaction", "compactedCount": 4,
                                                          "keptUserMessageCount": 0, "legacyTail": true]))
check("kimi takes one skill per message; claude and codex every one a message names",
      SkillAgent.oneSkillPerMessage(SkillAgent.kimi)
      && !SkillAgent.oneSkillPerMessage(SkillAgent.claude) && !SkillAgent.oneSkillPerMessage(SkillAgent.codex))
let twoDue = [
    SkillChoice(name: "a", description: "", scope: .global, sourceLabel: nil, unavailable: nil, codexPath: nil),
    SkillChoice(name: "b", description: "", scope: .global, sourceLabel: nil, unavailable: nil, codexPath: nil),
]
check("one skill per message: the first due of two goes, and only it",
      SkillPickReport.triggers(picks: ["a", "b"], choices: twoDue, evidence: [], sendsUnread: false,
                               onePerMessage: true) == [SkillTrigger(name: "a")]
      && SkillPickReport.triggers(picks: ["a", "b"], choices: twoDue, evidence: [.loaded(["a"])],
                                  sendsUnread: false, onePerMessage: true) == [SkillTrigger(name: "b")]
      && SkillPickReport.triggers(picks: ["a", "b"], choices: twoDue, evidence: [], sendsUnread: false).count == 2)
// A subfolder's skill: what a send needs to reach it rides the trigger.
let fromSub = [SkillChoice(name: "sub", description: "", scope: .folder, sourceLabel: nil, unavailable: nil,
                           codexPath: "/w/pkg/.agents/skills/sub/SKILL.md", subfolder: "/w/pkg",
                           subfolderName: "pkg", skillsFolder: "/w/pkg/.agents/skills")]
check("a subfolder's skill carries its subfolder and its skills folder to the send",
      SkillPickReport.triggers(picks: ["sub"], choices: fromSub, evidence: [], sendsUnread: false)
        == [SkillTrigger(name: "sub", path: "/w/pkg/.agents/skills/sub/SKILL.md",
                         subfolder: "/w/pkg", skillsFolder: "/w/pkg/.agents/skills")])
let manyFromSubs = [
    SkillTrigger(name: "a", subfolder: "/w/x", skillsFolder: "/w/x/.claude/skills"),
    SkillTrigger(name: "b", subfolder: "/w/x", skillsFolder: "/w/x/.agents/skills"),
    SkillTrigger(name: "c"),
    SkillTrigger(name: "d", subfolder: "/w/y", skillsFolder: "/w/y/.codex/skills"),
]
check("claude names each subfolder once with --add-dir; codex is handed each skills folder once",
      SkillTrigger.claudeAddDirs(manyFromSubs) == ["/w/x", "/w/y"]
      && SkillTrigger.codexExtraRoots(manyFromSubs) == ["/w/x/.claude/skills", "/w/x/.agents/skills", "/w/y/.codex/skills"])
check("a subfolder's skill: claude in any mode, codex only through its app-server, kimi never",
      SkillSubfolderReach.refusal(agent: SkillAgent.claude, codex: .exec) == nil
      && SkillSubfolderReach.refusal(agent: SkillAgent.codex, codex: .appServer) == nil
      && SkillSubfolderReach.refusal(agent: SkillAgent.codex, codex: .exec) != nil
      && SkillSubfolderReach.refusal(agent: SkillAgent.kimi, codex: .appServer) != nil)
// Offered only on a tool at least as new as the one it was measured on:
// an older one may take the flag or the call and list nothing.
check("…and on a tool known to be older than the one it was measured on, neither: it needs a newer one",
      SkillSubfolderReach.refusal(agent: SkillAgent.claude, claudeTooOld: true) == SkillSubfolderReach.newerAgentNeeded
      && SkillSubfolderReach.refusal(agent: SkillAgent.codex, codex: .needsNewer) == SkillSubfolderReach.newerAgentNeeded
      && SkillSubfolderReach.refusal(agent: SkillAgent.codex, codex: .exec) != SkillSubfolderReach.newerAgentNeeded)
check("codex's send: exec in a mode that runs it; the app-server where there is one that is new enough; a version not read yet is held to neither",
      SkillSubfolderReach.codexSend(usesFrontEnd: false, frontEndMissing: false, measured: true) == .exec
      && SkillSubfolderReach.codexSend(usesFrontEnd: true, frontEndMissing: false, measured: true) == .appServer
      && SkillSubfolderReach.codexSend(usesFrontEnd: true, frontEndMissing: true, measured: true) == .needsNewer
      && SkillSubfolderReach.codexSend(usesFrontEnd: true, frontEndMissing: false, measured: false) == .needsNewer)

// Claude: a load that did not happen, by what its own stream says — the
// two records measured on 2.1.287, .288 and .289.
let initLine = #"{"type":"system","subtype":"init","slash_commands":["known","cmdfile","simplify"],"skills":["known","simplify"]}"#
let ranLine = #"{"type":"result","subtype":"success","num_turns":0,"result_index":0,"local_command":"custom","is_error":false}"#
let notRanLine = #"{"type":"result","subtype":"success","num_turns":0,"result_index":1,"is_error":false}"#
let turnLine = #"{"type":"result","subtype":"success","num_turns":1,"result":"OK","is_error":false}"#
check("claude's init names the session's commands; any other line names none",
      ClaudeSkillLoadCheck.slashCommands(initLine: initLine) == ["known", "cmdfile", "simplify"]
      && ClaudeSkillLoadCheck.slashCommands(initLine: ranLine) == nil
      && ClaudeSkillLoadCheck.slashCommands(initLine: #"{"type":"system","subtype":"init"}"#) == nil)
check("the result of a skill message says whether a command ran for it; the turn's own result says nothing",
      ClaudeSkillLoadCheck.ranCommand(resultLine: ranLine) == true
      && ClaudeSkillLoadCheck.ranCommand(resultLine: notRanLine) == false
      && ClaudeSkillLoadCheck.ranCommand(resultLine: turnLine) == nil
      && ClaudeSkillLoadCheck.ranCommand(resultLine: initLine) == nil)
let known = ClaudeSkillLoadCheck.slashCommands(initLine: initLine)
check("a load failed only when BOTH say so: the name in no list claude gave, and no command run for it",
      ClaudeSkillLoadCheck.failed(name: "nosuch", slashCommands: known, ranCommand: false)
      && !ClaudeSkillLoadCheck.failed(name: "known", slashCommands: known, ranCommand: false)
      && !ClaudeSkillLoadCheck.failed(name: "nosuch", slashCommands: known, ranCommand: true)
      && !ClaudeSkillLoadCheck.failed(name: "nosuch", slashCommands: nil, ranCommand: false))
check("kimi's type: none, prompt, inline and flow can be started; reference cannot",
      SkillFrontmatter.parse("---\nname: a\ndescription: d\n---\nbody").kimiUserCanStart
      && SkillFrontmatter.parse("---\nname: a\ndescription: d\ntype: flow\n---\nbody").kimiUserCanStart
      && SkillFrontmatter.parse("---\nname: a\ndescription: d\ntype: Reference\n---\nbody").type == "reference"
      && !SkillFrontmatter.parse("---\nname: a\ndescription: d\ntype: reference\n---\nbody").kimiUserCanStart)

// MARK: - 5. Wire text

section("5. Wire text")
let lines = SkillWire.claudeStdinLines(skills: ["alpha", "beta"], text: "do X").split(separator: "\n").map(String.init)
check("claude: one message per skill, then the text", lines.count == 3)
func json(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}
check("…skill messages start no model call",
      json(lines[0])["shouldQuery"] as? Bool == false && json(lines[1])["shouldQuery"] as? Bool == false)
check("…the text message does",
      json(lines[2])["shouldQuery"] == nil
      && (json(lines[2])["message"] as? [String: Any])?["content"] as? String == "do X")
check("…parent_tool_use_id is JSON null", json(lines[0])["parent_tool_use_id"] is NSNull)
let codex = SkillWire.codexText(skills: [SkillTrigger(name: "a", path: "/p a/SKILL.md"),
                                         SkillTrigger(name: "b", path: "/odd)path/SKILL.md")],
                                text: "<scheduled-task name=\"t\"></scheduled-task>\ndo X")
check("codex: linked mention, bare fallback for an odd path",
      codex.hasPrefix("[$a](/p a/SKILL.md) $b\n\n"))
let split = SkillWire.splittingCodexMentionLine(codex)
check("…read back: the names and the user's own text",
      split?.names == ["a", "b"] && split?.rest == "<scheduled-task name=\"t\"></scheduled-task>\ndo X")
check("a message opening with shell variables is not a mention line",
      SkillWire.splittingCodexMentionLine("$HOME\n\nwhy is this empty?") == nil)
check("a link that holds no SKILL.md path is the user's own first line",
      SkillWire.splittingCodexMentionLine("[$100](https://example.com/pay)\n\nis this right?") == nil)
// Names as codex's own list spells a plugin's skills, and a path with a space.
let plugin = SkillTrigger(name: "presentations:Presentations", path: "/Users/me/My Project/skills/presentations/SKILL.md")
let pluginText = SkillWire.codexText(skills: [plugin], text: "do X")
check("a namespaced, upper-case name and a path with a space travel as a link",
      pluginText == "[$presentations:Presentations](/Users/me/My Project/skills/presentations/SKILL.md)\n\ndo X")
check("…and are read back whole",
      SkillWire.splittingCodexMentionLine(pluginText)?.names == ["presentations:Presentations"]
      && SkillWire.splittingCodexMentionLine(pluginText)?.rest == "do X")
check("a name that neither spelling can carry is not sent, so no line is left in the message",
      SkillWire.codexMention(SkillTrigger(name: "Presentations")) == nil
      && SkillWire.codexText(skills: [SkillTrigger(name: "Presentations")], text: "do X") == "do X"
      && SkillWire.codexLoads([SkillTrigger(name: "Presentations"), plugin]) == [plugin])
check("a skill moved since its folder was read goes by name, not by a path codex no longer has",
      SkillWire.codexTriggers([SkillTrigger(name: "a", path: "/gone/a/SKILL.md"),
                               SkillTrigger(name: "b", path: "/here/b/SKILL.md")],
                              exists: { $0 == "/here/b/SKILL.md" })
        == [SkillTrigger(name: "a"), SkillTrigger(name: "b", path: "/here/b/SKILL.md")])
check("claude's and kimi's live row keeps a first line shaped like a mention",
      CodexSessionScanner.strippedTaskMarker("$path\n\nwhy is this empty?", mentionLine: false) == "$path\n\nwhy is this empty?"
      && CodexSessionScanner.strippedTaskMarker("<scheduled-task name=\"t\"></scheduled-task>\ndo X", mentionLine: false) == "do X")
check("the displayed text never carries the line",
      CodexSessionScanner.strippedTaskMarker(codex) == "do X")

// MARK: - 6. Readers

section("6. Claude reader")
func record(_ obj: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
}
func user(_ uuid: String, _ content: Any, meta: Bool = false, extra: [String: Any] = [:]) -> String {
    var o: [String: Any] = ["type": "user", "uuid": uuid, "message": ["role": "user", "content": content]]
    if meta { o["isMeta"] = true }
    for (k, v) in extra { o[k] = v }
    return record(o)
}
func assistant(_ uuid: String, _ text: String) -> String {
    record(["type": "assistant", "uuid": uuid,
            "message": ["role": "assistant", "model": "claude-x", "content": [["type": "text", "text": text]]]])
}
let body = [["type": "text", "text": "Base directory for this skill: /x/alpha\n\nBODY"]]
// The batch SipAI sends, shaped as claude 2.1.287 writes it.
let transcript = [
    user("u1", "<command-message>alpha</command-message>\n<command-name>/alpha</command-name>"),
    user("u2", body, meta: true),
    record(["type": "attachment", "uuid": "a1"]),
    user("u3", "<command-message>beta</command-message>\n<command-name>/beta</command-name>"),
    user("u4", [["type": "text", "text": "Base directory for this skill: /x/beta\n\nBODY"]], meta: true),
    user("u5", "do X"),
    assistant("x1", "OK"),
    // A command typed with words.
    user("u6", "<command-message>alpha</command-message>\n<command-name>/alpha</command-name>\n<command-args>the auth module</command-args>"),
    user("u7", body, meta: true),
    assistant("x2", "Done"),
    // A command typed alone.
    user("u8", "<command-message>beta</command-message>\n<command-name>/beta</command-name>"),
    user("u9", body, meta: true),
    assistant("x3", "Fine"),
    // A built-in command is drawn as before.
    user("u10", "<command-name>/mcp</command-name>\n<command-message>mcp</command-message>\n<command-args></command-args>"),
    record(["type": "system", "subtype": "local_command", "uuid": "s1",
            "content": "<local-command-stdout>No MCP servers</local-command-stdout>"]),
].joined(separator: "\n") + "\n"
let claudeFile = root.appendingPathComponent("claude.jsonl")
try! Data(transcript.utf8).write(to: claudeFile)
let history = AgentSessionScanner.readHistory(of: claudeFile)
let userRows: [(String, [String], String?)] = history.compactMap {
    if case .userText(let t) = $0.kind { return (t, $0.loadedSkills, $0.recordUuid) }
    return nil
}
check("no row shows a skill's expanded text", !history.contains {
    if case .userText(let t) = $0.kind { return t.contains("Base directory") }; return false
})
check("loads SipAI sent ride under the message",
      userRows.first.map { $0.0 == "do X" && $0.1 == ["alpha", "beta"] } == true)
check("…its handle is the first load's record (a branch takes the loads with it)",
      userRows.first?.2 == "u1")
check("a typed command with words reads as typed",
      userRows.count > 1 && userRows[1].0 == "/alpha the auth module" && userRows[1].1.isEmpty)
check("a typed command alone reads as typed",
      userRows.count > 2 && userRows[2].0 == "/beta" && userRows[2].1.isEmpty && userRows[2].2 == "u8")
check("a built-in command is drawn as before",
      userRows.contains { $0.0.contains("/mcp") })
// The branch cut for a LIVE row lands on the first load too.
check("a live row's cut covers its loads",
      AgentSessionFork.resolveCutPoint(matchingUserText: "do X", in: claudeFile) == "u1")

section("6a. Claude: text a command expands into, with and without a skill folder")
// As claude writes them: the expansion carries its command's `promptId`
// (and `turnCompanion`); after the model's own Skill call it names the
// call. Only a skill that HAS a folder opens with "Base directory…".
let bundledText = "# Update Config Skill\n\nModify configuration by updating settings files.\n"
let expansions = [
    // A skill claude ships itself, typed with words.
    user("b1", "<command-message>update-config</command-message>\n<command-name>/update-config</command-name>\n<command-args>hi</command-args>",
         extra: ["promptId": "p-1"]),
    user("b2", [["type": "text", "text": bundledText]], meta: true, extra: ["promptId": "p-1", "turnCompanion": true]),
    assistant("y1", "OK"),
    // The same kind typed alone.
    user("b3", "<command-message>simplify</command-message>\n<command-name>/simplify</command-name>", extra: ["promptId": "p-2"]),
    user("b4", [["type": "text", "text": "You are improving the quality of the changed code.\n"]], meta: true,
         extra: ["promptId": "p-2", "turnCompanion": true]),
    assistant("y2", "OK"),
    // A command file (`.claude/commands/greet.md`).
    user("b5", "<command-message>greet</command-message>\n<command-name>/greet</command-name>\n<command-args>bob</command-args>",
         extra: ["promptId": "p-3"]),
    user("b6", [["type": "text", "text": "Say hello to bob in one word.\n"]], meta: true,
         extra: ["promptId": "p-3", "turnCompanion": true]),
    assistant("y3", "OK"),
    // The model's own Skill call on a skill with no folder.
    user("b7", "use the skill", extra: ["promptId": "p-4"]),
    record(["type": "assistant", "uuid": "y4", "message": ["role": "assistant", "model": "claude-x",
            "content": [["type": "tool_use", "id": "toolu_1", "name": "Skill", "input": ["skill": "update-config"]]]]]),
    record(["type": "user", "uuid": "b8", "promptId": "p-4", "toolUseResult": ["ok": true],
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "Launching skill"]]]]),
    user("b9", [["type": "text", "text": bundledText]], meta: true,
         extra: ["promptId": "p-4", "turnCompanion": true, "sourceToolUseID": "toolu_1"]),
    assistant("y5", "OK"),
    // A companion record that is NOT an expansion keeps its place: no
    // command above it carries its prompt.
    user("b10", "look at this", extra: ["promptId": "p-5"]),
    user("b11", [["type": "text", "text": "[Image: original 2538x1311, displayed at 2000x1033]"]], meta: true,
         extra: ["promptId": "p-5", "turnCompanion": true]),
    assistant("y6", "OK"),
    // A skill typed alone and stopped: its load is not the stop's.
    user("b12", "<command-message>alpha</command-message>\n<command-name>/alpha</command-name>", extra: ["promptId": "p-6"]),
    user("b13", body, meta: true, extra: ["promptId": "p-6", "turnCompanion": true]),
    user("b14", [["type": "text", "text": "[Request interrupted by user]"]]),
    user("b15", "carry on", extra: ["promptId": "p-7"]),
    assistant("y7", "OK"),
].joined(separator: "\n") + "\n"
let expansionFile = root.appendingPathComponent("claude-expansions.jsonl")
try! Data(expansions.utf8).write(to: expansionFile)
let expanded = AgentSessionScanner.readHistory(of: expansionFile)
let expandedUsers: [(String, [String])] = expanded.compactMap {
    if case .userText(let t) = $0.kind { return (t, $0.loadedSkills) }; return nil
}
check("a skill with no folder never shows its text as a message",
      !expandedUsers.contains { $0.0.contains("Update Config Skill") || $0.0.contains("improving the quality") })
check("…typed with words it reads as typed", expandedUsers.contains { $0.0 == "/update-config hi" })
check("…typed alone it reads as typed", expandedUsers.contains { $0.0 == "/simplify" })
check("a command file reads as typed, its prompt never a row",
      expandedUsers.contains { $0.0 == "/greet bob" } && !expandedUsers.contains { $0.0.contains("Say hello to bob") })
check("the model's own Skill call leaves no skill text behind",
      expanded.contains { if case .toolUse(_, let n, _) = $0.kind { return n == "Skill" }; return false }
      && expandedUsers.filter { $0.0 == "use the skill" }.count == 1)
check("a companion record that is not an expansion is left as it was",
      expandedUsers.contains { $0.0 == "look at this" && $0.1.isEmpty }
      && expandedUsers.contains { $0.0.hasPrefix("[Image: original") })
check("a skill typed alone and stopped keeps its own row; the stop and the next message carry no load",
      expandedUsers.contains { $0.0 == "/alpha" && $0.1.isEmpty }
      && expandedUsers.contains { $0.0.hasPrefix("[Request interrupted") && $0.1.isEmpty }
      && expandedUsers.contains { $0.0 == "carry on" && $0.1.isEmpty })
check("…and the skills the reopened conversation holds are the ones typed and called",
      SkillPreload.toLoad(picks: ["update-config", "simplify", "greet", "alpha", "other"],
                          evidence: SkillEvidenceReader.evidence(expanded.compactMap { item -> SkillTranscriptMark? in
                              switch item.kind {
                              case .userText(let t): return .user(text: t, loadedSkills: item.loadedSkills)
                              case .toolUse(_, let n, let i): return .tool(name: n, input: i)
                              default: return nil
                              }
                          }, agent: SkillAgent.claude)) == ["other"])
// A live row of a typed command is found in its record, in the words the row shows.
check("a typed command's live row finds its record (with words, and alone)",
      AgentSessionFork.resolveCutPoint(matchingUserText: "/update-config hi", in: expansionFile) == "b1"
      && AgentSessionFork.resolveCutPoint(matchingUserText: "/simplify", in: expansionFile) == "b3")
// A batch of folder-less skills ahead of a message: the cut covers them.
let bundledBatch = [
    user("c1", "<command-message>simplify</command-message>\n<command-name>/simplify</command-name>", extra: ["promptId": "q-1"]),
    user("c2", [["type": "text", "text": "You are improving the quality of the changed code.\n"]], meta: true,
         extra: ["promptId": "q-1", "turnCompanion": true]),
    record(["type": "attachment", "uuid": "a9"]),
    user("c3", "tidy this up", extra: ["promptId": "q-2"]),
    assistant("z1", "OK"),
].joined(separator: "\n") + "\n"
let bundledBatchFile = root.appendingPathComponent("claude-bundled-batch.jsonl")
try! Data(bundledBatch.utf8).write(to: bundledBatchFile)
let bundledRows = AgentSessionScanner.readHistory(of: bundledBatchFile)
check("a folder-less skill sent ahead of a message rides under it",
      bundledRows.contains { if case .userText(let t) = $0.kind { return t == "tidy this up" && $0.loadedSkills == ["simplify"] && $0.recordUuid == "c1" }; return false })
check("…and a live row's cut covers it",
      AgentSessionFork.resolveCutPoint(matchingUserText: "tidy this up", in: bundledBatchFile) == "c1")

section("6b. Codex reader")
let rollout = [
    record(["type": "session_meta", "payload": ["id": "t1", "cwd": "/p"]]),
    record(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "turn-1"]]),
    record(["type": "response_item", "payload": ["type": "message", "role": "user",
            "content": [["type": "input_text", "text": "[$beta](/p/beta/SKILL.md)\n\ndo X"]]]]),
    record(["type": "response_item", "payload": ["type": "message", "role": "user",
            "content": [["type": "input_text", "text": "<skill>\n<name>beta</name>\n<path>/p/beta/SKILL.md</path>\n---\nname: beta\n---\nBODY"]]]]),
    record(["type": "response_item", "payload": ["type": "message", "role": "assistant",
            "content": [["type": "output_text", "text": "OK"]]]]),
].joined(separator: "\n") + "\n"
let rolloutFile = root.appendingPathComponent("rollout.jsonl")
try! Data(rollout.utf8).write(to: rolloutFile)
let codexRows = CodexSessionScanner.readHistory(of: rolloutFile)
let codexUsers: [(String, [String])] = codexRows.compactMap {
    if case .userText(let t) = $0.kind { return (t, $0.loadedSkills) }; return nil
}
check("codex: the injected skill text is never a row", codexUsers.count == 1)
check("…the mention line becomes the skills line", codexUsers.first.map { $0.0 == "do X" && $0.1 == ["beta"] } == true)

section("6c. Kimi reader")
let wire = [
    record(["type": "context.append_message", "message": ["role": "user", "id": "msg_1",
            "origin": ["kind": "skill_activation", "trigger": "user-slash", "skillName": "xi", "skillArgs": "now"],
            "content": [["type": "text", "text": "User activated the skill \"xi\". <skill-loaded name=\"xi\">BODY"]]]]),
    record(["type": "context.append_message", "message": ["role": "user", "id": "msg_2",
            "origin": ["kind": "skill_activation", "trigger": "model-tool", "skillName": "xi", "inTurn": true],
            "content": [["type": "text", "text": "Skill tool loaded instructions for this request. <skill-loaded>BODY"]]]]),
    record(["type": "context.append_message", "message": ["role": "user", "id": "msg_3",
            "origin": ["kind": "user"], "content": [["type": "text", "text": "plain"]]]]),
].joined(separator: "\n") + "\n"
let wireFile = root.appendingPathComponent("wire.jsonl")
try! Data(wire.utf8).write(to: wireFile)
let kimiUsers: [(String, String?, [String])] = KimiSessionScanner.readHistory(of: wireFile).compactMap {
    if case .userText(let t) = $0.kind { return (t, $0.recordUuid, $0.loadedSkills) }; return nil
}
check("kimi: a message that carries a skill reads as its words with the skill named under them, its own handle",
      kimiUsers.first.map { $0.0 == "now" && $0.1 == "msg_1" && $0.2 == ["xi"] } == true)
// A bare activation has no words: it is drawn as typed, and the evidence
// reads the skill off it.
let bareWire = record(["type": "context.append_message", "message": ["role": "user", "id": "msg_9",
            "origin": ["kind": "skill_activation", "trigger": "user-slash", "skillName": "xi"],
            "content": [["type": "text", "text": "User activated the skill \"xi\". <skill-loaded name=\"xi\">BODY"]]]]) + "\n"
let bareFile = root.appendingPathComponent("wire-bare.jsonl")
try! Data(bareWire.utf8).write(to: bareFile)
let bareRows = KimiSessionScanner.readHistory(of: bareFile).compactMap { item -> (String, [String])? in
    if case .userText(let t) = item.kind { return (t, item.loadedSkills) }; return nil
}
check("…a bare /skill:name is drawn as typed, and still counts as the load",
      bareRows.first.map { $0.0 == "/skill:xi" && $0.1.isEmpty } == true
      && SkillEvidenceReader.evidence([.user(text: "/skill:xi", loadedSkills: [])], agent: SkillAgent.kimi) == [.loaded(["xi"])])
check("…the model's own load is no row", !kimiUsers.contains { $0.0.contains("Skill tool loaded") })
// The summary row carries kimi's own word on what it kept, live and
// reopened alike (the tailer hands the same row on as a live event).
let compactedWire = [
    record(["type": "context.apply_compaction", "agentId": "main", "summary": "s", "compactedCount": 6,
            "tokensBefore": 900, "tokensAfter": 300, "keptUserMessageCount": 2]),
    record(["type": "context.apply_compaction", "agentId": "main", "summary": "s", "compactedCount": 21,
            "tokensBefore": 45892, "tokensAfter": 40848, "keptUserMessageCount": 9, "keptHeadUserMessageCount": 1]),
].joined(separator: "\n") + "\n"
let compactedFile = root.appendingPathComponent("wire-compacted.jsonl")
try! Data(compactedWire.utf8).write(to: compactedFile)
let summaryRows = KimiSessionScanner.readHistory(of: compactedFile).filter {
    if case .compaction = $0.kind { return true }; return false
}
check("…a summary row says whether kimi kept the user's messages whole, and its live event says the same",
      summaryRows.map(\.compactionKeepsUserMessages) == [true, false]
      && summaryRows.compactMap { AgentSessionTailer.liveEvent(for: $0)?.compactionKeepsUserMessages } == [true, false])
check("…and the user's own message stays", kimiUsers.contains { $0.0 == "plain" })

// MARK: - 7b. Reads that are fresh for whoever asks

section("7b. Fresh reads")
// What the catalog's `refresh` runs through: a caller that arrives while
// a read is under way waits for a read that began after it asked.
@MainActor
final class Disk {
    var value = 0
    var seen: [Int] = []
    func read() async {
        let now = value
        try? await Task.sleep(nanoseconds: 120_000_000)
        seen.append(now)
    }
}
let disk = Disk()
let gate = FreshReads()
let firstCaller = Task { @MainActor in await gate.run("folder") { await disk.read() } }
try? await Task.sleep(nanoseconds: 30_000_000)
// The first read is under way; the world changes; a second caller asks.
let underWay = gate.isRunning("folder")
disk.value = 1
await gate.run("folder") { await disk.read() }
let seenByLate = disk.seen
check("a caller that arrives mid-read comes back with a read begun after it asked",
      underWay && seenByLate.last == 1, "under way \(underWay), saw \(seenByLate)")
await firstCaller.value
let seenByBoth = disk.seen
check("…and the two callers cost two reads, not three", seenByBoth == [0, 1], "\(seenByBoth)")
check("…with nothing left running", !gate.isRunning("folder"))
await gate.run("folder") { await disk.read() }
check("a caller that finds nothing running reads at once", disk.seen.count == 3)

// MARK: - 7c. The title and the task of a session that opens on skills

section("7c. A session that opens on skill loads")
do {
    func inspect(_ records: [String], _ name: String) -> (title: String, task: String?) {
        let file = root.appendingPathComponent(name)
        try! Data((records.joined(separator: "\n") + "\n").utf8).write(to: file)
        let r = AgentSessionScanner.inspectSession(from: file, decodedProjectPath: nil)
        return (r.title, r.scheduledTaskName)
    }
    // A scheduled run as claude writes it: the loads, then the marked prompt.
    let run = inspect([
        user("r1", "<command-message>alpha</command-message>\n<command-name>/alpha</command-name>", extra: ["promptId": "p1"]),
        user("r2", body, meta: true, extra: ["promptId": "p1", "turnCompanion": true]),
        record(["type": "attachment", "uuid": "ra"]),
        user("r3", "<scheduled-task name=\"nightly\"></scheduled-task>\ncheck the build", extra: ["promptId": "p2"]),
        assistant("rx", "OK"),
    ], "run.jsonl")
    check("a run that loads skills is filed under its task, named by its prompt",
          run.task == "nightly" && run.title == "check the build", "\(run)")
    // The same with skills long enough to fill the first window.
    let long = String(repeating: "Instruction line of a long skill.\n", count: 9_500)   // ~320 KB
    let longRun = inspect([
        user("l1", "<command-message>alpha</command-message>\n<command-name>/alpha</command-name>", extra: ["promptId": "p1"]),
        user("l2", [["type": "text", "text": "Base directory for this skill: /x/alpha\n\n" + long]], meta: true,
             extra: ["promptId": "p1", "turnCompanion": true]),
        user("l3", "<scheduled-task name=\"nightly\"></scheduled-task>\ncheck the build", extra: ["promptId": "p2"]),
        assistant("lx", "OK"),
    ], "long-run.jsonl")
    check("…and still is when its skills fill the first window",
          longRun.task == "nightly" && longRun.title == "check the build", "\(longRun)")
    // A session that opens on a skill with no folder is not named by the skill's text.
    let shipped = inspect([
        user("s1", "<command-message>update-config</command-message>\n<command-name>/update-config</command-name>\n<command-args>allow npm</command-args>",
             extra: ["promptId": "p1"]),
        user("s2", [["type": "text", "text": "# Update Config Skill\n\nModify configuration.\n"]], meta: true,
             extra: ["promptId": "p1", "turnCompanion": true]),
        assistant("sx", "OK"),
    ], "shipped.jsonl")
    check("a session opening on a folder-less skill is named by what was typed",
          shipped.title == "/update-config allow npm" && shipped.task == nil, "\(shipped)")
}

// MARK: - 7d. A folder's subfolders, and the folders a page has browsed

/// `work` run off the main thread, its answer if it came inside
/// `seconds` — for a call that, wrong, never returns. A plain function:
/// the wait is not one an async context may make itself.
func bounded<T>(_ seconds: Double, _ work: @escaping () -> T) -> T? {
    let done = DispatchSemaphore(value: 0)
    var answer: T? = nil
    DispatchQueue.global().async {
        answer = work()
        done.signal()
    }
    return done.wait(timeout: .now() + seconds) == .success ? answer : nil
}

section("7d. Subfolders with skills, and the folders browsed")
do {
    // What a read of `folder` holds — the scan the catalog makes.
    func rowsRead(_ folder: URL) -> [SkillRow] {
        let r = SkillRoots.scanRoots(env: env, folder: folder)
        let f = SkillScan.read(roots: r)
        return SkillGrouping.rows(entries: SkillScan.entries(from: f), library: f, roots: r)
    }
    // Paths as the walk spells them: the chosen folder's own spelling.
    func std(_ url: URL) -> String { SkillRoots.pathURL(url).path }
    func below(_ found: [SkillLevel], _ base: URL) -> [String] {
        found.map { String($0.path.dropFirst(std(base).count + 1)) }
    }

    // A workspace with no repository: projects below it, each with
    // skills of its own, and the places a walk must not go.
    let ws = root.appendingPathComponent("walk/Workspace", isDirectory: true)
    skill(ws.appendingPathComponent("Alpha/.agents/skills/a1"), name: "a1", description: "In Alpha.")
    skill(ws.appendingPathComponent("Beta/.claude/skills/b1"), name: "b1", description: "In Beta.")
    skill(ws.appendingPathComponent("Hold/.sipai/skills/h1"), name: "h1", description: "In Hold's library.")
    skill(ws.appendingPathComponent("Group/Inner/.kimi-code/skills/i1"), name: "i1", description: "Two down.")
    skill(ws.appendingPathComponent("Group/Inner/Deep/.codex/skills/c3"), name: "c3", description: "Three down.")
    skill(ws.appendingPathComponent("Group/Inner/Deep/Deeper/.claude/skills/d1"), name: "d1", description: "Four down.")
    skill(ws.appendingPathComponent(".hidden/.claude/skills/x1"), name: "x1", description: "Hidden.")
    skill(ws.appendingPathComponent("node_modules/pkg/.claude/skills/n1"), name: "n1", description: "In node_modules.")
    skill(ws.appendingPathComponent("Tool.app/.claude/skills/p1"), name: "p1", description: "In a package.")
    skill(ws.appendingPathComponent("Flagged/.claude/skills/f1"), name: "f1", description: "In a folder flagged hidden.")
    var flagged = ws.appendingPathComponent("Flagged", isDirectory: true)
    var hiddenFlag = URLResourceValues()
    hiddenFlag.isHidden = true
    try! flagged.setResourceValues(hiddenFlag)
    try! fm.createDirectory(at: ws.appendingPathComponent("Empty/.claude/skills/not-a-skill"), withIntermediateDirectories: true)
    write(ws.appendingPathComponent("Empty/.claude/skills/.DS_Store"), "x")
    link(ws.appendingPathComponent("Shortcut"), to: ws.appendingPathComponent("Alpha"))
    // Links in a skills folder: one to nothing is a row (a broken link);
    // one to a folder with no SKILL.md, and one someone put in the
    // library, are not.
    link(ws.appendingPathComponent("LinkOnly/.claude/skills/to-nothing"), to: ws.appendingPathComponent("gone"))
    try! fm.createDirectory(at: ws.appendingPathComponent("Plain/notes"), withIntermediateDirectories: true)
    link(ws.appendingPathComponent("LinkToPlain/.claude/skills/notes"), to: ws.appendingPathComponent("Plain/notes"))
    link(ws.appendingPathComponent("LibLink/.sipai/skills/a1"), to: ws.appendingPathComponent("Alpha/.agents/skills/a1"))

    let walk = SkillRoots.subfolders(of: ws, home: home)
    let names = below(walk.found, ws)
    check("the walk finds the subfolders holding skills, nearest first, then by name — three levels down",
          names == ["Alpha", "Beta", "Hold", "LinkOnly", "Group/Inner", "Group/Inner/Deep"] && !walk.stoppedEarly,
          "\(names) stopped early \(walk.stoppedEarly)")
    check("…and not a fourth level down, a hidden folder (by name or by flag), node_modules, a package or a link",
          !names.contains { $0.contains("Deeper") || $0.contains("hidden") || $0.contains("node_modules")
                            || $0.contains("Tool.app") || $0 == "Shortcut" || $0 == "Flagged" })
    check("…nor a skills folder with no skill, a link to a folder with no SKILL.md, or a link put in the library",
          !names.contains { $0 == "Empty" || $0 == "LinkToPlain" || $0 == "LibLink" })
    // The walk and the read agree: every folder the walk hands back has
    // something at its own level in its read, and no other folder does.
    let candidates = ["Alpha", "Beta", "Hold", "LinkOnly", "Group", "Group/Inner", "Group/Inner/Deep",
                      "Empty", "LinkToPlain", "LibLink", "Plain"]
    let drawn = candidates.filter { name in
        let folder = ws.appendingPathComponent(name, isDirectory: true)
        return !SkillListing.rows(rowsRead(folder), at: SkillLevel(path: folder.path)).isEmpty
    }
    check("a subfolder is found exactly when a read of it has something at its own level",
          Set(drawn) == Set(names), "read: \(drawn.sorted()) walk: \(names.sorted())")

    // The chosen folder reached through a link is walked all the same,
    // its subfolders spelled the way it is.
    let wsLink = root.appendingPathComponent("walk/ws-link", isDirectory: true)
    link(wsLink, to: ws)
    let throughLink = SkillRoots.subfolders(of: wsLink, home: home)
    check("a chosen folder that is a link is walked, its subfolders spelled through it",
          below(throughLink.found, wsLink) == names
          && throughLink.found.allSatisfy { $0.path.hasPrefix(std(wsLink) + "/") },
          "\(throughLink.found.map(\.path))")

    // Never the home folder, nor a folder above it — judged on the real
    // folders. A skill sits in a visible folder under the home so an
    // unguarded walk would find it.
    skill(home.appendingPathComponent("Projects/.claude/skills/hp"), name: "hp", description: "Under the home folder.")
    let homeLink = root.appendingPathComponent("walk/home-link", isDirectory: true)
    link(homeLink, to: home)
    check("(an unguarded walk of the home folder would find a project there)",
          SkillRoots.holdsSkills(home.appendingPathComponent("Projects").path, ownProject: true))
    check("the home folder and a folder above it are not walked",
          SkillRoots.subfolders(of: home, home: home) == SkillSubfolders()
          && SkillRoots.subfolders(of: home.deletingLastPathComponent(), home: home) == SkillSubfolders())
    check("…nor a link to the home folder, nor the disk's top",
          SkillRoots.subfolders(of: homeLink, home: home) == SkillSubfolders()
          && !SkillRoots.walksBelow("/", home: home.path) && !SkillRoots.walksBelow("/", home: "/Users/someone"))
    let shouted = home.path.uppercased()
    if SkillScan.realPath(shouted) != nil {
        // A volume that does not tell case apart: the same folder.
        check("…nor the home folder's path typed in another case", !SkillRoots.walksBelow(shouted, home: home.path))
    }
    check("…while a folder inside the home folder is",
          SkillRoots.walksBelow(home.appendingPathComponent("Projects").path, home: home.path)
          && SkillRoots.walksBelow("/Users/someone/Work", home: "/Users/someone")
          && !SkillRoots.walksBelow("/Users", home: "/Users/someone"))

    let many = root.appendingPathComponent("walk/Many", isDirectory: true)
    for i in 0..<(SkillRoots.subfolderLimit + 3) {
        skill(many.appendingPathComponent(String(format: "p%02d/.claude/skills/s", i)), name: "s", description: "One of many.")
    }
    let capped = SkillRoots.subfolders(of: many, home: home)
    check("past \(SkillRoots.subfolderLimit) subfolders the walk stops, and says it stopped early",
          capped.found.count == SkillRoots.subfolderLimit && capped.stoppedEarly, "\(capped.found.count) \(capped.stoppedEarly)")
    let wide = root.appendingPathComponent("walk/Wide", isDirectory: true)
    for i in 0...SkillRoots.subfolderVisitLimit {
        try! fm.createDirectory(at: wide.appendingPathComponent(String(format: "d%05d", i)), withIntermediateDirectories: true)
    }
    skill(wide.appendingPathComponent("zz-last/.claude/skills/z"), name: "z", description: "Past the bound.")
    let bounded2 = SkillRoots.subfolders(of: wide, home: home)
    check("past \(SkillRoots.subfolderVisitLimit) folders looked in it stops, and says so — with nothing found, which is why the page says \"may\"",
          bounded2.found.isEmpty && bounded2.stoppedEarly, "\(bounded2.found.map(\.path)) \(bounded2.stoppedEarly)")
    // A folder's files are not folders looked in: more of them than the
    // walk's whole bound, and the one subfolder with a skill is found.
    let files = root.appendingPathComponent("walk/Files", isDirectory: true)
    try! fm.createDirectory(at: files, withIntermediateDirectories: true)
    for i in 0..<(SkillRoots.subfolderVisitLimit + 500) {
        fm.createFile(atPath: files.appendingPathComponent(String(format: "f%05d.dat", i)).path, contents: nil)
    }
    skill(files.appendingPathComponent("zz/.claude/skills/z"), name: "z", description: "Beside the files.")
    let amongFiles = SkillRoots.subfolders(of: files, home: home)
    check("a folder's files cost the walk nothing: \(SkillRoots.subfolderVisitLimit + 500) of them, and the subfolder beside them is found",
          below(amongFiles.found, files) == ["zz"] && !amongFiles.stoppedEarly,
          "\(amongFiles.found.map(\.path)) \(amongFiles.stoppedEarly)")
    check("…the listing hands back folders alone, by name",
          SkillRoots.childFolders(of: files.path) == ["zz"]
          && SkillRoots.childFolders(of: ws.path) == ["Alpha", "Beta", "Empty", "Flagged", "Group", "Hold", "LibLink",
                                                       "LinkOnly", "LinkToPlain", "Plain", "Tool.app"],
          "\(SkillRoots.childFolders(of: ws.path))")
    check("…and a folder flagged hidden, a package and a link are not ones the walk looks in",
          !SkillRoots.isPlainFolder(ws.appendingPathComponent("Flagged").path)
          && !SkillRoots.isPlainFolder(ws.appendingPathComponent("Tool.app").path)
          && !SkillRoots.isPlainFolder(ws.appendingPathComponent("Shortcut").path)
          && SkillRoots.isPlainFolder(ws.appendingPathComponent("Alpha").path))

    // A folder URL a directory listing hands back climbs past "/": the
    // walk up for a project root must end anyway, and on the right folder.
    let listed = try! fm.contentsOfDirectory(at: ws, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        .first { $0.lastPathComponent == "Alpha" }!
    var climb = listed.standardizedFileURL
    for _ in 0..<(climb.pathComponents.count + 2) { climb = climb.deletingLastPathComponent() }
    check("(the hazard: a listing's folder URL climbs past the top — \(climb.path))",
          climb.path.hasPrefix("/.."), climb.path)
    if let ended = bounded(10, { (SkillRoots.projectRoot(of: listed).path, SkillRoots.scanRoots(env: env, folder: listed).count) }) {
        check("the project root of a listing's folder URL is found, and the walk up ends",
              ended.0 == std(ws.appendingPathComponent("Alpha")) && ended.1 > 7, "\(ended.0) \(ended.1)")
    } else {
        check("the project root of a listing's folder URL is found", false, "the walk up never ended")
        finish()
    }

    // Each subfolder is read as a folder of its own; the page draws only
    // what sits at that subfolder's own level.
    skill(ws.appendingPathComponent(".claude/skills/top"), name: "top", description: "The workspace's own.")
    let alpha = ws.appendingPathComponent("Alpha", isDirectory: true)
    let alphaRows = rowsRead(alpha)
    check("a subfolder with no repository above it is its own project: Codex and Kimi both have its common skills",
          SkillListing.rows(of: SkillAgent.codex, in: alphaRows, at: alpha.path).map(\.name) == ["a1"]
          && SkillListing.rows(of: SkillAgent.kimi, in: alphaRows, at: alpha.path).map(\.name) == ["a1"]
          && SkillListing.rows(of: SkillAgent.claude, in: alphaRows, at: alpha.path).isEmpty)
    let hold = ws.appendingPathComponent("Hold", isDirectory: true)
    check("a subfolder's library skill no agent has is that subfolder's, for Not in use",
          SkillListing.unused(rowsRead(hold), listed: SkillAgent.all, at: hold.path).map(\.name) == ["h1"]
          && SkillListing.unused(rowsRead(hold), listed: SkillAgent.all, at: ws.path).isEmpty)
    let linkOnly = ws.appendingPathComponent("LinkOnly", isDirectory: true)
    check("a subfolder holding only a link to nothing draws it, as a broken link",
          SkillListing.rows(of: SkillAgent.claude, in: rowsRead(linkOnly), at: linkOnly.path).map { $0.problems.contains(.brokenLink) } == [true])

    // Inside one repository: a subfolder is read from the root's project,
    // and at its own level only where Claude and Codex look between the
    // root and where they start (measured on each tool's own listing:
    // Codex reads `.codex/skills` there as well as `.agents/skills`;
    // Kimi reads the root alone).
    let repo = root.appendingPathComponent("walk/Repo", isDirectory: true)
    try! fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    skill(repo.appendingPathComponent(".claude/skills/root-skill"), name: "root-skill", description: "The repository's.")
    skill(repo.appendingPathComponent("pkg/.claude/skills/pkg-claude"), name: "pkg-claude", description: "The package's, for Claude.")
    skill(repo.appendingPathComponent("pkg/.agents/skills/pkg-common"), name: "pkg-common", description: "The package's, common.")
    skill(repo.appendingPathComponent("pkg/.codex/skills/pkg-codex"), name: "pkg-codex", description: "The package's, for Codex.")
    skill(repo.appendingPathComponent("codexonly/.codex/skills/c"), name: "c", description: "A package with Codex's folder alone.")
    skill(repo.appendingPathComponent("onlykimi/.kimi-code/skills/k"), name: "k", description: "Where Kimi does not look.")
    skill(repo.appendingPathComponent("onlylib/.sipai/skills/l"), name: "l", description: "Where no library is.")
    // A repository of its own inside: its own project, read whole.
    try! fm.createDirectory(at: repo.appendingPathComponent("vendor/sub/.git"), withIntermediateDirectories: true)
    skill(repo.appendingPathComponent("vendor/sub/.kimi-code/skills/vk"), name: "vk", description: "The inner repository's, for Kimi.")
    let pkg = repo.appendingPathComponent("pkg", isDirectory: true)
    let inRepo = below(SkillRoots.subfolders(of: repo, home: home).found, repo)
    check("a repository's walk finds the packages a read draws: not one holding only a folder nobody reads there",
          inRepo == ["codexonly", "pkg", "vendor/sub"], "\(inRepo)")
    check("…the same from a folder inside the repository (its root is above the chosen folder)",
          below(SkillRoots.subfolders(of: repo.appendingPathComponent("vendor"), home: home).found,
                repo.appendingPathComponent("vendor")) == ["sub"]
          && below(SkillRoots.subfolders(of: pkg.deletingLastPathComponent(), home: home).found, repo) == inRepo)
    let pkgRows = rowsRead(pkg)
    check("…whose read holds the repository's skills too, and the page takes only the package's own",
          pkgRows.contains { $0.name == "root-skill" }
          && SkillListing.rows(of: SkillAgent.claude, in: pkgRows, at: pkg.path).map(\.name) == ["pkg-claude"])
    check("…Codex has the package's common skill and its own-folder skill there, Kimi (which reads the root alone) neither",
          SkillListing.rows(of: SkillAgent.codex, in: pkgRows, at: pkg.path).map(\.name).sorted() == ["pkg-codex", "pkg-common"]
          && SkillListing.rows(of: SkillAgent.kimi, in: pkgRows, at: pkg.path).isEmpty,
          "\(SkillListing.rows(of: SkillAgent.codex, in: pkgRows, at: pkg.path).map(\.name))")
    check("…a skill in a package's folders is listed, and not SipAI's to write",
          pkgRows.filter { ["pkg-claude", "pkg-common", "pkg-codex"].contains($0.name) }.allSatisfy { !$0.isManaged }
          && SkillRoots.scanRoots(env: env, folder: pkg).filter { $0.url.path.hasPrefix(std(pkg) + "/") }
                .allSatisfy { !$0.managed })
    let onlyKimi = repo.appendingPathComponent("onlykimi", isDirectory: true)
    let innerRepo = repo.appendingPathComponent("vendor/sub", isDirectory: true)
    check("…Kimi's folder in a package is read by nobody; in a repository of its own inside, by Kimi",
          SkillListing.rows(rowsRead(onlyKimi), at: SkillLevel(path: onlyKimi.path)).isEmpty
          && SkillListing.rows(of: SkillAgent.kimi, in: rowsRead(innerRepo), at: innerRepo.path).map(\.name) == ["vk"])

    check("an entry's level is the folder holding its skills folder, by its path's text",
          SkillRoots.level(of: "/w/p/.agents/skills/x") == "/w/p" && SkillRoots.level(of: "/w/.claude/skills/x") == "/w"
          && SkillRoots.level(of: "/.claude/skills/x") == "/")
    check("…and a path with no such folder above it is at no level: an agent's own report of a skill has no path",
          SkillRoots.level(of: "") == nil && SkillRoots.level(of: "skills/x") == nil && SkillRoots.level(of: "/a/b") == nil)
    // The folder three levels above where the process runs: a path-less
    // row read as a relative path used to land there.
    var above = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
    for _ in 0..<3 { above.deleteLastPathComponent() }
    var noPath = SkillFrontmatter()
    noPath.name = "plugin:skill"
    let reported = SkillRow(id: "ro:claude:Plugin:plugin:skill", name: "plugin:skill", description: "", scope: .global,
                            home: .readOnly("Plugin"), realPath: nil,
                            entries: [SkillAgent.claude: SkillEntry(agent: SkillAgent.claude, name: "plugin:skill", description: "",
                                                                    scope: .global, rootKind: .readOnly, entryPath: "",
                                                                    realPath: nil, isLink: false, frontmatter: noPath,
                                                                    sourceLabel: "Plugin")],
                            frontmatter: noPath)
    check("…so a plugin's skill is drawn under no subfolder, wherever the app was started from",
          SkillListing.rows(of: SkillAgent.claude, in: [reported], at: above.path).isEmpty
          && SkillListing.rows([reported], at: SkillLevel(path: above.path)).isEmpty)
    let level = SkillLevel(path: alpha.path + "/")
    check("a level is spelled as the page spells it and as a real path does, and holds its own skills alone",
          level.path == std(alpha) && level.realPath == SkillScan.realPath(alpha.path)
          && level.holds(std(alpha) + "/.agents/skills/a1") && level.holds(level.realPath + "/.sipai/skills/x")
          && !level.holds(std(ws) + "/.claude/skills/top") && !level.holds(std(alpha) + "/deeper/.claude/skills/x"))

    // The folders a page has browsed.
    let calendar = Calendar(identifier: .gregorian)
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func day(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }
    typealias Visit = SkillFolderHistory.Visit
    let everywhere: (String) -> Bool = { _ in true }
    var visits: [Visit] = []
    for i in 0..<12 {
        visits = SkillFolderHistory.recording("/f\(i)", at: day(Double(12 - i)), in: visits, calendar: calendar)
    }
    var asked = 0
    let listedTen = SkillFolderHistory.current(visits, now: now, calendar: calendar, exists: { _ in asked += 1; return true })
    check("the menu lists the newest first, ten at most — out of all twelve kept",
          listedTen.map(\.path) == (2..<12).reversed().map { "/f\($0)" } && visits.count == 12,
          "\(listedTen.map(\.path)) kept \(visits.count)")
    check("…asking whether a folder is on disk of no more folders than it lists", asked == SkillFolderHistory.limit, "\(asked)")
    visits = SkillFolderHistory.recording("/f5", at: now, in: visits, calendar: calendar)
    check("a folder browsed again moves to the front, once",
          visits.first?.path == "/f5" && visits.filter { $0.path == "/f5" }.count == 1 && visits.count == 12)
    let aged = [Visit(path: "/new", at: day(1)),
                Visit(path: "/edge", at: calendar.date(byAdding: .month, value: -1, to: now)!),
                Visit(path: "/old", at: calendar.date(byAdding: .month, value: -1, to: now)!.addingTimeInterval(-1))]
    check("a folder not browsed for a month is retired — from the menu and from what is kept",
          SkillFolderHistory.current(aged, now: now, calendar: calendar, exists: everywhere).map(\.path) == ["/new", "/edge"]
          && SkillFolderHistory.kept(aged, now: now, calendar: calendar).map(\.path) == ["/new", "/edge"])
    // A folder whose disk is away: left out of the menu, kept in the
    // history — through the next folder browsed — and back with its disk.
    let away: (String) -> Bool = { $0 != "/new" }
    let whileAway = SkillFolderHistory.recording("/other", at: now, in: aged, calendar: calendar)
    check("a folder not on disk is not listed",
          SkillFolderHistory.current(aged, now: now, calendar: calendar, exists: away).map(\.path) == ["/edge"])
    check("…and is not forgotten: browsing another folder meanwhile keeps it, and it is listed again once it is back",
          whileAway.map(\.path) == ["/other", "/new", "/edge"]
          && SkillFolderHistory.current(whileAway, now: now, calendar: calendar, exists: away).map(\.path) == ["/other", "/edge"]
          && SkillFolderHistory.current(whileAway, now: now, calendar: calendar, exists: everywhere).map(\.path) == ["/other", "/new", "/edge"],
          "\(whileAway.map(\.path))")
    var crowd: [Visit] = []
    for i in 0..<(SkillFolderHistory.storeLimit + 10) {
        crowd = SkillFolderHistory.recording("/c\(i)", at: now.addingTimeInterval(Double(i)), in: crowd, calendar: calendar)
    }
    check("what is kept is bounded: \(SkillFolderHistory.storeLimit) folders, the newest",
          crowd.count == SkillFolderHistory.storeLimit && crowd.first?.path == "/c\(SkillFolderHistory.storeLimit + 9)"
          && crowd.last?.path == "/c10")
    check("a visit stamped after now — the clock was set back — does not stay ahead of the folder browsed now",
          SkillFolderHistory.recording("/browsed-now", at: now, in: [Visit(path: "/future", at: now.addingTimeInterval(86_400))],
                                       calendar: calendar).map(\.path) == ["/browsed-now", "/future"])
    check("a folder kept twice counts once, by its newest visit",
          SkillFolderHistory.kept([Visit(path: "/p", at: day(20)), Visit(path: "/q", at: day(3)), Visit(path: "/p", at: day(1))],
                                  now: now, calendar: calendar) == [Visit(path: "/p", at: day(1)), Visit(path: "/q", at: day(3))])
    let store = root.appendingPathComponent("history-defaults").path
    let saved = await MainActor.run { () -> [Visit] in
        SkillFolderHistory.defaults = UserDefaults(suiteName: store)!
        SkillFolderHistory.save(aged)
        return SkillFolderHistory.load()
    }
    check("the history is kept, and read back as written", saved == aged)
}

// MARK: - 8. Source

section("8. Source")
let src = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
if !src.isEmpty {
    let all = (fm.enumerator(atPath: src + "/SipAI")?.allObjects as? [String] ?? [])
        .filter { $0.hasSuffix(".swift") }
    let joined = all.compactMap { try? String(contentsOfFile: src + "/SipAI/" + $0, encoding: .utf8) }
        .joined(separator: "\n")
    check("no NativeSkillInvocation left", !joined.contains("NativeSkillInvocation"))
    check("the readers share one claude rule", joined.components(separatedBy: "ClaudeSkillLoadReader()").count - 1 == 2)
    func source(_ path: String) -> String {
        (try? String(contentsOfFile: src + "/SipAI/" + path, encoding: .utf8)) ?? ""
    }
    let catalog = source("Models/SkillCatalog.swift")
    let sessionViewSource = source("Views/Chat/AgentSessionView.swift")
    check("the catalog's refresh waits for a fresh read (FreshReads)",
          catalog.contains("await reads.run(k)") && !catalog.contains("pendingReload"))
    check("claude's batch has a floor, and a claude known to be older is told why in the list itself — as is a kimi with no front end",
          catalog.contains("claudeBatchFloor = CLIVersion.parse(\"2.1.283\")")
          && catalog.contains("case SkillAgent.claude: return Self.claudeBatchRefusal()")
          && catalog.contains("case SkillAgent.kimi: return kimiCanLoad ? nil : Self.newerAgentNeeded"))
    check("a write distrusts every folder's earlier read", catalog.contains("readAt.removeAll()")
          && catalog.contains("lastWrite = Date()"))
    check("a mention addresses codex by a skill's own path wherever codex listed it — a subfolder's by that subfolder's own listing",
          catalog.components(separatedBy: "codexPath(for: entry)").count - 1 == 2
          && catalog.contains("let path = agent == SkillAgent.codex ? snap.codexPath(for: entry) : nil")
          && catalog.contains("codexPath: agent == SkillAgent.codex ? sub.codexPath(for: entry) : nil"))
    check("…and its switch by the skill's own path alone: never the path codex gave for the name",
          catalog.contains("let path = (real as NSString).appendingPathComponent(\"SKILL.md\")")
          && catalog.contains("CodexSkillList.write(binary: bin, path: path, enabled: state != .off"))
    check("a switch that could not be asked is not reported as made",
          catalog.components(separatedBy: "else { return Self.noAnswer(label) }").count - 1 == 2
          && catalog.contains("return words.map { $0.isEmpty ? Self.refused(label) : $0 }"))
    check("share, delete and remove act only on a row that is still what the folders hold",
          catalog.components(separatedBy: "guard SkillPlanner.isCurrent(row, env: env, folder: folder) else { throw SkillOpError.changedSinceChecked }").count - 1 == 3)
    check("a read is as fresh as its start, and not fresh when a write landed during it",
          catalog.contains("self.readAt[k] = began >= self.lastWrite ? began : nil")
          && catalog.components(separatedBy: "distrustReads()").count - 1 == 3)
    // What the real catalog does with these is run in
    // `Verification/SkillCatalog`; here, that nothing else reaches them.
    check("a folder's read never looks below it: the walk is asked for on its own, by what shows a subfolder's skills",
          // The one walk in the catalog sits in `findSubfolders`, which
          // comes before `refresh` and everything a read runs.
          joined.components(separatedBy: "SkillRoots.subfolders(of:").count - 1 == 1
          && (catalog.range(of: "func findSubfolders(of folder: URL) {").flatMap { start in
                catalog.range(of: "    func refresh(folder: URL?) async {", range: start.upperBound..<catalog.endIndex)
                    .map { catalog[start.lowerBound..<$0.lowerBound].contains("SkillRoots.subfolders(of: folder, home: home)") } } ?? false)
          && joined.components(separatedBy: "catalog.findSubfolders(of:").count - 1 == 1
          && source("Views/Settings/SkillsPane.swift").contains("catalog.findSubfolders(of: folder)")
          && joined.components(separatedBy: "loadSubfolders(below:").count - 1 == 3
          && !catalog.contains("await refresh(folder: folder)\n        await walkSubfolders"))
    check("…its subfolders are read one after another, never all at once, and only while the page asks",
          catalog.contains("while let self, !self.queued.isEmpty {") && catalog.contains("guard queueReader == nil")
          && joined.components(separatedBy: "catalog.ensureLoaded(folders:").count - 1 == 2
          && source("Views/Settings/SkillsPane.swift").contains("catalog.ensureLoaded(folders: [])"))
    check("a skill named on a card is looked up in the session's own folder",
          source("Views/Chat/ApprovalCards.swift").contains("SkillDirectory.lookup(name, SkillAgent.claude, folder)")
          && sessionViewSource.contains("ToolApprovalCard(request: req, folder: runner.cwd,"))
    check("claude's listing counts a refusal as an answer (ClaudeSkillListing)",
          catalog.contains("report.note(obj)") && catalog.contains("report.isComplete ? report : nil"))
    let scheduler = source("Models/ScheduledTaskScheduler.swift")
    check("a run's skills are read fresh — a subfolder's too, until each name is found — and ride the call that follows the read",
          scheduler.contains("await catalog.refresh(folder: cwd)")
          && scheduler.contains("await catalog.readSubfolders(")
          && scheduler.contains("skills: Self.resolveSkills(")
          && !scheduler.contains("skillsResolved"))
    check("a kimi task loads one skill, and a run is refused with words when its file lists two",
          scheduler.contains("if SkillAgent.oneSkillPerMessage(agent), def.skills.count > 1 {")
          && scheduler.contains("subfolder: choice.subfolder, claudeAddDir: choice.claudeAddDir,")
          && scheduler.contains("skillsFolder: choice.skillsFolder"))
    check("the editor fills its form from the text its save is checked against",
          source("Views/Settings/SkillSheets.swift").contains("let now = SkillFrontmatter.parse(text)"))
    check("a chosen skill can always be unticked, its skill gone or not",
          source("Views/Chat/SkillPicker.swift").contains("orphans(among: choices)"))
    let runnerSource = source("Models/AgentRunner.swift")
    check("the live row strips a mention line for codex alone, and names only what the message carries",
          runnerSource.contains("trimmed, mentionLine: agentKey == SkillAgent.codex)")
          && runnerSource.contains("SkillWire.codexLoads(options.skillTriggers).map(\\.name)")
          && runnerSource.contains("case SkillAgent.kimi: return options.skillTriggers.prefix(1).map(\\.name)")
          && runnerSource.contains("let wireText = skillNames.isEmpty ? text : codexWire(codexTriggers)")
          && runnerSource.contains("skills: SkillWire.codexTriggers(triggers,"))
    check("a subfolder's skill: claude's turn names the subfolder with --add-dir, codex's app-server is told its skills folder, a headless codex turn is sent none",
          runnerSource.contains("for dir in SkillTrigger.claudeAddDirs(options.skillTriggers) {")
          && runnerSource.contains("args.append(contentsOf: [\"--add-dir\", dir])")
          && runnerSource.contains("let subfolderSkills = options.chatOnly ? [] : options.skillTriggers.filter { $0.skillsFolder != nil }")
          && runnerSource.contains("extraSkillRoots: SkillTrigger.codexExtraRoots(subfolderSkills),")
          && runnerSource.contains("options.skillTriggers.filter { $0.skillsFolder == nil } : options.skillTriggers")
          && source("Models/CodexAppServerTurn.swift").contains("_ = try await peer.request(\"skills/extraRoots/set\",")
          && source("Models/CodexAppServerTurn.swift").contains("params: [\"extraRoots\": extraSkillRoots],")
          && source("Models/CodexAppServerTurn.swift").contains("timeout: extraRootsTimeout)"))
    // A load the message was drawn with that did not happen: the row stops
    // naming it (it is what the chip takes for "in the conversation"), and
    // it is said — whichever agent, however it was found out.
    let codexTurnSource = source("Models/CodexAppServerTurn.swift")
    let kimiTurnSource = source("Models/KimiAcpTurn.swift")
    check("a load that did not happen is taken back off its row, the row keeping its identity, and the folder read again — its subfolders searched afresh for the skill",
          runnerSource.contains("events[index] = event.replacingLoadedSkills(kept)")
          && runnerSource.contains("SkillCatalog.shared.noteLoadFailed(gone, agent: agentKey, folder: cwd)")
          && runnerSource.contains("self.id = event.id")
          && source("Models/SkillCatalog.swift").contains("func noteLoadFailed(_ names: [String], agent: String, folder: URL) {")
          && source("Models/SkillCatalog.swift").contains("searched = searched.filter { !$0.key.hasPrefix(prefix) }"))
    check("…claude: found out from its own stream — the name in no list it gave, and no command run for the message",
          runnerSource.contains("if let commands = ClaudeSkillLoadCheck.slashCommands(initLine: line) {")
          && runnerSource.contains("} else if let ran = ClaudeSkillLoadCheck.ranCommand(resultLine: line) {")
          && runnerSource.contains("if ClaudeSkillLoadCheck.failed(name: name, slashCommands: claudeSlashCommands,")
          && runnerSource.contains("retractSkillLoads([name])")
          && runnerSource.contains("SkillLoadWords.notFound(agentName: agentDisplayName, skill: name)")
          && runnerSource.contains("pendingSkillLoadNames = claudeSkillLines == nil ? [] : skillNames"))
    check("…kimi: a skill it does not list, and any command it answered itself",
          kimiTurnSource.components(separatedBy: "host.retractSkillLoads(nil)").count == 3
          && kimiTurnSource.contains("SkillLoadWords.notFound(agentName: agentName, skill: skill)"))
    check("…codex: folders it would not take — refused or unanswered — and the message then goes without their mentions",
          codexTurnSource.contains("case .timedOut:")
          && codexTurnSource.contains("host.retractSkillLoads(subfolderSkills)")
          && codexTurnSource.contains("text = textWithoutSubfolderSkills")
          && runnerSource.contains("textWithoutSubfolderSkills: textWithoutSubfolderSkills,"))
    check("…and a turn that turned out headless: codex's row stops naming a subfolder's skill, kimi's says why its skill did not load",
          runnerSource.contains("retractSkillLoads(options.skillTriggers.filter { $0.skillsFolder != nil }.map(\\.name))")
          && runnerSource.contains("if isKimi, driver != .kimiAcp, !options.chatOnly, !options.skillTriggers.isEmpty {"))
    check("a kimi command the user typed is read off the wire text, by kimi's own rule, a skill's bare name included",
          runnerSource.contains("let typed = KimiAcp.typedSkill(trimmed, isSkill: { [cwd] name in")
          && runnerSource.contains("SkillDirectory.lookup(name, SkillAgent.kimi, cwd) != nil"))
    check("a kimi turn that loads a skill goes through kimi's front end in any mode, the skill ahead of the message",
          source("Models/AgentLaunchOptions.swift").contains("if frontEndOffered, !options.skillTriggers.isEmpty { return .kimiAcp }")
          && runnerSource.contains("options.permissionMode == nil || fixedCodexMode\n            || (agentKey == \"kimi\" && !options.skillTriggers.isEmpty)")
          && source("Models/KimiAcpTurn.swift").contains("sessionId: sid, text: KimiAcp.promptText(text, skill: skill)))")
          && source("Models/KimiAcpTurn.swift").contains("KimiAcp.answeredUnknownCommand(streamedText)"))
    check("the chip is on every agent; kimi's holds one skill; its picks, a subfolder's included, are read before a send",
          sessionViewSource.contains("SkillAgent.all.contains(sessionAgentKey)")
          && sessionViewSource.contains("onePerMessage: SkillAgent.oneSkillPerMessage(sessionAgentKey))")
          && sessionViewSource.contains("SkillCatalog.shared.ensurePicksReadable(skillPicks, agent: sessionAgentKey,")
          && source("Views/Chat/AgentComposer.swift").contains("skillCatalog.loadSubfolders(below: folder)")
          && source("Views/Chat/AgentComposer.swift").contains("oneAtATime: SkillAgent.oneSkillPerMessage(agentKey),")
          && source("Views/Chat/SkillPicker.swift").contains("} else if oneAtATime {\n            ticked = [choice.name]"))
    let sessionView = source("Views/Chat/AgentSessionView.swift")
    // The robot is orange when a skill is chosen, and nothing more: no
    // fill of its own behind the glyph.
    let composerSource = source("Views/Chat/AgentComposer.swift")
    let chipLabel = composerSource.range(of: "Image(\"SkillRobot\")").flatMap { start in
        composerSource.range(of: ".contentShape(Rectangle())", range: start.upperBound..<composerSource.endIndex)
            .map { String(composerSource[start.upperBound..<$0.lowerBound]) }
    }
    check("the skill chip is the orange glyph alone — no fill behind it",
          chipLabel.map { $0.contains(".foregroundColor(active ? .orange : SipDesign.textSecondary)")
                          && !$0.contains(".background(") && !$0.contains(".fill(") } == true)
    check("the summary a mark stands for carries the agent's own word on what it kept",
          sessionView.contains("return .compaction(keepsUserLoads: item.compactionKeepsUserMessages)")
          && sessionView.contains("return .compaction(keepsUserLoads: event.compactionKeepsUserMessages)")
          && source("Models/KimiSessions.swift").contains("row.compactionKeepsUserMessages = KimiSessionScanner.compactionKeepsUserMessages(obj)"))
    check("the branch editor opens a kimi message on what was SENT: a typed skill command, unless the chip holds that skill",
          sessionView.contains("beginMessageEdit(rowId: rowId, text: text, loadedSkills: loadedSkills)")
          && sessionView.contains("editDraft = KimiAcp.promptText(text, skill: skill)")
          && sessionView.contains("? { onBeginEdit(rowId, text, loadedSkills) } : nil,"))
    check("a pick is read IN HAND before it is looked for: a read under way is not a snapshot",
          catalog.contains("if reads.isRunning(k), isFresh(k, maxAge: maxAge) { await reads.join(k) }")
          && catalog.contains("await awaitLoaded(folder: folder)\n            let own = ownNames(agent: agent, folder: folder)"))
    check("the chip's subfolder reads are a queue of their own, not the Skills page's",
          catalog.range(of: "func loadSubfolders(below folder: URL").map { r in
              let body = catalog[r.upperBound...].prefix(900)
              return body.contains("await self.awaitLoaded(folder:") && !body.contains("ensureLoaded(folders:")
          } ?? false)
    check("a name goes to the nearest subfolder holding it, whichever read landed first",
          catalog.contains("guard let held = levelNames[Self.levelKey(level, agent)] else { break }")
          && catalog.contains("seen.formUnion(held)"))
    check("a scheduled run waits for the installed tool's version before its skills are resolved, and looks a subfolder's skill up afresh",
          scheduler.contains("AskingModeGate.frontEnd(agentKey: taskAgent) == .pending {")
          && scheduler.contains(".subtracting(catalog.ownNames(agent: taskAgent, folder: cwd)),"))
    check("a share that could not carry only-when-called says so once it is done",
          source("Views/Settings/SkillsPane.swift").contains("let lost = review.check.lostOnlyWhenCalled")
          && source("Views/Settings/SkillsPane.swift").contains("await catalog.share(row: row, with: agent, check: review.check, folder: folder) ?? lost"))
    check("an agent that takes one skill opens its picker on one, and its pin is judged on the list as read",
          source("Views/Chat/SkillPicker.swift").components(separatedBy: "oneAtATime ? Array(picks.prefix(1)) : picks").count == 3
          && source("Models/ConfigManager.swift").contains("if SkillAgent.oneSkillPerMessage(agentKey) { list = Array(list.prefix(1)) }"))
    check("live rows count as loads only once answered",
          sessionView.contains("SkillEvidenceReader.delivered(events.compactMap(Self.skillMark),")
          && sessionView.contains("case .assistantText, .thinking, .toolResult, .result:"))
    check("an untick two agents' shared folder cannot honour is refused with words",
          source("Views/Settings/SkillsPane.swift").contains("guard plan.blockedBy.isEmpty else {")
          && catalog.contains("plan.blockedBy.isEmpty"))
    check("a run's record is written before its skills are read",
          scheduler.range(of: "inFlight[def.name] = hold").map { r in
              scheduler[r.upperBound...].prefix(700).contains("state.lastOutcome = \"running\"") } ?? false)
    check("a message opening on a pasted path still loads the chosen skills",
          source("Views/Chat/AgentSessionView.swift").contains("AgentSlashCommands.leadingCommand(in: text) != nil"))
}

finish()
