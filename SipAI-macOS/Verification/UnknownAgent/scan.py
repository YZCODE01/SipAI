"""UnknownAgent, section 2: the sources, read for the shapes that hand an agent
the code does not name another agent's path.

    python3 -I scan.py <SipAI source folder>

Each rule prints the places that break it. A place kept on purpose is listed
below with the reason it is right for an agent no switch names; a new one
fails until it is either fixed or listed here with its reason.
"""

import os
import re
import sys

CLAUDE = re.compile(r'"claude_code"|SkillAgent\.claude\b')
OTHER = re.compile(r'"codex"|"kimi"|SkillAgent\.codex\b|SkillAgent\.kimi\b')

# Switches over an agent whose cases name Codex or Kimi Code but not Claude
# Code, kept on purpose: their default arm says nothing that is Claude
# Code's. (file, the enclosing declaration's name) → why.
SWITCH_KEPT = {
    ("Views/Settings/AgentGuidePane.swift", "accountDescription"):
        "the default arm's words name a plan or 'Subscription' — no agent's",
    ("Views/Settings/AgentGuidePane.swift", "progressSentence"):
        "the default arm names the agent's own vendor or label; install is never offered without a route",
}

# A default arm that answers no is the fail-closed answer already.
NO_ANSWER = re.compile(
    r"^(?:return(?:\s+(?:nil|false|\[\]|\[:\]|\"\"|0|\.(?:unavailable|unknown|unsupported|none|off)"
    r"|Reading\(verdict:\s*\.unknown,\s*fingerprint:\s*\"\"\)))?|break|continue"
    r"|throw\s+[\w.]*agentNotSupported|\w+\s*=\s*(?:nil|\[\]|0|false))$")

# Where an agent is told apart by an if-chain rather than a switch, the
# chain must name Claude Code before Claude Code's code runs: (file, the
# function or property, the line that must be in it) → why.
CHAINS = [
    ("Views/Chat/AgentSessionView.swift", "startHistoryLoad", 'guard agentKey == "claude_code" else',
     "a transcript no reader is named for is read by none"),
    ("Views/Chat/AgentSessionView.swift", "startHistoryLoad", 'if window == 0, agentKey == "kimi"',
     "kimi's window lookup runs for kimi's sessions alone"),
    ("Views/Chat/AgentSessionView.swift", "handleExternalTurnFlip", '} else if sessionAgentKey == "claude_code" {',
     "claude's token read runs for claude's sessions alone"),
    ("Views/Chat/AgentSessionView.swift", "canBranch", "AgentSessionFork.hasWriter(agentKey: sessionAgentKey)",
     "no branch pencil for an agent with no branch writer"),
    ("Views/Chat/AgentComposer.swift", "effortLevels", "guard isClaude else { return [] }",
     "no effort levels for an agent with none known"),
    ("Views/Chat/AgentComposer.swift", "fastModeSupported", "guard isClaude else { return false }",
     "no fast mode for an agent with none known"),
    ("Views/Chat/AgentComposer.swift", "modelRows", 'guard agentKey == "claude_code" else',
     "Default alone on the model chip of an agent with no model list"),
    ("Views/Chat/ScheduledTaskPanel.swift", "taskEffortLevels", "guard isClaudeTask else { return [] }",
     "no effort levels on a task of an agent with none known"),
    ("Models/AgentRunner.swift", "runOnce", "guard driver != .unsupported else",
     "a turn with no route is refused before anything is prepared or spawned"),
]

# A property that keeps claude's key as its default: data written before
# there was more than one agent reads as Claude Code's. (file, name) → why.
PROPERTY_KEPT = {
    ("Models/AgentSession.swift", "agentKey"):
        "a session's owner; claude's scanner builds rows without naming it",
    ("Models/AgentSession.swift", "agent"):
        "a scheduled task with no agent: line in its file is Claude Code's",
    ("Models/ScheduledTaskDefinition.swift", "agent"):
        "a task file with no agent: line is Claude Code's",
}

# `?? "claude_code"` kept on purpose: (file, a fragment of the line) → why.
COALESCE_KEPT = {
    ("Models/AgentSession.swift", "parsed?.agent"):
        "a task folder whose SKILL.md cannot be read: the task file's own default",
    ("Models/AgentSession.swift", "sessionsByTask[taskName]?.first?.agentKey"):
        "an orphaned task always has a run to answer for it",
    ("Views/Chat/AgentSessionView.swift", "resolved?.agentKey"):
        "a session the scan has not listed yet, not an agent: its runner already exists",
}

