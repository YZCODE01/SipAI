#!/bin/bash
# Headless check of in-app note editing — the rules that decide whether
# an autosave keeps the user's writing or quietly mangles it.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# It compiles the REAL NotesManager.swift against stand-ins for
# SipaiPaths and ChatMessage, and runs it over a throwaway notes
# directory under $TMPDIR. It never touches
# ~/Library/Application Support/SipAI.
#
# Run it after any change to NotesManager.swift — especially to the
# metadata header format, the title fallback chain, or anything that
# writes a note file. The editor saves without asking, so a broken rule
# here has no visible symptom until the damage is already on disk.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/noteharness" \
  "$here/Stubs.swift" "$here/main.swift" \
  "$here/../../SipAI/Models/NotesManager.swift"
"$out/noteharness" "$@"
