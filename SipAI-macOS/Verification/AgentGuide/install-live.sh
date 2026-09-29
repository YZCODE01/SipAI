#!/bin/bash
# The three install routes for real, under a throwaway HOME, then each
# delete plan — the measurement behind Settings → Agent Guide's Install
# and Delete. Downloads ~500 MB. Nothing outside $HOME_T is touched:
# Anthropic's and Moonshot's installers put everything under $HOME,
# and the codex route is SipAI's own layout under $HOME too.
#
#   bash install-live.sh [source-root]
set -u
src="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
HOME_T="$(mktemp -d /tmp/sipai-guide-home.XXXXXX)"
export HOME="$HOME_T"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1${2:+ — $2}"; }
trap 'rm -rf "$HOME_T"' EXIT

echo "HOME=$HOME_T"

# ---- claude: Anthropic's installer, then the delete plan ------------
echo
echo "claude — claude.ai/install.sh"
if curl -fsSL --max-time 30 https://claude.ai/install.sh -o "$HOME_T/claude-install.sh"; then
  ok "installer downloaded ($(wc -c < "$HOME_T/claude-install.sh" | tr -d ' ') bytes)"
  ( cd "$HOME_T" && /bin/bash "$HOME_T/claude-install.sh" > "$HOME_T/claude-install.log" 2>&1 < /dev/null )
  code=$?
  if [ -x "$HOME_T/.local/bin/claude" ] || [ -L "$HOME_T/.local/bin/claude" ]; then
    ok "installed to \$HOME/.local/bin/claude (exit $code)"
    ver="$("$HOME_T/.local/bin/claude" --version 2>/dev/null | head -1)"
    [ -n "$ver" ] && ok "answers --version: $ver" || bad "answers --version" "$(tail -3 "$HOME_T/claude-install.log")"
    ls "$HOME_T/.local/share/claude" >/dev/null 2>&1 && ok "versions tree under \$HOME/.local/share/claude: $(ls "$HOME_T/.local/share/claude" | tr '\n' ' ')"
    if grep -q ".local/bin" "$HOME_T/.zshrc" 2>/dev/null; then
      echo "       note: the installer wrote a PATH line to .zshrc: $(grep -n '.local/bin' "$HOME_T/.zshrc" | head -1)"
    else
      echo "       note: the installer did NOT touch .zshrc non-interactively (\$HOME/.zshrc: $([ -f "$HOME_T/.zshrc" ] && echo present || echo absent))"
    fi
    echo "       installer tail: $(tail -2 "$HOME_T/claude-install.log" | tr '\n' ' ')"
    # the delete plan: the launcher and the versions tree
    rm -f "$HOME_T/.local/bin/claude"; rm -rf "$HOME_T/.local/share/claude"
    [ ! -e "$HOME_T/.local/bin/claude" ] && [ ! -e "$HOME_T/.local/share/claude" ] && ok "delete plan leaves no claude binary" || bad "delete plan"
    [ -d "$HOME_T/.claude" ] && ok "…and \$HOME/.claude (settings, sessions) survives" || echo "       note: no \$HOME/.claude was created by the install"
  else
    bad "installed to \$HOME/.local/bin/claude" "exit $code: $(tail -5 "$HOME_T/claude-install.log" | tr '\n' ' ')"
  fi
else
  bad "installer downloaded"
fi

