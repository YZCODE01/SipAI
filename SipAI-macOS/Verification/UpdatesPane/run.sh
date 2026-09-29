#!/bin/bash
# Headless check that Settings → Updates and the app menu's Check for
# Updates… are the SAME in a copy that may not update itself — built
# locally, `UpdaterAvailability` says `.notDistributionSigned` — as in a
# release copy: the same rows and the same menu item, greyed out, with
# the reason on hover, and no updater behind them. See the header of
# main.swift for the passes.
#
# Everything under test is compiled from the SHIPPING sources, never
# copied: DesignSystem.swift and UpdaterAvailability.swift whole, and —
# EXTRACTED by text, because the files around them need the whole app —
# the pane from SettingsView.swift, the hover sentence from
# UpdateController.swift, and the app menu's update command from
# SipAIApp.swift (hosted in a menu-only probe app, no window, no Dock
# icon, that reads its own menu item back). Stubs.swift carries only
# what those read.
#
# An explicit source root points it at another checkout (the SipAI-macOS
# directory) — against a tree from before this change it fails.
#
#   ./run.sh [source-root]
#   UPDATES_PANE_RENDER=<dir> ./run.sh      # also write PNGs to look at
#
# Run it after touching the Updates pane, the app menu's update command,
# UpdateController's init, noteLaunch or notSelfUpdatingReason, or
# UpdaterAvailability.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${1:-$here/../..}" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

settings="$root/SipAI/Views/Settings/SettingsView.swift"
{
  echo "import SwiftUI"
  awk '/^struct UpdatesPane: View \{/{f=1} f{print} f&&/^\}$/{exit}' "$settings"
} > "$out/UpdatesPane.swift"
if ! grep -q '^struct UpdatesPane: View {' "$out/UpdatesPane.swift"; then
  echo "FAIL: SettingsView.swift has no UpdatesPane to extract."
  exit 1
fi

# The hover sentence, as the controller spells it — onto the stub.
{
  echo "import Foundation"
  echo "extension UpdateController {"
  awk '/^    var notSelfUpdatingReason: String \{/{f=1} f{print} f&&/^    \}$/{exit}' \
    "$root/SipAI/Models/UpdateController.swift"
  echo "}"
} > "$out/Reason.swift"
if ! grep -q 'var notSelfUpdatingReason: String' "$out/Reason.swift"; then
  echo "FAIL: UpdateController.swift has no notSelfUpdatingReason — the hover"
  echo "  the greyed-out controls share is spelled nowhere once."
  exit 1
fi

if ! swiftc -O -target arm64-apple-macos15.0 -o "$out/updatespane" \
  "$here/Stubs.swift" \
  "$out/Reason.swift" \
  "$out/UpdatesPane.swift" \
  "$root/SipAI/Utilities/DesignSystem.swift" \
  "$root/SipAI/Utilities/UpdaterAvailability.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log"
  exit 1
fi

# The app menu's update command, as SipAIApp.swift writes it, in a probe
# app that prints its own menu item's state and exits. A menu-only
# accessory app: it opens no window and takes no Dock icon.
block="$(awk '/CommandGroup\(after: \.appInfo\) \{/{f=1; match($0,/^ */); ind=substr($0,1,RLENGTH)} f{print} f&&$0==ind"}"{exit}' \
  "$root/SipAI/SipAIApp.swift")"
if [ -n "$block" ]; then
  {
    cat <<'SWIFT'
import SwiftUI
import AppKit

final class MenuProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ n: Notification) { NSApp.setActivationPolicy(.accessory) }
    func applicationDidFinishLaunching(_ n: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            var found = false
            for top in NSApp.mainMenu?.items ?? [] {
                for item in top.submenu?.items ?? [] where item.title == "Check for Updates…" {
                    found = true
                    print("enabled=\(item.isEnabled)")
                    // nil and "" are different answers: an empty tooltip
                    // is still a tooltip AppKit may draw.
                    print("tooltip=\(item.toolTip.map { "\"\($0)\"" } ?? "nil")")
                }
            }
            if !found { print("missing") }
            exit(0)
        }
    }
}

@MainActor
func probeController() -> UpdateController {
    let c = UpdateController()
    let local = ProcessInfo.processInfo.environment["UPDATES_PANE_MENU"] == "local"
    c.availability = local ? .notDistributionSigned : .enabled
    c.canCheckForUpdates = !local
    return c
}

@main
struct MenuProbe: App {
    @NSApplicationDelegateAdaptor(MenuProbeDelegate.self) var delegate
    @StateObject private var updateController = probeController()
    var body: some Scene {
        Settings { Text(verbatim: "probe") }
            .commands {
SWIFT
    echo "$block"
    echo "            }"
    echo "    }"
    echo "}"
  } > "$out/MenuProbe.swift"
  if swiftc -parse-as-library -O -target arm64-apple-macos15.0 -o "$out/menuprobe" \
       "$here/Stubs.swift" "$out/Reason.swift" \
       "$root/SipAI/Utilities/UpdaterAvailability.swift" \
       "$out/MenuProbe.swift" 2>"$out/menuprobe.log"; then
    set +e
    for variant in local release; do
      # Two arguments on purpose: perl's `exec` shell-splits a lone one.
      UPDATES_PANE_MENU=$variant perl -e 'alarm 20; exec @ARGV' "$out/menuprobe" --probe \
        > "$out/menu-$variant.txt" 2>/dev/null
    done
    set -e
  else
    echo "menu probe failed to build:" > "$out/menu-build-failed.txt"
    cat "$out/menuprobe.log" >> "$out/menu-build-failed.txt"
  fi
fi

# The rendered pass needs a window server. Without one the process would
# hang on the window rather than fail, so it is bounded, and a timeout
# reads as SKIP — pass 1 has printed its verdict by then.
set +e
perl -e 'alarm 120; exec @ARGV' "$out/updatespane" "$root" "$out"
status=$?
set -e
if [ $status -eq 142 ] || [ $status -eq 14 ]; then
  echo ""
  echo "SKIP — the rendered pass timed out reaching the window server (no"
  echo "       GUI session?). Pass 1 runs anywhere; rerun in a logged-in"
  echo "       session for the rest."
  exit 0
fi
exit $status
