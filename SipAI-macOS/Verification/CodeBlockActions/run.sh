#!/bin/bash
# Headless checks for fenced code blocks, compiled from the REAL
# MarkdownRenderer.swift and CodeBlockActions.swift (never copies).
#
#   §1  How fences are read. A fence starts a line (``` or ~~~, three or
#       more); it closes on the same character, at least as many, alone
#       on its line; a fence inside a list item loses the item's
#       indentation. Three backticks mid-sentence or in a table cell are
#       text. A Markdown file that holds its own code blocks travels in a
#       longer fence and stays ONE block — that is what Copy and Save
#       hand over. §1a pins that well-formed fences keep exactly the
#       blank-line shape they have always been drawn with.
#   §2  Copy drops one trailing newline (a pasted command must not run by
#       itself); a saved file ends in exactly one.
#   §3  The name the Save panel suggests: the conversation's title,
#       cleaned, with the language's extension.
#   §4  Long lines wrap: measured through the real view at every Font
#       Size tier, a 400-character unbroken line stays inside the width
#       it is offered.
#   §5  The wiring, read from the views: the buttons are an overlay (no
#       row changes height), a sent message hides its own corner buttons
#       while a code block inside it is hovered, both use one button.
#   §6  The new strings exist with their Chinese translations.
#
# Pointed at a tree that predates the buttons (`./run.sh <source-root>`)
# it compiles §1 and §4 alone and says PRE-FIX; there, §1b and §4 fail.
#
# Run it after touching MarkdownRenderer.swift's fence reading or
# CodeBlockView, or CodeBlockActions.swift.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$here/../..}"
root="$(cd "$root" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

extra=()
flags=()
if [ -f "$root/SipAI/Utilities/CodeBlockActions.swift" ]; then
  extra+=("$root/SipAI/Utilities/CodeBlockActions.swift")
  flags+=(-D CODE_BLOCK_ACTIONS)
fi

swiftc -O -target arm64-apple-macos15.0 "${flags[@]}" -o "$out/codeblocks" \
  "$here/Stubs.swift" \
  "$root/SipAI/Utilities/DesignSystem.swift" \
  "$root/SipAI/Utilities/LatexSymbols.swift" \
  "$root/SipAI/Utilities/SearchMatching.swift" \
  "$root/SipAI/Utilities/MathAlphabets.swift" \
  "$root/SipAI/Utilities/MathSymbols.swift" \
  "$root/SipAI/Utilities/MathParser.swift" \
  "$root/SipAI/Utilities/MathFont.swift" \
  "$root/SipAI/Utilities/MathLayout.swift" \
  "$root/SipAI/Utilities/MathDelimiters.swift" \
  "$root/SipAI/Utilities/MathDisplayBlock.swift" \
  "$root/SipAI/Utilities/MarkdownRenderer.swift" \
  "${extra[@]}" \
  "$here/main.swift"

"$out/codeblocks" "$root"
