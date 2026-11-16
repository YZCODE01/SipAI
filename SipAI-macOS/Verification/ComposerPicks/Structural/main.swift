// The composer's chips: a pick is saved where it is made, and only there.
//
// The session page holds the chips' state (`launchOptions`), and two kinds
// of change reach it: the user's picks on the chips, and SipAI's own
// updates (what a session recorded, the sticky picks, the model a turn ran
// as, a card's mode switch). Only the first may be saved as the user's
// pick — for the session and as the agent's starting picks for new
// sessions.
//
// The page used to tell the two apart after the fact, in an
// `onChange(of: launchOptions)`, with a yes/no flag each update of
// SipAI's set. SwiftUI does not deliver one change per update: it
// delivered two of SipAI's updates as two changes (a new session's page
// opened again while its first message ran — the model refine, then the
// flip's seed), the flag covered one, and the other was saved as the
// user's pick. This pass reads the page for the shape that cannot
// miscount: the chips write through a binding that saves, and nothing
// else saves a pick.
//
//   swiftc main.swift && ./main <source-root>

import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    print(cond ? "  ok   \(label)" : "  FAIL \(label) \(detail)")
    if !cond { failures += 1 }
}

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let path = root + "/SipAI/Views/Chat/AgentSessionView.swift"
guard let view = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("  FAIL cannot read \(path)")
    exit(1)
}

/// The text from `start` up to the first `end` after it, or "".
func slice(_ text: String, from start: String, to end: String) -> String {
    guard let a = text.range(of: start) else { return "" }
    let rest = text[a.lowerBound...]
    guard let b = rest.range(of: end, range: rest.index(after: rest.startIndex)..<rest.endIndex)
    else { return String(rest) }
    return String(rest[..<b.upperBound])
}
func occurrences(_ needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}
/// The closure after each `start` in `text`, braces matched — string
/// literals and line comments passed over.
func closures(after start: String, in text: String) -> [String] {
    var out: [String] = []
    var from = text.startIndex
    while let hit = text.range(of: start, range: from..<text.endIndex) {
        from = hit.upperBound
        guard let open = text[hit.upperBound...].firstIndex(of: "{") else { break }
        var depth = 0, inString = false, inComment = false
        var i = open
        while i < text.endIndex {
            let c = text[i]
            if inComment {
                if c == "\n" { inComment = false }
            } else if inString {
                if c == "\\", text.index(after: i) < text.endIndex { i = text.index(after: i) }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if text[i...].hasPrefix("//") {
                inComment = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { out.append(String(text[open...i])); break }
            }
            i = text.index(after: i)
        }
    }
    return out
}
/// `code` and the bodies of this file's functions it calls, one level down.
func withCallees(_ code: String, in text: String) -> String {
    let call = try! NSRegularExpression(pattern: "([A-Za-z_][A-Za-z0-9_]*)\\(")
    let names = Set(call.matches(in: code, range: NSRange(code.startIndex..., in: code))
        .compactMap { Range($0.range(at: 1), in: code).map { String(code[$0]) } })
    return names.reduce(code) { all, name in
        all + "\n" + (closures(after: "func \(name)(", in: text).first ?? "")
    }
}

print("structural — AgentSessionView.swift")

check("the composer's chips write through the binding that saves a pick",
      view.contains("options: userPicks,") && !view.contains("options: $launchOptions"))

let binding = slice(view, from: "private var userPicks: Binding<AgentLaunchOptions> {", to: "\n    }\n")
check("…which writes the state, and saves only a change",
      binding.contains("launchOptions = picked")
        && binding.contains("guard picked != old else { return }")
        && binding.contains("saveUserPick(picked, replacing: old)"))

// An `onChange` of the chips' state may keep them somewhere (an unsent new
// session's, at its place) — it cannot tell a pick from SipAI's own update,
// so nothing it runs may save one or act on one.
let pickActs = ["config.setAgentLaunchOptions(", "config.setAgentSessionLaunchOptions(",
                "saveUserPick(", "setNonStop(", "noteCodexChipLeftForPlan("]
let changeHandlers = closures(after: ".onChange(of: launchOptions)", in: view)
    .map { withCallees($0, in: view) }
check("nothing infers a pick from a change of the chips' state afterwards: no `onChange` of it saves one",
      !view.contains("seedingOptions")
        && !changeHandlers.contains { h in pickActs.contains { h.contains($0) } },
      "\(changeHandlers.count) handler(s)")

let save = slice(view, from: "private func saveUserPick(_ new: AgentLaunchOptions, replacing old: AgentLaunchOptions) {", to: "\n    }\n")
check("a pick is saved for the session and as the agent's starting picks",
      save.contains("config.setAgentLaunchOptions(picked, for: sessionAgentKey)")
        && save.contains("config.setAgentSessionLaunchOptions(picked, for: id)"))
check("…the user's own Non-stop pick while a turn runs (`ownPick`)",
      save.contains("let picked = ownPick(new, nonStopFlipped: old.nonStop != new.nonStop)"))
check("…and the turn in flight hears a Non-stop flip and a codex chip moved to Plan",
      save.contains("currentRunner?.setNonStop(new.nonStop)")
        && save.contains("currentRunner?.noteCodexChipLeftForPlan("))

check("the agent's starting picks are written in one place: a pick the user made",
      occurrences("config.setAgentLaunchOptions(", in: view) == 1)

let seed = slice(view, from: "private func applySeededOptions(_ options: AgentLaunchOptions) {", to: "\n    }\n")
check("SipAI's own update of the chips writes the state and saves nothing",
      seed.contains("launchOptions = options") && !seed.contains("config.set"))

let refine = slice(view, from: "private func adoptResolvedModel(_ resolved: AgentRunner.ResolvedModel?) {", to: "\n    }\n")
check("the model a turn ran as refines the chip without saving it as a pick",
      refine.contains("launchOptions.modelFullId = resolved.fullId")
        && !refine.contains("LaunchOptions("))

print(failures == 0 ? "Structural: OK" : "Structural: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
