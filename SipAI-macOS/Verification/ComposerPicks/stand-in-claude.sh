#!/bin/bash
# A stand-in for `claude`, for the Page pass. It answers the probes the
# app makes (--version, --help) and, for a turn (`-p`), records its
# arguments in $HOME/claude-argv.log, says `init` with a session id,
# writes the session's transcript where claude writes it, and then waits
# like a turn still running — until it is stopped. No model is called.
#
# `--version` answers whatever else is on the line, as claude's does beside
# a flag it does not know (this stand-in knows none): the app's probes put
# it after a flag they test (`--thinking-display sipai-probe --version`),
# and a probe taken for a turn would write a session of its own and wait
# here, past the end of the run.
case " $* " in
  *" --version "*) echo "2.1.301 (Claude Code)"; exit 0 ;;
esac
case "$1" in
  --help)
    cat <<'HELP'
Usage: claude [options] [command] [prompt]

Options:
  --effort <level>                      Effort level for the current session
                                        (low, medium, high, xhigh, max)
  --permission-mode <mode>              Permission mode to use for the session
                                        (choices: "acceptEdits", "auto",
                                        "bypassPermissions", "manual",
                                        "dontAsk", "plan")
  -p, --print                           Print response and exit
HELP
    exit 0 ;;
esac
echo "ARGV: $*" >> "$HOME/claude-argv.log"
mode=default; effort=""; resume=""; text=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -p) text="${args[$((i + 1))]}" ;;
    --permission-mode) mode="${args[$((i + 1))]}" ;;
    --effort) effort="${args[$((i + 1))]}" ;;
    --resume) resume="${args[$((i + 1))]}" ;;
  esac
done
sid="${resume:-$(uuidgen | tr 'A-Z' 'a-z')}"
cwd="$(pwd -P)"
dir="$HOME/.claude/projects/$(echo "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$dir"
f="$dir/$sid.jsonl"
ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
u="$(uuidgen | tr 'A-Z' 'a-z')"
a="$(uuidgen | tr 'A-Z' 'a-z')"
eff=""
[ -n "$effort" ] && eff=",\"effort\":\"$effort\""
printf '{"type":"user","uuid":"%s","parentUuid":null,"isSidechain":false,"sessionId":"%s","cwd":"%s","timestamp":"%s","permissionMode":"%s","message":{"role":"user","content":"%s"},"version":"2.1.301","entrypoint":"sdk-cli","userType":"external"}\n' \
  "$u" "$sid" "$cwd" "$ts" "$mode" "${text:-hello}" >> "$f"
printf '{"type":"system","subtype":"init","session_id":"%s","cwd":"%s","model":"claude-opus-5-5","permissionMode":"%s","tools":[],"mcp_servers":[],"slash_commands":[],"apiKeySource":"none"}\n' \
  "$sid" "$cwd" "$mode"
sleep 0.3
printf '{"type":"assistant","uuid":"%s","parentUuid":"%s","isSidechain":false,"sessionId":"%s","cwd":"%s","timestamp":"%s"%s,"message":{"id":"msg_%s","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Working on it."}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
  "$a" "$u" "$sid" "$cwd" "$ts" "$eff" "$a" >> "$f"
printf '{"type":"assistant","message":{"id":"msg_%s","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Working on it."}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"session_id":"%s","parent_tool_use_id":null}\n' \
  "$a" "$sid"
# Waiting as `sleep`, the turn no longer goes by this script's name: the
# harness stops whatever is left of it by this pid.
echo $$ >> "$HOME/stand-in.pids"
exec sleep 600
