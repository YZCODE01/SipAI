#!/bin/bash
# Headless check of a chat with a Claude model through Anthropic's
# Messages API: a reply that starts with thinking is read, the request
# streams, and its output cap is the model's own published maximum.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# It compiles the REAL APIClient.swift against stand-ins for the config
# layer and sends chats through the REAL `APIClient.sendChat` to
# anthropic_server.py — a local stand-in for the Messages API that
# answers in the shapes Anthropic documents (thinking blocks ahead of
# the text, `display: "omitted"`, `ping` and `error` events, a model's
# `max_tokens` from `GET /v1/models/{id}`). No key, no network beyond
# 127.0.0.1, no token billed. Needs python3; without it the stand-in
# section says SKIP and the rest still runs.
#
# Run it after touching the Anthropic path, and after Anthropic changes
# the shape of a reply: every check here was a decode error, a missing
# reply or a cut-off answer before it was written.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
# The real `ProviderHTTP` — the session every provider request rides and
# the Anthropic API version it carries — lifted out of ProviderCatalog.swift
# whole, so the request this harness checks is the app's own.
awk '/^enum ProviderHTTP \{/,/^\}/' "$here/../../SipAI/Models/ProviderCatalog.swift" \
  | { echo "import Foundation"; cat; } > "$out/ProviderHTTP.swift"
grep -q "static let anthropicVersion" "$out/ProviderHTTP.swift" \
  || { echo "could not lift ProviderHTTP out of ProviderCatalog.swift" >&2; exit 1; }
swiftc -O -o "$out/claudechatharness" \
  "$here/Stubs.swift" \
  "$here/../../SipAI/Models/AttachmentInline.swift" \
  "$here/../../SipAI/Models/ChatAttachment.swift" \
  "$here/../../SipAI/Models/APIClient.swift" \
  "$out/ProviderHTTP.swift" \
  "$here/main.swift"
ANTHROPIC_STANDIN="$here/anthropic_server.py" SIPAI_TEST_DATA_DIR="$out" \
  "$out/claudechatharness"
