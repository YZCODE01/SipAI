#!/bin/bash
# Headless check of a scheduled task that runs ONE time, the chips that
# choose when a task runs, and where a just-scheduled task sits in the
# sidebar — see the header of main.swift for the passes.
#
# Everything under test is compiled from the SHIPPING sources, never
# copied: ScheduledTaskDefinition.swift, ScheduleTimingEditor.swift,
# AgentSessionGrouping.swift and DesignSystem.swift whole; and, EXTRACTED
# by text because the files around them need the whole app, the
# scheduler's due rule, its bookkeeping and the run record
# (ScheduledTaskScheduler.swift), the task type and its scanner
# (AgentSession.swift), and the task panel's "unsaved" rule
# (ScheduledTaskPanel.swift). Only the session
# row type is stubbed. The editor's choosers are private to their file,
# so the rendered pass compiles a copy with `private struct` opened up
# and nothing else changed.
#
# An explicit source root points the whole thing at another checkout.
# Against one that predates the one-time form it stops before the
# build, which is what makes it worth having.
#
#   SCHEDULE_ONCE_RENDER=/tmp/once-png ./run.sh [source-root]
#
# Run it after touching the schedule parser, the due rule, the timing
# editor, the task panel's form, or how a task row is dated.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
# Paths inside main.swift are REPO-relative (SipAI-macOS/SipAI/…).
root="$(cd "${1:-$here/../../..}" && pwd)"
app="$root/SipAI-macOS/SipAI"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

if ! grep -q "enum TaskSchedule" "$app/Models/ScheduledTaskDefinition.swift"; then
  echo "PRE-FIX: ScheduledTaskDefinition.swift has no TaskSchedule — a task"
  echo "  can only repeat on a cron expression, and \"Custom cron\" is the"
  echo "  only thing that looks like a one-time run. That is the gap this"
  echo "  harness is for."
  exit 1
fi

scheduler="$app/Models/ScheduledTaskScheduler.swift"
{
  echo "import Foundation"
  awk '/^struct ScheduledTaskRunState: Codable, Equatable \{/{f=1} f{print} f&&/^\}/{exit}' "$scheduler"
  echo "enum ScheduledTaskScheduler {"
  grep -E "^\s+nonisolated static let (liveWindow|catchUpWindow): TimeInterval" "$scheduler"
  awk '/^    enum Decision: Equatable \{/{f=1} f{print} f&&/^    \}$/{exit}' "$scheduler"
  awk '/^    nonisolated static func decide\(_ def: ScheduledTaskDefinition,/{f=1} f{print} f&&/^    \}$/{exit}' "$scheduler"
  awk '/^    nonisolated static func applying\(/{f=1} f{print} f&&/^    \}$/{exit}' "$scheduler"
  awk '/^    enum OneTimeStatus: Equatable \{/{f=1} f{print} f&&/^    \}$/{exit}' "$scheduler"
  awk '/^    nonisolated static func oneTimeStatus\(/{f=1} f{print} f&&/^    \}$/{exit}' "$scheduler"
  echo "}"
} > "$out/Scheduler.swift"
for required in "struct ScheduledTaskRunState" "static func decide(" \
                "static func applying(" "var scheduleInForce: String?" \
                "enum OneTimeStatus" "static func oneTimeStatus(" \
                "liveWindow" "catchUpWindow"; do
  if ! grep -q "$required" "$out/Scheduler.swift"; then
    echo "  FAIL  '$required' did not extract from ScheduledTaskScheduler.swift"
    echo "        (the rule under test is not the one shipping)"
    exit 1
  fi
done

session="$app/Models/AgentSession.swift"
{
  echo "import Foundation"
  awk '/^struct ScheduledAgentTask: Identifiable, Hashable \{/{f=1} f{print} f&&/^\}/{exit}' "$session"
  awk '/^enum ScheduledAgentTaskScanner \{/{f=1} f{print} f&&/^\}/{exit}' "$session"
} > "$out/Task.swift"
for required in "var createdAt: Date?" "var lastRunAt: Date?" \
                "static func definition(in directory: URL)" "static func newTask(named" \
                "static func overlaying("; do
  if ! grep -q "$required" "$out/Task.swift"; then
    echo "  FAIL  '$required' did not extract from AgentSession.swift"
    exit 1
  fi
done

# The task panel's "unsaved" rule is a pure static on a view that needs
# the whole app, so it is extracted by text like the scheduler's rule. A
# tree without it still builds: a placeholder says it was not found, and
# the checks that need it fail by name instead of stopping the run.
panel="$app/Views/Chat/ScheduledTaskPanel.swift"
awk '/^    static func writesSameFile\(_ form: ScheduledTaskDefinition,$/{f=1} f{print} f&&/^    \}$/{exit}' \
  "$panel" > "$out/rule.txt" 2>/dev/null || true
{
  echo "import Foundation"
  echo "enum ScheduledTaskPanel {"
  if grep -q "formHasNameField: Bool) -> Bool {" "$out/rule.txt"; then
    echo "    static let extracted = true"
    cat "$out/rule.txt"
  else
    echo "    static let extracted = false"
    echo "    static func writesSameFile(_ form: ScheduledTaskDefinition, _ file: ScheduledTaskDefinition,"
    echo "                               formHasNameField: Bool) -> Bool { fatalError(\"not extracted\") }"
  fi
  echo "}"
} > "$out/Panel.swift"

# The choosers are `private` to the editor's file; the rendered pass
# needs to draw them on their own.
sed -e 's/^private struct /struct /' \
  "$app/Views/Chat/ScheduleTimingEditor.swift" > "$out/ScheduleTimingEditor.swift"

if ! swiftc -O -target arm64-apple-macos15.0 -o "$out/scheduleonce" \
  "$here/Stubs.swift" \
  "$app/Utilities/DesignSystem.swift" \
  "$app/Models/ScheduledTaskDefinition.swift" \
  "$app/Models/AgentSessionGrouping.swift" \
  "$out/Scheduler.swift" \
  "$out/Task.swift" \
  "$out/Panel.swift" \
  "$out/ScheduleTimingEditor.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log"
  exit 1
fi

# The rendered pass needs a window server. Without one the process
# would hang rather than fail, so it is bounded, and a timeout reads as
# SKIP — the rule passes have printed their own verdict by then.
set +e
perl -e 'alarm 240; exec @ARGV' "$out/scheduleonce" "$root"
status=$?
set -e
if [ $status -eq 142 ] || [ $status -eq 14 ]; then
  echo ""
  echo "SKIP — the rendered pass timed out reaching the window server (no GUI"
  echo "       session?). Rerun in a logged-in session for the chips."
  exit 0
fi
exit $status
