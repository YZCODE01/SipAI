#!/bin/bash
# Renders the REAL Settings → Agent Skills pane, the skill chip's popover in its
# two faces, a skill's detail and the new-skill sheet offscreen, over a
# fixture snapshot, at two tiers in both appearances — see main.swift.
#
# The view files are compiled whole (SkillsPane, SkillSheets,
# SkillPicker, the skill model files, DesignSystem); the three app views
# they borrow are EXTRACTED by text (SearchField, NoteSourceEditor,
# SettingsProminentButton); Stubs.swift stands in for the managers. The
# asset catalog is compiled into the harness's bundle so the robot draws.
# What fills under a made-up pointer goes through the shared gate
# (../SyntheticHover): the pane runs with macOS reporting the cursor visible,
# so that pointer reaches SwiftUI, and a SKIP is left for any other cause.
#
#   ./run.sh
#   SKILLS_PANE_RENDER=<dir> ./run.sh   # also write PNGs to look at
#
# Needs a window server; without one it says SKIP.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../.." && pwd)"
app="$src/SipAI"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

{ echo "import SwiftUI"; echo "import AppKit"
  awk '/^struct SearchField: NSViewRepresentable/{f=1} f{print} f&&/^}$/{exit}' "$app/Views/Chat/TranscriptFind.swift"
  awk '/^struct NoteSourceEditor: NSViewRepresentable/{f=1} f{print} f&&/^}$/{exit}' "$app/Views/Notes/NoteView.swift"
  awk '/^struct SettingsProminentButton/{f=1} f{print} f&&/^}$/{exit}' "$app/Views/Settings/SettingsView.swift"
} > "$out/Extracted.swift"
for want in "struct SearchField" "struct NoteSourceEditor" "struct SettingsProminentButton"; do
  grep -q "$want" "$out/Extracted.swift" || { echo "FAIL could not extract $want"; exit 1; }
done

mkdir -p "$out/Harness.app/Contents/MacOS" "$out/Harness.app/Contents/Resources"
cat > "$out/Harness.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>sipai.verification.skillspane</string>
<key>CFBundleExecutable</key><string>harness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun actool "$app/Resources/Assets.xcassets" --compile "$out/Harness.app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist "$out/partial.plist" >/dev/null 2>"$out/actool.log" \
  || { cat "$out/actool.log"; exit 1; }

m="$app/Models"
if ! swiftc -O -target arm64-apple-macos15.0 -o "$out/Harness.app/Contents/MacOS/harness" \
  "$here/Stubs.swift" \
  "$app/Utilities/DesignSystem.swift" \
  "$m/SkillModel.swift" \
  "$m/SkillOps.swift" \
  "$app/Views/Settings/SkillsPane.swift" \
  "$app/Views/Settings/SkillSheets.swift" \
  "$app/Views/Chat/SkillPicker.swift" \
  "$out/Extracted.swift" \
  "$here/../SyntheticHover/SyntheticHover.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

source "$here/../SyntheticHover/cursor_visible.sh"
cursor_preload "$out" || { echo "  FAIL cursor_visibility.c did not build" >&2; exit 1; }
# The pane sees macOS report the cursor visible, so a made-up pointer reaches
# SwiftUI (../SyntheticHover).
set +e
cursor_visible_within 240 "$out/Harness.app/Contents/MacOS/harness" "$app" | tee "$out/run.log"
status=${PIPESTATUS[0]}
if [ $status -eq 142 ]; then
  # Stopped by the clock. With no window server nothing is ever laid
  # out; once the first page has been, a stop is a page that hung —
  # which a walk up that never ended once was — and not a skip.
  if grep -q "PASS pane lays out" "$out/run.log"; then
    echo "FAIL the harness stopped answering after its first page was laid out"
    exit 1
  fi
  echo "SKIP no window server answered"
  exit 0
fi
exit $status
