#!/bin/bash
# Headless check of AgentSessionFork — the one thing in this app that
# WRITES into Claude Code's private session store.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, and the Xcode project references its sources explicitly, so
# these files are never compiled into the product.
#
# Run it after any change to AgentSessionFork.swift, and after a Claude
# Code upgrade that touches the transcript format — the end-to-end pass
# forks a COPY of a real session, so it is the cheapest way to find out
# that the format moved.
#
#   ./run.sh                 # pure rules only
#   ./run.sh <session.jsonl> # + fork a real transcript end to end
#
# Give it a COPY, never a session you care about. The fork never
# modifies its source (there is a check for exactly that), but the
# branch it writes lands in the same directory.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/forkharness" \
  "$here/Stubs.swift" "$here/main.swift" \
  "$here/../../SipAI/Models/AgentSessionFork.swift"
"$out/forkharness" "$@"
