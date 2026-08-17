#!/bin/bash
# Headless check of FactoryReset — the one action in this app that
# deletes the user's data on purpose.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# It compiles the REAL FactoryReset.swift against recording stand-ins
# for the managers, and runs it over a throwaway data directory under
# $TMPDIR. It never touches ~/Library/Application Support/SipAI.
#
# Run it after any change to FactoryReset.swift, and whenever a new
# @AppStorage key or a new file under the data directory is added —
# both are things a reset silently fails to clear.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/resetharness" \
  "$here/Stubs.swift" "$here/main.swift" \
  "$here/../../SipAI/Models/FactoryReset.swift"
"$out/resetharness" "$@"
