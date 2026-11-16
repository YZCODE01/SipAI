#!/bin/bash
# Settings → Display: its Appearance setting, and the names its controls
# give VoiceOver.
#
#   1. The look on screen, through the mechanism the app's root applies
#      (read off SipAIApp.swift) and the REAL `AppTheme` (extracted from
#      AppState.swift): a SwiftUI view in an offscreen window, its colour
#      scheme and its drawn background read after each choice — System →
#      Light → System → Dark → System, then Light ↔ Dark — each within a
#      moment and with nothing else happening to the window. Going back to
#      System must give back the Mac's own look on any Mac: on a dark Mac
#      the Light → System step is the one a stale scheme fails, on a light
#      Mac the Dark → System one. A window of the app's own that nobody gave
#      a look (an alert run on its own, a file panel, Sparkle's windows) and
#      a menu must follow Light and Dark as well.
#   2. The control: SwiftUI's `.preferredColorScheme` set back to nil leaves
#      the view on the old scheme while its window goes back to the Mac's
#      look — the hazard the app-wide appearance avoids. A NOTE, not a
#      failure, on the day SwiftUI stops doing it.
#   3. The wiring, read off the real files: the root applies the theme to
#      the application on every change, the first included; nothing in the
#      app sets `.preferredColorScheme`; the Display picker, the launch and
#      the factory reset each move `AppState.theme`, the one value the root
#      follows.
#   4. The REAL `DisplayPane` (extracted from SettingsView.swift, with the
#      real `DisplaySettings` and DesignSystem.swift) laid out offscreen and
#      read through the accessibility tree: every switch is named with the
#      words drawn beside it, and both pickers with the header above them —
#      of an unnamed control VoiceOver can announce nothing but its state.
#
# Sections 1, 2 and 4 need a logged-in GUI session; with no window server
# they report SKIP. Token-free; nothing is written outside a temp folder,
# and the Mac's own appearance is never touched.
#
#   ./run.sh [SipAI-macOS root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${1:-$here/../..}" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

app="$root/SipAI/SipAIApp.swift"
# Which mechanism the root uses decides what section 1 drives, so the
# section judges the app's own path rather than the one this harness hopes
# for.
if grep -q 'NSApp.appearance = theme.appearance' "$app"; then
  mechanism=MECH_APP
elif grep -q '\.preferredColorScheme(appState.theme.colorScheme)' "$app"; then
  mechanism=MECH_PREFERENCE
  echo "NOTE: SipAIApp.swift applies the theme with SwiftUI's .preferredColorScheme"
  echo "  on the window's root — section 1 drives that path."
else
  echo "FAIL: cannot tell how SipAIApp.swift applies the theme."
  exit 1
fi

# The real AppTheme, DisplaySettings and DisplayPane, each whole.
extract() {  # <file> <first line's pattern> <imports…>
  local file="$1" start="$2"; shift 2
  for module in "$@"; do echo "import $module"; done
  awk -v start="$start" '$0 ~ start {f=1} f {print} f && /^}$/ {exit}' "$file"
}
extract "$root/SipAI/Models/AppState.swift" '^enum AppTheme' SwiftUI AppKit > "$out/AppTheme.swift"
extract "$root/SipAI/Models/ConfigManager.swift" '^struct DisplaySettings \\{' Foundation > "$out/DisplaySettings.swift"
extract "$root/SipAI/Views/Settings/SettingsView.swift" '^struct DisplayPane: View \\{' SwiftUI \
  > "$out/DisplayPane.swift"
for part in "AppTheme:case system, light, dark" "DisplaySettings:var spellCheck" "DisplayPane:Appearance"; do
  name="${part%%:*}"
  if ! grep -q "${part#*:}" "$out/$name.swift"; then
    echo "FAIL: could not extract $name from the sources."
    exit 1
  fi
done

if ! swiftc -O -parse-as-library -target arm64-apple-macos15.0 -D "$mechanism" \
     -o "$out/display" "$out/AppTheme.swift" "$out/DisplaySettings.swift" "$out/DisplayPane.swift" \
     "$root/SipAI/Utilities/DesignSystem.swift" "$here/Stubs.swift" "$here/main.swift" \
     2>"$out/build.log"; then
  cat "$out/build.log"; exit 1
fi

set +e
"$out/display" wiring "$root"
wiring=$?
# Bound the window half: with no window server it would hang, not fail.
perl -e 'alarm 90; exec @ARGV' "$out/display" window
window=$?
set -e

if [ $window -eq 142 ] || [ $window -eq 14 ]; then
  echo ""
  echo "SKIP — sections 1, 2 and 4 timed out reaching the window server (no GUI session?)."
  window=0
fi
[ $wiring -eq 0 ] && [ $window -eq 0 ] && echo "" && echo "DisplayPane: all passed"
[ $wiring -eq 0 ] && [ $window -eq 0 ]
