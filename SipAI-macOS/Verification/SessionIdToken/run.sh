#!/bin/bash
# "Copy session ID" and the grey token a session id becomes in the agent
# composer: the token rule, the grey (a sidebar row's hover grey, over the
# same surface), the REAL composer field rendered offscreen — the token
# behind the id in the hover's own pixels, hugging the glyphs at Large
# text mode, following an edit, one coat where two ids' margins overlap,
# free of spelling dots — the copy pasted back from a private pasteboard,
# and the wiring.
#
# The field types are EXTRACTED from the shipping files, never copied:
# GrowingTextField out of AgentComposer.swift, DropForwardingTextView and
# MultilineTextField out of MessageInput.swift. Needs a logged-in GUI
# session for the window server; without one it reports SKIP.
# SESSION_ID_TOKEN_RENDER=<dir> writes the renders as PNGs.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

composer="$root/SipAI/Views/Chat/AgentComposer.swift"
input="$root/SipAI/Views/Chat/MessageInput.swift"
{
  echo "import SwiftUI"
  echo "import AppKit"
  awk '/^struct GrowingTextField: NSViewRepresentable \{/{f=1} f{print} f&&/^\}/{exit}' "$composer"
  awk '/^struct MultilineTextField: NSViewRepresentable \{/{f=1} f{print} f&&/^\}/{exit}' "$input"
  awk '/^final class DropForwardingTextView: NSTextView \{/{f=1} f{print} f&&/^\}/{exit}' "$input"
} > "$out/Extracted.swift"
for symbol in "struct GrowingTextField" "struct MultilineTextField" "final class DropForwardingTextView"; do
  grep -q "$symbol" "$out/Extracted.swift" || {
    echo "FAIL  could not extract \"$symbol\" (it moved or was renamed — fix this harness)"
    exit 1
  }
done

if ! swiftc -O -target arm64-apple-macos15.0 -o "$out/sessionidtoken" \
  "$root/SipAI/Utilities/DesignSystem.swift" \
  "$out/Extracted.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

set +e
perl -e 'alarm 120; exec @ARGV' "$out/sessionidtoken" "$root"
status=$?
set -e
if [ $status -eq 142 ] || [ $status -eq 14 ]; then
  echo ""
  echo "SKIP — timed out reaching the window server (no GUI session?)."
  exit 0
fi
exit $status
