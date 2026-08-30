#!/bin/bash
# Headless check of LatexSymbols.translate — the Unicode approximation
# that CHAT and AGENT transcripts render mathematics with. (Notes bypass
# this entirely and go to KaTeX; see Verification/NoteExport.)
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# The rule most worth protecting is all-or-nothing scripts. Converting
# each character independently looks harmless and is not: `x_{max}` has
# no subscript `m`, so it renders as `xmₐₓ` — a different expression,
# stated confidently. Falling back to `x_max` is the honest answer.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/latexharness" \
  "$src/SipAI/Utilities/LatexSymbols.swift" \
  "$src/SipAI/Utilities/MathAlphabets.swift" \
  "$here/main.swift"
"$out/latexharness"
