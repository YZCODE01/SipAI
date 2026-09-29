#!/bin/bash
# Headless check of Settings as a mode of the main window — the menu over
# the sidebar's Settings row, the sidebar's list of sections while
# Settings is open, the page's centred column, and the wiring that makes
# Settings a layer over the routes. See the header of main.swift for the
# four passes.
#
# Everything under test is compiled from the SHIPPING sources, never
# copied: SettingsNavigation.swift, SettingsPageLayout.swift and
# DesignSystem.swift whole, and — EXTRACTED by text, because the files
# around them need the whole app — AppState's settings members, the
# section enum, the page's `body`, the prompt pane and its three buttons
# from SettingsView.swift, the download badge's glyph from
# LeftSidebar.swift, and the overlay that places the menu from
# ContentView.swift. Stubs.swift carries only what those reference
# (managers that hold nothing but the prompt pane's roles, a recording
# factory reset).
#
# An explicit source root points it at another checkout (the SipAI-macOS
# directory). Against a tree where Settings is still a sheet it stops
# before the build — the files it reads do not exist there.
#
#   ./run.sh [source-root]
#   SETTINGS_NAV_RENDER=<dir> ./run.sh      # also write PNGs to look at
#
# Run it after touching Settings' navigation, the page's layout, the
# sidebar's bottom row, or ContentView's router.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${1:-$here/../..}" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

if [ ! -f "$root/SipAI/Views/Settings/SettingsNavigation.swift" ] \
   || [ ! -f "$root/SipAI/Utilities/SettingsPageLayout.swift" ]; then
  echo "PRE-FIX: no SettingsNavigation.swift / SettingsPageLayout.swift —"
  echo "  Settings is still a sheet over the window. That is the shape this"
  echo "  harness exists to hold the new one against."
  exit 1
fi

# AppState's settings members, in a class that holds nothing else.
{
  echo "import SwiftUI"
  echo "import Combine"
  echo "@MainActor"
  echo "final class AppState: ObservableObject {"
  echo "    @Published var leftSidebarVisible: Bool = true"
  awk '/^    @Published var settingsSection: /{f=1} f{print} /^    func openSettings\(/{g=1} g&&/^    \}$/{exit}' \
    "$root/SipAI/Models/AppState.swift"
  echo "}"
} > "$out/AppStateSettings.swift"
if ! grep -q "func openSettings" "$out/AppStateSettings.swift"; then
  echo "PRE-FIX: AppState.swift has no settingsSection / openSettings."
  exit 1
fi

# The section enum and the page's own body, around a stand-in pane.
settings="$root/SipAI/Views/Settings/SettingsView.swift"
{
  echo "import SwiftUI"
  echo "struct SettingsView: View {"
  awk '/^    enum Tab: String, CaseIterable, Identifiable \{/{f=1} f{print} f&&/^    \}$/{exit}' "$settings"
  echo "    let section: Tab"
  echo "    @Environment(\\.sipFontScale) private var fontScale"
  echo "    init(section: Tab) { self.section = section }"
  awk '/^    var body: some View \{/{f=1} f{print} f&&/^    \}$/{exit}' "$settings"
  echo "    @ViewBuilder private func pane(_ proxy: ScrollViewProxy) -> some View { HarnessPane(section: section) }"
  echo "}"
} > "$out/SettingsPage.swift"
if ! grep -q "SettingsPageLayout(viewport:" "$out/SettingsPage.swift"; then
  echo "PRE-FIX: the Settings page does not lay itself out by SettingsPageLayout."
  exit 1
fi

# The chat prompt pane and the three buttons it draws, whole.
{
  echo "import SwiftUI"
  echo "import AppKit"
  for name in PromptAndRolesPane SettingsTextButton SettingsProminentButton SettingsTrashButton; do
    awk -v n="$name" '$0 ~ "^struct " n ": View \\{" {f=1} f{print} f&&/^\}$/{exit}' "$settings"
  done
} > "$out/PromptPane.swift"
if ! grep -q "^struct PromptAndRolesPane: View {" "$out/PromptPane.swift"; then
  echo "PRE-FIX: SettingsView.swift has no PromptAndRolesPane."
  exit 1
