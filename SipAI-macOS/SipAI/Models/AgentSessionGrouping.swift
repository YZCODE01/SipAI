// AgentSessionGrouping.swift
// How an agent's sidebar list is bucketed — None / Folder / Date /
// State / Custom. Whether the section shows at all is `AgentPresence`
// (AgentGuide.swift). Grouping state lives in this app's own
// config.json.
//
// Two things about the buckets worth knowing before changing them:
//
// * There is no pinned "Active" section — liveness is an inline dot on
//   the row itself — so a working session lands in a real state bucket
//   (Waiting for approval / Working / …) rather than being lifted out
//   of the list.
// * Folder headers show the immediate parent's name, not the full tilde
//   path; a sidebar has room for one folder name (see `detail` below).

import Foundation

// MARK: - Mode

/// How an agent's list is bucketed. Raw values are what
/// `agent_group_mode` persists; do not rename them.
enum AgentGroupMode: String, CaseIterable, Identifiable {
    case none
    case folder
    case date
    case state
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:
            return String(localized: "None",
                          comment: "Grouping mode — one flat list, newest first")
        case .folder:
            return String(localized: "Folder",
                          comment: "Grouping mode — by working directory")
        case .date:
            return String(localized: "Date",
                          comment: "Grouping mode — by last activity")
        case .state:
            return String(localized: "State",
                          comment: "Grouping mode — by what the session is doing")
        case .custom:
            return String(localized: "Custom",
                          comment: "Grouping mode — by user-named groups")
        }
    }
}

// MARK: - State buckets

/// What a row is doing, for `state` grouping. Ordered most-urgent first:
/// an approval is blocking the user, so it outranks a turn that is simply
/// still running; a finished run nobody has opened comes next, above
/// everything that has nothing new to show.
enum AgentGroupState: String {
    case awaitingApproval
    case working
    case runningElsewhere
    case unread
    case scheduled
    case idle

    var order: Int {
        switch self {
        case .awaitingApproval: return 0
        case .working: return 1
        case .runningElsewhere: return 2
        case .unread: return 3
        case .scheduled: return 4
        case .idle: return 5
        }
    }

    var groupLabel: String {
        switch self {
        case .awaitingApproval:
            return String(localized: "Waiting for approval",
                          comment: "State group — session has a pending MCP approval")
        case .working:
            return String(localized: "Working",
                          comment: "State group — session is mid-turn in SipAI")
        case .runningElsewhere:
            return String(localized: "Running in another terminal",
                          comment: "State group — an external Claude Code process owns the turn")
        case .unread:
            return String(localized: "Unread",
                          comment: "State group — sessions whose run finished and that have not been opened since")
        case .scheduled:
            return String(localized: "Scheduled",
                          comment: "State group — scheduled task definitions")
        case .idle:
            return String(localized: "Sessions",
                          comment: "State group — everything not currently doing anything")
        }
    }
}

// MARK: - Tiers

/// Where a row stands in the sidebar's order before its time is asked:
/// running first, then a finished run nobody has opened yet, then
/// everything else. Newest first within a tier. The chat list and every
/// agent section order rows this way in every grouping mode, and Folder
/// and Custom order their GROUPS this way too (`AgentSessionGrouping
/// .buckets`, `arranged`).
///
/// The tier decides PLACEMENT only. The dot a row draws says what is
/// true now — a pulse while it runs, a steady dot while its finished
/// run is unopened — and never reads the held tier below.
enum SidebarTier: Int, Comparable {
    case running = 0
    case unread = 1
    case rest = 2

    static func < (lhs: SidebarTier, rhs: SidebarTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func of(running: Bool, unread: Bool) -> SidebarTier {
        running ? .running : (unread ? .unread : .rest)
    }

    /// The tier the OPEN row is placed at: never below the best tier it
    /// has stood in since it was opened. Opening an unread session reads
    /// it, and a run finishing while it is open leaves nothing unread —
    /// both would otherwise drop the row the user just clicked out from
    /// under the pointer, and take its group with it. It may still RISE
    /// (a send makes it running). It settles into its real tier when the
    /// user opens anything else, which is what clears `held`.
    static func placed(_ actual: SidebarTier,
                       heldSinceOpened held: SidebarTier?) -> SidebarTier {
        guard let held else { return actual }
        return min(actual, held)
    }
}

// MARK: - List items

/// One top-level row of the Claude Code list: a scheduled-task parent or
/// a regular session. The sidebar sorts these into a single chronological
/// stream and then hands them to `AgentSessionGrouping.buckets`.
enum AgentListItem: Identifiable, Hashable {
    case scheduled(ScheduledAgentTask)
    case regular(AgentSession)

