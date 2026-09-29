#!/bin/bash
# Headless check that the font-size tier reaches every surface it
# promises to, and that the transcript's rhythm scales as one — see the
# header of main.swift for the four passes and the two bugs they pin.
#
# The rules under test are compiled from the REAL DesignSystem.swift and
# the REAL MarkdownRenderer.swift (never copied), and the structural
# pass READS the view files. An explicit source root points the whole
# thing at another checkout — against 1.0.3 it fails, which is what
# makes the checks worth having.
#
# Run it after touching DesignSystem.swift's `SipFont`, the renderer's
# block stack, either composer's text field, or Settings' typography.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# The Help section's rhythm, answer and card live in SettingsView.swift
# beside views that need the whole app, so they are extracted by text —
# each a column-0 declaration closed by a column-0 `}` — never copied.
{
  echo "import SwiftUI"
  for decl in "enum HelpRhythm" "struct FAQAnswer" "struct FAQCard<Answer: View>"; do
    awk -v pat="private ${decl}" 'index($0, pat) == 1 {f=1} f{print} f&&/^\}/{exit}' \
      "$root/SipAI/Views/Settings/SettingsView.swift" | sed 's/^private //'
    echo
  done
} > "$out/HelpSection.swift"

if ! swiftc -O -target arm64-apple-macos15.0 -o "$out/fonttier" \
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
  "$root/SipAI/Utilities/CodeBlockActions.swift" \
  "$out/HelpSection.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  if grep -q "cannot find 'HelpRhythm'\|cannot find 'FAQAnswer'\|cannot find 'FAQCard'" "$out/build.log" \
     && ! grep -q "has no member 'transcriptBodyBase'\|cannot find 'TextInputTypography'" "$out/build.log"; then
    echo "PRE-FIX: SettingsView.swift has no HelpRhythm / FAQAnswer — the Help"
    echo "  section spaces its lines by a fixed 3 pt and pads its cards by fixed"
    echo "  points, whatever the font tier. That is the failure pass 3b is for."
    exit 1
  fi
  if grep -q "has no member 'transcriptBodyBase'\|cannot find 'TextInputTypography'" "$out/build.log"; then
    echo "PRE-FIX: this checkout has no tier-reach rules to check —"
    echo "  SipFont.scaled / transcriptGapScale and TextInputTypography are"
    echo "  absent, so the composers, Settings and the renderer's gaps cannot"
    echo "  follow the tier. That is the failure this harness is for."
    exit 1
  fi
  cat "$out/build.log"
  exit 1
fi
# Pass 5 needs a window server. Without one the process would hang on
# the window rather than fail, so it is bounded and a timeout reads as
# SKIP — passes 1–4 have printed their own verdict by then.
set +e
perl -e 'alarm 90; exec @ARGV' "$out/fonttier" "$root"
status=$?
set -e
if [ $status -eq 142 ] || [ $status -eq 14 ]; then
  echo ""
  echo "SKIP — pass 5 timed out reaching the window server (no GUI session?)."
  echo "       Passes 1–4 are the part that runs anywhere; rerun in a"
  echo "       logged-in session for the underline measurement."
  exit 0
fi
exit $status
