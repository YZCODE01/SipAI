// Stand-ins for the managers FactoryReset drives, so the REAL
// FactoryReset.swift can be compiled and run without a window, a
// subprocess or an Application Support directory.
//
// Each one records that it was called, and — for the four `reload()`s —
// whether the data directory had already been wiped when the call came
// in. That is what lets main.swift assert the ORDER, which is the part
// of `perform` that is load-bearing rather than obvious.
import Foundation

/// Every call FactoryReset made, in order. `SipaiPaths` appends to this
/// too, so the wipe itself has a position in the same sequence.
enum CallLog {
    static var entries: [String] = []
    static func record(_ what: String) { entries.append(what) }
    static func reset() { entries = [] }
    static func index(of what: String) -> Int? { entries.firstIndex(of: what) }
}

/// The real SipaiPaths resolves Application Support. The harness must
/// never touch the user's actual data, so this stand-in points wherever
/// the test says. `ensureDataDir` is copied verbatim from the original.
enum SipaiPaths {
    static var root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sipai-factory-reset-harness", isDirectory: true)

    static var dataDir: URL { root }

    static func ensureDataDir() {
        CallLog.record("ensureDataDir")
        try? FileManager.default.createDirectory(at: dataDir,
                                                 withIntermediateDirectories: true)
    }
}

// MARK: - Managers

/// Whether config.json was still on disk when a reload came in. A
/// reload that reads a config the wipe has not reached yet re-publishes
/// the very state the reset was supposed to remove.
private func configStillOnDisk() -> Bool {
    FileManager.default.fileExists(
        atPath: SipaiPaths.dataDir.appendingPathComponent("config.json").path)
}

class ConfigManager {
    var reloadSawConfig: Bool?
    func reload() {
        reloadSawConfig = configStillOnDisk()
        CallLog.record("config.reload")
    }
}

/// The versioned model names ("Opus 5") the app learns into config. The
/// harvest itself reads `~/.claude.json` and is nothing to do with a
/// reset — what matters here is that the reset FORGETS its launch-scoped
/// latch, because the wipe removed everything that latch was standing
/// in for. `harvestedAfterWipe` records the ordering: re-harvesting
/// before the wipe would just write the names back into a file about to
/// be deleted.
enum ClaudeModelCatalog {
    static var forgotten = false
    static var harvestedAfterWipe: Bool?

    static func forgetHarvest() {
        forgotten = true
        CallLog.record("models.forgetHarvest")
    }

    static func refreshObservedNames(config: ConfigManager,
                                     sessionURLs: [URL]) {
        harvestedAfterWipe = !configStillOnDisk()
        CallLog.record("models.refreshObservedNames")
    }
}

class ProjectManager {
    func reload() { CallLog.record("projects.reload") }
}

class ChatManager {
    func reload() { CallLog.record("chats.reload") }
}

class NotesManager {
    func reload() { CallLog.record("notes.reload") }
    /// A reset DISCARDS staged note edits — flushing them would
    /// re-create the files it just deleted.
    func discardPendingEdits() { CallLog.record("notes.discardPendingEdits") }
}

class AgentManager {
    func stopAllRunningTurns() { CallLog.record("agents.stopAllRunningTurns") }
    func reloadSessions() { CallLog.record("agents.reloadSessions") }
}

class ScheduledTaskScheduler {
    func forgetAllRuns() { CallLog.record("scheduler.forgetAllRuns") }
}

/// Only the two members the reset touches. `taskRoot` is redirected the
/// same way `SipaiPaths.root` is — the harness must never go near the
/// real `~/.claude/scheduled-tasks`, which holds tasks the user made.
enum ScheduledTaskCreator {
    static var taskRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sipai-factory-reset-tasks", isDirectory: true)

    static var crontabSwept = false
    static func removeAllCrontabEntries() {
        crontabSwept = true
        CallLog.record("crontab.removeAllEntries")
    }
}

// MARK: - AppState and the two enums it carries

enum AppTheme: String { case system, light, dark }

/// Mirrors the real `AppLanguage`: no `.system` case, and `.effective`
/// reads the BUNDLE rather than a stored default. Under the harness
/// `Bundle.main` is this test binary, which ships no localizations, so
/// `.effective` is `.english` — which is exactly the post-reset value
/// the reset is asserted to land on.
enum AppLanguage: String {
    case english
    case chinese

    static func matching(localizationCode code: String) -> AppLanguage? {
        let lower = code.lowercased()
        if lower == "en" || lower.hasPrefix("en-") { return .english }
        if lower.hasPrefix("zh") { return .chinese }
        return nil
    }

    static var effective: AppLanguage {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return matching(localizationCode: code) ?? .english
    }
}
struct RoleConfig: Equatable { var name: String; var prompt: String }

class AppState {
    var activeModel: String?
    var activeRole: RoleConfig?
    var theme: AppTheme = .system
    var language: AppLanguage = .effective
    var leftSidebarVisible = true
    var draftsCleared = false
    var startedNewChat = false

    func startNewChat() {
        startedNewChat = true
        CallLog.record("appState.startNewChat")
    }

    func clearComposerDrafts() {
        draftsCleared = true
        CallLog.record("appState.clearComposerDrafts")
    }
}
