#!/bin/bash
# Headless check of CodexSessionScanner.lastContextTokens — the read
# behind the composer's token chip on a codex session.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# Run it after a codex-cli upgrade. The synthetic cases pin the rules
# (last_token_usage vs the cumulative block, newest-wins, the old
# zero-components schema, the escalating tail); the real-store pass at
# the end is what notices that the rollout format moved.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/codexctxharness" \
  "$here/Stubs.swift" "$here/main.swift" \
  "$here/../../SipAI/Models/CodexSessions.swift"
"$out/codexctxharness" "$@"
