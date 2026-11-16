// What holds a new session's setup, read off the sources — and what a
// new session sent and left before it is named keeps.
//
// The centre pane's router replaces the session page on every detour — to
// a chat, a note, Settings — and opening any of those, or another session,
// drops the unsent new session itself. So nothing the user sets up for a
// new session may live in the page's own state or on the draft alone: a
// schedule kept in the composer died with the page, and skills kept on the
// draft died with the draft, while the text beside them — kept on AppState
// — came back. Each + is a place of its own (`NewSessionPlace`): what was
// set up under it waits there, keyed by it — the chips only as far as they
// were changed there — and its other chips start from its memory: a
// group's newest session, else the agent's latest choices. Skills and a
// schedule belong to the one new session they were set on: a new session
// starts with no schedule and with the agent's pinned skills alone,
// whatever another session loaded.
//
//   ./structural <SipAI-macOS root>

import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    print(cond ? "  ok   \(label)" : "  FAIL \(label) \(detail)")
    if !cond { failures += 1 }
}

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func source(_ path: String) -> String {
    (try? String(contentsOfFile: root + "/SipAI/" + path, encoding: .utf8)) ?? ""
}
/// The body of the first `func <name>(` in `text`, up to its closing brace
/// at the same indentation.
func body(of name: String, in text: String) -> String {
    guard let start = text.range(of: "func \(name)(") else { return "" }
    let lineStart = text[..<start.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
    let indent = String(text[lineStart..<start.lowerBound].prefix { $0 == " " })
    guard let end = text.range(of: "\n" + indent + "}\n", range: start.upperBound..<text.endIndex) else { return "" }
    return String(text[start.lowerBound..<end.upperBound])
}

let appState = source("Models/AppState.swift")
let page = source("Views/Chat/AgentSessionView.swift")
let composer = source("Views/Chat/AgentComposer.swift")
let sidebar = source("Views/Sidebar/AgentSessionsSection.swift")
let session = source("Models/AgentSession.swift")
let config = source("Models/ConfigManager.swift")
let manager = source("Models/AgentManager.swift")
let launch = source("Models/AgentLaunchOptions.swift")
guard !appState.isEmpty, !page.isEmpty, !composer.isEmpty, !sidebar.isEmpty, !session.isEmpty,
      !config.isEmpty, !manager.isEmpty, !launch.isEmpty else {
    print("  FAIL the sources were not found under \(root)/SipAI")
    exit(1)
}

print("Each + is a place of its own")
check("a new session carries the place it was started from",
      session.contains("enum NewSessionPlace: Hashable") && session.contains("var place: NewSessionPlace"))
check("…and is filed by it, never by its own id or one shared slot",
      page.contains("case .draft(let d): return d.place.draftKey(agentKey: d.agentKey)")
      && !page.contains("\"draft:new\""))
let startNew = body(of: "startNewSession", in: sidebar)
check("a folder header's + names its folder; every other + its group, Ungrouped or no group",
      sidebar.components(separatedBy: "place: .folder(path))").count == 3
      && startNew.contains("place: place ?? .of(customGroup: group, groupedByCustom: groupMode == .custom)"))
check("a branch started as a new session has a place of its own",
      page.contains("draft.place = .branch(draft.id)"))

print("The schedule set up on a new session")
check("the composer is handed it, and owns no copy that dies with the page",
      composer.contains("@Binding var scheduleDraft: ScheduleDraft")
      && !composer.contains("@State private var scheduleDraft"))
check("the composer never throws it away on its own when the page moves off a new session",
      !composer.contains("if !available { scheduleDraft = ScheduleDraft() }"))
check("the page writes it through to AppState on every change, keyed like the text",
      page.contains(".onChange(of: scheduleDraft) { _, _ in stashComposerSchedule() }")
      && body(of: "stashComposerSchedule", in: page)
          .contains("appState.setComposerSchedule(scheduleDraft, for: AppState.agentDraftKey(key))"))
check("…and reads it back on appear and on a switch",
      body(of: "restoreComposerDraft", in: page).contains("scheduleDraft = appState.composerSchedule(")
      && body(of: "stashAndRestoreComposerDraft", in: page).contains("scheduleDraft = appState.composerSchedule(")
      && body(of: "stashAndRestoreComposerDraft", in: page).contains("appState.setComposerSchedule(scheduleDraft,"))
check("the session a sent new session becomes holds none",
      body(of: "rekeyComposerDraft", in: page).contains("scheduleDraft = ScheduleDraft()"))

print("The chips and skills set on a new session wait at its place")
check("the skills: what the place holds, else the agent's pinned skills — nothing another session chose",
      page.contains("""
            return d.skillPicks
                ?? appState.newSessionSkillPicks(for: newSessionStoreKey(d))
                ?? config.agentSkillPreloads(for: d.agentKey)
"""))
let setPicks = body(of: "setSkillPicks", in: page)
check("…kept for the place on every pick before the first send",
      setPicks.contains("if isDraftBeforeFirstSend {")
      && setPicks.contains("appState.setNewSessionSkillPicks(picks, for: newSessionStoreKey(d))"))
// A pick remembered for the agent would be a later new session's start:
// the skills one session loaded would turn up, ticked, on the next.
check("…and remembered nowhere else: no latest skill choice is kept for the agent",
      !setPicks.contains("LatestSkillPicks")
      && !page.contains("agentLatestSkillPicks")
      && !config.contains("latest_skill_picks"))
// The chips are kept chip by chip, as the user changed them: a place keeps
// the chips moved on it, and the others follow what it starts with. Read
// off a change of the chips' state instead, SipAI's own seeds would count
// as changes — and kept whole, one chip changed held every other chip
// where it was while the group's newest session moved on.
let pick = body(of: "saveUserPick", in: page)
let keepPick = body(of: "keepNewSessionPick", in: page)
check("the chips: what a pick moved is kept for the place, chip by chip, where the pick is made — never off a change of the chips' state",
      pick.contains("keepNewSessionPick(from: old, to: picked)")
      && keepPick.contains("guard case .draft(let d) = mode, isDraftBeforeFirstSend else { return }")
      && keepPick.contains("edits.note(from: old, to: new)")
      && keepPick.contains("appState.setNewSessionChipEdits(edits, for: key)")
      && !page.contains(".onChange(of: launchOptions) { _, new in keepNewSessionPick"))
check("…and a new session is seeded with what its place starts with, the kept chips laid over it",
      body(of: "seedLaunchOptions", in: page)
          .contains("?? appState.newSessionChipEdits(for: newSessionStoreKey(d))?\n                    .applied(to: start, offer: newSessionChipOffer(forModel:))\n                ?? start)"))
// A kept chip and a start that has moved on can disagree: a model kept
// over the start's effort, an effort kept over the start's model.
check("…fitted to the model they land on where they mix — as a model pick fits its chips — and nothing dropped on what is not known",
      launch.contains("guard !chips.isDisjoint(with: [.model, .effort, .speed]) else { return out }")
      && launch.contains("return out.fitted(to: offer(out.model))")
      && launch.contains("let levels = offer.efforts, !levels.contains(effort)")
      && composer.contains("options = updated.fitted(to: modelPickOffer(forModel: value))")
      && body(of: "newSessionChipOffer", in: page).contains("codex.speedTiers(forModel: model, folder: folder.path)?")
      && !body(of: "newSessionChipOffer", in: page).contains("?? []"))

print("What a place starts with")
let start = body(of: "newSessionStartingSetup", in: page)
check("its chips: a group's newest session's, else the agent's latest choices",
      start.contains("d.place.startingSetup(")
      && start.contains("?? config.agentLaunchOptions(for: agent)"))
// A new session's row and picks come with its session id, seconds after
// its first message went. A + clicked in between — the user starting the
// next session in the group at once — started from the session before it.
check("…a new session whose first message has gone counting from that moment, before it is named",
      start.contains("unnamed: agents.unnamedNewSessions(for: agent)")
      && body(of: "startingSetup", in: session).contains("among: sessions + unnamed.map(\\.row)"))
// Codex keeps a session's speed in some modes and that session's chips
// show the speed it keeps; its pick may say another.
check("…and for codex, the speed that session's chips show where codex keeps it",
      start.contains("CodexKeptSpeed.startingTier(")
      && start.contains("Self.codexSavedSpeed(of: session.fileURL)")
      && body(of: "startingTier", in: launch).contains("forkTier(saved) ?? pick"))
check("…and never another session's skills",
      !start.contains("SkillPicks") && !start.contains("skills")
      && !session.contains("enum NewSessionSkills"))
check("…worked out once per new session, after forgetting what waits for groups that are gone",
      body(of: "refreshNewSessionStart", in: page).contains("appState.dropNewSessions(ofGroupsNotIn: config.agentCustomGroups(for: d.agentKey),"))

print("A custom group's rename, a send and the factory reset")
check("the sidebar's rename moves what waits for the group",
      body(of: "commitGroupPrompt", in: sidebar).contains("appState.renameNewSessionGroup(old, to: name, agentKey: agentKey)"))
check("…and a new session of that group on screen takes the new key",
      page.contains(".onChange(of: draftPlaceIdentity) { old, new in adoptRenamedPlace(from: old, to: new) }"))
let send = body(of: "handleSend", in: page)
// What a first message uses up is spelled once, in `useUpNewSession`, which a
// send calls when it went and codex's own commands call when they start —
// never for a message held while a turn runs (the first turn already used it).
let useUpNew = body(of: "useUpNewSession", in: page)
check("a new session's first message uses up its skills, chips and schedule",
      send.contains("useUpNewSession()")
      && useUpNew.contains("appState.setNewSessionSkillPicks(nil, for: newSessionStoreKey(d))")
      && useUpNew.contains("appState.setNewSessionChipEdits(nil, for: newSessionStoreKey(d))")
      && useUpNew.contains("scheduleDraft = ScheduleDraft()"))
// A task made from a new session takes its message, its schedule and the
// skills its runs load. Left ticked, those skills would turn up on the
// next new session from the same +, as if carried over from the task. The
// task lands after its file is written, when the page may show another
// conversation, so the new session is the one the closure was made for.
let created = page.range(of: "onScheduleCreated: {").map { String(page[$0.lowerBound...].prefix(900)) } ?? ""
let useUp = body(of: "useUpNewSessionSkills", in: page)
check("a task made from a new session uses up its skills, as it uses up its message and schedule",
      created.contains("[unsent = unsentNewSession]")
      && created.contains("useUpNewSessionSkills(unsent)")
      && useUp.contains("appState.setNewSessionSkillPicks(nil, for: unsent.key)")
      && useUp.contains("appState.pendingClaudeSessionDraft?.skillPicks = nil"))
// What its place starts with may be another session's setup, so once the
// first message has gone the chips are the new session's own, as its skills
// are: a page built again before the session is named seeds from them, the
// switch then saves them as the session's, and a turn that ends puts its
// Non-stop back from them.
check("…and its chips go on with it: kept on the new session, seeded and its Non-stop put back from there",
      session.contains("var sentOptions: AgentLaunchOptions?")
      && useUpNew.contains("appState.pendingClaudeSessionDraft?.sentOptions = launchOptions")
      && body(of: "keepSentOptions", in: page)
          .contains("appState.pendingClaudeSessionDraft?.sentOptions = options")
      && page.contains(".onChange(of: launchOptions) { _, new in keepSentOptions(new) }")
      && body(of: "seedLaunchOptions", in: page).contains("applySeededOptions(d.sentOptions")
      && body(of: "savedNonStopPick", in: page)
          .contains("if case .draft(let d) = mode, let sent = d.sentOptions"))
// An edit of a session's FIRST message starts a new session the same way,
// and that session keeps the chips its message went out with — not the
// agent's latest choices, which its place would otherwise start it on.
check("…a first message edited into a new session included: it keeps the chips that message went out with",
      body(of: "startBranchAsNewSession", in: page).contains("draft.sentOptions = launchOptions"))
// The page saves a new session's chips when it switches to the session,
// once the transcript lands. A page that moved on before that — the
// group's + clicked again to start the next session, a chat — never did:
// the session was left with no picks, reopened on the agent's latest
// choices, and its group's + passed it over. The manager files them
// instead, when the id arrives, from its own copy of the new session.
let migrate = body(of: "migrateRunner", in: manager)
check("a new session's chips are filed under its id by the manager, whichever page is on screen",
      migrate.contains("config?.setAgentSessionLaunchOptions(chips, for: newSessionId)")
      && migrate.contains("if let chips = draft?.sentOptions {"))
check("…before its placeholder row, like its group",
      (migrate.range(of: "if let chips = draft?.sentOptions {")?.lowerBound).map { at in
          migrate.range(of: "sessions.insert(placeholder").map { at < $0.lowerBound } ?? false
      } ?? false)
check("…from the new session as its page last left it, not the copy taken when its runner was made",
      migrate.contains("let draft = sentDrafts.removeValue(forKey: oldKey) ?? draft"))
check("…which the page keeps in step: at the send, a change of its chips or skills after it, and a first message edited into a new session",
      useUpNew.contains("if let sent = appState.pendingClaudeSessionDraft { agents.noteSentDraft(sent) }")
      && body(of: "keepSentOptions", in: page)
          .contains("if let draft = appState.pendingClaudeSessionDraft { agents.noteSentDraft(draft) }")
      && setPicks.contains("agents.noteSentDraft(draft)")
      && body(of: "startBranchAsNewSession", in: page).contains("agents.noteSentDraft(draft)"))
// The page keeps the copy from a change of the chips' state, which cannot
// tell the user's pick from SipAI's own update: the copy is kept, never
// saved from there.
let note = body(of: "noteSentDraft", in: manager)
check("…a copy kept until the id arrives, and nothing saved from it before then",
      note.contains("guard let runner = runners[key], runner.sessionId == nil else { return }")
      && note.contains("sentDrafts[key] = draft") && !note.contains("config"))
check("…a new session counting while its first message runs, and not after one that named no session",
      body(of: "unnamedNewSessions", in: manager)
          .contains("runner.sessionId == nil, let sentAt = runner.status.runningSince"))

let clear = body(of: "clearComposerDrafts", in: appState)
check("the factory reset clears all of it with the text",
      clear.contains("composerSchedules.removeAll()") && clear.contains("newSessionSkillPicks.removeAll()")
      && clear.contains("newSessionChipEdits.removeAll()"))

print("The README says it as it is")
// Words joined across the README's line breaks.
let readme = ((try? String(contentsOfFile: root + "/../README.md", encoding: .utf8)) ?? "")
    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
check("a group's + starts on the chips of its newest session run from SipAI — one just sent included — under the chips changed there, and skills and a schedule are never carried over",
      readme.contains("starts on the chips of that group's newest session run from SipAI (its mode, model, effort and speed), the one you sent a moment ago included")
      && readme.contains("with its schedule, its skills and the chips you changed on it")
      && readme.contains("Every other chip follows that **+**")
      && readme.contains("Skills and a schedule are never carried over there: a new session started from a **+** begins with no schedule and with only the skills pinned with **Start New Sessions With It**")
      && !readme.contains("keeps the remembered one over a pin"))

print(failures == 0 ? "Structural: OK" : "Structural: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