# ---- kimi: Moonshot's installer, then `kimi upgrade` under EOF, then the delete plan
echo
echo "kimi — code.kimi.com/kimi-code/install.sh"
latest="$(curl -fsSL --max-time 15 https://code.kimi.com/kimi-code/latest | tr -d '[:space:]')"
# The PATH the Guide hands the installer: SipAI's child PATH shape with
# SipAI's own guesses for kimi's directories taken out
# (`AgentInstallRoute.kimiInstallerEnvironment`). The installer edits
# the shell's rc file only when `$KIMI_INSTALL_DIR/bin` is NOT already
# on PATH, so the bare PATH this script used to run under passed for
# the wrong reason, and SipAI's unfixed shape — ~/.kimi-code/bin always
# present — wrote no line: SipAI found kimi, Terminal did not.
GUIDE_PATH="/usr/local/bin:/usr/bin:/opt/homebrew/bin:$HOME_T/.local/bin:/usr/sbin:/sbin:/bin"
if curl -fsSL --max-time 30 https://code.kimi.com/kimi-code/install.sh -o "$HOME_T/kimi-install.sh"; then
  ok "installer downloaded; latest = $latest"
  # The script's OWN PATH rule, run on its own functions and no
  # download: the installer minus its final `main "$@"` is sourced from
  # a file (bash 3.2's `source` reads nothing from a process
  # substitution), then `_update_path` alone runs, under each PATH
  # shape, into a HOME of its own — the kimi bin on the unfixed PATH is
  # THAT home's, which is what the installer compares against.
  /usr/bin/grep -v -x -F 'main "$@"' "$HOME_T/kimi-install.sh" > "$HOME_T/kimi-installer-functions.sh"
  cat > "$HOME_T/probe-update-path.sh" <<'EOF'
#!/bin/bash
source "$1"
_update_path
EOF
  probe_update_path() {  # $1 = HOME to write into, $2 = "own-bin-on-path" | "guide"
    local home="$1" probePath   # not `path`: zsh ties that name to PATH
    mkdir -p "$home"
    if [ "$2" = "own-bin-on-path" ]; then
      probePath="/usr/local/bin:/usr/bin:/opt/homebrew/bin:$home/.local/bin:$home/.kimi-code/bin:$home/.kimi/bin:/usr/sbin:/sbin:/bin"
    else
      probePath="/usr/local/bin:/usr/bin:/opt/homebrew/bin:$home/.local/bin:/usr/sbin:/sbin:/bin"
    fi
    ( cd "$home" && env -i HOME="$home" SHELL=/bin/zsh PATH="$probePath" /bin/bash "$HOME_T/probe-update-path.sh" "$HOME_T/kimi-installer-functions.sh" >/dev/null 2>&1 )
    /usr/bin/grep -qsF ".kimi-code/bin" "$home/.zshrc"
  }
  if probe_update_path "$HOME_T/probe-unfixed" own-bin-on-path; then
    bad "negative control: with its own bin on PATH (SipAI's unfixed shape) _update_path wrote a line" "the installer's rule changed — it used to skip"
  else
    ok "negative control: with its own bin on PATH (SipAI's unfixed shape) _update_path writes NO rc line"
  fi
  if probe_update_path "$HOME_T/probe-fixed" guide; then
    ok "under the PATH the Guide hands it, _update_path writes the rc line"
  else
    bad "under the PATH the Guide hands it, _update_path writes the rc line" "no .kimi-code/bin in $HOME_T/probe-fixed/.zshrc"
  fi
  ( cd "$HOME_T" && env PATH="$GUIDE_PATH" /bin/bash "$HOME_T/kimi-install.sh" --version "$latest" > "$HOME_T/kimi-install.log" 2>&1 < /dev/null )
  code=$?
  if [ -x "$HOME_T/.kimi-code/bin/kimi" ]; then
    ok "installed to \$HOME/.kimi-code/bin/kimi (exit $code)"
    ver="$("$HOME_T/.kimi-code/bin/kimi" --version 2>/dev/null | head -1)"
    [ "$ver" = "$latest" ] && ok "answers --version $ver" || bad "answers --version" "got '$ver'"
    grep -q ".kimi-code/bin" "$HOME_T/.zshrc" 2>/dev/null && ok "the installer added the PATH line to .zshrc under the Guide's PATH (as a Terminal install does)" || bad "the installer added the PATH line to .zshrc" "$(tail -2 "$HOME_T/kimi-install.log" | tr '\n' ' ')"
    [ -f "$HOME_T/.kimi-code/region" ] && ok "region file written: $(cat "$HOME_T/.kimi-code/region")"
    # M-6: `kimi upgrade` with stdin at EOF, on a CURRENT install (nothing to do) — what does it print, and does it exit 0?
    out="$(cd "$HOME_T" && /usr/bin/perl -e 'alarm 60; exec @ARGV' "$HOME_T/.kimi-code/bin/kimi" upgrade < /dev/null 2>&1)"; ucode=$?
    echo "       M-6 'kimi upgrade' </dev/null on a current install → exit $ucode: $(echo "$out" | tr '\n' ' ' | cut -c1-300)"
    # the delete plan: bin/ alone
    rm -rf "$HOME_T/.kimi-code/bin"
    [ ! -e "$HOME_T/.kimi-code/bin" ] && [ -d "$HOME_T/.kimi-code" ] && ok "delete plan removes bin/ and leaves \$HOME/.kimi-code" || bad "delete plan"
  else
    bad "installed to \$HOME/.kimi-code/bin/kimi" "exit $code: $(tail -5 "$HOME_T/kimi-install.log" | tr '\n' ' ')"
  fi
