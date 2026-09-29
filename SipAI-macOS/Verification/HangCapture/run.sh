#!/bin/bash
# Headless check of HangCapture — the Debug-only watchdog that writes a
# `sample` of this process to ~/Library/Logs/SipAI when the main thread
# stops answering, and touches nothing else.
#
# Three passes: the verdict table over the pure `decide`; the REAL
# watchdog (compiled from Utilities/HangCapture.swift, DEBUG on) against
# a driver that genuinely blocks its main thread, under a throwaway HOME
# and a 3 s threshold; and a read of the source for the things it must
# never do. Needs /usr/bin/sample to work on an unsigned same-user
# process, which is also the condition the Debug app runs under.
#
#   ./run.sh
#
# See CLAUDE.md → "A hang is CAPTURED, never cured".
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
src="$root/SipAI/Utilities/HangCapture.swift"
app="$root/SipAI/SipAIApp.swift"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
fail=0
ok()   { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; [ -n "$2" ] && echo "        $2"; fail=$((fail + 1)); }

[ -f "$src" ] || { echo "cannot find $src"; exit 1; }

echo "HangCapture source rules"
code="$out/hang.code"
sed 's://.*::' "$src" | grep -vE '^[[:space:]]*$' > "$code"
grep -q 'pthread_create' "$code" && ok "the watchdog is a plain pthread" \
  || bad "the watchdog is a plain pthread" "no pthread_create — GCD or Swift concurrency may be the thing that is wedged"
grep -q '#if DEBUG' "$src" && ok "the implementation is Debug-only" \
  || bad "the implementation is Debug-only" "no #if DEBUG — sample cannot work under the hardened runtime, and nothing here may ship silently"
if grep -q 'CFRunLoopSourceSignal' "$code" && grep -q 'CFRunLoopWakeUp' "$code" && grep -q 'CFRunLoopSourceCreate' "$code"; then
  ok "the heartbeat is a PING: a run-loop source the watchdog signals and wakes"
else
  bad "the heartbeat is a PING: a run-loop source the watchdog signals and wakes" \
      "an idle main thread does not cycle its loop — a pass-counting heartbeat reads every quiet moment as a hang (measured)"
fi
if grep -qE 'terminate\(|\.cancel\(|setStatus|finalizeTurn|killChild|NSApp|NSLog' "$code"; then
  bad "it never intervenes" "$(grep -nE 'terminate\(|\.cancel\(|setStatus|finalizeTurn|killChild|NSApp|NSLog' "$code" | head -3)"
else
  ok "it never intervenes (no terminate/cancel/status/NSLog)"
fi
kills="$(grep -c 'kill(' "$code" || true)"
if [ "$kills" -le 1 ] && grep -q 'kill(child, SIGKILL)' "$code"; then
  ok "the only signal it sends is to its own sample child"
else
  bad "the only signal it sends is to its own sample child" "kill( appears $kills times"
fi
grep -q 'Library/Logs/SipAI' "$code" && ok "captures land under ~/Library/Logs/SipAI" \
  || bad "captures land under ~/Library/Logs/SipAI"
if grep -q 'HangCapture.start()' "$app"; then ok "SipAIApp starts it once at launch"; else bad "SipAIApp starts it once at launch"; fi

echo
echo "Behaviour (real watchdog, real block, real sample — ~45 s)"
if ! swiftc -O -D DEBUG -target arm64-apple-macos15.0 -o "$out/hang" "$src" "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log"; echo "  FAIL  harness did not build"; exit 1
fi
home="$out/home"
mkdir -p "$home"
if HOME="$home" SIPAI_HANG_THRESHOLD=3 SIPAI_HANG_GRACE=1 "$out/hang" 2>"$out/stderr.log"; then :; else fail=$((fail + 1)); fi
echo "  (watchdog stderr:)"; sed 's/^/        /' "$out/stderr.log" | head -8

echo
if [ "$fail" -eq 0 ]; then
  echo "All HangCapture checks passed."
else
  echo "$fail check group(s) FAILED."
  exit 1
fi
