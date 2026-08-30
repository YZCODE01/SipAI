#!/bin/bash
# Headless check of the search feature's matching layer — the rule that
# the find bar's "3 of 47" and the highlights on screen describe the
# same matches — plus the renderer's link gate: which URL schemes it
# will let a model's reply, a note or an agent tool result make
# clickable.
#
# Compiles the REAL SearchMatching.swift and the REAL MarkdownRenderer
# (plus DesignSystem and LatexSymbols, which they need), so this pins
# the shipped behaviour rather than a paraphrase of it. `ChatDesign`
# lives inside ChatView.swift and would drag a whole view in, so its
# two used colours are stubbed.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# Run it after touching SearchMatching.swift or MarkdownRenderer.swift —
# especially after any change to what the renderer DRAWS, since that is
# what search counts in.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -target arm64-apple-macos15.0 -o "$out/searchharness" \
  "$here/Stubs.swift" \
  "$here/../../SipAI/Utilities/DesignSystem.swift" \
  "$here/../../SipAI/Utilities/LatexSymbols.swift" \
  "$here/../../SipAI/Utilities/SearchMatching.swift" \
  "$here/../../SipAI/Utilities/MathAlphabets.swift" \
  "$here/../../SipAI/Utilities/MathSymbols.swift" \
  "$here/../../SipAI/Utilities/MathParser.swift" \
  "$here/../../SipAI/Utilities/MathFont.swift" \
  "$here/../../SipAI/Utilities/MathLayout.swift" \
  "$here/../../SipAI/Utilities/MathDelimiters.swift" \
  "$here/../../SipAI/Utilities/MathDisplayBlock.swift" \
  "$here/../../SipAI/Utilities/MarkdownRenderer.swift" \
  "$here/../../SipAI/Views/Chat/TranscriptFind.swift" \
  "$here/main.swift"
"$out/searchharness" "$@"