# `= "claude_code"` assignments kept on purpose: (file, fragment) → why.
ASSIGN_KEPT = {
    ("Models/MCPBridge.swift", "self.agentKey"): "the init for claude's own approver socket",
    ("Models/AgentGuide.swift", "let key"): "inside signInClaude, Claude Code's own sign-in",
    ("Models/SkillModel.swift", "static let claude"): "the skills code's name for Claude Code's key",
}


def swift_files(root):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for f in sorted(files):
            if f.endswith(".swift"):
                path = os.path.join(base, f)
                yield os.path.relpath(path, root), path


def split_line(line, in_block_comment):
    """The line twice, comments removed: once with string literals kept (agent
    keys are string literals) and once with their insides blanked, so braces and
    words inside a string count for nothing. Returns (kept, blanked, still in a
    block comment)."""
    kept, blanked = [], []
    i = 0
    n = len(line)
    in_str = False
    while i < n:
        c = line[i]
        if in_block_comment:
            if line.startswith("*/", i):
                in_block_comment = False
                i += 2
                continue
            i += 1
            continue
        if in_str:
            if c == "\\" and i + 1 < n:
                kept.append(line[i:i + 2])
                blanked.append("  ")
                i += 2
                continue
            kept.append(c)
            blanked.append('"' if c == '"' else " ")
            if c == '"':
                in_str = False
            i += 1
            continue
        if line.startswith("//", i):
            break
        if line.startswith("/*", i):
            in_block_comment = True
            i += 2
            continue
        if c == '"':
            in_str = True
        kept.append(c)
        blanked.append(c)
        i += 1
    return "".join(kept), "".join(blanked), in_block_comment


def literal_lines(lines):
    """Each line with comments removed and string literals kept, plus a
    parallel list with the literals blanked for brace counting. A multi-line
    string's lines count as empty."""
    kept, blanked = [], []
    in_block = False
    in_multiline = False
    for line in lines:
        if line.count('"""') % 2 == 1:
            in_multiline = not in_multiline
            kept.append("")
            blanked.append("")
            continue
        if in_multiline:
            kept.append("")
            blanked.append("")
            continue
        k, b, in_block = split_line(line, in_block)
        kept.append(k)
        blanked.append(b)
    return kept, blanked


MODIFIERS = r"(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|internal|public|static|class|nonisolated|override|final|mutating|lazy)\s+)*"
DECLARATION = re.compile(r"^\s*" + MODIFIERS + r"(func|var|let)\s+([A-Za-z_][A-Za-z0-9_]*)")
INIT = re.compile(r"^\s*" + MODIFIERS + r"init\b")


def enclosing_name(blanked, index):
    """The name of the function or property a line sits in: the nearest
    declaration above it at a lower indentation."""
    indent = len(blanked[index]) - len(blanked[index].lstrip())
    for j in range(index - 1, -1, -1):
        text = blanked[j]
        if not text.strip():
            continue
        lead = len(text) - len(text.lstrip())
        if lead >= indent:
            continue
        indent = lead
        m = DECLARATION.match(text)
        if m:
            return m.group(2)
        if INIT.match(text):
            return "init"
    return "?"


def block_end(blanked, start):
    """The index of the line that closes the brace opened on `start`'s line
    (or the first brace after it)."""
    depth = 0
    started = False
    for j in range(start, len(blanked)):
        for ch in blanked[j]:
            if ch == "{":
                depth += 1
                started = True
            elif ch == "}":
                depth -= 1
        if started and depth <= 0:
            return j
    return len(blanked) - 1


def switch_blocks(kept, blanked):
    """(start line index, [(top-level label, [its arm's statements])]) for each
    switch."""
    for i, code in enumerate(blanked):
        if not re.search(r"\bswitch\b[^{]*\{\s*$", code):
            continue
        end = block_end(blanked, i)
        depth = 0
        labels = []
        for j in range(i, end + 1):
            line_depth = depth
            for ch in blanked[j]:
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
            if j == i:
                continue
            stripped = kept[j].strip()
            if line_depth == 1 and (stripped.startswith("case ") or stripped.startswith("default")):
                rest = stripped.split(":", 1)[1].strip() if ":" in stripped else ""
                labels.append((stripped, [rest] if rest else []))
            elif labels and stripped and j < end:
                labels[-1][1].append(stripped)
        yield i, labels


def answers_no(statements):
    """Whether a default arm's statements only answer no."""
    parts = [p.strip() for s in statements for p in s.split(";") if p.strip()]
    return bool(parts) and all(NO_ANSWER.match(p) for p in parts)


def body_lines(lines, blanked, name):
    """Each declaration of `name` (a function or a property), as its text."""
    bodies = []
    for i, code in enumerate(blanked):
        m = DECLARATION.match(code)
        if not m or m.group(2) != name:
            continue
        end = block_end(blanked, i) if "{" in "".join(blanked[i:i + 8]) else i
        bodies.append("\n".join(lines[i:end + 1]))
    return bodies


