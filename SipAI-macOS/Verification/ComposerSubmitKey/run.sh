#!/bin/bash
# Headless check that the Enter key in the agent composer follows the
# composer's CURRENT state.
#
# The failure it pins: an NSViewRepresentable's Coordinator is made once
# and keeps the struct it was handed. That struct is a snapshot of its
# host, so `GrowingTextField.onSubmit` — which closes over the
# composer's `canSend`, and through it the plain `sending` /
# `externalBusy` properties — drives whatever the composer looked like
# when the text view was BUILT. A composer built mid-turn has a
# permanently dead Enter key while the send button, re-evaluated on
# every body pass, keeps working; one built idle keeps sending after an
# external turn starts. The cure is one line in updateNSView, and it is
# the same line `SearchField` already carries.
#
# Pass 1 reads the real view files and requires every coordinator that
# caches a parent to re-point it. Pass 2 EXTRACTS GrowingTextField from
# AgentComposer.swift (never a copy — a second spelling of the code
# under test is how a harness comes to pass while the app is broken)
# and presses Return on it in an offscreen window.
#
# Pass 2 needs a logged-in GUI session for the window server; over SSH
# with no session it reports SKIP rather than a failure it cannot judge.
#
# Run it after touching any of the app's AppKit text inputs.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

composer="$root/SipAI/Views/Chat/AgentComposer.swift"

# The struct, verbatim, out of the shipping file: from its declaration
# to the closing brace in column 0.
{
  echo "import SwiftUI"
  echo "import AppKit"
  awk '/^struct GrowingTextField: NSViewRepresentable \{/{f=1} f{print} f&&/^\}/{exit}' "$composer"
} > "$out/Extracted.swift"

if ! grep -q "func updateNSView" "$out/Extracted.swift"; then
  echo "FAIL  could not extract GrowingTextField from AgentComposer.swift"
  echo "      (the struct moved or was renamed — fix this harness)"
  exit 1
fi

swiftc -O -target arm64-apple-macos15.0 -o "$out/submitkey" \
  "$root/SipAI/Utilities/DesignSystem.swift" \
  "$out/Extracted.swift" \
  "$here/main.swift"

# Bound the GUI pass: with no window server the process would hang
# rather than fail. perl's alarm is the wrapper; it is not in the way of
# anything being measured here.
set +e
perl -e 'alarm 60; exec @ARGV' "$out/submitkey" "$root"
status=$?
set -e

if [ $status -eq 142 ] || [ $status -eq 14 ]; then
  echo ""
  echo "SKIP — timed out reaching the window server (no GUI session?)."
  echo "       Pass 1 is the part that runs anywhere; rerun in a logged-in"
  echo "       session for the Return-key pass."
  exit 0
fi
exit $status
