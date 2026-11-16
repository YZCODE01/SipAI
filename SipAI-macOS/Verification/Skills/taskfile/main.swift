// The task file's `skills:` key, compiled with the definition alone.

import Foundation

var passed = 0
var failed = 0

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("  PASS \(name)") }
    else { failed += 1; let d = detail(); print("  FAIL \(name)" + (d.isEmpty ? "" : " — \(d)")) }
}
func section(_ title: String) { print("\n" + title) }

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sipai-skills-task-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: root) }

// MARK: - 7. Task file

section("7. Task file")
let taskFile = root.appendingPathComponent("task/SKILL.md")
var def = ScheduledTaskDefinition(name: "task", description: "A task")
def.prompt = "Go."
def.skills = ["release-notes", "review-pr"]
def.passthroughFields = [(key: "owner", value: "me")]
check("written", def.write(to: taskFile))
let text = (try? String(contentsOf: taskFile, encoding: .utf8)) ?? ""
check("skills: is one line", text.contains("\nskills: release-notes, review-pr\n"))
let readBack = ScheduledTaskDefinition.read(name: "task", skillFile: taskFile)
check("read back the same", readBack?.skills == ["release-notes", "review-pr"] && readBack == def)
check("a list with blanks and repeats reads clean",
      ScheduledTaskDefinition.skillList(" a, ,b , A ") == ["a", "b"])
var plain = ScheduledTaskDefinition(name: "p", description: "p")
plain.prompt = "x"
check("no skills, no line", !plain.fileContents().contains("skills:"))
// A hand-written file may spell the list the YAML ways. Unread, the run
// would start WITHOUT its skills.
func readTask(_ frontmatter: String) -> ScheduledTaskDefinition? {
    let file = root.appendingPathComponent("hand-\(UUID().uuidString)/SKILL.md")
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(("---\nname: hand\n" + frontmatter + "---\n\nGo.\n").utf8).write(to: file)
    return ScheduledTaskDefinition.read(name: "hand", skillFile: file)
}
check("a flow list reads as its names", readTask("skills: [a, \"b\"]\n")?.skills == ["a", "b"])
let listed = readTask("skills:\n  - a\n  - plugin:b\nmodel: opus\nowner: me\n")
check("a block list reads as its names",
      listed?.skills == ["a", "plugin:b"] && listed?.model == "opus", "\(String(describing: listed?.skills))")
check("…its items are not kept as unknown keys, and a save writes the one line",
      listed?.passthroughFields.map(\.key) == ["owner"]
      && listed?.fileContents().contains("\nskills: a, plugin:b\n") == true)
check("another key's list is not taken for skills",
      readTask("tags:\n  - x\nskills: a\n")?.skills == ["a"])


print("\n\(passed)/\(passed + failed) checks passed")
exit(failed == 0 ? 0 : 1)
