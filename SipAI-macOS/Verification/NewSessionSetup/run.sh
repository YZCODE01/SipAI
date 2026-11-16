#!/bin/bash
# A new session is remembered by the + it was started from: what the user
# set up on it — its message, schedule, chips and skills — waits there
# through a trip away and back until its first message uses it up (a task
# created from it takes the message, the schedule and the skills), and a +
# with nothing waiting starts its chips from its group's newest session, or
# the agent's latest choices for no group — never another session's skills
# or a schedule: only the agent's pinned skills. A new session whose first
# message has gone counts as its group's newest from that moment, and keeps
# the chips it went out with though the page moved on before it was named.
# See Page/main.swift for the flows and Structural/main.swift for the shape
# that holds them.
#
#   ./run.sh [source-root]      (default: this checkout's SipAI-macOS)
#
# 1. Structural — reads AppState.swift, AgentSession.swift,
#    AgentSessionView.swift, AgentComposer.swift, AgentSessionsSection.swift,
#    ConfigManager.swift, AgentManager.swift and AgentLaunchOptions.swift.
# 2. The real page — every app source compiled into one test program (the
#    app's `@main` dropped in that copy), the session page hosted in an
#    offscreen window under a throwaway home, with a stand-in claude
#    (stand-in-claude.sh) and two skills of the home's own. The project
#    folders go in ~/Library/Caches and are removed on the way out: the app
#    lists no session whose folder is in a temp folder. No model is
#    called. SipAI links Sparkle, so this pass needs Sparkle's framework:
#    the copy Xcode resolved for the project (build it once), or
#    $SIPAI_SPARKLE_FRAMEWORK (its macos-arm64_x86_64 slice); without one it
#    says SKIP. On appearing the composer asks each installed agent CLI for
#    its models, as the app does — an installed codex answers from the
#    throwaway home too. Whether the pencil shows under a made-up pointer
#    goes through the shared gate (../SyntheticHover): the page runs with
#    macOS reporting the cursor visible, so that pointer reaches SwiftUI, and
#    a SKIP is left for any other cause; the edit itself goes through the message's
#    own Edit this message action, which needs no pointer.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${1:-$here/../..}" && pwd)"
out="$(mktemp -d)"
# The throwaway home's path is kept SHORT on purpose: the app's approver
# socket lives under it, and macOS refuses a socket path past 104 bytes.
home="$(mktemp -d /tmp/nss.XXXXXX)"
mkdir -p "$HOME/Library/Caches"
work="$(mktemp -d "$HOME/Library/Caches/sipai-nss.XXXXXX")"
bundle_id="com.sipai.harness.newsessionsetup"
cleanup() {
  pkill -f "$home/.local/bin/claude" 2>/dev/null
  rm -rf "$out" "$home" "$work"
  defaults delete "$bundle_id" >/dev/null 2>&1
}
trap cleanup EXIT
status=0

swiftc -swift-version 5 -o "$out/structural" "$here/Structural/main.swift" || exit 1
"$out/structural" "$root" || status=1

fw="${SIPAI_SPARKLE_FRAMEWORK:-$(ls -d ~/Library/Developer/Xcode/DerivedData/SipAI-*/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64 2>/dev/null | head -1)}"
if [ -z "$fw" ] || [ ! -d "$fw/Sparkle.framework" ]; then
  echo "  SKIP the real page — no Sparkle framework (build the project in Xcode once, or set SIPAI_SPARKLE_FRAMEWORK)"
  exit $status
fi

src="$out/src"
mkdir -p "$src"
cp -R "$root/SipAI/." "$src/"
if ! grep -q '^@main$' "$src/SipAIApp.swift"; then
  echo "  FAIL SipAIApp.swift has no '@main' line to drop — the copy below is not the app's code"
  exit 1
fi
sed -i '' 's/^@main$//' "$src/SipAIApp.swift"

app="$out/NewSessionSetup.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$src/Resources/approver.py" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleExecutable</key><string>NewSessionSetup</string>
<key>CFBundleName</key><string>NewSessionSetup</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$src" -name '*.swift' -print0)
# The app reads codex's compressed rollouts through a bundled C decoder,
# handed to Swift by the bridging header: both go into the build, as Xcode
# builds them.
objc=()
if [ -f "$src/SipAI-Bridging-Header.h" ]; then
  xcrun clang -O2 -std=gnu17 -c "$src/Vendor/zstd/sipai_zstd.c" -o "$out/zstd.o" || exit 1
  objc=(-import-objc-header "$src/SipAI-Bridging-Header.h" "$out/zstd.o")
fi
echo "compiling the app's ${#files[@]} sources with the replay (about a minute)"
if ! swiftc -swift-version 5 -D DEBUG -Onone -target "$(uname -m)-apple-macos15.0" \
     -F "$fw" -framework Sparkle -Xlinker -rpath -Xlinker "$fw" \
     -o "$app/Contents/MacOS/NewSessionSetup" "${files[@]}" ${objc[@]+"${objc[@]}"} \
     "$here/../SyntheticHover/SyntheticHover.swift" "$here/Page/main.swift" 2> "$out/build.err"; then
  grep -E 'error' "$out/build.err" | head -10
  echo "  FAIL the app's sources did not compile with the replay"
  exit 1
fi

mkdir -p "$home/.local/bin" "$work/proj" "$work/proj2" \
  "$home/.claude/skills/demo" "$home/.claude/skills/extra"
cp "$here/stand-in-claude.sh" "$home/.local/bin/claude"
chmod +x "$home/.local/bin/claude"
# A made-up claude.ai login, so the app counts the stand-in as signed in.
printf '%s' '{"oauthAccount":{"accountUuid":"00000000-0000-4000-8000-000000000001","emailAddress":"example-user@example.com","organizationUuid":"00000000-0000-4000-8000-000000000002","billingType":"stripe_subscription","organizationType":"claude_max"},"hasCompletedOnboarding":true}' \
  > "$home/.claude.json"
printf -- '---\nname: demo\ndescription: A skill for the replay\n---\nSay that the demo skill loaded.\n' \
  > "$home/.claude/skills/demo/SKILL.md"
printf -- '---\nname: extra\ndescription: Another skill for the replay\n---\nSay that the extra skill loaded.\n' \
  > "$home/.claude/skills/extra/SKILL.md"

source "$here/../SyntheticHover/cursor_visible.sh"
cursor_preload "$out" || { echo "  FAIL cursor_visibility.c did not build"; exit 1; }
# Foundation reads its home from CFFIXED_USER_HOME (it ignores HOME); the
# children the app starts read HOME. The page sees macOS report the cursor
# visible, so a made-up pointer reaches SwiftUI (../SyntheticHover).
( export HOME="$home" CFFIXED_USER_HOME="$home"
  cursor_visible "$app/Contents/MacOS/NewSessionSetup" "$home" "$work/proj" "$work/proj2" ) &
pid=$!
( sleep 420; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
watchdog=$!
disown "$watchdog"
wait "$pid" || status=1
kill "$watchdog" 2>/dev/null
exit $status
