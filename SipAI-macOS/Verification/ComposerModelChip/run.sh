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
# Run it after touching anything that decides a model's NAME. The whole
# class of bug here is silent and permanent: a wrong pairing does not
# fail, it renames a model in every picker on the machine, and it
# renames it again after a relaunch.
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
  "$here/../../SipAI/Models/ConfigManager.swift" \
  "$here/../../SipAI/Models/ProviderCatalog.swift"
"$out/modelchipharness" "${1:-$here/../..}"