else
  bad "installer downloaded"
fi

# ---- codex: OpenAI's package, SipAI's layout, then the delete plan ---
echo
echo "codex — OpenAI's release package into \$HOME/.local/share/sipai/codex"
version="$(curl -fsSL --max-time 15 https://registry.npmjs.org/@openai/codex/latest | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
arch="$(uname -m)"; case "$arch" in arm64) asset="codex-package-aarch64-apple-darwin.tar.gz";; x86_64) asset="codex-package-x86_64-apple-darwin.tar.gz";; esac
base="https://github.com/openai/codex/releases/download/rust-v$version"
mkdir -p "$HOME_T/pkg"
if curl -fsSL --max-time 600 -o "$HOME_T/pkg/$asset" "$base/$asset" && curl -fsSL --max-time 30 -o "$HOME_T/pkg/SUMS" "$base/codex-package_SHA256SUMS"; then
  ok "package and checksum file downloaded (rust-v$version)"
  expected="$(grep " $asset\$" "$HOME_T/pkg/SUMS" | cut -d' ' -f1)"
  actual="$(shasum -a 256 "$HOME_T/pkg/$asset" | cut -d' ' -f1)"
  [ "$expected" = "$actual" ] && ok "sha256 matches OpenAI's checksum file" || bad "sha256" "expected $expected got $actual"
  xattr -p com.apple.quarantine "$HOME_T/pkg/$asset" >/dev/null 2>&1 && bad "no quarantine flag on the download" || ok "no quarantine flag on the download"
  root="$HOME_T/.local/share/sipai/codex"; staging="$root/.$version-staging"
  mkdir -p "$staging" "$HOME_T/.local/bin"
  /usr/bin/tar -xzf "$HOME_T/pkg/$asset" -C "$staging" && ok "extracted with /usr/bin/tar"
  entry="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["entrypoint"])' "$staging/codex-package.json")"
  mv "$staging" "$root/$version" && ln -sfn "$root/$version/$entry" "$HOME_T/.local/bin/codex"
  ver="$("$HOME_T/.local/bin/codex" --version 2>/dev/null)"
  [ "$ver" = "codex-cli $version" ] && ok "answers --version through the link: $ver" || bad "answers --version" "got '$ver'"
  upd="$(/usr/bin/perl -e 'alarm 30; exec @ARGV' "$HOME_T/.local/bin/codex" update 2>&1 | head -2 | tr '\n' ' ')"
  echo "$upd" | grep -q "Could not detect the Codex installation method" && ok "codex update declines the layout, as measured" || echo "       note: codex update said: $upd"
  rm -f "$HOME_T/.local/bin/codex"; rm -rf "$root"
  [ ! -e "$HOME_T/.local/bin/codex" ] && [ ! -e "$root" ] && ok "delete plan leaves no codex" || bad "delete plan"
else
  bad "package downloaded"
fi

echo
echo "$pass ok, $fail failed"
[ "$fail" -eq 0 ]
