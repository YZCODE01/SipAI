#!/bin/bash
# A sent message's pencil and copy appear while the pointer is over the
# message — including while macOS reports the cursor hidden, the state in
# which SwiftUI's own hover hears nothing (it drops every pointer event and
# ends a hover that is on at its next layout). See main.swift for the checks.
#
#   ./run.sh [source-root]      (default: this checkout's SipAI-macOS)
#
# Every app source is compiled into one test program (the app's `@main`
# dropped in that copy), and the REAL MessageBubble is hosted in a scroll view
# in an offscreen window under a throwaway home. The pointer harnesses' cursor
# library (../SyntheticHover/cursor_visibility.c) is preloaded into that
# program alone: it answers CGCursorIsVisible from $HARNESS_CURSOR_VISIBLE,
# which the checks set as they go. No agent CLI runs and no model is called.
# SipAI links Sparkle, so this needs Sparkle's framework: the copy Xcode
# resolved for the project (build it once), or $SIPAI_SPARKLE_FRAMEWORK (its
# macos-arm64_x86_64 slice); without one it says SKIP.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${1:-$here/../..}" && pwd)"
out="$(mktemp -d)"
home="$(mktemp -d)"
bundle_id="com.sipai.harness.hiddencursorhover"
cleanup() {
  rm -rf "$out" "$home"
  defaults delete "$bundle_id" >/dev/null 2>&1
}
trap cleanup EXIT

fw="${SIPAI_SPARKLE_FRAMEWORK:-$(ls -d ~/Library/Developer/Xcode/DerivedData/SipAI-*/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64 2>/dev/null | head -1)}"
if [ -z "$fw" ] || [ ! -d "$fw/Sparkle.framework" ]; then
  echo "  SKIP — no Sparkle framework (build the project in Xcode once, or set SIPAI_SPARKLE_FRAMEWORK)"
  exit 0
fi

source "$here/../SyntheticHover/cursor_visible.sh"
cursor_preload "$out" || { echo "  FAIL cursor_visibility.c did not build"; exit 1; }

src="$out/src"
mkdir -p "$src"
cp -R "$root/SipAI/." "$src/"
if ! grep -q '^@main$' "$src/SipAIApp.swift"; then
  echo "  FAIL SipAIApp.swift has no '@main' line to drop — the copy below is not the app's code"
  exit 1
fi
sed -i '' 's/^@main$//' "$src/SipAIApp.swift"

app="$out/HiddenCursorHover.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleExecutable</key><string>HiddenCursorHover</string>
<key>CFBundleName</key><string>HiddenCursorHover</string>
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
echo "compiling the app's ${#files[@]} sources with the checks (about a minute)"
if ! swiftc -swift-version 5 -D DEBUG -Onone -target "$(uname -m)-apple-macos15.0" \
     -F "$fw" -framework Sparkle -Xlinker -rpath -Xlinker "$fw" \
     -o "$app/Contents/MacOS/HiddenCursorHover" "${files[@]}" ${objc[@]+"${objc[@]}"} \
     "$here/main.swift" 2> "$out/build.err"; then
  grep -E 'error' "$out/build.err" | head -10
  echo "  FAIL the app's sources did not compile with the checks"
  exit 1
fi

# Foundation reads its home from CFFIXED_USER_HOME (it ignores HOME): the
# app's settings are read from the throwaway one.
( export HOME="$home" CFFIXED_USER_HOME="$home"
  cursor_visible "$app/Contents/MacOS/HiddenCursorHover" ) &
pid=$!
( sleep 300; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
watchdog=$!
disown "$watchdog"
wait "$pid"
status=$?
kill "$watchdog" 2>/dev/null
exit $status
