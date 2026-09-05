#!/bin/bash
# Headless check of the composer's CONTEXT CHIP and the compaction rows
# — what the number means, what it is divided by, and what the
# transcript says when an agent summarises itself.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# Three things regress silently here, which is why they are pinned:
#
#  * The NUMERATOR. It is the INPUT side of the newest call — what
#    claude's own indicator and kimi's status bar divide by. Adding the
#    call's reply back in puts this chip a few percent above the
#    terminal the user can hold beside it, and nothing errors.
#  * The WINDOW. Claude's comes from a table inside its own binary
#    (`1e6` is JS source; reading the digits alone answers 1, and a
#    one-token window makes every session read 100%), codex's from
#    `models_cache.json`, kimi's from `config.toml`. A window is never
#    guessed: with none known the chip shows a token count instead.
#  * COMPACTION. The chip legitimately falls by most of its value, and
#    the row is the only thing on screen explaining it. Claude's
#    summary is a user-role record it did not write — unlabelled, it
#    renders as the user's own words on both feeds.
#
# Run it after a Claude Code, codex or kimi upgrade: the binary table,
# the rollout schema and the wire schema are all somebody else's to
# change.
#
#   ./run.sh                 # this checkout
#   ./run.sh <source-root>   # another checkout, e.g. to watch it fail
#
# Optional: SIPAI_CLAUDE_BINARY=<path to a claude executable> adds the
# real binary-table pass (otherwise that section reports SKIP).
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

if [ -z "$SIPAI_CLAUDE_BINARY" ]; then
  latest="$(ls -d "$HOME"/.local/share/claude/versions/* 2>/dev/null | sort -V | tail -1 || true)"
  if [ -x "$latest" ]; then export SIPAI_CLAUDE_BINARY="$latest"; fi
fi

# Pointed at a checkout from before this feature, the subjects simply
# are not there — the resolver, the format rules and the compaction
# signal are all new types. Say so plainly instead of printing a
# compiler wall: an absent subject IS the pre-fix result.
if ! swiftc -O -o "$out/contextchip" \
  "$here/Stubs.swift" "$here/main.swift" \
  "$src/SipAI/Models/AgentSession.swift" \
  "$src/SipAI/Models/AgentEventParsing.swift" \
  "$src/SipAI/Models/CodexSessions.swift" \
  "$src/SipAI/Models/CodexEventParsing.swift" \
  "$src/SipAI/Models/KimiSessions.swift" \
  "$src/SipAI/Models/KimiEventParsing.swift" \
  "$src/SipAI/Models/AgentLaunchOptions.swift" \
  "$src/SipAI/Models/ConfigManager.swift" \
  "$src/SipAI/Models/ProviderCatalog.swift" 2>"$out/build.log"; then
  if grep -q "cannot find 'ContextWindowResolver'\|cannot find 'ContextUsageFormat'\|has no member 'compactingSignal'" "$out/build.log"; then
    echo "PRE-FIX: this checkout has no context chip to check —"
    echo "  the resolver, the shared format rules and the compaction"
    echo "  signal are all absent. That is the failure this harness is for."
    exit 1
  fi
  cat "$out/build.log" >&2
  exit 1
fi
"$out/contextchip" "$src" "$here/fixtures"
