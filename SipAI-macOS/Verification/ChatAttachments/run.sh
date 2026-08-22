#!/bin/bash
# Headless check of chat file attachments.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# It compiles the REAL ChatAttachment.swift and the REAL APIClient.swift
# against stand-ins for the config layer, and drives them over throwaway
# files under $TMPDIR. It never touches ~/Library/Application Support/SipAI
# and never opens a socket.
#
# The last pass READS ChatView.swift and MessageInput.swift rather than
# restating their rules — a third copy of a rule is how a harness comes
# to pass while the app is broken.
#
# Run it after touching the attachment path, and after adding a provider
# whose API style is not one of the three here: a fourth dialect that
# nobody teaches to carry an image sends the question without it.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/attachmentharness" \
  "$here/Stubs.swift" \
  "$here/../../SipAI/Models/ChatAttachment.swift" \
  "$here/../../SipAI/Models/APIClient.swift" \
  "$here/main.swift"
# An explicit source root overrides, so the structural pass can be
# pointed at an older checkout to confirm it still catches the bug.
"$out/attachmentharness" "${1:-$here/../..}"
