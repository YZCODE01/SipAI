#!/bin/bash
# Probe the Kimi Code CLI against every assumption SipAI's kimi support
# was written on.
#
# WHY THIS EXISTS. The claude and codex paths in this app were written
# against binaries that were present, and the things that actually
# mattered were the things reading the docs would never have found:
# that `codex exec` has no `-a`, that `codex exec resume` takes neither
# `--sandbox` nor `--color`, that a PTY prefixes codex's first stdout
# line with `^D^H^H`. Kimi Code was NOT installed when its support was
# written — every argv, path and JSON key in KimiSessions.swift /
# KimiEventParsing.swift comes from Moonshot's documentation. This
# script is how those become measured facts.
#
#   ./run.sh            # probe (spawns two real kimi turns)
#   ./run.sh --dry      # flag/table checks only, spawns nothing
#
# It runs its turns in a TEMP working directory, so nothing of yours is
# read or written by the agent, and prompts kimi for one word so a turn
# is cheap. It uses your REAL $KIMI_CODE_HOME, because that is where
# your credentials are — so it does leave two probe sessions in the
# store. They are rooted in /var/folders, which SipAI classifies as
# scratch and hides, and the script prints their ids so you can delete
# them.
#
# Every check prints PASS / FAIL / SKIP and the file + line of the
# assumption it is checking, so a FAIL says what to edit.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../SipAI/Models"
dry=0
[ "${1:-}" = "--dry" ] && dry=1

pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n'   "$1"; fail=$((fail+1));
         [ $# -gt 1 ] && printf '        → %s\n' "$2"; }
sk()   { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; skip=$((skip+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- 0
head_ "0. The binary"

kimi_bin=""
for d in /usr/local/bin /usr/bin /opt/homebrew/bin "$HOME/.local/bin" \
         "$HOME/.volta/bin" "$HOME/.kimi-code/bin" "$HOME/.kimi/bin"; do
  [ -x "$d/kimi" ] && { kimi_bin="$d/kimi"; break; }
done
[ -z "$kimi_bin" ] && kimi_bin="$(command -v kimi 2>/dev/null || true)"

if [ -z "$kimi_bin" ]; then
  echo "  kimi is not installed. Nothing can be verified — install it first:"
  echo "    curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash"
  echo
  echo "  NOTE: AgentManager.searchPaths is the list SipAI itself looks in."
  echo "  If kimi lands somewhere else, that list needs the directory added"
  echo "  or the app will report it as not installed."
  exit 2
fi
ok "found: $kimi_bin"
echo "        version: $("$kimi_bin" --version 2>&1 | head -1)"

# Whether SipAI can SEE this binary. Read out of AgentManager.swift
# rather than restated here: this check used to carry its own hardcoded
# copy of the directory list, so when kimi turned out to install to
# ~/.kimi-code/bin — and the list was fixed — the harness went on
# failing against a list nothing used any more. A probe that repeats the
# thing it is probing can only ever verify itself.
#
# `searchPaths` is the built-in list PLUS the login shell's own PATH
# (folded in via ShellEnvironment), so both are accepted, and the second
# is reported as such: it depends on the shell capture landing, which is
# asynchronous and can fail, where a built-in entry never does.
kimi_dir="$(dirname "$kimi_bin")"
mgr="$src/AgentManager.swift"
builtin_dirs=""
while IFS= read -r line; do
  case "$line" in *nvmBase*) continue ;; esac          # dynamic, globbed below
  frag="$(printf '%s\n' "$line" | grep -o '"/[^"]*"' | head -1 | tr -d '"')"
  [ -z "$frag" ] && continue
  case "$line" in
    *"home +"*) builtin_dirs="$builtin_dirs$HOME$frag"$'\n' ;;
    *)          builtin_dirs="$builtin_dirs$frag"$'\n' ;;
  esac
done < <(awk '/let builtInSearchPaths/,/^    \}\(\)/' "$mgr" 2>/dev/null)
for d in "$HOME"/.nvm/versions/node/*/bin; do
  [ -d "$d" ] && builtin_dirs="$builtin_dirs$d"$'\n'
done

if [ -z "$builtin_dirs" ]; then
  no "could not read builtInSearchPaths out of AgentManager.swift" \
     "the detection list was renamed or restructured — update this check"
elif grep -qxF "$kimi_dir" <<<"$builtin_dirs"; then
  ok "on a path AgentManager.searchPaths already scans"
elif grep -qxF "$kimi_dir" \
     <<<"$("$SHELL" -ilc 'printf "%s\n" ${(s.:.)PATH}' 2>/dev/null \
           || /bin/zsh -ilc 'printf "%s\n" ${(s.:.)PATH}' 2>/dev/null)"; then
  ok "reachable via the login shell's PATH (ShellEnvironment fold-in)"
  echo "        not in builtInSearchPaths — detection waits on the shell capture"
else
  no "installed outside AgentManager.searchPaths" \
     "add $kimi_dir to builtInSearchPaths in AgentManager.swift"
fi

# ---------------------------------------------------------------- 1
head_ "1. Flags SipAI passes  (AgentRunner.kimiArguments)"

help="$("$kimi_bin" --help 2>&1)"
for flag in --prompt --output-format --session --model; do
  if grep -q -- "$flag" <<<"$help"; then
    ok "$flag is documented in --help"
  else
    no "$flag missing from --help" "AgentRunner.kimiArguments builds it"
  fi
done
if grep -q -- "stream-json" <<<"$help"; then
  ok "--output-format offers stream-json"
else
  no "stream-json not named in --help" \
     "KimiEventParser decodes that format; check the accepted values"
fi

# ---------------------------------------------------------------- 2
# Everything in this section runs WITHOUT credentials and without a
# single API call: kimi validates its arguments and resolves its config
# before it ever reaches a model, so each check below is decided by an
# error message that arrives in milliseconds. That is why it is not
# gated behind --dry the way sections 3+ are — these are the facts the
# composer's chips are built on, and they should be free to re-check.
#
# A scratch $KIMI_CODE_HOME keeps the real store untouched.
head_ "2. Chip rules  (AgentLaunchOptions: kimiFlags, KimiCapabilities, KimiCatalog)"

probe_home="$(mktemp -d)"
trap 'rm -rf "$probe_home"' EXIT
cat > "$probe_home/config.toml" <<'TOML'
default_model = "sipai-probe-model"

[models.sipai-probe-model]
provider = "probe"
TOML

# `perl -e alarm` rather than `timeout`, which macOS does not ship.
run_kimi() {
  KIMI_CODE_HOME="$probe_home" perl -e 'alarm 30; exec @ARGV' \
    "$kimi_bin" "$@" </dev/null 2>&1
}

# 2a. The assumption behind the composer showing kimi a fixed
# auto-approve chip instead of a mode picker. If any of these FAIL —
# i.e. the combination is accepted — kimi can carry a permission mode
# after all, and AgentLaunchOptions.kimiFlags should start emitting one.
for mode_flag in --yolo --auto --plan; do
  combo="$(run_kimi --prompt "hi" "$mode_flag")"
  if grep -qi "cannot combine\|cannot be used with\|mutually exclusive\|unexpected argument" <<<"$combo"; then
    ok "--prompt + $mode_flag is refused"
  else
    no "--prompt + $mode_flag was ACCEPTED" \
       "kimiFlags may emit a mode; the composer can offer a real picker"
  fi
done

# 2b. Why the model picker may offer ONLY `[models.*]` aliases: an alias
# kimi does not know is not a soft fallback, it kills the turn. If this
# starts passing unknown models through, KimiCatalog could widen its
# list (it deliberately does not harvest session-observed models today).
unknown="$(run_kimi --prompt "hi" --model sipai-definitely-not-a-model)"
if grep -qi "not configured in config.toml\|unknown model\|not found" <<<"$unknown"; then
  ok "an unlisted --model is rejected (so the picker must offer config aliases)"
else
  no "an unlisted --model was NOT rejected" \
     "KimiCatalog.parseConfig could relax to include observed models"
fi

# 2c. The key the model chip reads. Reading the wrong one is invisible:
# the chip silently falls back to the bare word "Model". `default_model`
# resolving is proved by the error moving PAST model resolution.
seeded="$(run_kimi --prompt "hi")"
if grep -qi "no model configured\|use /login" <<<"$seeded"; then
  no "default_model in config.toml was ignored" \
     "KimiCatalog.parseConfig reads the wrong key — kimi wants default_model"
else
  ok "default_model in config.toml is resolved"
fi

# 2d. The channel kimi's effort chip travels on. It cannot be proved to
# take EFFECT without credentials — that needs section 3 — but a
# rejected or unknown variable would show up here as an argument or
# validation error, and does not.
effort_run="$(KIMI_MODEL_THINKING_EFFORT=high run_kimi --prompt "hi")"
if grep -qi "thinking_effort\|invalid effort\|unknown.*effort" <<<"$effort_run"; then
  no "KIMI_MODEL_THINKING_EFFORT was rejected" \
     "KimiCapabilities.effortLevels / effortEnvVar need re-measuring"
else
  ok "KIMI_MODEL_THINKING_EFFORT is accepted (effect needs a real turn)"
fi

# 2d-bis. Why AgentRunner.stripDynamicLinkerVars exists. Kimi ships as
# a Node SEA — its JavaScript lives in a Mach-O section of the binary —
# and an inserted dylib perturbs the image the SEA loader reads that
# section back out of, so node aborts before running a line of kimi.
# A GUI app launched by Xcode carries DYLD_INSERT_LIBRARIES
# (libMainThreadChecker.dylib), and children inherit the environment,
# so every kimi turn died on a user's machine with a native stack trace
# and no session. Reproduced 2026-08-14; this is that reproduction.
#
# If this ever stops failing, the strip is no longer load-bearing —
# leave it in regardless (the variables still describe SipAI's image
# graph, not an agent's), but the crash it cites will have moved.
mtc=/Applications/Xcode.app/Contents/Developer/usr/lib/libMainThreadChecker.dylib
if [ ! -f "$mtc" ]; then
  sk "no libMainThreadChecker.dylib — cannot re-check the SEA crash"
else
  # Invoked DIRECTLY, not through `run_kimi`'s `perl` alarm wrapper:
  # /usr/bin/perl is SIP-protected, and dyld strips every DYLD_* from
  # the environment when exec'ing a protected binary — so the variable
  # would never reach kimi and this check would always "pass". SipAI's
  # own spawn has no such intermediary (Foundation execs the CLI
  # directly with the inherited environment), which is precisely why
  # the crash is reachable there. `--version` returns at once, so no
  # timeout guard is needed.
  inserted="$(cd "$probe_home" && KIMI_CODE_HOME="$probe_home" \
              DYLD_INSERT_LIBRARIES="$mtc" "$kimi_bin" --version 2>&1)"
  if grep -qiE "sea|kMagic|Assertion failed|Native stack trace" <<<"$inserted"; then
    ok "an inserted dylib still breaks kimi (so the DYLD strip is load-bearing)"
  else
    sk "an inserted dylib no longer breaks kimi — keep the strip anyway"
  fi
  clean="$(run_kimi --version)"
  if grep -q "^0\." <<<"$clean"; then
    ok "kimi starts cleanly once DYLD_* is absent"
  else
    no "kimi fails even without DYLD_*" "something else is wrong: $clean"
  fi
fi

# 2e. The levels themselves are read out of the binary, so a kimi
# upgrade that renames or extends them is caught here rather than by a
# user picking a level that silently clamps.
levels="$(strings -a "$kimi_bin" 2>/dev/null \
          | grep -A 8 -E '^(BUDGET_THINKING_EFFORTS|LATEST_OPUS_THINKING_EFFORTS)\$?1? = \[' \
          | grep -oE '"(low|medium|high|xhigh|max)"' | tr -d '"' | sort -u | tr '\n' ' ')"
if [ -z "$levels" ]; then
  sk "could not read effort levels out of the binary (packaging changed?)"
elif [ "$levels" = "high low max medium xhigh " ]; then
  ok "effort levels still low/medium/high/xhigh/max"
else
  no "effort levels moved: $levels" \
     "update KimiCapabilities.effortLevels in AgentLaunchOptions.swift"
fi

# ---------------------------------------------------------------- 3
head_ "3. A real turn  (KimiEventParser.parse)"

home="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
echo "        store: $home"
sessions_dir="$home/sessions"

ids_now() {
  [ -d "$sessions_dir" ] || return 0
  find "$sessions_dir" -mindepth 2 -maxdepth 2 -type d \
    -exec basename {} \; 2>/dev/null | sort
}

if [ $dry -eq 1 ]; then
  sk "needs a spawn (--dry)"
  new_id=""
else
  work="$(mktemp -d)"
  before="$(ids_now)"
  out="$work/stdout.jsonl"
  ( cd "$work" && "$kimi_bin" --prompt "Reply with the single word: PROBE" \
      --output-format stream-json ) >"$out" 2>"$work/stderr.txt"
  rc=$?
  if [ $rc -eq 0 ]; then ok "exit 0"
  else no "exit $rc" "$(tail -3 "$work/stderr.txt" | tr '\n' ' ')"; fi

  if [ -s "$out" ]; then
    ok "stdout produced $(wc -l <"$out" | tr -d ' ') line(s)"
  else
    no "stdout was empty" "the turn would render as nothing in SipAI"
  fi

  # The PTY trap that cost codex a silent blank transcript: bytes before
  # the first '{'. KimiEventParser.decode drops them — this reports
  # whether it has to.
  if head -1 "$out" | grep -q '^{'; then
    ok "first line starts at '{' (no tty-handshake prefix over a pipe)"
  else
    sk "first line has a prefix — KimiEventParser.decode already strips it"
  fi

  if head -1 "$out" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; then
    ok "lines are JSON"
  else
    no "first line is not JSON" "KimiEventParser.decode expects one object per line"
  fi

  roles="$(python3 - "$out" <<'PY' 2>/dev/null
import json, sys
seen = []
for line in open(sys.argv[1], errors="replace"):
    line = line.strip()
    if "{" not in line: continue
    try: obj = json.loads(line[line.index("{"):])
    except Exception: continue
    r = obj.get("role")
    if r and r not in seen: seen.append(r)
print(" ".join(seen))
PY
)"
  if [ -n "$roles" ]; then
    ok "records carry a top-level \"role\": $roles"
  else
    no "no top-level \"role\" found" \
       "KimiEventParser switches on it — dump: $(head -1 "$out" | cut -c1-160)"
  fi

  if grep -q '"tool_calls"' "$out"; then
    ok "tool_calls present — the toolUse path is exercised"
  else
    sk "no tool_calls in this turn (a one-word prompt uses none)"
  fi

  # ------------------------------------------------------------- 4
  head_ "4. Store layout  (KimiSessionScanner)"
  after="$(ids_now)"
  new_id="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)"
  if [ -n "$new_id" ]; then
    ok "the turn created exactly one new session id: $new_id"
  else
    no "no new session directory appeared" \
       "AgentRunner.startKimiSessionDiscovery can never find an id — every send would start a new session"
  fi

  if [ -n "$new_id" ]; then
    sdir="$(find "$sessions_dir" -mindepth 2 -maxdepth 2 -type d -name "$new_id" | head -1)"
    echo "        dir: ${sdir/#$HOME/\~}"
    bucket="$(basename "$(dirname "$sdir")")"
    echo "        bucket key: $bucket"
    case "$bucket" in
      -*|/*) ok "bucket looks like an encoded PATH (decodeWorkDirKey can try it)" ;;
      *)     sk "bucket looks opaque — cwd must come from state.json / the index" ;;
    esac

    [ -f "$sdir/state.json" ] \
      && ok "state.json exists" \
      || no "no state.json" "KimiSessionScanner.readState reads title/cwd/createdAt from it"
    [ -f "$sdir/agents/main/wire.jsonl" ] \
      && ok "agents/main/wire.jsonl exists" \
      || no "no agents/main/wire.jsonl" \
            "KimiSessionScanner.wireFile points every reader at that path"

    if [ -f "$sdir/state.json" ]; then
      keys="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(sorted(d)))' "$sdir/state.json" 2>/dev/null)"
      echo "        state.json keys: $keys"
      grep -qw cwd <<<"$keys" \
        && ok "state.json names \"cwd\"" \
        || no "state.json has no \"cwd\" key" \
              "sessions would resolve to \$HOME — readState reads it from here"
      # MEASURED: kimi stores NO title for an ordinary session — the
      # keys are id/version/cwd/archived/agents/custom/lastTurnReason/
      # createdAt/updatedAt/isCustomTitle, and session_index.jsonl
      # carries only sessionId/sessionDir/workDir. So SipAI ALWAYS
      # derives the title from the first user message, and
      # `titleIsFallback` is correspondingly always true. This is not a
      # gap to close; it is the shape of the store. What would be worth
      # noticing is a title APPEARING — that is where a renamed session
      # would put it, and `readState` should then learn the spelling.
      if grep -qw title <<<"$keys"; then
        no "state.json now carries a \"title\" — readState should read it" \
           "add the spelling to readState's list in KimiSessions.swift"
      else
        ok "no stored title (expected) — SipAI derives it from turn 1"
      fi
      grep -qw isCustomTitle <<<"$keys" \
        && echo "        (isCustomTitle present: a renamed session may store one)"
    fi

    if [ -f "$home/session_index.jsonl" ]; then
      ok "session_index.jsonl exists"
      echo "        newest entry: $(tail -1 "$home/session_index.jsonl" | cut -c1-200)"
    else
      sk "no session_index.jsonl (indexEntries just returns empty)"
    fi

    if [ -f "$sdir/agents/main/wire.jsonl" ]; then
      echo "        --- first 3 wire records, truncated ---"
      head -3 "$sdir/agents/main/wire.jsonl" | cut -c1-220 | sed 's/^/        /'
      wroles="$(python3 - "$sdir/agents/main/wire.jsonl" <<'PY' 2>/dev/null
import json, sys
seen = []
for line in open(sys.argv[1], errors="replace"):
    try: obj = json.loads(line)
    except Exception: continue
    for probe in (obj, obj.get("message"), obj.get("payload"),
                  obj.get("data"), obj.get("event"), obj.get("item")):
        if isinstance(probe, dict) and probe.get("role"):
            if probe["role"] not in seen: seen.append(probe["role"])
            break
print(" ".join(seen))
PY
)"
      if [ -n "$wroles" ]; then
        ok "wire records reduce to chat messages: $wroles"
      else
        no "no role-bearing record found in wire.jsonl" \
           "KimiSessionScanner.message() cannot unwrap this shape — history would render empty"
      fi
      if grep -q '"timestamp"\|"ts"\|"created_at"\|"createdAt"' "$sdir/agents/main/wire.jsonl"; then
        ok "wire records carry a timestamp (sidebar can sort on the last user message)"
      else
        no "wire records carry no timestamp field this reader knows" \
           "lastUserMessageDate returns nil, so rows fall back to mtime — see CLAUDE.md"
      fi
    fi

    # ----------------------------------------------------------- 5
    head_ "5. Resume  (--session <id>)"
    before2="$(ids_now)"
    ( cd "$work" && "$kimi_bin" --prompt "Reply with the single word: AGAIN" \
        --output-format stream-json --session "$new_id" ) \
        >"$work/stdout2.jsonl" 2>"$work/stderr2.txt"
    rc2=$?
    if [ $rc2 -eq 0 ]; then ok "resume exit 0"
    else no "resume exit $rc2" "$(tail -3 "$work/stderr2.txt" | tr '\n' ' ')"; fi
    after2="$(ids_now)"
    extra="$(comm -13 <(printf '%s\n' "$before2") <(printf '%s\n' "$after2") | head -1)"
    if [ -z "$extra" ]; then
      ok "resume reused the session (no new directory)"
    else
      no "resume created a NEW session ($extra)" \
         "every follow-up turn would lose the conversation — kimiArguments needs a different resume form"
    fi
  fi
  rm -rf "$work"
fi

# ----------------------------------------------------------------
head_ "Summary"
printf '  %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
if [ -n "${new_id:-}" ]; then
  echo
  echo "  Probe session left in the store: $new_id"
  echo "  It is rooted in a temp folder, so SipAI hides it as scratch;"
  echo "  remove it with:  rm -rf \"\$(find '$sessions_dir' -maxdepth 2 -name '$new_id')\""
fi
echo
echo "  Assumptions live in:"
echo "    ${src#"$here/../../"}/KimiSessions.swift      store layout, state.json, wire.jsonl"
echo "    ${src#"$here/../../"}/KimiEventParsing.swift  stdout schema"
echo "    ${src#"$here/../../"}/AgentLaunchOptions.swift  kimiFlags, KimiCatalog"
echo "    SipAI/Models/AgentRunner.swift               kimiArguments, session discovery"
[ "$fail" -eq 0 ] || exit 1
