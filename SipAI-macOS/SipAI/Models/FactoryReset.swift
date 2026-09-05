// FactoryReset.swift
// The ONE implementation of "put this app back to first run".
//
// The wipe lives in ONE place, however many surfaces ask for it, and
// it enumerates the data directory and SKIPS `mcp/` rather than
// removing the directory whole: the live `MCPBridge` listener stays
// bound to `mcp/approver.sock` for the app's entire run, and removing
// it under the listener leaves every later agent approval connecting
// to nothing, silently, until the app is relaunched.
//
// What the reset does NOT touch, deliberately:
//
//  * `mcp/` — see above. It holds only app-managed runtime files
//    (approver.py, its config, the socket), no user data, so keeping it
//    withholds nothing the reset promises to remove.
//  * The agent CLIs' own stores (`~/.claude`, `~/.codex`,
//    `~/.kimi-code`). Those transcripts belong to the CLIs and are read
//    by other clients; they are not SipAI's to delete. A scheduled run
//    that already happened is one of those transcripts and stays.
//  * Local copies written into a user-chosen dedicated folder. The
//    pointer to that folder is config and goes; the files in it are the
//    user's own documents sitting in the user's own folder.
//
// Scheduled tasks DO go, definitions included, even though they sit
// under `~/.claude`. `~/.claude/scheduled-tasks` is SipAI's own
// convention, not Claude Code's, and the alternative was the one
// outcome nobody could defend: an app reset to first run that goes on
// spawning unattended agent turns on a schedule its owner can no longer
// see. That is also why they go BEFORE the wipe rather than after —
// see `perform`.
//
// The confirmation alert in `SettingsView` states each of these, so the
// list here and the sentence there have to be changed together.

import Foundation

extension Notification.Name {
    /// Posted once a factory reset has finished wiping.
    ///
    /// `ContentView`'s onboarding decision is a LATCHED `@State` — it has
    /// to be, because the wizard writes providers and models mid-flow and
    /// re-deriving the gate on those writes unmounts the wizard after its
    /// first save. The consequence is that emptying config cannot on its
    /// own send the window back to onboarding: the latch still reads
    /// `false` from whenever the app last launched configured. This
    /// notification is how the reset re-arms it.
    static let sipFactoryReset = Notification.Name("sipFactoryReset")
}

@MainActor
enum FactoryReset {

    /// Every UserDefaults key this app writes for itself. Any new
    /// `@AppStorage` belongs in this list on the same commit that
    /// introduces it — a key that isn't here outlives a reset that
    /// promised to clear "every setting".
    ///
    /// `rightSidebarWidth` (a retired setting) stays listed on purpose:
    /// installs from before it went away still carry the value on disk.
    ///
    /// AppKit's own window-frame autosaves are deliberately NOT here.
    /// Those are the OS remembering where the user put the window, not a
    /// setting SipAI offers, and yanking the window out from under
    /// someone mid-reset reads as a glitch rather than a fresh start.
    static let userDefaultsKeys = [
        "leftSidebarWidth",
        "rightSidebarWidth",
        "scheduledTaskPanelExpanded",
        // Which outdated-CLI banners the user has closed, keyed by the
        // version they closed. Mac-only UI state, so it lives here
        // rather than in the config file the CLI shares.
        AgentCLIUpdateMonitor.dismissalsDefaultsKey,
        // Whether the CLI release checks run at all — the switch in
        // Settings → Updates. Same home, same reason.
        AgentCLIUpdateMonitor.remoteChecksDefaultsKey,
        // Sparkle's own preferences. They are settings the user can
        // change (the automatic-check toggle) or decisions they made
        // (a skipped version), so "every setting goes" covers them —
        // and un-skipping a skipped version is the right outcome for a
        // reset, since after one the user has expressed no opinion
        // about any version. `SUHasLaunchedBefore` going too is
        // harmless: the first-run permission modal it guards is
        // suppressed by `UpdateController` regardless.
        "SUEnableAutomaticChecks",
        "SUAutomaticallyUpdate",
        "SUScheduledCheckInterval",
        "SULastCheckTime",
        "SUSkippedVersion",
        "SUHasLaunchedBefore",
        "SUSendProfileInfo",
        "SULastProfileSubmitDate",
        "SUUpdateGroupIdentifier",
        // Not an @AppStorage key: this is the per-app language override
        // the picker writes (see `ConfigManager.setLanguage`). It has to
        // go for the same reason the rest do — an install reset to first
        // run must come back up in the language the USER's Mac is in,
        // not one chosen in the install that was just erased. Cleared
        // before `config.reload()` below, so the reloaded config seeds
        // from the bundle rather than from our own leftover override.
        "AppleLanguages",
    ]

    /// Data-directory entries the wipe walks past. See the file header.
    private static let preservedEntries: Set<String> = ["mcp"]