    var id: String {
        switch self {
        case .scheduled(let task): return "scheduled:\(task.id)"
        case .regular(let session): return "session:\(session.id)"
        }
    }

    var title: String {
        switch self {
        case .scheduled(let task): return task.description
        case .regular(let session): return session.title
        }
    }

    /// When this row's owner last SPOKE to it — the last user message
    /// for a session; for a task, the last prompt a schedule fired or
    /// the moment the task was scheduled, whichever is later
    /// (`ScheduledAgentTask.lastActive`). Nil only for a task with
    /// neither — Date grouping keeps nil in its own bucket rather than
    /// filing it under some arbitrary month.
    ///
    /// Deliberately not the file's mtime: this value is both printed
    /// on the row and used to order it, and mtime keeps moving for as
    /// long as the agent works, so a session left running pinned
    /// itself to the top of its group for the length of the turn.
    var activityDate: Date? {
        switch self {
        case .scheduled(let task): return task.lastActive
        case .regular(let session): return session.activityAt
        }
    }

    /// Sort key. A row with no date sinks to the bottom of the stream.
    var sortDate: Date { activityDate ?? .distantPast }

    var isSpawnedSubagent: Bool {
        switch self {
        case .scheduled: return false
        case .regular(let session): return session.origin == .subagent
        }
    }

    /// Directory this row belongs to. A scheduled task uses the `cwd:`
    /// from its SKILL.md, falling back to where its newest run actually
    /// ran — a task whose frontmatter omits cwd would otherwise land in
    /// "No directory" even though every one of its runs has a folder.
    var folderURL: URL? {
        switch self {
        case .scheduled(let task):
            return task.workingDirectory ?? task.sessions.first?.projectPath
        case .regular(let session):
            return session.projectPath
        }
    }

    /// Key a custom-group assignment is stored under: sessions key off
    /// their id (so a renamed session keeps its group), scheduled tasks
    /// off their name behind a `sched:` prefix that keeps the two id
    /// spaces apart.
    var groupItemKey: String {
        switch self {
        case .scheduled(let task):
            return AgentListItem.groupItemKey(forScheduledTaskName: task.name)
        case .regular(let session):
            return session.id
        }
    }

    /// The same key for a task there is no row for yet — a task the
    /// composer has just created, whose directory the scanner has not
    /// walked. The prefix is spelled ONCE, here: a caller that builds
    /// the key itself is a second spelling to keep in step, and a
    /// filing written under the wrong one is silent (the row simply
    /// reads as unfiled).
    static func groupItemKey(forScheduledTaskName name: String) -> String {
        "sched:" + name
    }
}

// MARK: - Groups

/// One rendered group: a header plus the rows under it.
struct AgentSessionGroup: Identifiable {
    /// Stable identity, and what collapsed state is written against.
    /// Never empty except in `.none` mode, which draws no header.
    let key: String
    let label: String
    /// Dim trailing text on the header — in folder mode the *immediate*
    /// parent's name, so two folders called `work` stay distinguishable.
    /// Only the parent name, not the whole path: a sidebar header has room
    /// for one folder name, and head-truncating a full path there reads as
    /// broken ("…ktop/Some Project Name"). The full tilde path is one
    /// hover away, in `tooltip`.
    let detail: String
    /// Full tilde path behind the header, surfaced as a tooltip.
    let tooltip: String
    let items: [AgentListItem]
    /// The newest `activityDate` among ALL the group's rows, taken
    /// before any cap trims them — nil when no row has one (a named
    /// group with no rows yet, or one holding only undated tasks).
    /// What `AgentSessionGrouping.arranged` asks when deciding whether
    /// a turn has started here since the headers were last dragged; a
    /// trimmed copy must carry it over rather than recompute it from
    /// the rows it kept.
    let newestActivity: Date?
    /// The best tier among ALL the group's rows, taken before any cap —
    /// `.rest` for a group with none running or unread (and for an empty
    /// one). What `arranged` draws above a dragged order in the modes
    /// whose groups follow the tiers; a trimmed copy carries it over.
    var tier: SidebarTier = .rest

    var id: String { key }
}

enum AgentSessionGrouping {

    /// Keys that cannot collide with a user's group name or a real path.
    /// Non-empty on purpose: collapsed state is a list of keys, and "" is
    /// indistinguishable from "no key", which would leave these two the
    /// only headers that cannot fold.
    static let ungroupedKey = "\u{0}ungrouped"
    static let noDirectoryKey = "\u{0}nodir"

