#!/bin/bash
# A stand-in for `claude`, for the Page pass. No model is called.
#  --version / --help    what the app's probes read; any other probe that is
#                        not a turn exits at once.
#  the skill listing     (stream-json input carrying control requests):
#                        each request refused the way a claude that does
#                        not know it refuses it, so the listing ends at once.
#  a turn (`-p`)         its arguments to $HOME/claude-argv.log and, when it
#                        reads its message from stdin, every line to
#                        $HOME/claude-stdin.log; then `init`, the session's
#                        transcript where claude writes it, and `result`.
#                        A message holding "never named" ends a second
#                        later with an error and no `init` or transcript,
#                        as a claude that cannot start does: the session
#                        is never named. One holding "slow start" waits
#                        three seconds before its `init` and transcript, as
#                        a claude loading its plugins and MCP servers does:
#                        the session is named a while after the message
#                        went.
case "$1" in
  --version) echo "2.1.301 (Claude Code)"; exit 0 ;;
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
args=("$@")
# Anything but a turn (`-p`) is one of the app's capability probes.
is_turn=0
for a in "${args[@]}"; do [ "$a" = "-p" ] && is_turn=1; done
[ "$is_turn" = 1 ] || exit 0
# The message comes on stdin only under `--input-format stream-json`; every
# turn also asks for `--output-format stream-json`, which says nothing about
# where its message is.
streamed=0
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = "--input-format" ] && [ "${args[$((i + 1))]}" = "stream-json" ] && streamed=1
done
text=""
unnamed=0
slow=0
if [ "$streamed" = 1 ]; then
  turn=0
  while IFS= read -r line; do
    if [[ "$line" == *'"control_request"'* ]]; then
      id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\1/')
      printf '{"type":"control_response","response":{"subtype":"error","request_id":"%s","error":"Unsupported control request subtype"}}\n' "$id"
    else
      turn=1
      echo "$line" >> "$HOME/claude-stdin.log"
      [[ "$line" == *"never named"* ]] && unnamed=1
      [[ "$line" == *"slow start"* ]] && slow=1
    fi
  done
  [ "$turn" = 1 ] || exit 0
  text="(stdin)"
fi
echo "ARGV: $*" >> "$HOME/claude-argv.log"
resume=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -p) [ "$streamed" = 1 ] || text="${args[$((i + 1))]}" ;;
    --resume) resume="${args[$((i + 1))]}" ;;
  esac
done
[[ "$text" == *"never named"* ]] && unnamed=1
[[ "$text" == *"slow start"* ]] && slow=1
if [ "$unnamed" = 1 ]; then
  sleep 1
  echo "the stand-in failed to start" >&2
  exit 1
fi
[ "$slow" = 1 ] && sleep 3
sid="${resume:-$(uuidgen | tr 'A-Z' 'a-z')}"
cwd="$(pwd -P)"
dir="$HOME/.claude/projects/$(echo "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$dir"
ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
u="$(uuidgen | tr 'A-Z' 'a-z')"
printf '{"type":"user","uuid":"%s","parentUuid":null,"isSidechain":false,"sessionId":"%s","cwd":"%s","timestamp":"%s","permissionMode":"default","message":{"role":"user","content":"%s"},"version":"2.1.301","entrypoint":"sdk-cli","userType":"external"}\n' \
  "$u" "$sid" "$cwd" "$ts" "${text:-hello}" >> "$dir/$sid.jsonl"
printf '{"type":"system","subtype":"init","session_id":"%s","cwd":"%s","model":"claude-opus-5-5","permissionMode":"default","tools":[],"mcp_servers":[],"slash_commands":[],"apiKeySource":"none"}\n' \
  "$sid" "$cwd"
sleep 0.3
printf '{"type":"result","subtype":"success","is_error":false,"result":"Done.","session_id":"%s","num_turns":1,"duration_ms":300,"usage":{"input_tokens":10,"output_tokens":5}}\n' "$sid"
exit 0
