#!/usr/bin/env bash
# DIVE-1535: default a2a return-channel convention seeded into a new codex
# agent's standing instructions. Follow-up to DIVE-1528/DIVE-1410: the push-back
# convention was proven end-to-end but only ever hand-written into andy's
# ~/.codex/AGENTS.md, so every other codex worker booted with no return channel.
#
# Pure test — no root, network, users, or runtime state. Exercises the content
# generator (_codex_return_channel_doc) plus the non-destructive guard logic of
# preseed_codex_return_channel with the filesystem primitives stubbed to a temp
# HOME. The real ownership/perms plumbing is covered by the create-path smoke test.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/agent_setup.sh

pass=0
check() { if eval "$2"; then pass=$((pass+1)); else echo "FAIL: $1"; exit 1; fi; }

# --- content generator: agent-name interpolation + push-back convention -------
doc=$(_codex_return_channel_doc andy)
check "doc names the agent"            '[[ "$doc" == *"# andy — standing instructions"* ]]'
check "doc has the push-back verb"     'grep -q "5dive agent send <from>" <<<"$doc"'
check "doc cites DIVE-1410 rationale"  '[[ "$doc" == *"DIVE-1410"* ]]'
check "doc warns no backticks"         '[[ "$doc" == *"NO backticks"* ]]'
check "doc says when-done not mid-job" '[[ "$doc" == *"not mid-render"* ]]'
# A different agent name interpolates through, not a hardcoded "andy".
doc2=$(_codex_return_channel_doc worker7)
check "doc interpolates any name"      '[[ "$doc2" == *"# worker7 — standing instructions"* && "$doc2" == *"You (worker7)"* ]]'

# --- non-destructive + fresh-seed behavior, with primitives stubbed ----------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
HOME_BASE="$tmp/home"
# Stub the plumbing so preseed_codex_return_channel writes into $tmp, not /home.
id() { return 0; }                                   # user "exists"
install() {                                          # honor -d (mkdir) and file-create
  local mkdir=0 dest=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) mkdir=1 ;;
      -m|-o|-g) shift ;;                             # skip mode/owner/group values
      /dev/null) : ;;                                # source placeholder
      *) dest="$1" ;;
    esac
    shift
  done
  if (( mkdir )); then mkdir -p "$dest"; else : >"$dest"; fi
}
sudo() {                                             # drop `-u <user>`, run the rest here
  shift 2
  "$@"
}

seed_one() {                                         # run against a rewritten home path
  local name="$1"
  local home="$HOME_BASE/agent-${name}"
  mkdir -p "$home"
  # Re-run the real logic but with $home pointed at the temp tree. The function
  # hardcodes /home/agent-<name>, so exercise its body via a thin local copy that
  # only differs in the home base — keeping the guard + write path identical.
  local user="agent-${name}" dir="$home/.codex" file="$home/.codex/AGENTS.md"
  if sudo -u "$user" test -e "$file"; then return 0; fi
  install -d -m 700 -o "$user" -g "$user" "$dir" 2>/dev/null || return 0
  install -m 600 -o "$user" -g "$user" /dev/null "$file" 2>/dev/null || return 0
  _codex_return_channel_doc "$name" | sudo -u "$user" tee "$file" >/dev/null
}

# fresh agent → file is created with the convention
seed_one fresh
f="$HOME_BASE/agent-fresh/.codex/AGENTS.md"
check "fresh seed creates AGENTS.md"   '[[ -f "$f" ]]'
check "fresh seed has convention"      'grep -q "5dive agent send <from>" "$f"'

# curated file already present → NOT overwritten
mkdir -p "$HOME_BASE/agent-curated/.codex"
printf 'CUSTOM CURATED FILE\n' > "$HOME_BASE/agent-curated/.codex/AGENTS.md"
seed_one curated
check "existing AGENTS.md untouched"   'grep -qx "CUSTOM CURATED FILE" "$HOME_BASE/agent-curated/.codex/AGENTS.md"'
check "existing file not appended-to"  '[[ $(wc -l < "$HOME_BASE/agent-curated/.codex/AGENTS.md") -eq 1 ]]'

echo "codex_return_channel_unit: ${pass}/${pass} checks passed"
