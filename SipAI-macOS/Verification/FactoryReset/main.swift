// Headless verification for FactoryReset. See run.sh.
//
// Not part of the app target — this directory sits outside SipAI/.
//
// The reset is the one action in this app that deletes the user's data
// on purpose, and it is by definition tried once, at the worst possible
// moment to discover it half-works. So the rules that are easy to get
// wrong get exercised here against a throwaway data directory:
//
//   * mcp/ survives (MCPBridge's listener is bound to a socket in it)
//   * hidden files do NOT survive (they are still our data)
//   * the managers are rebuilt AFTER the wipe, never before
//   * the scheduler is silenced BEFORE running turns are stopped
//   * a file that cannot be removed is REPORTED, not swallowed
//
// What this cannot reach: ContentView's onboarding latch, which is
// SwiftUI @State. The notification that re-arms it is asserted here;
// that it lands is a one-line `.onReceive` in ContentView.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "  ok   " : "  FAIL ") + label + (detail.isEmpty ? "" : " — \(detail)"))
    if !ok { failures += 1 }
}

let fm = FileManager.default

/// Build a data directory that looks like a used install: config, root
/// chats, a project folder, notes, the scheduler's state, the usage
/// log, a hidden file — and the mcp runtime that has to survive.
func makeFixture() {
    try? fm.removeItem(at: SipaiPaths.root)
    let d = SipaiPaths.dataDir
    try? fm.createDirectory(at: d, withIntermediateDirectories: true)
    for name in ["config.json", "meta.json", "usage.json",
                 "scheduled_state.json", "my-first-chat.json",
                 "system_prompt.txt", ".DS_Store", ".hidden-leftover"] {
        fm.createFile(atPath: d.appendingPathComponent(name).path,
                      contents: Data("x".utf8))
    }
    for sub in ["notes", "new-project"] {
        let s = d.appendingPathComponent(sub, isDirectory: true)
        try? fm.createDirectory(at: s, withIntermediateDirectories: true)
        fm.createFile(atPath: s.appendingPathComponent("a.json").path,
                      contents: Data("x".utf8))
    }
    let mcp = d.appendingPathComponent("mcp", isDirectory: true)
    try? fm.createDirectory(at: mcp, withIntermediateDirectories: true)
    for name in ["approver.py", "config.json", "approver.sock"] {
        fm.createFile(atPath: mcp.appendingPathComponent(name).path,
                      contents: Data("x".utf8))
    }
}

/// A task root that looks like one the user has been using: two normal
/// tasks, one paused, one half-made directory with no SKILL.md, and a
/// stray hidden file.
func makeTaskFixture() {
    try? fm.removeItem(at: ScheduledTaskCreator.taskRoot)
    let root = ScheduledTaskCreator.taskRoot
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["debug", "readme-file-fix", "paused-one", "half-made"] {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if name != "half-made" {
            fm.createFile(atPath: dir.appendingPathComponent("SKILL.md").path,
                          contents: Data("---\nname: \(name)\n---\n".utf8))
        }
    }
    fm.createFile(atPath: root.appendingPathComponent(".DS_Store").path,
                  contents: Data("x".utf8))
}

func exists(_ relative: String) -> Bool {
    fm.fileExists(atPath: SipaiPaths.dataDir.appendingPathComponent(relative).path)
}

func taskExists(_ name: String) -> Bool {
    fm.fileExists(atPath: ScheduledTaskCreator.taskRoot
        .appendingPathComponent(name).path)
}

