#!/usr/bin/env bash
# DIVE-1882: 5dive-agent-start must never resolve codex through the bare `v24`
# nvm alias — nvm only ever creates versioned dirs (v24.18.0), so that path is
# absent on a freshly provisioned box and the unit crash-loops forever.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
START="$ROOT/5dive-agent-start"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- static guards -----------------------------------------------------------

grep -qE '/home/claude/\.nvm/versions/node/v24/' "$START" \
  && fail "5dive-agent-start still hardcodes the bare v24 nvm alias (nvm never creates it)"

grep -q 'RestartPreventExitStatus=2 3' "$ROOT/systemd/5dive-agent@.service" \
  || fail "unit must not retry permanent boot failures (exit 2 unknown type / exit 3 binary missing)"

grep -q 'StartLimitBurst=' "$ROOT/systemd/5dive-agent@.service" \
  || fail "unit needs a start limit so a crash-loop cannot run unbounded"

# --- behavioural: resolve_codex against a fake nvm tree ----------------------

# Source only the resolver block; the rest of agent-start needs a real agent.
eval "$(sed -n '/^newest_node24_bin() {/,/^}/p;/^resolve_codex() {/,/^}/p' "$START")"
declare -F newest_node24_bin >/dev/null || fail "could not extract newest_node24_bin"
declare -F resolve_codex     >/dev/null || fail "could not extract resolve_codex"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Repoint the hardcoded absolute paths at a sandbox so the test never depends on
# (or is rescued by) the hand-made v24 symlink on the control-plane host.
sandbox() {
  eval "${1//\/home\/claude/$TMP}"
}
sandbox "$(declare -f newest_node24_bin)"
sandbox "$(declare -f resolve_codex)"

mkdir -p "$TMP/.nvm/versions/node/v24.9.0/bin" \
         "$TMP/.nvm/versions/node/v24.18.0/bin" \
         "$TMP/.local/bin"

# Nothing installed anywhere -> must fail cleanly, not print a bogus path.
resolve_codex >/dev/null 2>&1 && fail "resolve_codex must fail when codex is absent"

# Only the versioned nvm dirs have codex: pick the NEWEST by version sort.
# v24.18.0 sorts BEFORE v24.9.0 lexicographically, so a plain glob picks wrong.
for v in v24.9.0 v24.18.0; do
  printf '#!/bin/sh\n' > "$TMP/.nvm/versions/node/$v/bin/codex"
  chmod +x "$TMP/.nvm/versions/node/$v/bin/codex"
done
got="$(resolve_codex)"
[[ "$got" == "$TMP/.nvm/versions/node/v24.18.0/bin/codex" ]] \
  || fail "expected newest v24.18.0 codex, got '$got'"

# The stable ~/.local/bin link written by `5dive agent install` wins over nvm.
printf '#!/bin/sh\n' > "$TMP/.local/bin/codex"
chmod +x "$TMP/.local/bin/codex"
got="$(resolve_codex)"
[[ "$got" == "$TMP/.local/bin/codex" ]] \
  || fail "expected the stable ~/.local/bin/codex link to win, got '$got'"

echo "PASS: codex resolves via ~/.local/bin then newest nvm v24.*, never the bare v24 alias"
