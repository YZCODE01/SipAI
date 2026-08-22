#!/bin/bash
# Headless check of chat-turn delivery — what happens to a reply the
# user asked for and then clicked away from.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# It compiles the REAL ChatManager.swift against a stand-in for
# SipaiPaths and runs it over a throwaway data directory under $TMPDIR.
# It never touches ~/Library/Application Support/SipAI. The second pass
# READS ChatView.swift rather than restating its rules — a third copy of
# a rule is how a harness comes to pass while the app is broken.
#
# Run it after any change to the chat send path. The failure it guards
# is silent: the reply lands on disk, the open pane never shows it, and
# that pane's next save writes over it.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/chatturnharness" \
  "$here/Stubs.swift" "$here/main.swift" \
  "$here/../../SipAI/Models/ChatManager.swift"
# An explicit source root overrides, so the structural pass can be
# pointed at an older checkout to confirm it still catches the bug.
"$out/chatturnharness" "${1:-$here/../..}"
