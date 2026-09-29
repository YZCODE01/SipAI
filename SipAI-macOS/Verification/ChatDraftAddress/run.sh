#!/bin/bash
# A chat's unsent text follows the chat, never its old address: pins the
# composer-draft store (AppState's section, EXTRACTED from the shipping
# file) and the chat views' wiring — a new chat's first save, a move, a
# branch, a deleted chat, a deleted group. Headless.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

appstate="$root/SipAI/Models/AppState.swift"
{
  echo "import Foundation"
  echo "struct ChatAttachment {}"
  echo "@MainActor final class AppState {"
  # The draft section, verbatim: its MARK down to the doc comment of the
  # routing helper that follows it.
  awk '/^    \/\/ MARK: - Composer drafts$/{f=1} /^    \/\/\/ Clear all four routing fields/{f=0} f{print}' "$appstate"
  echo "}"
} > "$out/Extracted.swift"
grep -q "func setComposerDraft" "$out/Extracted.swift" || {
  echo "FAIL  could not extract the composer-draft section from AppState.swift"
  exit 1
}

if ! swiftc -O -o "$out/chatdraftaddress" "$out/Extracted.swift" "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi
"$out/chatdraftaddress" "$root"
