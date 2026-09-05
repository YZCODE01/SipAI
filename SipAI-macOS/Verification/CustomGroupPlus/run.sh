#!/bin/bash
# Headless check that a custom group's header can start a session in
# itself, and that the session lands there — see the header of
# main.swift for the rules and what each was written for.
#
# The grouping rules are compiled from the SHIPPING
# AgentSessionGrouping.swift, not restated here: a harness holding its
# own copy of a rule under test passes for the wrong reason. Only the
# two row types are stubbed, and Foundation is all either needs.
#
# The last two passes READ the views and the string catalog, because
# the + needs a window and the filing needs a subprocess. An explicit
# source root points those at another checkout — against 1.0.2 they
# fail, which is what makes them worth having:
#
#   mkdir -p /tmp/sipai-102 && git -C <repo> archive fbbac86 | tar -x -C /tmp/sipai-102
#   ./run.sh /tmp/sipai-102
#
# Run it after touching the bucketer, the header +, the draft→session
# migration, or anything that files a row into a group.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
# Paths inside main.swift are REPO-relative (SipAI-macOS/SipAI/…),
# which is also how `git archive` lays an older checkout out.
root="$(cd "$here/../../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

grouping="$here/../../SipAI/Models/AgentSessionGrouping.swift"
if ! grep -q "static func latestFolder" "$grouping"; then
  echo "  FAIL  AgentSessionGrouping.latestFolder not found in $grouping"
  echo "        (the rule deciding a group's folder does not exist, so"
  echo "         the + would have to guess one)"
  exit 1
fi

swiftc -O -o "$out/groupplus" \
  "$here/Stubs.swift" "$grouping" "$here/main.swift"
"$out/groupplus" "${1:-$root}"
