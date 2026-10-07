#!/usr/bin/env bash
# DIVE-5820 — a hire that names no account, on a fresh box whose only AI is the
# free demo-ai account, used to mint an empty per-agent profile and launch
# DEGRADED. Grade the rule (_import_demo_ai_default) on box fixtures through the
# REAL credential check (cmd_auth.sh auth_creds_present), then the real
# cmd_import seam up to the cmd_create argv.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/lib/validation.sh
# shellcheck source=/dev/null
STATE_DIR="$(mktemp -d)"   # cmd_auth.sh reads it at source time; never the live /var/lib/5dive
source src/cmd_auth.sh
# shellcheck source=/dev/null
source src/cmd_pack.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

TMP=$(mktemp -d); rm -rf "$STATE_DIR"
AUTH_PROFILES_DIR="$TMP/auth-profiles"
CONNECTORS_DIR="$TMP/connectors"
declare -A TYPE_AUTH=([claude]="$CONNECTORS_DIR/anthropic.env:CLAUDE_CODE_OAUTH_TOKEN")
declare -A TYPE_API_FILE=([claude]="anthropic.env")

# box <profile:line>... — a fresh box: each arg is one account and one line of
# its combined.env (an empty line = the empty per-agent profile an import mints).
box() {
  rm -rf "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR"
  mkdir -p "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR"
  local a
  for a in "$@"; do
    mkdir -p "$AUTH_PROFILES_DIR/${a%%:*}"
    printf '%s\n' "${a#*:}" > "$AUTH_PROFILES_DIR/${a%%:*}/combined.env"
  done
}
rule() { _import_demo_ai_default "$1" && echo bind || echo keep; }
DEMO='demo-ai:ANTHROPIC_AUTH_TOKEN=sk-or-v1-fixture'

echo '== the rule =='
box "$DEMO"
eq_t 'only demo-ai on the box: a claude hire binds it' bind "$(rule claude)"
eq_t 'a codex hire never binds the claude demo key' keep "$(rule codex)"
box "$DEMO" 'olivia:'
eq_t "an earlier hire's EMPTY per-agent profile is not an AI of the owner's" bind "$(rule claude)"
box "$DEMO" 'mark:CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture'
eq_t "the owner's own Claude account wins: keep the per-agent sign-in" keep "$(rule claude)"
box "$DEMO" 'gpt:OPENAI_API_KEY=sk-fixture'
eq_t 'an account that only signs in codex does not count against demo-ai' bind "$(rule claude)"
box "$DEMO"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-shared\n' > "$CONNECTORS_DIR/anthropic.env"
eq_t "the box's shared Claude login counts as the owner's: keep" keep "$(rule claude)"
box 'demo-ai:'
eq_t 'a demo-ai account with no key is not an AI' keep "$(rule claude)"
box
eq_t 'no demo-ai on the box: keep' keep "$(rule claude)"
box 'demo-ai:# ANTHROPIC_AUTH_TOKEN=commented-out'
eq_t 'a commented-out key is not a key' keep "$(rule claude)"

echo '== real cmd_import seam =='
# As in pack_import_isolation_override_unit.sh: drive cmd_import through the
# manifest and stop at cmd_create, recording its argv.
printf '%s\n' '{"packFormat":1,"agentName":"marcus","config":{"type":"claude"},"includes":{"memory":false}}' > "$TMP/manifest.json"
: > "$TMP/marcus.tar.gz"
export DIVE5820_FIXTURE="$TMP/manifest.json"
require_root() { :; }
registry_read() { printf '%s\n' '{"agents":{}}'; }
_agents_md_is() { return 1; }
_pack_safe_extract() { cp "$DIVE5820_FIXTURE" "$2/manifest.json"; }
_pack_harness_targets() { printf '%s\n' claude codex; }
_pack_targets_declared() { return 1; }
_pack_disclosure_json() { printf '%s\n' '{}'; }
_pack_disclosure_print() { :; }
_pack_rename_persona() { :; }
resolve_model_alias() { printf '%s' "$1"; }
resolve_model_for_profile() { printf '%s' "$1"; }
is_known_type() { [[ "$1" == claude || "$1" == codex ]]; }
step() { printf 'STEP: %s\n' "$*" >> "$DIVE5820_REC.log"; }
cmd_create() { printf '%s\n' "$@" > "$DIVE5820_REC"; return 1; }
import_profile() { # <label> <args>... — the --auth-profile cmd_create got
  export DIVE5820_REC="$TMP/$1.argv"; shift
  rm -f "$DIVE5820_REC" "$DIVE5820_REC.log"
  ( cmd_import "$TMP/marcus.tar.gz" "$@" ) >/dev/null 2>&1
  grep -m1 '^--auth-profile=' "$DIVE5820_REC" 2>/dev/null || echo "(cmd_create not reached)"
}

box "$DEMO"
eq_t "lodar's hire (agent import marcus --as=marcus, no account) on a demo-only box binds demo-ai" \
  '--auth-profile=demo-ai' "$(import_profile lodar --as=marcus)"
grep -q "free demo AI account 'demo-ai'" "$TMP/lodar.argv.log" 2>/dev/null \
  && ok_t 'the import says which account it used' \
  || bad_t 'the import did not say it bound demo-ai' "$(cat "$TMP/lodar.argv.log" 2>/dev/null)"
eq_t 'an explicit account is never overridden' \
  '--auth-profile=mine' "$(import_profile explicit --as=marcus --auth-profile=mine)"
eq_t 'a codex hire keeps the per-agent profile' \
  '--auth-profile=marcus' "$(import_profile codex --as=marcus --type=codex)"
eq_t 'a BYO key keeps the per-agent profile' \
  '--auth-profile=marcus' "$(import_profile byo --as=marcus --provider=openrouter --api-key=sk-or-v1-x)"
box "$DEMO" 'mark:CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture'
eq_t "with the owner's own Claude account, the DIVE-620 per-agent profile stays" \
  '--auth-profile=marcus' "$(import_profile own --as=marcus)"

echo
printf 'DIVE-5820 import binds demo-ai on a demo-only box: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
