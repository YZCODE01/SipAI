#!/bin/bash
# Headless check that codex's COMPRESSED rollouts (`.jsonl.zst`) are read
# the way a plain one is — listed, opened, branched from, followed when
# codex unpacks one — through the zstd decoder SipAI bundles. See the
# header of main.swift for the rules and the store they were measured on.
#
# Compiles the bundled decoder (`SipAI/Vendor/zstd/sipai_zstd.c`) and the
# REAL readers; builds throwaway stores under ~/Library/Caches (a rollout
# whose folder is a temp root reads as a probe and is dropped) and removes
# them on the way out. No codex, no network, no token.
#
# An explicit checkout root points the readers at another tree. One from
# before the decoder (no `SessionFileCompression` in it) is compiled
# without it and the store checks are run alone: they fail there, which
# is what makes them worth having.
#
#   mkdir -p /tmp/sipai-before && git -C <repo> archive <rev> | tar -x -C /tmp/sipai-before
#   ./run.sh /tmp/sipai-before
#
# Run it after a Codex upgrade, and after touching any reader that opens
# a rollout by path.
#
#   ./run.sh [checkout-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$(cd "$here/../../.." && pwd)}"
src="$root/SipAI-macOS/SipAI"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

files=(
  "$here/../KimiCode/Stubs.swift"
  "$src/Models/AttachmentInline.swift"
  "$src/Models/SkillModel.swift"
  "$src/Models/ShellCommands.swift" \
  "$src/Models/AgentSession.swift"
  "$src/Models/AgentSessionTailer.swift"
  "$src/Models/AgentEventParsing.swift"
  "$src/Models/CodexSessions.swift"
  "$src/Models/CodexRecordedTools.swift"
  "$src/Models/AgentLaunchOptions.swift"
  "$src/Models/KimiSessions.swift"
  "$src/Models/KimiEventParsing.swift"
)

if grep -q "enum SessionFileCompression" "$src/Models/AgentSession.swift"; then
  xcrun clang -O2 -std=gnu17 -c "$src/Vendor/zstd/sipai_zstd.c" -o "$out/zstd.o"
  swiftc -O -o "$out/compressedrollouts" \
    -import-objc-header "$src/SipAI-Bridging-Header.h" \
    "${files[@]}" "$src/Utilities/ZstdFileDecoder.swift" "$here/main.swift" "$out/zstd.o"
else
  echo "PRE-FIX: $src has no SessionFileCompression — compiled without the"
  echo "  decoder, the store checks alone."
  swiftc -O -D PREFIX -o "$out/compressedrollouts" "${files[@]}" "$here/main.swift"
fi
"$out/compressedrollouts" "$here/fixtures" "$root"
