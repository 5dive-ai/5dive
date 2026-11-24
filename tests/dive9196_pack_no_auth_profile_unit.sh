#!/usr/bin/env bash
# DIVE-9196 — an exported agent (and so every member of a team export) carried
# the exporter's sign-in name in config.authProfile, and import took it ahead of
# the box's own defaults: the recipient's seat came up bound to an empty profile
# named after someone else's account. Export now writes null; import ignores the
# pack's value, so packs already in the wild land on this box's account.
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

echo '== export =='
registry_read() { printf '%s\n' '{"agents":{"rex":{"type":"claude","isolation":"standard","workdir":"/w","authProfile":"plan"}}}'; }
cfg=$(_pack_agent_config rex)
eq_t 'a seat signed in on "plan" exports authProfile null' null "$(jq -c '.authProfile' <<<"$cfg")"
eq_t 'the rest of the config still travels' '"claude" "/w"' "$(jq -c '.type, .workdir' <<<"$cfg" | paste -sd' ')"

echo '== import of a pack that still carries authProfile=plan =='
AUTH_PROFILES_DIR="$TMP/auth-profiles"
CONNECTORS_DIR="$TMP/connectors"
declare -A TYPE_AUTH=([claude]="$CONNECTORS_DIR/anthropic.env:CLAUDE_CODE_OAUTH_TOKEN")
declare -A TYPE_API_FILE=([claude]="anthropic.env")
box() { # <profile:line>... — each arg one account and one line of its combined.env
  rm -rf "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR"
  mkdir -p "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR"
  local a
  for a in "$@"; do
    mkdir -p "$AUTH_PROFILES_DIR/${a%%:*}"
    printf '%s\n' "${a#*:}" > "$AUTH_PROFILES_DIR/${a%%:*}/combined.env"
  done
}
printf '%s\n' '{"packFormat":1,"agentName":"rex","config":{"type":"claude","authProfile":"plan"},"includes":{"memory":false}}' > "$TMP/manifest.json"
: > "$TMP/rex.tar.gz"
export DIVE9196_FIXTURE="$TMP/manifest.json"
require_root() { :; }
registry_read() { printf '%s\n' '{"agents":{}}'; }
_agents_md_is() { return 1; }
_pack_safe_extract() { cp "$DIVE9196_FIXTURE" "$2/manifest.json"; }
_pack_harness_targets() { printf '%s\n' claude codex; }
_pack_targets_declared() { return 1; }
_pack_disclosure_json() { printf '%s\n' '{}'; }
_pack_disclosure_print() { :; }
_pack_rename_persona() { :; }
resolve_model_alias() { printf '%s' "$1"; }
resolve_model_for_profile() { printf '%s' "$1"; }
is_known_type() { [[ "$1" == claude || "$1" == codex ]]; }
step() { :; }
cmd_create() { printf '%s\n' "$@" > "$DIVE9196_REC"; return 1; }
import_profile() { # <label> <args>... — the --auth-profile cmd_create got
  export DIVE9196_REC="$TMP/$1.argv"; shift
  rm -f "$DIVE9196_REC"
  ( cmd_import "$TMP/rex.tar.gz" "$@" ) >/dev/null 2>&1
  grep -m1 '^--auth-profile=' "$DIVE9196_REC" 2>/dev/null || echo "(no --auth-profile)"
}
fn() { awk -v n="$2" '$0 ~ "^"n"\\(\\) \\{" { on = 1 } on { print } on && $0 == "}" { exit }' "$1"; }
for f in _create_sole_account _create_has_login _create_uses_demo_ai _create_demo_ai_key; do eval "$(fn src/cmd_agent_create.sh "$f")"; done
eval "$(grep -m1 '^CREATE_DEMO_AI_ACCOUNT=' src/cmd_agent_create.sh)"

box 'mark:CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture'
eq_t "a box with one signed-in account: the seat uses it, not the exporter's 'plan'" \
  '--auth-profile=mark' "$(import_profile sole --as=rex)"
eq_t 'an explicit --auth-profile still wins' \
  '--auth-profile=mine' "$(import_profile explicit --as=rex --auth-profile=mine)"
box
eq_t "a box with no AI: the per-agent profile, never 'plan'" \
  '--auth-profile=rex' "$(import_profile empty --as=rex)"

echo
printf 'DIVE-9196 packs carry no sign-in name: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
