#!/bin/bash
# Headless check of the codex context-window feature: the "?" on the
# composer's context chip, the Help card behind it, and the one-click
# switch that raises `model_context_window` THROUGH codex.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# Four things regress silently here, which is why they are pinned:
#
#  * The ARITHMETIC. Codex clamps the user's `model_context_window` to
#    each model's `max_context_window` and leaves a percentage usable;
#    the card states default and maximum per model from the same
#    catalog the picker reads. Read the raw window instead and every
#    number on the card is wrong by 5 %, with nothing erroring.
#  * The WRITE. It goes through `codex app-server`'s
#    `config/value/write` — codex's own writer, codex's own schema — and
#    a null REMOVES the key. SipAI writes no TOML. The real client is
#    driven here against the real codex over a throwaway CODEX_HOME:
#    zero tokens, no sign-in, and the real ~/.codex is never touched.
#  * The WIRING. The glyph appears on codex sessions only, the session
#    view observes the catalog (or the chip never moves after a write),
#    and the deep link lands on the card whose id the topic names.
#  * The STRINGS. Every new key must carry a zh-Hans value, or the
#    Chinese UI comes up half English.
#
# Run it after any codex-cli upgrade: the write RPC is marked
# experimental by codex, the cache schema is theirs, and the clamp is
# read from their source.
#
#   ./run.sh                    # this checkout
#   ./run.sh <source-root>      # another checkout, e.g. to watch it fail
#   SIPAI_CXWIN_LIVE=1 ./run.sh # + two real codex turns (a few tokens)
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

model="$src/SipAI/Models/AgentCLIUpdates.swift"

# The app-server client and the config write, EXTRACTED VERBATIM from
# the shipping file the way Verification/CLIUpdates extracts its
# subjects — a harness holding its own copy of the client passes for
# the wrong reason. A top-level `}` in column 1 closes each declaration.
{
  echo "import Foundation"
  for decl in "struct CLIVersion" "struct CLIBinaryFingerprint" "enum AgentCLIProbe" \
              "enum CodexAppServerCall" "enum CodexModelListRefresh" \
              "enum CodexConfigWrite" "extension CodexConfigRead"; do
    awk -v pat="^${decl}[ :]" '$0 ~ pat, /^\}/' "$model"
    echo
  done
} > "$out/Extracted.swift"

for required in "enum CodexConfigWrite" "static func request(keyPath:" \
                "static func outcome(from" "enum CodexAppServerCall"; do
  if ! grep -q "$required" "$out/Extracted.swift"; then
    echo "PRE-FIX: '$required' is not in $model —"
    echo "  this checkout has no config write to check. That is the"
    echo "  failure this harness is for."
    exit 1
  fi
done

if ! swiftc -O -o "$out/cxwin" \
  "$here/Stubs.swift" "$out/Extracted.swift" "$here/main.swift" \
  "$src/SipAI/Models/AttachmentInline.swift" \
  "$src/SipAI/Models/AgentSession.swift" \
  "$src/SipAI/Models/AgentEventParsing.swift" \
  "$src/SipAI/Models/CodexSessions.swift" \
  "$src/SipAI/Models/CodexEventParsing.swift" \
  "$src/SipAI/Models/KimiSessions.swift" \
  "$src/SipAI/Models/KimiEventParsing.swift" \
  "$src/SipAI/Models/AgentLaunchOptions.swift" \
  "$src/SipAI/Models/KimiToolPolicy.swift" \
  "$src/SipAI/Models/ConfigManager.swift" \
  "$src/SipAI/Models/ProviderCatalog.swift" 2>"$out/build.log"; then
  if grep -q "has no member 'parseModelsCache'\|has no member 'parseConfigDefaults'\|cannot find 'CodexCatalogStamp'" "$out/build.log"; then
    echo "PRE-FIX: this checkout's CodexCatalog has no pure parsers —"
    echo "  the default/maximum split and the config write are absent."
    exit 1
  fi
  cat "$out/build.log" >&2
  exit 1
fi
"$out/cxwin" "$src"
