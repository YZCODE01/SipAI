#!/bin/bash
# Headless check of AgentSessionRename — the write that carries a rename
# out of SipAI and into the agent's own session store.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, and the Xcode project references its sources explicitly, so
# these files are never compiled into the product.
#
# It compiles the REAL AgentSessionRename.swift against a stand-in for
# the one KimiSessionScanner helper it calls, and runs it over throwaway
# stores under $TMPDIR. It never touches ~/.claude or ~/.kimi-code.
#
# Run it after any change to AgentSessionRename.swift, and after a
# Claude Code or Kimi Code upgrade. The failures this catches are all
# silent ones — the sidebar shows the new name whether or not the write
# landed, so the only symptom of a broken rule is the CLI's own picker
# still showing the old name.
#
# The one rule worth knowing before editing: claude locates the title
# record by testing each line for the literal substring
# `"type":"custom-title"` BEFORE parsing it. Pretty-print that record
# and the rename does nothing, with no error anywhere.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/renameharness" \
  "$here/Stubs.swift" "$here/main.swift" \
  "$here/../../SipAI/Models/AgentSessionRename.swift"
"$out/renameharness" "$@"