    /// Bucket `items` (already sorted — insertion order is preserved
    /// inside each group) into display groups.
    ///
    /// Folder, date and custom groups are ordered by their most recent
    /// row, so the group a turn has just started in is the first one
    /// under the section header. Scheduling a task dates its row too
    /// (`ScheduledAgentTask.lastActive`), so the group a task was just
    /// created in rises the same way. A group with no dated row — a
    /// named group nothing has been filed into yet — sorts after every
    /// group that has one, and
    /// custom groups among those keep the order they were created in,
    /// Ungrouped last. State groups use `AgentGroupState.order`: that
    /// order is urgency, and recency must not reshuffle it. An order the
    /// user DRAGGED the headers into is applied on top of this one, by
    /// `arranged`.
    ///
    /// In Folder and Custom (`tiersOrderGroups`) the TIER comes before
    /// recency: a group with a running row first, then one with an
    /// unread row, then the rest — each group placed where its top row
    /// would sort (its best tier, then the newest row OF that tier).
    /// Without that, a group whose session started earlier and is still
    /// running sat below one whose session started later and had
    /// already finished. Date keeps date order (it is a calendar, not a
    /// place) and State its urgency order; the tiers apply to the rows
    /// inside those, through the stream's own order.
    ///
    /// An empty bucket is dropped — deleting a group's last session
    /// removes its header too — with ONE exception: a group the user
    /// NAMED renders while empty. A folder or a date bucket describes
    /// rows and means nothing without them, but a named group is a
    /// thing the user made, and its header is the only route to its +,
    /// its Rename and its Delete. Dropping it made "New group…" look
    /// like it had done nothing, and left the group unreachable until
    /// something was filed into it by hand. Ungrouped is not in the
    /// exception: nobody made it, and an empty one says nothing.
    static func buckets(_ items: [AgentListItem],
                        mode: AgentGroupMode,
                        state: (AgentListItem) -> AgentGroupState = { _ in .idle },
                        tier: (AgentListItem) -> SidebarTier = { _ in .rest },
                        customGroups: [String] = [],
                        assignments: [String: String] = [:],
                        now: Date = Date()) -> [AgentSessionGroup] {
        struct Bucket {
            let label: String
            let detail: String
            let tooltip: String
            var items: [AgentListItem]
        }
        var buckets: [String: Bucket] = [:]
        var keyOrder: [String] = []
        var fixedOrder: [String: Int] = [:]

        func bucket(_ key: String,
                    _ label: String,
                    detail: String = "",
                    tooltip: String = "",
                    add item: AgentListItem?) {
            if buckets[key] == nil {
                buckets[key] = Bucket(label: label, detail: detail,
                                      tooltip: tooltip, items: [])
                keyOrder.append(key)
            }
            if let item = item {
                buckets[key]?.items.append(item)
            }
        }

        if mode == .custom {
            for (index, name) in customGroups.enumerated() {
                fixedOrder[name] = index
                bucket(name, name, add: nil)
            }
            fixedOrder[ungroupedKey] = customGroups.count
        }

        for item in items {
            switch mode {
            case .none:
                bucket("", "", add: item)
            case .folder:
                if let url = item.folderURL {
                    let path = url.standardizedFileURL.path
                    let name = url.standardizedFileURL.lastPathComponent
                    bucket(path,
                           name.isEmpty ? path : name,
                           detail: parentName(url),
                           tooltip: parentLabel(url),
                           add: item)
                } else {
                    bucket(noDirectoryKey,
                           String(localized: "No directory",
                                  comment: "Folder group for rows with no known directory"),
                           add: item)
                }
            case .date:
                let bucketed = dateBucket(for: item.activityDate, now: now)
                bucket(bucketed.key, bucketed.label, add: item)
            case .state:
                let rowState = state(item)
                fixedOrder[rowState.rawValue] = rowState.order
                bucket(rowState.rawValue, rowState.groupLabel, add: item)
            case .custom:
                let assigned = assignments[item.groupItemKey]
                if let name = assigned, customGroups.contains(name) {
                    bucket(name, name, add: item)
                } else {
                    // An assignment naming a group that no longer exists
                    // (hand-edited config) reads as unfiled rather than
                    // conjuring a group back into being.
                    bucket(ungroupedKey,
                           String(localized: "Ungrouped",
                                  comment: "Custom-group bucket for rows the user has not filed"),
                           add: item)
                }
            }
        }

        func newest(_ key: String) -> Date? {
            buckets[key]?.items.compactMap(\.activityDate).max()
        }

        // Each group's best tier, and its newest row OF that tier — read
        // once per group rather than once per comparison.
        var bestTier: [String: SidebarTier] = [:]
        var tierNewest: [String: Date] = [:]
        for key in keyOrder {
            let rows = buckets[key]?.items ?? []
            let tiers = rows.map(tier)
            let best = tiers.min() ?? .rest
            bestTier[key] = best
            tierNewest[key] = zip(rows, tiers)
                .filter { $0.1 == best }
                .compactMap { $0.0.activityDate }
                .max()
        }
        let byTier = tiersOrderGroups(mode)

        let ordered = keyOrder.sorted { lhs, rhs in
            let lhsOrder = fixedOrder[lhs] ?? Int.max
            let rhsOrder = fixedOrder[rhs] ?? Int.max
            // Urgency outranks recency in State mode. Custom mode has
            // fixed positions too — the creation order — but there they
            // only break the tie between groups with no dated row.
            if mode != .custom, lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            if byTier {
                let lhsTier = bestTier[lhs] ?? .rest
                let rhsTier = bestTier[rhs] ?? .rest
                if lhsTier != rhsTier { return lhsTier < rhsTier }
                if lhsTier != .rest {
                    // Two running (or two unread) groups: the one whose
                    // newest such row is newer. An undated row of that
                    // tier counts as the oldest — a key, never a reason
                    // to fall through to another one, which would make
                    // the comparison inconsistent across three groups.
                    let left = tierNewest[lhs] ?? .distantPast
                    let right = tierNewest[rhs] ?? .distantPast
                    if left != right { return left > right }
                }
            }
            switch (newest(lhs), newest(rhs)) {
            case let (left?, right?):
                if left != right { return left > right }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        return ordered.compactMap { key in
            guard let found = buckets[key] else { return nil }
            let userNamed = mode == .custom && customGroups.contains(key)
            guard !found.items.isEmpty || userNamed else { return nil }
            let ranked = found.items.filter { !$0.isSpawnedSubagent }
                + found.items.filter(\.isSpawnedSubagent)
            return AgentSessionGroup(key: key,
                                     label: found.label,
                                     detail: found.detail,
                                     tooltip: found.tooltip,
                                     items: ranked,
                                     newestActivity: newest(key),
                                     tier: bestTier[key] ?? .rest)
        }
    }

    /// Whether a mode's GROUPS follow the tiers — Folder and Custom, the
    /// places a session lives. Date is a calendar and keeps date order;
    /// State is already ordered by what its groups are doing; None draws
    /// one group.
    static func tiersOrderGroups(_ mode: AgentGroupMode) -> Bool {
        switch mode {
        case .folder, .custom: return true
        case .none, .date, .state: return false
        }
    }

    // MARK: - Group order over a dragged one

    /// Whether a group a turn starts in moves to the top even over an
    /// order the user dragged the headers into — Folder, Date and
    /// Custom, the modes whose own order is already "most recent
    /// first". State mode's order is urgency, where recency has no
    /// say, and None draws no headers to drag.
    static func liftsActiveGroups(_ mode: AgentGroupMode) -> Bool {
        switch mode {
        case .folder, .date, .custom: return true
        case .none, .state: return false
        }
    }

    /// The order a section draws its groups in: `groups` in the order
    /// `buckets` gave them, `dragged` the ids the user last dragged the
    /// headers into (empty if they never have), `draggedAt` when.
    ///
    /// A dragged order is written WHOLE — every header on screen, at the
    /// moment of the drag — so on its own it pins every group that
    /// existed then, and recency stops reaching any of them: the folder
    /// a new session runs in stays wherever it was dropped, and a
    /// folder that is new since then lands BELOW all the pinned ones.
    /// So a group whose newest row is later than the drag is lifted out
    /// of the dragged order and drawn first, newest on top; every other
    /// group keeps the dragged position (`SidebarOrdering.apply`). A
    /// drag therefore holds until a turn starts somewhere, and then
    /// that group goes to the top — the same thing the section does
    /// when nothing was ever dragged.
    ///
    /// `draggedAt` nil is an order dragged before the time was recorded:
    /// every group with a dated row is lifted, which leaves the saved
    /// order deciding only among the undated ones until the headers are
    /// dragged again. The next drag records the time.
    ///
    /// Above all of that, in the modes whose groups follow the tiers
    /// (`tiersOrderGroups`: Folder and Custom), a group holding a
    /// running or an unread row is drawn first WHATEVER was dragged —
    /// "always on top" — in the tier order `buckets` already gave it.
    /// The dragged order and the lift above only arrange the rest.
    ///
    /// Pure, with the group's id, newest date and tier handed in, so the
    /// rule runs headless over the section's own wrapper type.
    static func arranged<Group>(_ groups: [Group],
                                mode: AgentGroupMode,
                                dragged: [String],
                                draggedAt: Date?,
                                id: (Group) -> String,
                                newest: (Group) -> Date?,
                                tier: (Group) -> SidebarTier = { _ in .rest }) -> [Group] {
        guard !dragged.isEmpty else { return groups }
        guard liftsActiveGroups(mode) else {
            return SidebarOrdering.apply(groups, order: dragged, id: id)
        }
        let byTier = tiersOrderGroups(mode)
        let since = draggedAt ?? .distantPast
        var tiered: [Group] = []
        var lifted: [Group] = []
        var kept: [Group] = []
        for group in groups {
            if byTier, tier(group) < .rest {
                tiered.append(group)
            } else if let date = newest(group), date > since {
                lifted.append(group)
            } else {
                kept.append(group)
            }
        }
        // `groups` is in tier order, then newest-first, in every mode
        // that lifts, so both the tiered and the lifted ones are already
        // in the order they should be drawn in.
        return tiered + lifted + SidebarOrdering.apply(kept, order: dragged, id: id)
    }

    // MARK: - A group's folder

    /// Where a session started from `name`'s header should open: the
    /// newest row filed in that group whose folder still exists.
    ///
    /// `sortedItems` must be the sidebar's own stream — tier first
    /// (`SidebarTier`), then newest-first on `AgentListItem.activityDate`,
    /// the last USER message and never a file's mtime, or a session left
    /// working answers for the group for the length of its turn. Walking
    /// that order and taking the first row that qualifies makes the
    /// answer "where you are working in this group" — its top row —
    /// rather than "where most of its rows are".
    ///
    /// A row whose folder cannot be opened is SKIPPED, not returned. A
    /// session with no recorded cwd falls back to decoding its
    /// `~/.claude/projects` dirname, and that encoding is lossy, so it
    /// can name a plausible path that never existed. `usable` is passed
    /// in, which keeps this a pure function of its inputs and testable
    /// with no filesystem.
    ///
    /// Nil when nothing qualifies — the caller falls back to its own
    /// default rather than this inventing a folder.
    static func latestFolder(inGroup name: String,
                             sortedItems: [AgentListItem],
                             assignments: [String: String],
                             usable: (URL) -> Bool) -> URL? {
        for item in sortedItems where assignments[item.groupItemKey] == name {
            guard let url = item.folderURL?.standardizedFileURL else { continue }
            if usable(url) { return url }
        }
        return nil
    }

    // MARK: - Labels

    /// Full tilde-shortened parent directory — the header's tooltip.
    static func parentLabel(_ url: URL) -> String {
        let parent = url.standardizedFileURL.deletingLastPathComponent().path
        guard !parent.isEmpty, parent != "/" else { return parent }
        return (parent as NSString).abbreviatingWithTildeInPath
    }

    /// The immediate parent's name, which is what a sidebar header has room
    /// for. "~" when the folder sits directly in the home directory, rather
    /// than the account's short name.
    static func parentName(_ url: URL) -> String {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        let path = parent.path
        guard !path.isEmpty, path != "/" else { return path }
        if path == FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path {
            return "~"
        }
        let name = parent.lastPathComponent
        return name.isEmpty ? path : name
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    /// Today / Yesterday / Previous 7 days / Previous 30 days / month.
    /// A future timestamp (clock skew) reads as today rather than
    /// "-1 days".
    static func dateBucket(for date: Date?, now: Date) -> (key: String, label: String) {
        guard let date = date else {
            return ("undated",
                    String(localized: "No activity yet",
                           comment: "Date group for scheduled tasks with no run and no creation date"))
        }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 {
            return ("today", String(localized: "Today", comment: "Date group"))
        }
        if days == 1 {
            return ("yesterday", String(localized: "Yesterday", comment: "Date group"))
        }
        if days < 7 {
            return ("prev7",
                    String(localized: "Previous 7 days", comment: "Date group"))
        }
        if days < 30 {
            return ("prev30",
                    String(localized: "Previous 30 days", comment: "Date group"))
        }
        let parts = calendar.dateComponents([.year, .month], from: date)
        let key = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        return (key, monthFormatter.string(from: date))
    }
}
