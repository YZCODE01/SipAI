#!/bin/bash
# Headless check of the native math typesetter — the font layer, the
# parser, the layout, and the block segmentation that routes a display
# equation to it.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# What it is really protecting is that every command a derivation-heavy
# reply uses is IMPLEMENTED. An unimplemented one does not crash and
# does not look broken from the code — it draws its own name in red in
# the middle of an equation, and the only way to find out is to render
# it. Section 3 renders the whole corpus and fails on any of them.
#
# Run it after touching any Math*.swift, and after a macOS upgrade: the
# constants come from the system's STIX Two Math, and section 1 is what
# says the table reader is still reading the fields it thinks it is.
#
#   ./run.sh                 check
#   MATH_RENDER=1 ./run.sh   check, and write a PNG of the corpus to look at
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/mathharness" \
  "$src/SipAI/Utilities/MathFont.swift" \
  "$src/SipAI/Utilities/MathAlphabets.swift" \
  "$src/SipAI/Utilities/MathSymbols.swift" \
  "$src/SipAI/Utilities/MathParser.swift" \
  "$src/SipAI/Utilities/MathLayout.swift" \
  "$src/SipAI/Utilities/MathDelimiters.swift" \
  "$src/SipAI/Utilities/MathDisplayBlock.swift" \
  "$src/SipAI/Utilities/MarkdownRenderer.swift" \
  "$src/SipAI/Utilities/LatexSymbols.swift" \
  "$src/SipAI/Utilities/SearchMatching.swift" \
  "$src/SipAI/Utilities/DesignSystem.swift" \
  "$here/Stubs.swift" \
  "$here/main.swift"
"$out/mathharness"
