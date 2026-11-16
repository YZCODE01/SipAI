// SkillCatalog harness: the REAL SkillCatalog.swift, driven the way
// Settings → Agent Skills drives it — a folder's read, the walk below it, its
// subfolders read one after another, a write in the middle — over a
// throwaway tree and a throwaway home (run.sh). No agent tool is started:
// a read is the scan of the folders, then a stand-in for codex's listing
// that records the folder asked about and holds the read in flight
// (`Stubs.swift`).

import Foundation

var passed = 0
var failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("  PASS \(name)") }
    else { failed += 1; let d = detail(); print("  FAIL \(name)" + (d.isEmpty ? "" : " — \(d)")) }
}
func section(_ title: String) { print("\n" + title) }

let fm = FileManager.default
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sipai-skillcatalog-\(UUID().uuidString)", isDirectory: true)
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)

func finish() -> Never {
    print("\n\(passed)/\(passed + failed) checks passed")
    try? fm.removeItem(at: scratch)
    exit(failed == 0 ? 0 : 1)
}

func dir(_ path: String) -> URL { URL(fileURLWithPath: scratch.appendingPathComponent(path).path, isDirectory: true) }
func skill(_ path: String, description: String = "A skill.", extra: String = "") {
    let folder = scratch.appendingPathComponent(path)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = (path as NSString).lastPathComponent
    try! Data("---\nname: \(name)\ndescription: \(description)\n\(extra)---\n\nBody.\n".utf8)
        .write(to: folder.appendingPathComponent("SKILL.md"))
}
func pause(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

// The agents' homes, inside the scratch tree; the user's home is the
// scratch one run.sh named.
for agent in [".claude", ".codex", ".kimi-code"] {
    try! fm.createDirectory(at: scratch.appendingPathComponent("agents/\(agent)"), withIntermediateDirectories: true)
}
let homes = ["CLAUDE_CONFIG_DIR": scratch.appendingPathComponent("agents/.claude").path,
             "CODEX_HOME": scratch.appendingPathComponent("agents/.codex").path,
             "KIMI_CODE_HOME": scratch.appendingPathComponent("agents/.kimi-code").path]

@MainActor func names(_ catalog: SkillCatalog, _ folder: URL, _ agent: String = SkillAgent.claude) -> [String] {
    SkillListing.rows(of: agent, in: catalog.snapshot(folder: folder)?.rows ?? [], at: folder.path).map(\.name).sorted()
}

/// Wait until nothing is being read and nothing waits, twice running.
@MainActor func settle(_ catalog: SkillCatalog) async {
    var quiet = 0
    for _ in 0..<1_500 {
        quiet = catalog.loading.isEmpty && catalog.waiting.isEmpty && catalog.loadingSubfolders == nil ? quiet + 1 : 0
        if quiet >= 3 { return }
        await pause(20)
    }
}

@MainActor func run() async {
    let expectedHome = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
    guard !expectedHome.isEmpty,
          SkillScan.realPath(fm.homeDirectoryForCurrentUser.path) == SkillScan.realPath(expectedHome) else {
        // Never over the user's own home: the catalog reads its global
        // skills folders there.
        check("the home folder is the scratch one (run this through run.sh)", false,
              fm.homeDirectoryForCurrentUser.path)
        finish()
    }
    CLIScrapeEnvironment.provider = { homes }
    CatalogHarness.binaries = [SkillAgent.codex: "/usr/bin/true"]
    let catalog = SkillCatalog.shared

    // ------------------------------------------------------------ 1
    section("1. A folder's read never looks below it; the walk is asked for on its own")
    skill("W/A/.claude/skills/x")
    skill("W/B/.claude/skills/x2")
    skill("W/A/inner/.claude/skills/z")
    let W = dir("W"), A = dir("W/A"), B = dir("W/B"), inner = dir("W/A/inner")
    CatalogHarness.hold = 50_000_000
    await catalog.refresh(folder: W)
    await pause(400)
    check("a read of a folder finds its skills and leaves what is below it unlooked for",
          catalog.snapshot(folder: W) != nil && catalog.subfolders(of: W) == nil,
          "\(String(describing: catalog.subfolders(of: W)))")
    catalog.findSubfolders(of: W)
    for _ in 0..<150 where catalog.subfolders(of: W) == nil { await pause(20) }
    let found = catalog.subfolders(of: W)?.found.map(\.path) ?? []
    let subs = found.map { URL(fileURLWithPath: $0, isDirectory: true) }
    check("asked for, the walk finds the subfolders with skills, nearest first",
          found == [A, B, inner].map { SkillRoots.pathURL($0).path } && catalog.subfolders(of: W)?.stoppedEarly == false,
          "\(found)")
    catalog.ensureLoaded(folders: subs, maxAge: 5)
    await settle(catalog)
    check("each subfolder is read as a folder of its own",
          names(catalog, A) == ["x"] && names(catalog, B) == ["x2"] && names(catalog, inner) == ["z"],
          "\(names(catalog, A)) \(names(catalog, B)) \(names(catalog, inner))")
    check("…and its read does not walk below it either",
          catalog.subfolders(of: A) == nil && catalog.subfolders(of: B) == nil)
    // A walk that finds what was known writes nothing: every write
    // redraws the page.
    var published = 0
    let watch = catalog.$subfolders.dropFirst().sink { _ in published += 1 }
    catalog.findSubfolders(of: W)
    await pause(500)
    check("a walk that finds nothing new publishes nothing", published == 0, "\(published)")
    // Two asks in a row around a change: the second is answered by a
    // walk that began after it.
    catalog.findSubfolders(of: W)
    skill("W/C/.claude/skills/n")
    catalog.findSubfolders(of: W)
    let C = dir("W/C")
    for _ in 0..<150 where !(catalog.subfolders(of: W)?.found.map(\.path) ?? []).contains(SkillRoots.pathURL(C).path) { await pause(20) }
    check("an ask made after a change is answered by a walk that began after it",
          (catalog.subfolders(of: W)?.found.map(\.path) ?? []).contains(SkillRoots.pathURL(C).path) && published >= 1,
          "\(catalog.subfolders(of: W)?.found.map(\.path) ?? [])")
    watch.cancel()

    // ------------------------------------------------------------ 2
    section("2. Subfolders are read one after another, in the order asked")
    for i in 0..<4 { skill("Q/p\(i)/.claude/skills/s\(i)") }
    let q = (0..<4).map { dir("Q/p\($0)") }
    CatalogHarness.hold = 150_000_000
    CatalogHarness.forget()
    catalog.ensureLoaded(folders: q, maxAge: 5)
    var most = 0
    var sawWaiting = false
    for _ in 0..<400 {
        most = max(most, catalog.loading.count)
        if !catalog.waiting.isEmpty { sawWaiting = true }
        if catalog.loading.isEmpty && catalog.waiting.isEmpty && q.allSatisfy({ catalog.snapshot(folder: $0) != nil }) { break }
        await pause(10)
    }
    check("never two at once, and in order", most == 1 && CatalogHarness.asked == q.map(\.path),
          "most at once \(most); asked \(CatalogHarness.asked.map { ($0 as NSString).lastPathComponent })")
    check("…the ones not yet begun are told to the page as waiting", sawWaiting)

    // ------------------------------------------------------------ 3
    section("3. The list is what the page shows NOW")
    for i in 0..<6 { skill("W1/p\(i)/.claude/skills/s\(i)") }
    skill("W2/only/.claude/skills/t")
    let w1 = (0..<6).map { dir("W1/p\($0)") }
    let w2 = [dir("W2/only")]
    CatalogHarness.hold = 250_000_000
    CatalogHarness.forget()
    catalog.ensureLoaded(folders: w1, maxAge: 5)                    // the page shows W1
    await pause(80)
    catalog.ensureLoaded(folders: w2, maxAge: 5)                    // the folder menu: W2
    check("another folder chosen: only its subfolders wait",
          catalog.waiting == Set(w2.map { SkillCatalog.key($0) }), "\(catalog.waiting)")
    await settle(catalog)
    check("…they are read next — after the one read under way — and the first folder's others are let go",
          CatalogHarness.asked == [w1[0].path, w2[0].path]
          && w1.dropFirst().allSatisfy { catalog.snapshot(folder: $0) == nil },
          "\(CatalogHarness.asked.map { ($0 as NSString).lastPathComponent })")
    for i in 0..<3 { skill("W3/p\(i)/.claude/skills/s\(i)") }
    let w3 = (0..<3).map { dir("W3/p\($0)") }
    CatalogHarness.forget()
    catalog.ensureLoaded(folders: w3, maxAge: 5)
    await pause(80)
    catalog.ensureLoaded(folders: [])                               // the page went away
    await settle(catalog)
    check("an empty list — the page has gone — lets go of everything waiting",
          CatalogHarness.asked == [w3[0].path], "\(CatalogHarness.asked.map { ($0 as NSString).lastPathComponent })")
    // Asked again with the same list while the first is being read:
    // nothing is read twice, nothing is dropped.
    for i in 0..<3 { skill("W4/p\(i)/.claude/skills/s\(i)") }
    let w4 = (0..<3).map { dir("W4/p\($0)") }
    CatalogHarness.forget()
    catalog.ensureLoaded(folders: w4, maxAge: 5)
    await pause(80)
    catalog.ensureLoaded(folders: w4, maxAge: 5)
    await pause(200)
    catalog.ensureLoaded(folders: w4, maxAge: 5)
    await settle(catalog)
    check("the same list asked again while it is being read: each folder read once, in order",
          CatalogHarness.asked == w4.map(\.path), "\(CatalogHarness.asked.map { ($0 as NSString).lastPathComponent })")
    // A read asked for with no age allowed (the Refresh button) is not
    // weakened by the ordinary ask that follows it.
    CatalogHarness.forget()
    catalog.ensureLoaded(folders: w4, maxAge: 0)
    await pause(80)
    catalog.ensureLoaded(folders: w4, maxAge: 5)
    await settle(catalog)
    check("a forced read is still owed after an ordinary ask for the same folders",
          CatalogHarness.asked == w4.map(\.path), "\(CatalogHarness.asked.map { ($0 as NSString).lastPathComponent })")

    // ------------------------------------------------------------ 4
    section("4. A write that lands while a subfolder is being read")
    CatalogHarness.hold = 400_000_000
    CatalogHarness.forget()
    await pause(50)
    catalog.ensureLoaded(folders: [A, B], maxAge: 0)                // the page: its subfolders
    for _ in 0..<100 where CatalogHarness.reads(of: A) == 0 { await pause(10) }
    // A's files have been scanned; its listing is out. Now the write.
    skill("W/A/.claude/skills/y")
    let before = catalog.revision
    let write = Task { @MainActor in await catalog.perform(folder: W) { _, _ in } }
    for _ in 0..<200 where catalog.revision == before { await pause(5) }
    check("(the write landed while A was being read)", catalog.loading.contains(SkillCatalog.key(A)))
    catalog.ensureLoaded(folders: [A, B], maxAge: 5)                // the page: onChange(of: revision)
    _ = await write.value
    await settle(catalog)
    check("the subfolder that was being read is read again: its rows are the folder's as the write left it",
          names(catalog, A) == ["x", "y"] && CatalogHarness.reads(of: A) == 2,
          "\(names(catalog, A)), read \(CatalogHarness.reads(of: A)) time(s)")
    check("…and the one that had not begun is read once", CatalogHarness.reads(of: B) == 1, "\(CatalogHarness.reads(of: B))")
    // The same for a folder read on its own (the composer's chip, a page
    // of its own): asked for again after the write, a read that began
    // before it does not count as "being read".
    skill("Solo/.claude/skills/one")
    let solo = dir("Solo")
    CatalogHarness.forget()
    let first = Task { @MainActor in await catalog.refresh(folder: solo) }
    for _ in 0..<100 where CatalogHarness.reads(of: solo) == 0 { await pause(10) }
    skill("Solo/.claude/skills/two")
    _ = await catalog.perform(folder: W) { _, _ in }
    catalog.ensureLoaded(folder: solo, maxAge: 60)
    _ = await first.value
    await settle(catalog)
    check("a single folder's read overtaken by a write is made again when the folder is next asked for",
          names(catalog, solo) == ["one", "two"] && CatalogHarness.reads(of: solo) == 2,
          "\(names(catalog, solo)), read \(CatalogHarness.reads(of: solo)) time(s)")
    CatalogHarness.forget()
    catalog.ensureLoaded(folder: solo, maxAge: 60)
    await pause(300)
    check("…and a fresh read in hand is not made again", CatalogHarness.reads(of: solo) == 0)
    // Asked twice in one breath — a page's appearance and the folder
    // change its own default pick makes — is one read, not two.
    skill("Twice/.claude/skills/t")
    let twice = dir("Twice")
    CatalogHarness.forget()
    catalog.ensureLoaded(folder: twice, maxAge: 5)
    catalog.ensureLoaded(folder: twice, maxAge: 5)
    await settle(catalog)
    await pause(200)
    await settle(catalog)
    check("a folder asked for twice before its read has begun is read once",
          CatalogHarness.reads(of: twice) == 1, "\(CatalogHarness.reads(of: twice))")

    // ------------------------------------------------------------ 5
    section("5. A folder read directly while it waited is not read twice")
    for i in 0..<2 { skill("D/p\(i)/.claude/skills/s\(i)") }
    let d = (0..<2).map { dir("D/p\($0)") }
    CatalogHarness.hold = 250_000_000
    CatalogHarness.forget()
    catalog.ensureLoaded(folders: d, maxAge: 5)
    await pause(60)
    await catalog.refresh(folder: d[1])                             // a write made for it, a page of its own
    await settle(catalog)
    check("read once", CatalogHarness.reads(of: d[1]) == 1 && CatalogHarness.reads(of: d[0]) == 1,
          "\(CatalogHarness.asked.map { ($0 as NSString).lastPathComponent })")

    // ------------------------------------------------------------ 6
    section("6. A skill named on a card is looked up in the session's own folder")
    skill("Shop/alpha/.claude/skills/deploy", description: "Alpha's: push the docs site.", extra: "allowed-tools: Read\n")
    skill("Shop/gamma/.claude/skills/deploy", description: "Gamma's: roll the cluster.", extra: "allowed-tools: Bash(kubectl *)\n")
    skill("Shop/beta/.claude/skills/build", description: "Beta's.")
    skill("agents/.claude/skills/lint", description: "The global one.")
    let alpha = dir("Shop/alpha"), gamma = dir("Shop/gamma"), beta = dir("Shop/beta"), unread = dir("Shop/unread")
    try! fm.createDirectory(at: unread, withIntermediateDirectories: true)
    CatalogHarness.hold = 10_000_000
    for folder in [gamma, beta, alpha] { await catalog.refresh(folder: folder) }
    await catalog.refresh(folder: nil)
    let claude = SkillAgent.claude
    check("each project's own skill of that name answers for a session in that project",
          catalog.row(named: "deploy", agent: claude, folder: alpha)?.description == "Alpha's: push the docs site."
          && catalog.row(named: "deploy", agent: claude, folder: gamma)?.frontmatter.allowedTools == "Bash(kubectl *)"
          && catalog.row(named: "DEPLOY", agent: claude, folder: alpha)?.frontmatter.allowedTools == "Read")
    check("…a project that has no skill of that name is shown none — never another project's",
          catalog.row(named: "deploy", agent: claude, folder: beta) == nil)
    check("…a folder nobody has read is shown none either, whatever other folders' reads hold",
          catalog.row(named: "deploy", agent: claude, folder: unread) == nil
          && catalog.row(named: "deploy", agent: claude, folder: nil) == nil)
    check("…while a global skill answers in every folder, read or not",
          catalog.row(named: "lint", agent: claude, folder: alpha)?.description == "The global one."
          && catalog.row(named: "lint", agent: claude, folder: unread)?.scope == .global
          && catalog.row(named: "lint", agent: claude, folder: nil)?.description == "The global one.")
    check("the card's lookup is the catalog's",
          SkillDirectory.lookup("deploy", claude, gamma)?.description == "Gamma's: roll the cluster."
          && SkillDirectory.lookup("deploy", claude, unread) == nil)

    // ------------------------------------------------------------ 7
    section("7. A session's chip offers its folder's subfolders' skills, as the send can reach them")
    skill("S/.claude/skills/own")
    skill("S/.agents/skills/ownk")
    skill("S/sub/.claude/skills/subc")
    skill("S/sub/.agents/skills/suba")
    skill("S/sub2/.claude/skills/own", description: "The subfolder's namesake.")
    skill("S/sub2/.agents/skills/ownk", description: "A namesake Codex and Kimi read.")
    let S = dir("S"), sub = dir("S/sub")
    CatalogHarness.hold = 10_000_000
    await catalog.refresh(folder: S)
    check("before the subfolders are read, the chip offers the folder's own alone",
          catalog.choices(agent: claude, folder: S).allSatisfy { $0.subfolder == nil })
    catalog.loadSubfolders(below: S, maxAge: 5)
    for _ in 0..<150 where catalog.subfolders(of: S) == nil { await pause(20) }
    await settle(catalog)
    let cl = catalog.choices(agent: claude, folder: S)
    let subc = cl.first { $0.name == "subc" }
    check("claude: a subfolder's skill is offered, loadable, with its subfolder and the name of it",
          subc?.subfolder == SkillRoots.pathURL(sub).path && subc?.subfolderName == "sub" && subc?.unavailable == nil
          && subc?.skillsFolder == SkillRoots.pathURL(sub).path + "/.claude/skills",
          "\(String(describing: subc))")
    check("…a name the session already has is that skill: the subfolder's namesake is not offered",
          cl.filter { $0.name == "own" }.count == 1 && cl.first { $0.name == "own" }?.subfolder == nil
          && !cl.contains { $0.name.contains(":") })
    // Claude 2.1.309 offers that namesake as <subfolder>:<name>, the
    // subfolder spelled the way `--add-dir` was handed it — so it is
    // handed the path below the session's folder (measured).
    CatalogHarness.claudeVersion = CLIVersion.parse(ClaudeSkillNames.namesakeFloor)
    let withNamesakes = catalog.choices(agent: claude, folder: S)
    CatalogHarness.claudeVersion = CLIVersion.parse("2.1.308")
    let beforeNamesakes = catalog.choices(agent: claude, folder: S)
    CatalogHarness.claudeVersion = nil
    let prefixed = withNamesakes.first { $0.name == "sub2:own" }
    check("claude 2.1.309 and newer: the namesake is offered as <subfolder>:<name>, its subfolder handed relative",
          prefixed?.subfolder == SkillRoots.pathURL(dir("S/sub2")).path && prefixed?.claudeAddDir == "sub2"
          && prefixed?.unavailable == nil && prefixed?.subfolderName == "sub2"
          && withNamesakes.filter { $0.name == "own" }.count == 1
          && withNamesakes.first { $0.name == "own" }?.subfolder == nil,
          String(describing: prefixed))
    check("…every subfolder's skill is handed relative, the namesake's or not",
          withNamesakes.first { $0.name == "subc" }?.claudeAddDir == "sub")
    check("…an older claude offers no namesake: it cannot reach one",
          !beforeNamesakes.contains { $0.name.contains(":") })
    check("codex keeps the one-name rule: its subfolder's namesake is not offered",
          !catalog.choices(agent: SkillAgent.codex, folder: S, codexSend: .appServer).contains { $0.name.contains(":") }
          && catalog.choices(agent: SkillAgent.codex, folder: S, codexSend: .appServer).filter { $0.name == "ownk" }.count == 1)
    let viaExec = catalog.choices(agent: SkillAgent.codex, folder: S, codexSend: .exec).first { $0.name == "suba" }
    let viaServer = catalog.choices(agent: SkillAgent.codex, folder: S, codexSend: .appServer).first { $0.name == "suba" }
    check("codex: offered dimmed for a headless turn, loadable through its app-server with the skills folder to add",
          viaExec?.unavailable != nil && viaServer?.unavailable == nil
          && viaServer?.skillsFolder == SkillRoots.pathURL(sub).path + "/.agents/skills"
          && (viaServer?.codexPath ?? "").hasSuffix("/S/sub/.agents/skills/suba/SKILL.md"),
          "\(String(describing: viaExec?.unavailable)) / \(String(describing: viaServer))")
    // Offered only on a tool at least as new as the one it was measured
    // on; the folder's own skills are not held to that.
    let viaOld = catalog.choices(agent: SkillAgent.codex, folder: S, codexSend: .needsNewer)
    check("…and on a codex older than the call was measured on, dimmed as needing a newer one — its own skills untouched",
          viaOld.first { $0.name == "suba" }?.unavailable == SkillCatalog.newerAgentNeeded
          && viaOld.first { $0.name == "ownk" }?.unavailable == nil
          && viaExec?.unavailable != SkillCatalog.newerAgentNeeded)
    CatalogHarness.claudeVersion = CLIVersion.parse("2.1.285")
    let oldClaude = catalog.choices(agent: claude, folder: S)
    CatalogHarness.claudeVersion = CLIVersion.parse(SkillSubfolderReach.claudeFloor)
    let measuredClaude = catalog.choices(agent: claude, folder: S)
    CatalogHarness.claudeVersion = nil
    check("claude: older than --add-dir was measured to list skills on, a subfolder's is dimmed; its own load as before",
          oldClaude.first { $0.name == "subc" }?.unavailable == SkillCatalog.newerAgentNeeded
          && oldClaude.first { $0.name == "own" }?.unavailable == nil
          && measuredClaude.first { $0.name == "subc" }?.unavailable == nil)
    check("while a chip's subfolders are being read the catalog says so, and no longer once they are",
          !catalog.readingSubfolders(below: S))
    let kimiSub = catalog.choices(agent: SkillAgent.kimi, folder: S).first { $0.name == "suba" }
    check("kimi: offered dimmed — it loads a subfolder's skill only in a session started there",
          kimiSub?.unavailable != nil && kimiSub?.subfolder == SkillRoots.pathURL(sub).path)
    check("kimi with no front end of its own: even the folder's own skill is dimmed with the reason",
          catalog.choices(agent: SkillAgent.kimi, folder: S, kimiCanLoad: false).first { $0.name == "ownk" }?.unavailable
            == SkillCatalog.newerAgentNeeded
          && catalog.choices(agent: SkillAgent.kimi, folder: S).first { $0.name == "ownk" }?.unavailable == nil)
    // Kimi starts a skill from `/skill:<name> …` and reads the name up to
    // the first space: one it cannot spell that way it cannot be asked for.
    let spaced = scratch.appendingPathComponent("K/.kimi-code/skills/two-words")
    try! fm.createDirectory(at: spaced, withIntermediateDirectories: true)
    try! Data("---\nname: two words\ndescription: A skill.\n---\n\nBody.\n".utf8).write(to: spaced.appendingPathComponent("SKILL.md"))
    skill("K/.kimi-code/skills/plain")
    let K = dir("K")
    await catalog.refresh(folder: K)
    let kimiChoices = catalog.choices(agent: SkillAgent.kimi, folder: K)
    check("kimi: a skill whose name its command cannot carry is dimmed, one it can is not",
          kimiChoices.first { $0.name == "two words" }?.unavailable != nil
          && kimiChoices.first { $0.name == "plain" }?.unavailable == nil,
          "\(kimiChoices.map { ($0.name, $0.unavailable ?? "-") })")

    // ------------------------------------------------------------ 8
    section("8. A run, or a session's picks, reads only the subfolders it needs")
    for i in 0..<4 { skill("R/p\(i)/.claude/skills/r\(i)") }
    let R = dir("R")
    await catalog.refresh(folder: R)
    CatalogHarness.forget()
    await catalog.readSubfolders(below: R, wanting: ["r2"], agent: claude)
    check("by the files first: the one subfolder that holds the skill is read, and no other",
          CatalogHarness.asked == [dir("R/p2").path]
          && catalog.choices(agent: claude, folder: R).first { $0.name == "r2" }?.subfolder == SkillRoots.pathURL(dir("R/p2")).path,
          "\(CatalogHarness.asked.map { ($0 as NSString).lastPathComponent })")
    CatalogHarness.forget()
    await catalog.readSubfolders(below: R, wanting: [], agent: claude)
    check("…and nothing at all when every name is the folder's own", CatalogHarness.asked.isEmpty)
    // A name no subfolder holds — a pinned skill of another folder, a
    // deleted one, a typo in a task's `skills:` — starts nothing: read one
    // after another until it turned up, every subfolder was read for it.
    CatalogHarness.forget()
    await catalog.readSubfolders(below: R, wanting: ["no-such-skill"], agent: claude)
    check("a name no subfolder holds has none of them read for it",
          CatalogHarness.asked.isEmpty, "\(CatalogHarness.asked.map { ($0 as NSString).lastPathComponent })")
    // A Claude namesake is asked for as <subfolder>:<name> (a task's
    // `skills:`, a session's picks): its subfolder alone is read for it.
    skill("NS/.claude/skills/twin")
    skill("NS/n0/.claude/skills/other")
    skill("NS/n1/.claude/skills/twin", description: "The namesake.")
    let NS = dir("NS")
    await catalog.refresh(folder: NS)
    CatalogHarness.forget()
    await catalog.readSubfolders(below: NS, wanting: ["n1:twin"], agent: claude)
    CatalogHarness.claudeVersion = CLIVersion.parse(ClaudeSkillNames.namesakeFloor)
    let nChoices = catalog.choices(agent: claude, folder: NS)
    CatalogHarness.claudeVersion = nil
    check("a Claude namesake asked for as <subfolder>:<name>: that subfolder alone is read, and offered under the name",
          CatalogHarness.asked == [dir("NS/n1").path]
          && nChoices.first { $0.name == "n1:twin" }?.subfolder == SkillRoots.pathURL(dir("NS/n1")).path,
          "\(CatalogHarness.asked.map { ($0 as NSString).lastPathComponent }); \(nChoices.map(\.name))")

    // ------------------------------------------------------------ 9
    section("9. A read under way is not a snapshot in hand")
    skill("U/.claude/skills/mine")
    skill("U/s0/.claude/skills/other0")
    skill("U/s1/.claude/skills/other1")
    let U = dir("U")
    CatalogHarness.hold = 300_000_000
    CatalogHarness.forget()
    Task { await catalog.refresh(folder: U) }
    await pause(40)                                                 // the read is in flight, nothing landed
    let landedBefore = catalog.snapshot(folder: U) != nil
    await catalog.awaitLoaded(folder: U)
    check("asked while the folder's first read is in flight, the caller gets the snapshot — and no second read",
          !landedBefore && catalog.snapshot(folder: U) != nil && CatalogHarness.reads(of: U) == 1,
          "landed before \(landedBefore), reads \(CatalogHarness.reads(of: U))")
    // The session's picks, asked for while its folder is still being
    // read: every pick read as "missing" for that moment, and every
    // subfolder was read for the folder's OWN skill.
    skill("V/.claude/skills/mine")
    skill("V/s0/.claude/skills/other0")
    skill("V/s1/.claude/skills/other1")
    let V = dir("V")
    CatalogHarness.forget()
    Task { await catalog.refresh(folder: V) }
    await pause(40)
    catalog.ensurePicksReadable(["mine"], agent: claude, folder: V)
    await pause(200)
    await settle(catalog)
    await pause(200)
    await settle(catalog)
    check("a session's own pick, asked for mid-read, has no subfolder read for it",
          !CatalogHarness.asked.contains(dir("V/s0").path) && !CatalogHarness.asked.contains(dir("V/s1").path)
          && CatalogHarness.reads(of: V) == 1,
          "\(CatalogHarness.asked.map { ($0 as NSString).lastPathComponent })")
    // A subfolder's skill in hand from some earlier read is not the
    // folder's own: it is looked for again, so one deleted since is found out.
    await catalog.readSubfolders(below: V, wanting: ["other1"], agent: claude)
    check("a subfolder's skill already in hand is not counted among the folder's own",
          catalog.choices(agent: claude, folder: V).contains { $0.name == "other1" && $0.subfolder != nil }
          && !catalog.ownNames(agent: claude, folder: V).contains("other1")
          && catalog.ownNames(agent: claude, folder: V).contains("mine"))

    // ------------------------------------------------------------ 10
    section("10. A name goes to the nearest subfolder holding it, whichever was read first")
    skill("N/a/.claude/skills/review", description: "A's review.")
    skill("N/b/.claude/skills/review", description: "B's review.")
    skill("N/b/.claude/skills/only-b")
    let N = dir("N")
    CatalogHarness.hold = 10_000_000
    await catalog.refresh(folder: N)
    await catalog.refresh(folder: dir("N/b"))                        // b's read lands first — a session of its own, the Skills page
    await catalog.walkSubfolders(of: N)
    let early = catalog.choices(agent: claude, folder: N)
    check("with the nearer subfolder unread and unknown, the farther one's skills are not offered yet",
          !early.contains { $0.subfolder != nil }, "\(early.map { ($0.name, $0.subfolderName ?? "-") })")
    CatalogHarness.forget()
    await catalog.readSubfolders(below: N, wanting: ["review"], agent: claude)
    let settled = catalog.choices(agent: claude, folder: N)
    check("the name is the nearest subfolder's — and that one alone was read for it",
          settled.first { $0.name == "review" }?.description == "A's review."
          && settled.filter { $0.name == "review" }.count == 1
          && CatalogHarness.asked == [dir("N/a").path],
          "\(settled.map { ($0.name, $0.subfolderName ?? "-") }) asked \(CatalogHarness.asked.map { ($0 as NSString).lastPathComponent })")
    check("…and what only the farther one holds is offered from it",
          settled.first { $0.name == "only-b" }?.subfolderName == "b")

    // ------------------------------------------------------------ 11
    section("11. A chip's subfolder reads are a queue of their own")
    for i in 0..<3 { skill("Q/q\(i)/.claude/skills/s\(i)") }
    skill("O/o0/.claude/skills/t0")
    let pageSubs = (0..<3).map { dir("Q/q\($0)") }
    let O = dir("O")
    CatalogHarness.hold = 250_000_000
    CatalogHarness.forget()
    catalog.ensureLoaded(folders: pageSubs, maxAge: 5)                      // the Skills page's list
    await pause(60)
    catalog.loadSubfolders(below: O, maxAge: 5)                      // a session's chip, opened meanwhile
    check("…and the catalog says a chip's are being read", catalog.readingSubfolders(below: O))
    await pause(200)
    await settle(catalog)
    await pause(200)
    await settle(catalog)
    check("the page's subfolders are all still read, and the chip's too",
          pageSubs.allSatisfy { CatalogHarness.reads(of: $0) == 1 } && CatalogHarness.reads(of: dir("O/o0")) == 1
          && !catalog.readingSubfolders(below: O),
          "\(CatalogHarness.asked.map { ($0 as NSString).lastPathComponent })")

    // ------------------------------------------------------------ 12
    section("12. A load that failed is looked into: the folder read again, and the subfolder its skill has left")
    skill("L/.claude/skills/own")
    skill("L/a/.claude/skills/gone")
    skill("L/a/.claude/skills/stays")
    skill("L/b/.claude/skills/kept")
    skill("L/c/.claude/skills/solo")
    let L = dir("L")
    CatalogHarness.hold = 10_000_000
    await catalog.refresh(folder: L)
    await catalog.readSubfolders(below: L, wanting: ["gone", "kept", "solo"], agent: claude)
    let offered = { catalog.choices(agent: claude, folder: L).filter { $0.subfolder != nil }.map(\.name).sorted() }
    check("(the fixture) the three subfolders' skills are offered", offered() == ["gone", "kept", "solo", "stays"], "\(offered())")
    // A session whose picks are the two: what its reload asks for.
    await catalog.readSubfolders(below: L, wanting: ["gone", "solo"], agent: claude)
    // Deleted behind SipAI's back — in a terminal, by another tool: no
    // write of SipAI's own distrusts what was read.
    try! fm.removeItem(at: scratch.appendingPathComponent("L/a/.claude/skills/gone"))
    try! fm.removeItem(at: scratch.appendingPathComponent("L/c/.claude/skills/solo"))
    CatalogHarness.forget()
    await catalog.readSubfolders(below: L, wanting: ["gone", "solo"], agent: claude)
    check("an ordinary ask a moment later looks at nothing again — the search is remembered",
          CatalogHarness.asked.isEmpty && offered().contains("gone"), "\(CatalogHarness.asked) \(offered())")
    CatalogHarness.forget()
    catalog.noteLoadFailed(["gone", "solo"], agent: claude, folder: L)
    await pause(300)
    await settle(catalog)
    await pause(300)
    await settle(catalog)
    check("a failed load has the folder read again, and the subfolder whose files no longer hold the skill — no other",
          CatalogHarness.reads(of: L) == 1 && CatalogHarness.reads(of: dir("L/a")) == 1
          && CatalogHarness.reads(of: dir("L/b")) == 0 && CatalogHarness.reads(of: dir("L/c")) == 0,
          "\(CatalogHarness.asked.map { ($0 as NSString).lastPathComponent })")
    check("…so the chip stops offering what is gone, and keeps what is there",
          offered() == ["kept", "stays"], "\(offered())")
}

await run()
finish()
