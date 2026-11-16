#!/bin/bash
# Headless checks for the first-launch welcome page and the size the
# first window opens at, compiled from the REAL sources (never copies):
# `WelcomePage` is cut out of OnboardingView.swift and `FirstWindowSize`
# out of SipAIApp.swift, and built with the real DesignSystem.swift.
#
#   §1  The first window's size: about 70 % of the screen's free area,
#       held between the welcome page's floor (720 × 540) and 1200 × 800,
#       never larger than the area, whole points.
#   §2  The page laid out and drawn offscreen at the floor size, light and
#       dark: it fits with room above and below, its column is centred,
#       its symbols and button are drawn in SipAI's blue.
#       WELCOME_PAGE_RENDER=<dir> writes the PNGs.
#   §3  What the sources say: macOS's own text styles at their own line
#       heights (no 12.5 pt text, no added line spacing, no circles behind
#       the symbols, and no colour left over for them), the system's large
#       prominent button, the window
#       placed by the rule instead of a fixed 720 × 540.
#
# Pointed at a tree that predates the change (`./run.sh <source-root>`),
# the two pieces are not there to cut out: §1 and §2 fail, and §3 says
# what the old sources hold.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$here/../..}"
root="$(cd "$root" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# A top-level declaration, from its first line to the closing brace at
# the start of a line.
cut_out() { # file pattern
  awk -v pat="$2" '
    !inside && $0 ~ pat { inside = 1 }
    inside { print }
    inside && /^}/ { exit }
  ' "$1"
}

flags=()
cut_out "$root/SipAI/Views/OnboardingView.swift" '^(private )?struct WelcomePage: View' > "$out/page.part"
cut_out "$root/SipAI/SipAIApp.swift" '^enum FirstWindowSize' > "$out/size.part"
[ -s "$out/page.part" ] && flags+=(-D WELCOME_PAGE)
[ -s "$out/size.part" ] && flags+=(-D FIRST_WINDOW_SIZE)
{ echo "import SwiftUI"; cat "$out/page.part"; } > "$out/WelcomePage.swift"
{ echo "import SwiftUI"; cat "$out/size.part"; } > "$out/FirstWindowSize.swift"

swiftc -O -target arm64-apple-macos15.0 "${flags[@]}" -o "$out/welcome" \
  "$root/SipAI/Utilities/DesignSystem.swift" \
  "$out/WelcomePage.swift" \
  "$out/FirstWindowSize.swift" \
  "$here/main.swift"

# The page names its logo from the asset catalog: compiled beside the
# binary, where a command-line tool's main bundle looks for it, the
# logo takes its real room and is drawn.
xcrun actool --compile "$out" --platform macosx --minimum-deployment-target 15.0 \
  --output-format human-readable-text "$root/SipAI/Resources/Assets.xcassets" >/dev/null

"$out/welcome" "$root"
