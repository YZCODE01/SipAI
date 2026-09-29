#!/bin/bash
# Headless check of which group an agent section draws first, and of
# the activity dot a FOLDED group header or a COLLAPSED section header
# draws for something running inside it — see the header of main.swift
# for the passes.
#
# Everything under test is compiled from the SHIPPING sources, never
# copied: AgentSessionGrouping.swift whole, DesignSystem.swift whole
# (`SidebarOrdering`, `ActivityDot`, `UnreadDot`, `GroupActivityDots`,
# `SipFont`), and — EXTRACTED by text, because the files around them
# need the whole app — the agent group's title line, a scheduled task's
# glyph, the section header and the chat group's title line, and
# ChatManager's two live-set members. Only the two row types are stubbed.
#
# An explicit source root points the whole thing at another checkout,
# which needs only the six files read here. Against 1.0.3 it stops
# before the build — the rule and the title lines do not exist there —
# which is what makes it worth having:
#
#   for f in Models/AgentSessionGrouping.swift Models/ConfigManager.swift \
#            Models/ChatManager.swift Utilities/DesignSystem.swift \
#            Views/Sidebar/AgentSessionsSection.swift Views/Sidebar/ChatListView.swift; do
#     mkdir -p "/tmp/sipai-103/SipAI-macOS/SipAI/$(dirname $f)"
#     git -C <repo> show "v1.0.3:SipAI-macOS/SipAI/$f" > "/tmp/sipai-103/SipAI-macOS/SipAI/$f"
#   done
#   ./run.sh /tmp/sipai-103
#
# Run it after touching the bucketer, the group-order rule, the drag
# ordering, or a group header.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
# Paths inside main.swift are REPO-relative (SipAI-macOS/SipAI/…),
# which is also how `git archive` lays an older checkout out.
root="$(cd "${1:-$here/../../..}" && pwd)"
app="$root/SipAI-macOS/SipAI"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

{
  echo "import SwiftUI"
  awk '/^struct AgentGroupHeaderLabel: View \{/{f=1} f{print} f&&/^\}/{exit}' \
    "$app/Views/Sidebar/AgentSessionsSection.swift"
} > "$out/HeaderLabel.swift"
if [ "$(wc -l < "$out/HeaderLabel.swift")" -lt 5 ]; then
  echo "PRE-FIX: AgentSessionsSection.swift has no AgentGroupHeaderLabel —"
  echo "  a folded group header draws no activity dot, so a running session"
  echo "  inside it is invisible. That is the gap this harness is for."
  exit 1
fi

# A scheduled task's glyph — its icon and its fold control at once —
# lives in the same file, and is extracted the same way.
{
  echo "import SwiftUI"
  awk '/^struct ScheduledTaskGlyph: View \{/{f=1} f{print} f&&/^\}/{exit}' \
    "$app/Views/Sidebar/AgentSessionsSection.swift"
} > "$out/TaskGlyph.swift"
if [ "$(wc -l < "$out/TaskGlyph.swift")" -lt 5 ]; then
  echo "PRE-FIX: AgentSessionsSection.swift has no ScheduledTaskGlyph — a"
  echo "  scheduled task still carries a chevron beside its clock, and its"
  echo "  runs sit two glyphs in."
  exit 1
fi

# The section header every sidebar section uses, and a chat group's
# title line — both live in ChatListView.swift beside views that need
# the whole app, so they are extracted by text like the agent header.
chats="$app/Views/Sidebar/ChatListView.swift"
{
  echo "import SwiftUI"
  awk '/^struct DisclosureSection</{f=1} f{print} f&&/^\}/{exit}' "$chats"
  awk '/^extension DisclosureSection where Accessory == EmptyView \{/{f=1} f{print} f&&/^\}/{exit}' "$chats"
  awk '/^struct ChatGroupHeaderLabel: View \{/{f=1} f{print} f&&/^\}/{exit}' "$chats"
} > "$out/ChatHeaders.swift"
if ! grep -q "struct ChatGroupHeaderLabel" "$out/ChatHeaders.swift" \
   || ! grep -q "var live: Bool" "$out/ChatHeaders.swift"; then
  echo "PRE-FIX: ChatListView.swift has no ChatGroupHeaderLabel, or a"
  echo "  DisclosureSection without \`live\` — a folded chat group, or a"
  echo "  collapsed section, hides a conversation that is still running."
  exit 1
fi

# ChatManager is too entangled to compile here, so its two members that
# decide "is anything in this scope waiting?" are extracted, by text,
# into a class that holds nothing but the live set they read.
manager="$app/Models/ChatManager.swift"
{
  echo "import Foundation"
  echo "final class ChatLiveSet {"
  echo "    var liveTurns: [String: Bool] = [:]"
  awk '/static func liveKey\(slug: String, project: String\?\) -> String \{/{f=1} f{print} f&&/^    \}/{exit}' "$manager"
  awk '/func hasChatInFlight\(inProject project: String\?\) -> Bool \{/{f=1} f{print} f&&/^    \}/{exit}' "$manager"
  echo "}"
} > "$out/ChatLive.swift"
if ! grep -q "func hasChatInFlight" "$out/ChatLive.swift"; then
  echo "PRE-FIX: ChatManager.swift has no hasChatInFlight(inProject:) —"
  echo "  nothing can ask whether a folded chat group is waiting on a reply."
  exit 1
fi
if ! grep -q "static func arranged" "$app/Models/AgentSessionGrouping.swift"; then
  echo "PRE-FIX: AgentSessionGrouping.swift has no arranged(...) — a dragged"
  echo "  group order pins every group, so a new session never lifts its"
  echo "  group to the top. That is the gap this harness is for."
  exit 1
fi

if ! swiftc -O -target arm64-apple-macos15.0 -o "$out/groupactivity" \
  "$here/Stubs.swift" \
  "$app/Utilities/DesignSystem.swift" \
  "$app/Models/AgentSessionGrouping.swift" \
  "$out/HeaderLabel.swift" \
  "$out/TaskGlyph.swift" \
  "$out/ChatHeaders.swift" \
  "$out/ChatLive.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log"
  exit 1
fi

# Pass 3 needs a window server. Without one the process would hang
# rather than fail, so it is bounded, and a timeout reads as SKIP —
# passes 1 and 2 have printed their own verdict by then.
set +e
perl -e 'alarm 120; exec @ARGV' "$out/groupactivity" "$root"
status=$?
set -e
if [ $status -eq 142 ] || [ $status -eq 14 ]; then
  echo ""
  echo "SKIP — pass 3 timed out reaching the window server (no GUI session?)."
  echo "       Passes 1 and 2 run anywhere; rerun in a logged-in session"
  echo "       for the rendered header."
  exit 0
fi
exit $status
