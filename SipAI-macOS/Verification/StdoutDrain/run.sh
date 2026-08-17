#!/bin/bash
# Headless check of AgentRunner's stdout read loop — the one descriptor
# draining a live agent child. Whatever ends that loop strands the
# child: it blocks in write() on a PTY nobody is reading, and since
# every turn-end bound waits on the child EXITING, the turn never ends.
# The session sits at "Sipping…" until the app is quit.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, and no source of the product is compiled in. The code rules
# below are checked by READING Models/AgentRunner.swift, deliberately —
# a harness that restated the loop would keep passing against a product
# that no longer had it.
#
# Run it after any change to readStdout, and after a macOS upgrade: the
# second half pins PTY and dispatch-source behaviour the rules rest on.
#
#   ./run.sh
#
# See CLAUDE.md → "Agent-session streaming (macOS)" § 3.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
runner="$here/../../SipAI/Models/AgentRunner.swift"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

fail=0
ok()   { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; [ -n "$2" ] && echo "        $2"; fail=$((fail + 1)); }

[ -f "$runner" ] || { echo "cannot find $runner"; exit 1; }

# The read loop only — from readStdout's signature to the state class
# that follows it. If this range comes back empty the function has been
# restructured, and these rules need re-reading rather than re-running.
body="$out/readstdout.swift"
awk '/private func readStdout\(handle:/ {inside=1}
     /private final class StdoutReadState/ {inside=0}
     inside {print}' "$runner" > "$body"

echo "AgentRunner.readStdout source rules"

if [ ! -s "$body" ]; then
  bad "readStdout is where the harness expects it" \
      "extraction came back empty — the function moved or was renamed"
  echo; echo "1 check FAILED."; exit 1
fi
ok "readStdout located ($(wc -l < "$body" | tr -d ' ') lines)"

# Every rule below is about control flow, and this function carries more
# comment than code. Match on the code alone, or a rule is satisfied by
# a paragraph describing it.
code="$out/readstdout.code"
sed 's://.*::' "$body" | grep -vE '^[[:space:]]*$' > "$code"

# 1. Drain to EAGAIN. A PTY hands back one line-discipline block per
#    call, so breaking on a short read leaves bytes queued and keeps the
#    reader a wake behind the child forever.
if grep -qE 'n[[:space:]]*<[[:space:]]*bufSize' "$code"; then
  bad "the loop does not stop on a short read" \
      "found 'n < bufSize' in the loop — see CLAUDE.md § 3, first rule"
else
  ok "the loop does not stop on a short read"
fi

# 2. errno is captured with the result, inside the closure. It is
#    thread-local but not call-local, and every errno that is not EAGAIN
#    ends the reader.
if awk '/withUnsafeMutableBufferPointer/{inside=1}
        inside {print}
        inside && /^[[:space:]]*\}$/ {exit}' "$code" | grep -q 'errno'; then
  ok "errno is captured inside the read closure, with the result"
else
  bad "errno is captured inside the read closure, with the result" \
      "errno read outside the closure can be clobbered before it is tested"
fi

# 3. EINTR retries. This is the one that hangs a turn in the field.
if ! grep -q 'EINTR' "$code"; then
  bad "EINTR retries instead of ending the stream" \
      "EINTR is not handled at all — it falls into the end-of-stream branch"
elif awk '/EINTR/{found=NR} found && NR>=found && NR<=found+2' "$code" \
     | grep -q 'continue'; then
  ok "EINTR retries instead of ending the stream"
else
  bad "EINTR retries instead of ending the stream" \
      "EINTR is tested but does not lead to a retry"
fi

# 4. A real EOF still cancels. Without it the handler is re-entered in a
#    tight spin on a descriptor that can only keep failing.
if grep -q 'source.cancel()' "$code" && grep -q 'atEnd' "$code"; then
  ok "a real end-of-stream still cancels the source"
else
  bad "a real end-of-stream still cancels the source" \
      "an uncancelled source spins the handler on a dead descriptor"
fi

echo
swiftc -O -o "$out/ptycheck" "$here/main.swift" 2>&1 | grep -v '^$' || true
[ -x "$out/ptycheck" ] || { echo "  FAIL  harness did not build"; exit 1; }
if "$out/ptycheck"; then :; else fail=$((fail + 1)); fi

echo
if [ "$fail" -eq 0 ]; then
  echo "All stdout-drain checks passed."
else
  echo "$fail check group(s) FAILED."
  exit 1
fi
