#!/bin/bash
# Which session did a new kimi turn create? Pins the rule SipAI uses to
# read a draft's session id back off kimi's store — the session holding
# the words the turn sent, and only when exactly one does — and REPRODUCES
# the race it closes: two real `kimi --prompt` runs started together in
# one folder, token-free against ../ChatOnlyMode/fake_server.py under a
# throwaway KIMI_CODE_HOME, each held to the id its own announcement
# names. The rule this replaced ("the newest new directory") is measured
# in the same run and shown to hand both runs one session.
#
# Section 2 needs kimi and python3; without them it reports SKIP. Run it
# after a Kimi Code upgrade: the wire's first-message record, the
# announcement and the refusal of a caller-chosen id are kimi's to move.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

if ! swiftc -O -o "$out/kimidiscovery" \
  "$here/../KimiCode/Stubs.swift" \
  "$root/SipAI/Models/AttachmentInline.swift" \
  "$root/SipAI/Models/AgentSession.swift" \
  "$root/SipAI/Models/AgentSessionTailer.swift" \
  "$root/SipAI/Models/AgentEventParsing.swift" \
  "$root/SipAI/Models/CodexSessions.swift" \
  "$root/SipAI/Models/AgentLaunchOptions.swift" \
  "$root/SipAI/Models/KimiSessions.swift" \
  "$root/SipAI/Models/KimiEventParsing.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

# Bounded: a kimi that never answers would otherwise hold the run.
perl -e 'alarm 180; exec @ARGV' "$out/kimidiscovery" "$root" "$here/../ChatOnlyMode/fake_server.py"