fi

# The download badge's glyph.
{
  echo "import SwiftUI"
  awk '/^struct UpdateBadgeGlyph: View \{/{f=1} f{print} f&&/^\}$/{exit}' \
    "$root/SipAI/Views/Sidebar/LeftSidebar.swift"
} > "$out/BadgeGlyph.swift"

# The menu's placement: ContentView's own overlay block — the modifier
# chain that reads the Settings row's anchor and puts the real menu over
# it — extracted by text and hung on a stand-in of the layout it sits on
# (a sidebar column ending in a Settings-shaped row, a pane beside it).
{
  echo "import SwiftUI"
  echo "@MainActor enum MenuMeasure { static var row: CGRect = .zero }"
  echo "struct MenuOverlayProbe: View {"
  echo "    @State private var showingSettingsMenu = true"
  echo "    let sidebarWidth: CGFloat"
  echo "    var body: some View {"
  echo "        HStack(spacing: 0) {"
  echo "            VStack(spacing: 0) {"
  echo "                Color.clear"
  echo "                Button {} label: {"
  echo "                    Text(verbatim: \"Settings\").frame(maxWidth: .infinity, alignment: .leading)"
  echo "                        .padding(.horizontal, 12).padding(.vertical, 10)"
  echo "                }"
  echo "                .buttonStyle(.plain)"
  echo "                .anchorPreference(key: SettingsMenuAnchorKey.self, value: .bounds) { \$0 }"
  echo "                .onGeometryChange(for: CGRect.self) { \$0.frame(in: .named(\"probe\")) } action: { MenuMeasure.row = \$0 }"
  echo "            }"
  echo "            .frame(width: sidebarWidth)"
  echo "            Color.clear.frame(maxWidth: .infinity)"
  echo "        }"
  awk '/\.overlayPreferenceValue\(SettingsMenuAnchorKey\.self\)/{f=1} f{print} f&&/^        }$/{exit}' \
    "$root/SipAI/Views/ContentView.swift"
  echo "        .coordinateSpace(.named(\"probe\"))"
  echo "    }"
  echo "}"
} > "$out/MenuOverlay.swift"
if ! grep -q "SettingsLauncherMenu(isPresented: \$showingSettingsMenu)" "$out/MenuOverlay.swift"; then
  echo "PRE-FIX: ContentView.swift draws no SettingsLauncherMenu over the Settings row's anchor."
  exit 1
fi

if ! swiftc -O -target arm64-apple-macos15.0 -o "$out/settingsnav" \
  "$here/Stubs.swift" \
  "$out/AppStateSettings.swift" \
  "$out/SettingsPage.swift" \
  "$out/PromptPane.swift" \
  "$out/BadgeGlyph.swift" \
  "$out/MenuOverlay.swift" \
  "$root/SipAI/Utilities/DesignSystem.swift" \
  "$root/SipAI/Utilities/SettingsPageLayout.swift" \
  "$root/SipAI/Views/Settings/SettingsNavigation.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log"
  exit 1
fi

# Passes 2 and 3 need a window server. Without one the process would hang
# on the window rather than fail, so it is bounded, and a timeout reads
# as SKIP — pass 1 has printed its verdict by then.
set +e
perl -e 'alarm 120; exec @ARGV' "$out/settingsnav" "$root"
status=$?
set -e
if [ $status -eq 142 ] || [ $status -eq 14 ]; then
  echo ""
  echo "SKIP — the rendered passes timed out reaching the window server (no"
  echo "       GUI session?). Pass 1 runs anywhere; rerun in a logged-in"
  echo "       session for the rest."
  exit 0
fi
exit $status
