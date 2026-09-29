#!/bin/bash
# Headless check of the tool-approval cards an agent session draws for
# claude, and of the plan card that ends a Plan-mode turn.
#
# What fails silently here, which is why it is pinned:
#
#  * A new session's FIRST turn is spawned from a draft, so its child
#    carries SIPAI_SESSION_ID = the draft's task uuid for its whole life,
#    while claude names the real session id in its first second and the
#    runner adopts it. A card filter that matches on the session id alone
#    draws none of that turn's approvals: each sits in MCPBridge.pending
#    unseen, the turn waits on it forever, and Stop answers it "Denied by
#    SipAI.". Plan mode meets it nearly every time, since its one approval
#    (ExitPlanMode) ends a planning turn that is usually the session's
#    first.
#  * ExitPlanMode is a plan, not a tool call: the generic permission card
#    would show it as a 260-character JSON line under Allow / Deny /
#    Always. The plan card asks what claude's own terminal asks — approve
#    and accept edits, approve and ask before edits, keep planning — and
#    an approval moves the session's chip off Plan, or the next turn
#    would plan again.
#
# Section 1 and 2 are the pure rules. Section 3 runs the REAL
# MCPBridge.swift (compiled whole, its socket in a throwaway directory)
# against the REAL approver.py, reading back exactly what claude would
# receive. Section 4 drives the REAL claude over a fake Messages endpoint
# (plan_server.py) through that bridge — a first turn, a resumed turn,
# a plan approved with accept edits, a plan kept — under throwaway
# config directories. Token-free; SKIP when claude is not installed.
# Section 5 reads the shipping sources for the wiring. Section 6 runs a
# second real bridge beside the first, the way two copies of SipAI share
# mcp/: a quit must remove only the socket that copy bound.
#
# The harness binary is wrapped in a minimal .app: the bridge talks to
# Notification Center, which refuses a process without a bundle.
#
#   ./run.sh                  # this checkout
#   ./run.sh <source-root>    # another checkout
#
# Run it after a Claude Code upgrade: the plan tool's name and input, the
# permission-prompt result shape and `setMode` are claude's to change.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

bridge="$src/SipAI/Models/MCPBridge.swift"
approver="$src/SipAI/Resources/approver.py"
for f in "$bridge" "$approver"; do
  if [ ! -f "$f" ]; then
    echo "PRE-FIX: $f does not exist — nothing to test."
    exit 1
  fi
done
if ! grep -q "static func request(sessionId requestSessionId" "$bridge"; then
  echo "PRE-FIX: MCPBridge.swift has no ownership rule (MCPBridge.request(sessionId:…))."
  echo "  A first turn's approval cards are matched on the session id alone and"
  echo "  never drawn — the failure this harness exists for."
  exit 1
fi

mkdir -p "$out/mcp" "$out/work" "$out/Harness.app/Contents/MacOS"
cp "$approver" "$out/mcp/approver.py"
cat > "$out/Harness.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.sipai.harness.approvalcards</string>
<key>CFBundleExecutable</key><string>harness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

if ! swiftc -O -o "$out/Harness.app/Contents/MacOS/harness" \
  "$here/Stubs.swift" "$bridge" "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi
APPROVAL_HARNESS_MCP_DIR="$out/mcp" \
  "$out/Harness.app/Contents/MacOS/harness" "$src" "$out/work" "$here"
