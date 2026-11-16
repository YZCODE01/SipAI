#!/bin/bash
# Skills — headless, over the real sources and a throwaway tree.
#
# Pins the folder table, the scan and its rows (shared, an agent's own,
# not in use, a common-folder skill, a broken link, a clash, read-only),
# every file operation with its refusals, byte-preserving edits, what
# each agent needs of a SKILL.md and the fixes a share makes, the
# "once" preload rule, the wire text per agent, the three transcript
# readers over records in the shape each CLI writes, the task file's
# `skills:` key, the walk below a folder for subfolders with skills (its
# bounds, and that it finds a folder exactly when a read of it draws
# something), the folders the Skills page has browsed, and the source
# rules. Nothing under the user's own home is read or written; the tree
# lives in a temp folder removed on exit. (The catalog's reads — the
# queue, a write in the middle — are `../SkillCatalog`'s.)
#
#   ./run.sh
#   SIPAI_SKILLS_LIVE=1 ./run.sh    # also re-measure the CLI facts against
#                                   # the installed claude, codex and kimi —
#                                   # what each loads, which SKILL.md
#                                   # shapes each skips, and which folders
#                                   # codex and kimi read by where they
#                                   # start (token-free: throwaway homes
#                                   # and the fake endpoint; see live.py)
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
m="$src/SipAI/Models"
if ! swiftc -O -o "$out/skillsharness" \
  "$here/../KimiCode/Stubs.swift" \
  "$m/AttachmentInline.swift" \
  "$m/SkillModel.swift" \
  "$m/SkillOps.swift" \
  "$m/ShellCommands.swift" \
  "$m/AgentSession.swift" \
  "$m/AgentSessionTailer.swift" \
  "$m/AgentEventParsing.swift" \
  "$m/AgentSessionFork.swift" \
  "$m/CodexSessions.swift" \
  "$m/CodexRecordedTools.swift" \
  "$m/AgentLaunchOptions.swift" \
  "$m/KimiSessions.swift" \
  "$m/KimiEventParsing.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi
if ! swiftc -O -o "$out/taskfile" \
  "$m/ScheduledTaskDefinition.swift" \
  "$here/taskfile/main.swift" 2>"$out/task-build.log"; then
  cat "$out/task-build.log" >&2
  exit 1
fi
status=0
if [ "${SIPAI_SKILLS_LIVE:-}" = "1" ]; then
  # The SKILL.md shapes the harness measures, raw and as SipAI fixes
  # them, for live.py to hand the installed CLIs.
  export SIPAI_SKILLS_SHAPES_DIR="$out/shapes"
fi
"$out/skillsharness" "$src" || status=1
"$out/taskfile" || status=1
if [ "${SIPAI_SKILLS_LIVE:-}" = "1" ]; then
  perl -e 'alarm 900; exec @ARGV' python3 "$here/live.py" || status=1
fi
exit $status
