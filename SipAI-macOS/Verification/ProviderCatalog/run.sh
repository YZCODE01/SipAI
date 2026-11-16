#!/bin/bash
# Headless check of the provider catalog and the config migration that
# retires a provider key.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# It compiles the REAL ProviderCatalog.swift and ConfigManager.swift
# against stand-ins for the app types ConfigManager happens to
# reference, and runs the migration over a throwaway config.json under
# $TMPDIR. It never touches ~/Library/Application Support/SipAI.
#
# Run it after ANY change to the catalog. The flags it pins
# (listsModels, listsModelsWithoutAuth, modelsPath) each exist because
# the add flow was measured doing the wrong thing without them, and all
# three fail SILENTLY: a skipped key probe looks like a working setup
# until the first chat, and a wrong models path looks like a provider
# with no models.
#
# It also sends two requests through the REAL `ProviderHTTP.session` to
# cache_server.py — a local stand-in provider whose every answer a web
# cache would keep — and searches a throwaway cache folder for the key
# they carried: nothing a provider request carries may be kept on disk.
# The same requests through a default session are the control. Needs
# python3; without it that section says SKIP.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/catalogharness" \
  "$here/Stubs.swift" "$here/main.swift" \
  "$here/../../SipAI/Models/ProviderCatalog.swift" \
  "$here/../../SipAI/Models/KimiToolPolicy.swift" \
  "$here/../../SipAI/Models/ConfigManager.swift"
PROVIDER_CACHE_SERVER="$here/cache_server.py" SIPAI_SOURCE_ROOT="$here/../.." \
  "$out/catalogharness" "$@"
