#!/bin/bash
# Headless check of the sidebar's ⋮ menus on its section and group
# headers — Hide on Notes, Chats and Chat groups (and the Settings →
# Display switches that bring a section back); Mark all as read and the
# deletes on a Folder or Custom group; the + and ⋮ on Ungrouped; Mark
# all as read on a scheduled task. See the header of main.swift for the
# rules and what each was written for.
#
# Compiled from the SHIPPING AgentSessionGrouping.swift and
# ConfigManager.swift (with the files ConfigManager needs), never a copy
# of either: a harness holding its own copy of a rule passes for the
# wrong reason. Only the row types and ConfigManager's app-level
# neighbours are stubbed. Config is written to a throwaway directory
# under $TMPDIR, never to ~/Library/Application Support/SipAI.
#
# The wiring pass READS the views and the string catalog, and takes a
# source root so it can be pointed at another checkout; against one
# without these menus the build stops at the missing rules (PRE-FIX).
#
# Run it after touching the bucketer, a group or section header, the
# custom-group config, or the Display pane's sidebar switches.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
# Paths inside main.swift are REPO-relative (SipAI-macOS/SipAI/…).
root="$(cd "${1:-$here/../../..}" && pwd)"
app="$root/SipAI-macOS/SipAI"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

if ! grep -q "static func headerActions" "$app/Models/AgentSessionGrouping.swift"; then
  echo "PRE-FIX: AgentSessionGrouping.swift has no headerActions(...) — a group"
  echo "  header carries no ⋮, Ungrouped has no +, and nothing decides either."
  exit 1
fi

# The group-order rule resolves a dragged order through the sidebar's
# one `SidebarOrdering`, which lives among the views; it is pure, so it
# is extracted rather than compiling the whole design system.
awk '/^enum SidebarOrdering \{/{f=1} f{print} f&&/^\}/{exit}' \
  "$app/Utilities/DesignSystem.swift" > "$out/Ordering.swift"

if ! swiftc -O -target arm64-apple-macos15.0 -o "$out/sidebarmenus" \
  "$here/Stubs.swift" "$out/Ordering.swift" \
  "$app/Models/AgentSessionGrouping.swift" \
  "$app/Models/AgentLaunchOptions.swift" \
  "$app/Models/SkillModel.swift" \
  "$app/Models/KimiToolPolicy.swift" \
  "$app/Models/ConfigManager.swift" \
  "$app/Models/ProviderCatalog.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log"
  exit 1
fi
"$out/sidebarmenus" "$root"
