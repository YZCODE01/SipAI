#!/bin/bash
# Headless check that dragging a file onto the chat composer ATTACHES it,
# instead of typing the file's path into the message.
#
# It extracts MultilineTextField and DropForwardingTextView from the
# shipping MessageInput.swift — never a copy, since a second spelling of
# the code under test is how a harness comes to pass while the app is
# broken — hosts the real representable in an offscreen window, and
# delivers a drag carrying a real file URL to whatever text view the
# representable actually installed.
#
# It also re-measures the HAZARD on a stock NSTextView: that a freshly
# built one is registered for no dragged types, and that AppKit registers
# the file types the moment it enters a window. That is why the drop is
# intercepted rather than filtered away, and the day it stops being true
# is the day someone will try the cheap fix again.
#
# Needs a logged-in GUI session for the window server; over SSH with no
# session it reports SKIP rather than a failure it cannot judge.
#
# Run it after touching the chat composer's text input or the attachment
# staging path.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

input="$root/SipAI/Views/Chat/MessageInput.swift"
[ -f "$input" ] || { echo "FAIL  no MessageInput.swift under $root"; exit 1; }

# Both types, verbatim, out of the shipping file: declaration to the
# closing brace in column 0.
{
  echo "import SwiftUI"
  echo "import AppKit"
  awk '/^struct MultilineTextField: NSViewRepresentable \{/{f=1} f{print} f&&/^\}/{exit}' "$input"
  awk '/^final class DropForwardingTextView: NSTextView \{/{f=1} f{print} f&&/^\}/{exit}' "$input"
} > "$out/Extracted.swift"

for symbol in "func updateNSView" "final class DropForwardingTextView"; do
  grep -q "$symbol" "$out/Extracted.swift" || {
    echo "FAIL  could not extract \"$symbol\" from MessageInput.swift"
    echo "      (it moved or was renamed — fix this harness)"
    exit 1
  }
done

swiftc -O -target arm64-apple-macos15.0 -o "$out/filedrop" \
  "$root/SipAI/Utilities/DesignSystem.swift" \
  "$out/Extracted.swift" \
  "$here/main.swift"

# Bound the GUI pass: with no window server the process would hang
# rather than fail. perl's alarm is the wrapper, not part of what is
# being measured.
set +e
perl -e 'alarm 90; exec @ARGV' "$out/filedrop"
status=$?
set -e

if [ $status -eq 142 ] || [ $status -eq 14 ]; then
  echo ""
  echo "SKIP — timed out reaching the window server (no GUI session?)."
  echo "       Rerun in a logged-in session for the drag pass."
  exit 0
fi
exit $status
