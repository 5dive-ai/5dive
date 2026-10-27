#!/usr/bin/env bash
# DIVE-7074 — `team import <slug> --auth-profile=<account>` puts every seat that
# names no account on that account, also on a box with two Claude logins.
#
# The Dropshipping trial (DIVE-6902, OSS CLI 0.102.0): `team import dropshipping
# --auth-profile=mp` printed "--auth-profile=mp has no effect on this template"
# and all six seats came up signed out, each on its own empty profile. The flag
# only filled ${TEAM_AUTH_PROFILE}, which no marketplace template references.
# DIVE-7028 covers a box with ONE login; on a box with two (a work and a personal
# plan) the owner's explicit choice was still dropped.
#
#   1. the spec transform (_compose_apply_auth_profile): which seats move;
#   2. the REAL `up` (cmd_compose_up), every `agent import|create` it runs
#      recorded instead of run: the argv each seat gets, with and without the flag;
#   3. `team import` hands the flag to `up`, and no longer warns;
#   4. the real cmd_import -> cmd_create on a two-login box, fed the argv `up`
#      built: the seat is signed in on that account at create, not deferred.
#
# COVERAGE LIMIT: no unix user is made (create stops at create_agent_user), so
# "the seat's process boots AUTH ok" is the live arm on a scratch box, not this.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/lib/models.sh
# shellcheck disable=SC1091
source src/lib/agent_setup.sh
STATE_DIR="$(mktemp -d)"   # cmd_auth.sh reads it at source time; never the live /var/lib/5dive
# shellcheck disable=SC1091
source src/cmd_auth.sh
# shellcheck disable=SC1091
source src/cmd_agent_create.sh
# shellcheck disable=SC1091
source src/cmd_pack.sh
# shellcheck disable=SC1091
source src/cmd_compose.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

TMP=$(mktemp -d); rm -rf "$STATE_DIR"; STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"

# The Dropshipping template's shape (marketplace teams/dropshipping.5dive.yaml):
# claude by default, defer_auth, every seat a pack, no account named anywhere.
# Plus the two seats the row says keep theirs: one names its own account, one
# brings its own key.
cat > "$TMP/shop.5dive.yaml" <<'YAML'
version: "2"
defaults:
  type: claude
  defer_auth: true
agents:
  clip:    {pack: clip,    role: "Shop lead"}
  dude:    {pack: dude,    role: "Product scout",  reports_to: clip}
  pixel:   {pack: pixel,   role: "Pictures",       reports_to: clip}
  axe:     {pack: axe,     role: "Ads",            reports_to: clip}
  desk:    {pack: desk,    role: "Buyers",         reports_to: clip}
  clicker: {pack: clicker, role: "Browser hands",  reports_to: clip}
  books:   {role: "Books", reports_to: clip, auth_profile: work}
  byo:     {role: "Cheap", reports_to: clip, provider: openrouter, api_key: sk-or-v1-fixture}
YAML

echo '== 1. the spec transform =='
BASE=$(_compose_parse "$TMP/shop.5dive.yaml" 2>/dev/null)
[[ -n "$BASE" ]] && ok_t 'T0 the template parses' || bad_t 'T0 the template did not parse — every arm below is vacuous' ''
declare -F _compose_apply_auth_profile >/dev/null \
  && ok_t 'T0b the transform exists' || bad_t 'T0b _compose_apply_auth_profile is missing' ''
OVR=$(_compose_apply_auth_profile "$BASE" konst 2>/dev/null)
eq_t 'T1 every seat that names no account goes on konst' \
  '{"axe":"konst","books":"work","byo":"","clicker":"konst","clip":"konst","desk":"konst","dude":"konst","pixel":"konst"}' \
  "$(jq -cS '.agents | map_values(.auth_profile // "")' <<<"$OVR")"
eq_t 'T1b NEGATIVE CONTROL: the parsed template itself names no account but books' \
  '{"axe":"","books":"work","byo":"","clicker":"","clip":"","desk":"","dude":"","pixel":"","x":""}' \
  "$(jq -cS '.agents | map_values(.auth_profile // "") + {x:""}' <<<"$BASE")"
