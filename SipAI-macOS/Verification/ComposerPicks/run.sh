#!/bin/bash
# The composer's chips: a pick is saved where it is made, and SipAI's own
# updates of the chips are never saved as one. See Structural/main.swift
# for the hazard and the shape that cannot have it.
#
#   ./run.sh [source-root]      (default: this checkout's SipAI-macOS)
#
# 1. Structural — reads AgentSessionView.swift.
# 2. The real page — every app source compiled into one test program (the
#    app's `@main` dropped and `ConfigManager` unsealed in that copy, so the
#    saves can be counted), the session page hosted in an offscreen window
#    under a throwaway home, and a stand-in claude (stand-in-claude.sh) that
#    starts a turn and keeps it running; the chips are pressed through
#    accessibility, as an assistive client presses them. No model is
#    called. SipAI links Sparkle, so this pass needs Sparkle's framework:
#    the copy Xcode resolved for the project (build it once), or
#    $SIPAI_SPARKLE_FRAMEWORK (its macos-arm64_x86_64 slice); without one it
#    says SKIP. On appearing the composer asks each installed agent CLI for
#    its models, as the app does — an installed codex answers from the
#    throwaway home too.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${1:-$here/../..}" && pwd)"
out="$(mktemp -d)"
# The throwaway home's path is kept SHORT on purpose: the app's approver
# socket lives under it, and macOS refuses a socket path past 104 bytes.
home="$(mktemp -d /tmp/cpk.XXXXXX)"
bundle_id="com.sipai.harness.composerpicks"
cleanup() {
  # A turn's stand-in waits as `sleep` (it execs), so it is stopped by the
  # pid it wrote down — and only while that pid is still the stand-in's.
  if [ -f "$home/stand-in.pids" ]; then
    while read -r p; do
      [ "$(ps -o command= -p "$p" 2>/dev/null)" = "sleep 600" ] && kill "$p" 2>/dev/null
    done < "$home/stand-in.pids"
  fi
  rm -rf "$out" "$home"
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
sealed='^final class ConfigManager: ObservableObject {$'
if ! grep -q "$sealed" "$src/Models/ConfigManager.swift"; then
  echo "  FAIL 'final class ConfigManager: ObservableObject {' not found — the saves could not be counted"
  exit 1
fi
sed -i '' "s/$sealed/class ConfigManager: ObservableObject {/" "$src/Models/ConfigManager.swift"

app="$out/ComposerPicks.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$src/Resources/approver.py" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleExecutable</key><string>ComposerPicks</string>
<key>CFBundleName</key><string>ComposerPicks</string>
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
     -o "$app/Contents/MacOS/ComposerPicks" "${files[@]}" ${objc[@]+"${objc[@]}"} \
     "$here/Page/main.swift" 2> "$out/build.err"; then
  grep -E 'error' "$out/build.err" | head -10
  echo "  FAIL the app's sources did not compile with the replay"
  exit 1
fi

mkdir -p "$home/.local/bin" "$home/proj"
cp "$here/stand-in-claude.sh" "$home/.local/bin/claude"
chmod +x "$home/.local/bin/claude"
# A made-up claude.ai login, so the app counts the stand-in as signed in.
printf '%s' '{"oauthAccount":{"accountUuid":"00000000-0000-4000-8000-000000000001","emailAddress":"example-user@example.com","organizationUuid":"00000000-0000-4000-8000-000000000002","billingType":"stripe_subscription","organizationType":"claude_max"},"hasCompletedOnboarding":true}' \
  > "$home/.claude.json"

# Foundation reads its home from CFFIXED_USER_HOME (it ignores HOME); the
# children the app starts read HOME.
HOME="$home" CFFIXED_USER_HOME="$home" "$app/Contents/MacOS/ComposerPicks" "$home" &
pid=$!
( sleep 150; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
watchdog=$!
disown "$watchdog"
wait "$pid" || status=1
kill "$watchdog" 2>/dev/null
exit $status
