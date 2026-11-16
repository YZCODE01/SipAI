#!/bin/bash
# Headless check of the files an agent session's composer attaches: the
# + and a drop stage the chat page's chip in EVERY mode — never the
# file's path typed into the message. Outside Chat only the agent reads
# the file itself, so its path travels as a marker after the user's
# words and the transcript names it on the paperclip line; under Chat
# only the file is read the chat page's way and its content travels.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# Two passes:
#  1. RULES (main.swift) — the REAL AttachmentInline.swift and
#     ChatAttachment.swift, compiled and driven over throwaway files
#     under $TMPDIR: the marker and what the readers make of it, staging
#     per mode, the switch into Chat only, a scheduled task's prompt,
#     the chips — then each INSTALLED claude, codex and kimi runs one
#     ordinary turn against a FAKE local model endpoint
#     (../ChatOnlyMode/fake_server.py: records every request, answers
#     "OK") under a throwaway home, sent the message the composer builds:
#     what reached the model, and what the CLI recorded, are read back.
#     Token-free; SKIP for a CLI that is not installed.
#  2. WIRING (wiring.swift) — the composer, the session view, the chip
#     row and the string catalog READ, never restated: a third copy of a
#     rule is how a harness comes to pass while the app is broken.
#
# Token-free; touches no agent's own store — unless asked:
#
#   ./run.sh [source-root]
#   SIPAI_AFC_LIVE=1 ./run.sh   # + one REAL short turn per installed CLI
#                               #   (tokens, from the user's own login):
#                               #   does each model open the file a marker
#                               #   names, and answer from it? Claude runs
#                               #   haiku; SIPAI_AFC_LIVE_CODEX_MODEL and
#                               #   SIPAI_AFC_LIVE_KIMI_MODEL name the other
#                               #   two (else their default), at low effort.
#                               #   The sessions land in each tool's REAL
#                               #   store, under /tmp (scratch to SipAI's
#                               #   sidebar); their ids are printed.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

status=0

echo "1. RULES (the real AttachmentInline.swift and ChatAttachment.swift)"
if grep -q "struct AgentAttachment" "$src/SipAI/Models/ChatAttachment.swift" \
   && grep -q "static func referenceMarker" "$src/SipAI/Models/AttachmentInline.swift"; then
  if swiftc -O -o "$out/rules" \
       "$src/SipAI/Models/AttachmentInline.swift" \
       "$src/SipAI/Models/ChatAttachment.swift" \
       "$here/main.swift" 2>"$out/build.log"; then
    SIPAI_AFC_SERVER="$here/../ChatOnlyMode/fake_server.py" "$out/rules" || status=1
  else
    cat "$out/build.log" >&2
    echo "  FAIL the rules did not compile against $src"
    status=1
  fi
else
  echo "  FAIL PRE-FIX: no AgentAttachment / AttachmentInline.referenceMarker in $src —"
  echo "       an agent session's + and drop type the file's path into the message"
  status=1
fi

echo
echo "2. WIRING (the views and the catalog, read)"
swiftc -O -o "$out/wiring" "$here/wiring.swift" 2>"$out/wiring.log" || { cat "$out/wiring.log" >&2; exit 1; }
"$out/wiring" "$src" || status=1

exit $status