    /// Wipe the app back to a fresh install and rebuild every manager
    /// from the now-empty disk.
    ///
    /// Returns the names of any data-directory entries that could NOT be
    /// removed — empty on success. The caller is expected to SHOW a
    /// non-empty result: a reset that half-happened and reported nothing
    /// leaves the user believing their API keys are gone when they are
    /// still on disk.
    ///
    /// The three optional managers exist for callers that do not hold
    /// them — today only `Verification/FactoryReset`, which passes nil
    /// to exercise the partial-failure report. Everything reachable
    /// from the Settings sheet passes all of them, and should.
    @discardableResult
    static func perform(config: ConfigManager,
                        projects: ProjectManager,
                        chats: ChatManager,
                        notes: NotesManager?,
                        agents: AgentManager?,
                        scheduler: ScheduledTaskScheduler?,
                        appState: AppState) -> [String] {
        // ORDER IS LOAD-BEARING. Everything that could still WRITE goes
        // quiet before the wipe, and the scheduler goes first of all:
        // stopping a runner ends its turn, a scheduled run's `.done`
        // observer answers that by writing a fresh run record, and that
        // write would land after the wipe. Dropping the observers first
        // means there is nothing left to answer.
        scheduler?.forgetAllRuns()
        // Then the definitions, while the scheduler is quiet — a task
        // whose file is gone can never be read as due again, whatever a
        // due-check that was already in flight decides.
        var failed = wipeScheduledTasks()
        agents?.stopAllRunningTurns()

        failed += wipeDataDirectory()

        for key in userDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // Rebuild from the empty disk. Config first — the others' own
        // published state is what the sidebar renders, and config is
        // what decides whether the window shows onboarding at all.
        config.reload()
        // The versioned model names ("Opus 5", not "Opus") are LEARNED
        // into config, not cached in memory, so the wipe above erases
        // them — and any launch-scoped latch over data the reset wipes
        // has to be cleared by the reset, the static "already
        // harvested" latch included. Forget the latch and re-harvest
        // at once: the state file alone can name every family claude
        // has recorded for this account, and passing no sessions
        // leaves the latch open so the seeding pass still runs when
        // one opens.
        ClaudeModelCatalog.forgetHarvest()
        ClaudeModelCatalog.refreshObservedNames(config: config,
                                                sessionURLs: [])
        projects.reload()
        chats.reload()
        notes?.reload()
        // The sidebar's scheduled-task rows come from a SCAN, not from
        // config, so emptying config leaves the tasks just deleted still
        // listed. Nothing else would rescan until the app is next
        // activated, which is well after the user is back in the app.
        agents?.reloadSessions()

        // In-memory state that mirrors what was just wiped. Composer
        // drafts included: an unsent message is user data held only in
        // RAM, so nothing on disk can clear it and it would otherwise
        // reappear in the first composer opened after the reset.
        appState.startNewChat()
        appState.clearComposerDrafts()
        // Unsaved note edits are the same kind of thing: RAM-only, so
        // the wipe cannot reach them, and a later flush would put a file
        // back into the folder just emptied.
        notes?.discardPendingEdits()
        appState.activeModel = nil
        appState.activeRole = nil
        appState.theme = .system
        // Read back from the BUNDLE, not assumed to be some default:
        // the `AppleLanguages` override was removed above, but a reset
        // cannot re-render the app in another language (that needs a
        // relaunch), so the picker has to keep naming a real answer
        // rather than one the user never chose.
        appState.language = .effective
        appState.leftSidebarVisible = true

        // Posted on the SUCCESS path only. This notification swaps the
        // whole main layout out for onboarding, and the Settings sheet
        // goes with it — including the alert that is the only report a
        // partial wipe ever gets. A reset that left something behind
        // therefore stays put and lets the caller speak. It is also not
        // clear that first-run setup is even the right destination when
        // the entry that survived might be config.json itself.
        if failed.isEmpty {
            NotificationCenter.default.post(name: .sipFactoryReset, object: nil)
        }
        return failed
    }

    /// Empty `~/.claude/scheduled-tasks`, and sweep the crontab of any
    /// tagged entries left over from before in-app scheduling.
    ///
    /// Everything directly inside the task root goes — every entry, not
    /// only directories holding a readable SKILL.md. A half-written or
    /// hand-edited task is still a task the user made here, and one left
    /// behind is one the scheduler can pick back up. The root directory
    /// itself stays, empty, so nothing has to reason about recreating it.
    ///
    /// Names come back prefixed with the directory so a failure reads as
    /// a place rather than a bare word ("scheduled-tasks/nightly", not
    /// "nightly") — the report is shown next to data-directory entries.
    ///
    /// Run SESSIONS are untouched. Those are ordinary transcripts under
    /// `~/.claude/projects`, and deleting the schedule is not a reason to
    /// delete the work it produced.
    private static func wipeScheduledTasks() -> [String] {
        let fm = FileManager.default
        let root = ScheduledTaskCreator.taskRoot
        ScheduledTaskCreator.removeAllCrontabEntries()
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        var failed: [String] = []
        for url in entries {
            do {
                try fm.removeItem(at: url)
            } catch {
                failed.append("scheduled-tasks/\(url.lastPathComponent)")
                NSLog("SipAI factory reset: could not remove scheduled task \(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        return failed
    }

    /// Remove the data directory's contents, entry by entry, skipping
    /// `preservedEntries`.
    ///
    /// Enumerate-and-skip rather than removing the directory itself:
    /// `mcp/` has to survive, and re-creating the tree around a live
    /// socket is not something to attempt from here.
    ///
    /// No `.skipsHiddenFiles`. A dot-file in our own data directory is
    /// still our data, and a "wipe" that steps over the invisible half
    /// of it is not a wipe.
    private static func wipeDataDirectory() -> [String] {
        let fm = FileManager.default
        defer { SipaiPaths.ensureDataDir() }
        guard let entries = try? fm.contentsOfDirectory(
            at: SipaiPaths.dataDir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var failed: [String] = []
        for url in entries where !preservedEntries.contains(url.lastPathComponent) {
            do {
                try fm.removeItem(at: url)
            } catch {
                failed.append(url.lastPathComponent)
                NSLog("SipAI factory reset: could not remove \(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        return failed
    }
}
