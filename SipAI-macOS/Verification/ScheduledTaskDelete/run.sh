#!/bin/bash
# Headless check of deleting a scheduled task — "Delete definition" and
# "Delete all" — see the header of main.swift for the passes.
#
# The path rule is compiled from the SHIPPING ScheduledTaskCreator.swift
# (with ScheduledTaskDefinition.swift, all it needs) and run against a
# throwaway root, never the real ~/.claude/scheduled-tasks; nothing here
# calls deleteTask itself, which also edits the crontab. The rest READS
# the sidebar, AgentManager and the string catalog.
#
#   SIPAI_TASKDELETE_LIVE=1 ./run.sh [source-root]
#
# The live pass runs the real claude twice against a local endpoint that
# never answers, under a throwaway CLAUDE_CONFIG_DIR — no token is spent.
# Run it after a Claude Code upgrade.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
# Paths inside main.swift are REPO-relative (SipAI-macOS/SipAI/…).
root="$(cd "${1:-$here/../../..}" && pwd)"
app="$root/SipAI-macOS/SipAI"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

if ! grep -q "static func taskDirectory(named" "$app/Models/ScheduledTaskCreator.swift"; then
  echo "PRE-FIX: ScheduledTaskCreator.swift has no taskDirectory(named:in:) —"
  echo "  deleting a task removes whatever directory its name points at, and"
  echo "  an orphan's name comes from a transcript. That is the gap this"
  echo "  harness is for."
  exit 1
fi

swiftc -O -target arm64-apple-macos15.0 -o "$out/taskdelete" \
  "$app/Models/ScheduledTaskCreator.swift" \
  "$app/Models/ScheduledTaskDefinition.swift" \
  "$here/main.swift"
"$out/taskdelete" "$root"