MainActor.assumeIsolated {

    // ---------- 1. what the wipe removes, and what it spares ----------
    print("perform() — the wipe")
    makeFixture()
    makeTaskFixture()
    CallLog.reset()

    let config = ConfigManager()
    let appState = AppState()
    appState.activeModel = "gpt-5"
    appState.activeRole = RoleConfig(name: "Editor", prompt: "p")
    appState.theme = .dark
    // Deliberately the NON-default language, so "the reset moved it"
    // and "it was already there" can't be confused.
    appState.language = .chinese
    appState.leftSidebarVisible = false

    var notified = 0
    let token = NotificationCenter.default.addObserver(
        forName: .sipFactoryReset, object: nil, queue: nil) { _ in notified += 1 }

    for key in FactoryReset.userDefaultsKeys {
        UserDefaults.standard.set(123, forKey: key)
    }

    let failed = FactoryReset.perform(config: config,
                                      projects: ProjectManager(),
                                      chats: ChatManager(),
                                      notes: NotesManager(),
                                      agents: AgentManager(),
                                      scheduler: ScheduledTaskScheduler(),
                                      appState: appState)

    check("reports no failures on a clean wipe", failed.isEmpty, "\(failed)")
    check("data directory still exists",
          fm.fileExists(atPath: SipaiPaths.dataDir.path))
    check("config.json gone", !exists("config.json"))
    check("root chat gone", !exists("my-first-chat.json"))
    check("project folder gone", !exists("new-project"))
    check("notes folder gone", !exists("notes"))
    check("scheduler state gone", !exists("scheduled_state.json"))
    check("usage log gone", !exists("usage.json"))
    check("system prompt gone", !exists("system_prompt.txt"))
    // No `.skipsHiddenFiles` — a dot-file in our own data directory is
    // still our data, and a wipe that steps over the invisible half of
    // it is not a wipe.
    check("hidden .DS_Store gone", !exists(".DS_Store"))
    check("hidden leftover gone", !exists(".hidden-leftover"))
    // The whole reason the wipe enumerates instead of removing the
    // directory: MCPBridge stays bound to mcp/approver.sock for the
    // app's entire run, and every agent approval goes through it.
    check("mcp/ survives", exists("mcp"))
    check("mcp/approver.sock survives", exists("mcp/approver.sock"))
    check("mcp/approver.py survives", exists("mcp/approver.py"))
    check("mcp/config.json survives", exists("mcp/config.json"))

    // ---------- 1b. scheduled tasks ----------
    // "Factory reset means factory reset": an app reset to first run
    // must not go on spawning unattended agent turns on a schedule its
    // owner can no longer see.
    print("perform() — scheduled tasks")
    check("task 'debug' gone", !taskExists("debug"))
    check("task 'readme-file-fix' gone", !taskExists("readme-file-fix"))
    check("paused task gone", !taskExists("paused-one"))
    // Not only directories holding a readable SKILL.md — a half-written
    // or hand-edited task is still one the scheduler could pick up.
    check("half-made task dir gone", !taskExists("half-made"))
    check("hidden file in task root gone", !taskExists(".DS_Store"))
    check("task root itself survives, empty",
          fm.fileExists(atPath: ScheduledTaskCreator.taskRoot.path))
    check("crontab swept of tagged entries", ScheduledTaskCreator.crontabSwept)
    // Definitions go while the scheduler is quiet, so no due-check can
    // read one as owed on the way past.
    let iTasks = CallLog.index(of: "crontab.removeAllEntries")
    let iSilenced = CallLog.index(of: "scheduler.forgetAllRuns")
    check("tasks deleted after the scheduler is silenced",
          iSilenced != nil && iTasks != nil && iSilenced! < iTasks!,
          "\(CallLog.entries)")
    check("sessions rescanned so deleted tasks leave the sidebar",
          CallLog.index(of: "agents.reloadSessions") != nil)

    // ---------- 2. order ----------
    print("perform() — order")
    // The scheduler drops its run observers first. Stopping a turn ends
    // it, and a scheduled run's observer answers a turn ending by
    // writing a fresh run record — which would land after the wipe.
    let iScheduler = CallLog.index(of: "scheduler.forgetAllRuns")
    let iAgents = CallLog.index(of: "agents.stopAllRunningTurns")
    check("scheduler silenced before turns are stopped",
          iScheduler != nil && iAgents != nil && iScheduler! < iAgents!,
          "\(CallLog.entries)")
    check("both happen before the managers reload",
          iAgents != nil && CallLog.index(of: "config.reload").map { iAgents! < $0 } == true)
    // A reload that reads a config the wipe has not reached yet
    // re-publishes the very state the reset was asked to remove.
    check("config.reload ran after the wipe", config.reloadSawConfig == false,
          "saw config on disk: \(String(describing: config.reloadSawConfig))")
    for m in ["projects.reload", "chats.reload", "notes.reload"] {
        check("\(m) called", CallLog.index(of: m) != nil)
    }
    // The wipe erased the learned model names ("Opus 5") along with the
    // rest of config, so the launch-scoped latch saying "already
    // harvested" is now claiming knowledge nothing holds. Left armed, it
    // makes every model picker in the app read a bare family name until
    // the next relaunch.
    check("model-name harvest latch forgotten", ClaudeModelCatalog.forgotten)
    check("names re-harvested, after the wipe",
          ClaudeModelCatalog.harvestedAfterWipe == true,
          "harvested after wipe: \(String(describing: ClaudeModelCatalog.harvestedAfterWipe))")

    // ---------- 3. in-memory state ----------
    print("perform() — in-memory state")
    check("routing cleared", appState.startedNewChat)
    // Unsent drafts live in RAM alone, so nothing on disk can clear them.
    check("composer drafts cleared", appState.draftsCleared)
    check("active model cleared", appState.activeModel == nil)
    check("active role cleared", appState.activeRole == nil)
    check("theme back to system", appState.theme == .system)
    check("language back to the bundle's own resolution",
          appState.language == .effective)
    check("sidebar shown", appState.leftSidebarVisible)
    check("onboarding notification posted once", notified == 1, "\(notified)")
    for key in FactoryReset.userDefaultsKeys {
        let after = UserDefaults.standard.object(forKey: key)
        if key == "AppleLanguages" {
            // This one ALSO lives in NSGlobalDomain — it is the user's
            // own system language list — so a read goes down the domain
            // search chain and can never come back nil, however
            // thoroughly our override is gone. Asserting `== nil` here
            // would be asserting that the reset wiped a macOS-wide
            // setting, which is neither true nor wanted.
            //
            // What the reset owes the user is that OUR per-app override
            // stops applying, so the app comes back up in the language
            // the Mac is in. That is exactly "no longer reads back the
            // value we wrote".
            check("UserDefaults \(key) override dropped, global left alone",
                  (after as? Int) != 123, "\(String(describing: after))")
        } else {
            check("UserDefaults \(key) removed", after == nil)
        }
    }
    NotificationCenter.default.removeObserver(token)

    // ---------- 4. a removal that fails is REPORTED ----------
    print("perform() — partial failure")
    makeFixture()
    makeTaskFixture()
    // An immutable file cannot be unlinked, so removing the directory
    // holding it fails. Stands in for any permissions/locking case.
    let stuckDir = SipaiPaths.dataDir.appendingPathComponent("new-project",
                                                             isDirectory: true)
    let stuckFile = stuckDir.appendingPathComponent("a.json")
    try? fm.setAttributes([.immutable: true], ofItemAtPath: stuckFile.path)
    // Same again in the task root: a scheduled task that survives the
    // reset is the one leftover that keeps ACTING, so it has to be
    // named just as loudly as a leftover file.
    let stuckTask = ScheduledTaskCreator.taskRoot
        .appendingPathComponent("debug", isDirectory: true)
        .appendingPathComponent("SKILL.md")
    try? fm.setAttributes([.immutable: true], ofItemAtPath: stuckTask.path)

    var notifiedOnFailure = 0
    let token2 = NotificationCenter.default.addObserver(
        forName: .sipFactoryReset, object: nil, queue: nil) { _ in
            notifiedOnFailure += 1
        }

    let failed2 = FactoryReset.perform(config: ConfigManager(),
                                       projects: ProjectManager(),
                                       chats: ChatManager(),
                                       notes: nil,
                                       agents: nil,
                                       scheduler: nil,
                                       appState: AppState())

    // Silence here is the dangerous outcome: the user is told their API
    // keys are gone while the file holding them is still on disk.
    check("names both entries it could not remove",
          Set(failed2) == ["scheduled-tasks/debug", "new-project"], "\(failed2)")
    check("a stuck task is named as a place, not a bare word",
          failed2.contains("scheduled-tasks/debug"), "\(failed2)")
    check("kept going past the failure", !exists("config.json"))
    check("kept going past the stuck task", !taskExists("paused-one"))
    check("nil managers are tolerated", true)
    // The notification swaps out the view hosting the Settings sheet,
    // taking the alert that reports this failure with it.
    check("no onboarding notification on a partial wipe",
          notifiedOnFailure == 0, "\(notifiedOnFailure)")
    NotificationCenter.default.removeObserver(token2)

    try? fm.setAttributes([.immutable: false], ofItemAtPath: stuckFile.path)
    try? fm.setAttributes([.immutable: false], ofItemAtPath: stuckTask.path)
    try? fm.removeItem(at: SipaiPaths.root)
    try? fm.removeItem(at: ScheduledTaskCreator.taskRoot)
}

print(failures == 0 ? "\nAll checks passed."
                    : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