eq_t 'T1c nothing else in a seat changes' \
  "$(jq -cS '.agents | map_values(del(.auth_profile))' <<<"$BASE")" \
  "$(jq -cS '.agents | map_values(del(.auth_profile))' <<<"$OVR")"

echo '== 2. the real up, every agent call recorded =='
# What `up` would run as `5dive agent import|create`, one argv per file.
cat > "$TMP/fake5dive" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == agent && ( "${2:-}" == import || "${2:-}" == create ) ]]; then
  verb=$2; shift 2
  name=""; for a in "$@"; do case "$a" in --as=*) name="${a#--as=}" ;; esac; done
  [[ -n "$name" ]] || name="$1"
  printf '%s\n' "$@" > "$RECORD/$verb.$name"
fi
exit 0
SH
chmod +x "$TMP/fake5dive"
export RECORD="$TMP/rec"
_compose_self() { printf '%s' "$TMP/fake5dive"; }
ensure_state() { :; }
require_root() { :; }
registry_read() { printf '%s\n' '{"agents":{}}'; }
_compose_wire_role() { :; }
step() { printf 'STEP: %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
# up <args>... — run the real cmd_compose_up; its output in $TMP/up.log.
up() {
  rm -rf "$RECORD"; mkdir -p "$RECORD"
  ( cmd_compose_up -f "$TMP/shop.5dive.yaml" "$@" ) > "$TMP/up.log" 2>&1
}
# seat <name> — the --auth-profile= the seat's create/import argv carries, or (none).
seat() {
  local f; f=$(ls "$RECORD"/*."$1" 2>/dev/null | head -1)
  [[ -n "$f" ]] || { echo '(not created)'; return; }
  grep -m1 '^--auth-profile=' "$f" || echo '(none)'
}
roster() { local n; for n in clip dude pixel axe desk clicker books byo; do printf '%s=%s ' "$n" "$(seat "$n")"; done; }

up --auth-profile=konst; up_rc=$?
eq_t 'T2 up --auth-profile=konst runs' 0 "$up_rc"
[[ $up_rc -eq 0 ]] || printf '%s\n' "$(tail -15 "$TMP/up.log")" >&2
eq_t 'T2a all six pack seats are imported on konst; books keeps work; byo keeps its key' \
  'clip=--auth-profile=konst dude=--auth-profile=konst pixel=--auth-profile=konst axe=--auth-profile=konst desk=--auth-profile=konst clicker=--auth-profile=konst books=--auth-profile=work byo=(none) ' \
  "$(roster)"
grep -q -- '--api-key=sk-or-v1-fixture' "$RECORD/create.byo" 2>/dev/null \
  && ok_t 'T2b the BYO seat still gets its own key' || bad_t 'T2b the BYO seat lost its key' "$(cat "$RECORD/create.byo" 2>/dev/null)"
grep -qF "every seat that names none signs in on 'konst'" "$TMP/up.log" \
  && ok_t 'T2c up says which account the roster is on' || bad_t 'T2c up did not name the account' "$(cat "$TMP/up.log")"

up
eq_t 'T3 NEGATIVE CONTROL: without the flag nothing changes (DIVE-7028 then picks a one-login box'"'"'s account per seat)' \
  'clip=(none) dude=(none) pixel=(none) axe=(none) desk=(none) clicker=(none) books=--auth-profile=work byo=(none) ' \
  "$(roster)"

up --auth-profile=Bad.Name; bad_rc=$?
[[ $bad_rc -ne 0 && ! -d "$RECORD" || $bad_rc -ne 0 && -z "$(ls "$RECORD")" ]] \
  && ok_t 'T4 a malformed account name is refused before any seat is made' \
  || bad_t 'T4 a malformed --auth-profile was accepted or made seats' "rc=$bad_rc $(ls "$RECORD" 2>/dev/null | tr '\n' ' ')"

echo '== 3. team import hands it to up =='
UPARGS="$TMP/upargs"
( cmd_compose_up() { printf '%s\n' "$@" > "$UPARGS"; return 0; }
  _team_manifest_write() { :; }
  cmd_team import "$TMP/shop.5dive.yaml" --auth-profile=konst ) > "$TMP/import.log" 2>&1
grep -qx -- '--auth-profile=konst' "$UPARGS" 2>/dev/null \
  && ok_t 'T5 team import --auth-profile=konst runs up with --auth-profile=konst' \
  || bad_t 'T5 the flag did not reach up' "up argv: $(tr '\n' ' ' < "$UPARGS" 2>/dev/null) · $(tail -5 "$TMP/import.log")"
grep -q 'has no effect' "$TMP/import.log" \
  && bad_t 'T5b team import still says the flag has no effect' "$(grep 'has no effect' "$TMP/import.log")" \
  || ok_t 'T5b no "has no effect" warning'

echo '== 4. two Claude logins: the seat is signed in on the named one =='
AUTH_PROFILES_DIR="$TMP/auth-profiles"; CONNECTORS_DIR="$TMP/connectors"
TYPE_AUTH[claude]="$CONNECTORS_DIR/anthropic.env:CLAUDE_CODE_OAUTH_TOKEN"
mkdir -p "$TMP/bin" "$CONNECTORS_DIR" "$AUTH_PROFILES_DIR"/{mp,konst}
for _t in claude codex; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$_t"; chmod +x "$TMP/bin/$_t"; TYPE_BIN[$_t]="$TMP/bin/$_t"; done
cmd_install() { return 1; }
export FIVEDIVE_CHAT_ONLY_MARK="$TMP/chat-only"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture-mp\n'    > "$AUTH_PROFILES_DIR/mp/combined.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture-konst\n' > "$AUTH_PROFILES_DIR/konst/combined.env"
actor_routing_agent() { return 1; }
create_agent_user() { printf 'REACHED profile=%s defer=%s\n' "$profile" "$defer_auth"; exit 0; }
printf '%s\n' '{"packFormat":1,"agentName":"clip","config":{"type":"claude"},"includes":{"memory":false}}' > "$TMP/manifest.json"
: > "$TMP/clip.tar.gz"
export DIVE7074_FIXTURE="$TMP/manifest.json"
_agents_md_is() { return 1; }
_pack_safe_extract() { cp "$DIVE7074_FIXTURE" "$2/manifest.json"; }
_pack_harness_targets() { printf '%s\n' claude codex; }
_pack_targets_declared() { return 1; }
_pack_disclosure_json() { printf '%s\n' '{}'; }
_pack_disclosure_print() { :; }
_pack_rename_persona() { :; }
resolve_model_alias() { printf '%s' "$1"; }
resolve_model_for_profile() { printf '%s' "$1"; }
# made <import-argv-file> — the account and deferral the real create reached:
# the real cmd_import builds the create argv (recorded), then the real cmd_create
# runs it, stopped where the agent user would be made.
made() {
  mapfile -t A < "$1"; A=("${A[@]:1}")   # drop the pack slug: the fixture tarball stands in for it
  local rec="$TMP/create.argv"; rm -f "$rec"
  ( cmd_create() { printf '%s\n' "$@" > "$rec"; return 1; }; cmd_import "$TMP/clip.tar.gz" "${A[@]}" ) >/dev/null 2>&1
  [[ -f "$rec" ]] || { echo '(cmd_create not reached)'; return; }
  mapfile -t C < "$rec"
  local out; out=$( ( cmd_create "${C[@]}" ) 2>&1 )
  grep -m1 '^REACHED ' <<<"$out" | sed 's/^REACHED //' || true
  grep -q '^REACHED ' <<<"$out" || echo "(refused: $(tail -2 <<<"$out" | tr '\n' ' '))"
}
up --auth-profile=konst
eq_t 'T6 clip, imported with the argv up built under --auth-profile=konst: signed in on konst, not deferred' \
  'profile=konst defer=0' "$(made "$RECORD/import.clip")"
up
eq_t 'T6n NEGATIVE CONTROL: without the flag, two logins: clip is left to sign in later on its own profile' \
  'profile=clip defer=1' "$(made "$RECORD/import.clip")"

echo
printf 'DIVE-7074 team import --auth-profile puts every seat on it: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
