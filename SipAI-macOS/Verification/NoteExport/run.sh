#!/bin/bash
# Headless check of the note RENDER path — the document that both the
# note Preview pane and "Save as PDF" are built from.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# It compiles the REAL NoteHTML.swift against the REAL MarkdownRenderer,
# LatexSymbols and SearchMatching, plus a stand-in for the one design
# token that lives in a view file. No window, no web view, no network.
#
# Run it after touching NoteHTML.swift, the block parser, or the link
# scheme gate. The check that matters most is section 1: if a note is
# ever routed through `MarkdownInline.attributed`, LaTeX is translated
# into Unicode before KaTeX can lay it out, and every equation in every
# note and every exported PDF quietly degrades.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/noteexport" \
  "$here/Stubs.swift" \
  "$src/SipAI/Utilities/NoteHTML.swift" \
  "$src/SipAI/Utilities/MarkdownRenderer.swift" \
  "$src/SipAI/Utilities/DesignSystem.swift" \
  "$src/SipAI/Utilities/LatexSymbols.swift" \
  "$src/SipAI/Utilities/SearchMatching.swift" \
  "$src/SipAI/Views/Notes/NoteWebView.swift" \
  "$here/main.swift"
"$out/noteexport"