def main():
    root = sys.argv[1]
    problems = []
    seen_kept = set()
    sources = {}
    for rel, path in swift_files(root):
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
        kept, blanked = literal_lines(lines)
        sources[rel] = (lines, blanked)

        # 1. A switch over an agent names Claude Code wherever it names
        # another, unless its default arm only answers no.
        for start, labels in switch_blocks(kept, blanked):
            cases = " ".join(l for l, _ in labels if l.startswith("case "))
            if not OTHER.search(cases) or CLAUDE.search(cases):
                continue
            defaults = [arm for l, arm in labels if l.startswith("default")]
            if not defaults or answers_no(defaults[0]):
                continue
            name = enclosing_name(blanked, start)
            key = (rel, name)
            if key in SWITCH_KEPT:
                seen_kept.add(("switch",) + key)
                continue
            problems.append(f"{rel}:{start + 1} {name}: a switch names "
                            f"{', '.join(sorted(set(OTHER.findall(cases))))} but not Claude Code — "
                            "its default arm runs Claude Code's path for any other agent")

        for i, text in enumerate(kept):
            code = blanked[i]
            # 2. "Not Codex and not Kimi" standing for Claude Code.
            if re.search(r"!\s*is(Codex|Kimi)\w*", code) and re.search(r"!\s*isKimi\w*|!=\s*\"kimi\"", text) \
                    and re.search(r"!\s*isCodex\w*|!=\s*\"codex\"", text):
                problems.append(f"{rel}:{i + 1}: 'not Codex and not Kimi' stands for Claude Code — "
                                "name Claude Code instead")
            # 3. A parameter or property defaulting to Claude Code's key or reader.
            for m in re.finditer(r"\b(var|let)?\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*String\s*=\s*\"claude_code\"", text):
                if m.group(1):
                    key = (rel, m.group(2))
                    if key in PROPERTY_KEPT:
                        seen_kept.add(("property",) + key)
                        continue
                    problems.append(f"{rel}:{i + 1}: property {m.group(2)} defaults to Claude Code's key")
                else:
                    problems.append(f"{rel}:{i + 1}: parameter {m.group(2)} defaults to Claude Code's key — "
                                    "every caller must name its agent")
            if re.search(r"\bformat\s*:\s*Format\s*=\s*\.claude\b", text):
                problems.append(f"{rel}:{i + 1}: the tailer's format defaults to Claude Code's")
            # 4. `?? "claude_code"`: an unknown answer read as Claude Code.
            if re.search(r'\?\?\s*"claude_code"', text):
                hit = [k for k in COALESCE_KEPT if k[0] == rel and k[1] in text]
                if hit:
                    seen_kept.add(("coalesce",) + hit[0])
                else:
                    problems.append(f"{rel}:{i + 1}: ?? \"claude_code\" reads an unknown agent as Claude Code")
            # 5. Plain assignments of Claude Code's key.
            if re.search(r'(?<![=!<>:])=\s*"claude_code"', text) and not re.search(r":\s*String\s*=", text):
                hit = [k for k in ASSIGN_KEPT if k[0] == rel and k[1] in text]
                if hit:
                    seen_kept.add(("assign",) + hit[0])
                else:
                    problems.append(f"{rel}:{i + 1}: Claude Code's key assigned where an agent was not named")

    # 6. The if-chains name Claude Code before Claude Code's code runs.
    for rel, name, snippet, why in CHAINS:
        if rel not in sources:
            problems.append(f"{rel}: not found — {name} cannot be read")
            continue
        lines, blanked = sources[rel]
        bodies = body_lines(lines, blanked, name)
        if not any(snippet in b for b in bodies):
            problems.append(f"{rel} {name}: '{snippet}' is missing — {why}")

    stale = []
    for table, kind in ((SWITCH_KEPT, "switch"), (PROPERTY_KEPT, "property"),
                        (COALESCE_KEPT, "coalesce"), (ASSIGN_KEPT, "assign")):
        for key in table:
            if (kind,) + key not in seen_kept:
                stale.append(f"{kind} kept for {key[0]} {key[1]} is no longer in the source — drop it from the list")

    for p in problems:
        print("  FAIL  " + p)
    for s in stale:
        print("  FAIL  " + s)
    if not problems and not stale:
        print(f"  PASS  every agent switch names Claude Code; {len(seen_kept)} places keep claude's key on purpose, "
              "each with its reason")
    sys.exit(1 if problems or stale else 0)


if __name__ == "__main__":
    main()
