#!/bin/bash
# Headless check of what a model ALIAS is named — the composer's chip,
# the picker rows, and the observed-id map behind both.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# It compiles the REAL AgentLaunchOptions.swift and ConfigManager.swift
# against stand-ins for their app-level neighbours, drives them over a
# throwaway config.json under $TMPDIR, and then READS AgentRunner.swift
# and AgentSessionView.swift for the two rules that live in code this
# cannot instantiate. It never writes
# ~/Library/Application Support/SipAI — section 5 reads it, and only to
# report.
#
# Run it after touching anything that decides a model's NAME or the
# effort levels offered for it, and after every Claude Code upgrade: the
# table both are read from is an object literal inside claude's
# executable, in a shape that is Anthropic's to change. Sections 12 and
# 13 parse whatever claude is installed here, and section 14 RUNS it —
# one-line turns against the local fake endpoint in ../ChatOnlyMode
# (junk key, throwaway config directory; no provider is reached and no
# token is spent) — to hold the levels the picker offers to what claude
# actually sends. The whole class of bug here is silent and permanent:
# a wrong pairing does not fail, it renames a model in every picker on
# the machine, and it renames it again after a relaunch.
#
#   ./run.sh                 # this checkout
#   ./run.sh <source-root>   # another checkout, e.g. to watch it fail
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/modelchipharness" \
  "$here/Stubs.swift" "$here/main.swift" \
  "$here/../../SipAI/Models/AgentLaunchOptions.swift" \
  "$here/../../SipAI/Models/KimiToolPolicy.swift" \
  "$here/../../SipAI/Models/ConfigManager.swift" \
  "$here/../../SipAI/Models/ProviderCatalog.swift"
"$out/modelchipharness" "${1:-$here/../..}" "$here"
