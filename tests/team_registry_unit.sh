#!/usr/bin/env bash
# DIVE-4196 — team templates resolve from the MARKETPLACE REGISTRY, not from a
# bundled dir, and a template this binary cannot read is REFUSED by version.
#
# What this harness grades, and why each arm exists:
#
#   * The registry is now the only slug source. The bundled dir is gone, so the
#     interesting negative is not "a missing dir errors" — it is that a file
#     SITTING in the old bundled location does not resolve a slug any more. A
#     leftover /usr/local/lib/5dive/team-templates on an upgraded box would
#     otherwise keep serving a stale template forever and the move would be
#     invisible on exactly the boxes it was written for.
#
#   * "Cannot ask" must never be reported as "does not exist". That conflation
#     is the defect class cmd_pack.sh's _marketplace_fetch_pack was written
#     around, and the team path now has the same seam.
#
#   * The schema gate replaces the one guarantee bundling gave for free. It has
#     to fire on a --path import too, and it must NAME the version — a refusal
#     that does not say which 5dive reads the template is not actionable.
set +e -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

command -v jq >/dev/null || { echo 'SKIP - jq unavailable'; exit 0; }

PASS=0
FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- seams -------------------------------------------------------------------
# Only the EXTERNAL seams are replaced: the network and the process-killing
# `fail`. Everything under test is the real code from src/cmd_compose.sh.
E_USAGE=2; E_NOT_FOUND=4
FIVE_VERSION="0.29.0"
FAIL_MSG=""
fail() { FAIL_MSG="$2"; printf '%s\n' "$2" >&2; return "$1"; }
gh_org() { echo "5dive-ai"; }
warn() { :; }
step() { :; }

. "$ROOT/src/cmd_compose.sh" 2>/dev/null

# A registry that exists, offline. $REG_RC drives the failure-class arms.
REG_RC=0
mkdir -p "$TMP/reg/teams"
cat > "$TMP/reg/teams/index.json" <<'JSON'
{"registryFormat":1,"companies":[
 {"slug":"startup","name":"Lean SaaS startup","size":1,"roster":[{"key":"ceo","role":"CEO"}],
  "path":"teams/startup.5dive.yaml","schemaVersion":2},
 {"slug":"from-the-future","name":"Future","size":1,"roster":[{"key":"ceo","role":"CEO"}],
  "path":"teams/from-the-future.5dive.yaml","schemaVersion":9}
]}
JSON
printf 'version: "2"\nteam:\n  slug: startup\n' > "$TMP/reg/teams/startup.5dive.yaml"
printf 'version: "9"\nteam:\n  slug: from-the-future\n' > "$TMP/reg/teams/from-the-future.5dive.yaml"
printf 'team:\n  slug: ancient\n'                       > "$TMP/v1.5dive.yaml"

# Replace the ONE network call. Everything above it is under test.
#
# Every fetch is LOGGED TO A FILE and not counted in a variable, for the same
# reason the fix exists: callers resolve through `$( )`, so a counter kept in a
# variable is incremented in the subshell and lost — a fetch-count arm written
# that way reads 0 no matter what the code does. $BODY_RC fails one template
# BODY while the index still fetches, which is the shape defect (2) needs.
GETLOG="$TMP/gets"; : > "$GETLOG"
BODY_RC=0
_teams_get() {
  local url="$1" out="$2"
  local rel="${url#https://raw.githubusercontent.com/5dive-ai/character-packs/main/}"
  printf '%s\n' "$rel" >> "$GETLOG"
  (( REG_RC == 0 )) || return "$REG_RC"
  if (( BODY_RC != 0 )) && [[ "$rel" != teams/index.json ]]; then return "$BODY_RC"; fi
  [[ -f "$TMP/reg/$rel" ]] || return 1
  cp "$TMP/reg/$rel" "$out"
}
gets_of() { grep -cx "$1" "$GETLOG" 2>/dev/null || echo 0; }

# --- T1 a registry slug resolves and the FETCHED file is what comes back ------
REG_RC=0
f=$(_team_resolve_template startup); rc=$?
if (( rc == 0 )) && [[ -f "$f" ]] && grep -q 'slug: startup' "$f"; then
  ok_t 'T1 a slug resolves through the registry index and the template is fetched'
else
  bad_t 'T1 a registry slug does not resolve' "rc=$rc file=$f"
fi

# --- T2 an unknown slug is rc 1 — the ONLY code that means "does not exist" ---
_team_resolve_template no-such-team >/dev/null 2>&1; rc=$?
(( rc == 1 )) && ok_t 'T2 an unknown slug returns 1 (the index was read and has no such slug)' \
  || bad_t 'T2 an unknown slug does not return 1' "rc=$rc"

# --- T3 an unreachable registry is NOT "does not exist" ----------------------
# The whole point of separating the codes. If this ever returns 1, the CLI tells
# a customer their template was deleted because their wifi dropped.
REG_RC=4
_team_resolve_template startup >/dev/null 2>&1; rc=$?
if (( rc == 24 )); then
  ok_t 'T3 an unreachable registry returns its own class (24), never 1'
else
  bad_t 'T3 a transport failure is reported as a missing slug' "rc=$rc"
fi
# ...and the message a caller prints says so. The class must survive the
# command-substitution subshell every caller resolves through, which is why it
# rides in the return code rather than in a variable.
msg=$( _team_resolve_fail startup 24 2>&1 )
case "$msg" in
  *"network"*|*"transport"*) ok_t 'T3c the cause survives the subshell and names the transport failure' ;;
  *) bad_t 'T3c the cause was lost crossing the subshell (prints "unknown")' "$msg" ;;
esac
msg=$( _team_resolve_fail startup 24 2>&1 ); 
case "$msg" in
  *"not a claim"*|*"could not resolve"*) ok_t 'T3b the refusal text does not assert the slug is absent' ;;
  *) bad_t 'T3b the refusal text asserts absence on a transport failure' "$msg" ;;
esac
REG_RC=0

# --- T4 THE BUNDLED DIR IS DEAD ---------------------------------------------
# A leftover file in the old staged location must not resolve a slug. This is
# the arm that proves the move actually happened on an UPGRADED box.
REG_RC=4
mkdir -p "$TMP/fakelib/team-templates"
printf 'version: "2"\nteam:\n  slug: startup\n' > "$TMP/fakelib/team-templates/startup.5dive.yaml"
out=$(cd "$TMP/fakelib/team-templates" && _team_resolve_template startup 2>/dev/null); rc=$?
if (( rc != 0 )); then
  ok_t 'T4 a leftover bundled template does not resolve a slug once the registry is unreachable'
else
  bad_t 'T4 a stale bundled copy still serves the slug — the move is invisible on upgraded boxes' "$out"
fi
# Control: T4 is not passing merely because everything fails here.
REG_RC=0
_team_resolve_template startup >/dev/null 2>&1 \
  && ok_t 'T4b control — with the registry reachable the same slug DOES resolve' \
  || bad_t 'T4b control failed: nothing resolves in this fixture, so T4 is vacuous' ''

# --- T5 a PATH still resolves, and is the offline route ----------------------
REG_RC=4
f=$(_team_resolve_template "$TMP/v1.5dive.yaml"); rc=$?
[[ $rc -eq 0 && "$f" == "$TMP/v1.5dive.yaml" ]] \
  && ok_t 'T5 a path resolves with no network at all — the documented offline route' \
  || bad_t 'T5 a path does not resolve offline' "rc=$rc f=$f"
REG_RC=0

# --- T6..T9 THE SCHEMA GATE --------------------------------------------------
FAIL_MSG=""; ( _team_assert_schema "$TMP/reg/teams/startup.5dive.yaml" startup ) ; rc=$?
(( rc == 0 )) && ok_t 'T6 a template at the readable schema version is accepted' \
  || bad_t 'T6 a v2 template is refused' "rc=$rc"

FAIL_MSG=""; msg=$( _team_assert_schema "$TMP/reg/teams/from-the-future.5dive.yaml" from-the-future 2>&1 ); rc=$?
if (( rc == E_USAGE )); then
  ok_t 'T7 a template declaring a newer schema is REFUSED, not half-parsed'
else
  bad_t 'T7 a newer-schema template is not refused' "rc=$rc"
fi
case "$msg" in
  *"v9"*"0.29.0"*"v2"*) ok_t 'T7b the refusal names the declared version, this CLI version, and what it reads' ;;
  *) bad_t 'T7b the refusal does not name the versions — nothing the customer can act on' "$msg" ;;
esac

# The gate is about the FILE, so a --path import is gated identically.
cp "$TMP/reg/teams/from-the-future.5dive.yaml" "$TMP/handed-over.5dive.yaml"
( _team_assert_schema "$TMP/handed-over.5dive.yaml" ./handed-over.5dive.yaml ) >/dev/null 2>&1; rc=$?
(( rc == E_USAGE )) \
  && ok_t 'T8 the gate fires on a --path import too, not only on a registry slug' \
  || bad_t 'T8 a path import bypasses the schema gate' "rc=$rc"

# A v1 template (no `version:` at all) is NOT the gate's business.
( _team_assert_schema "$TMP/v1.5dive.yaml" ancient ) >/dev/null 2>&1; rc=$?
(( rc == 0 )) \
  && ok_t 'T9 a template with no version: line is untouched — the gate adds no new refusal to v1' \
  || bad_t 'T9 the gate refuses a v1 template it never used to' "rc=$rc"

# --- T10 ONE INDEX ROUND TRIP PER COMMAND, THROUGH THE SHAPE CALLERS USE -----
# The previous version of this arm called _teams_registry_index directly in the
# harness shell and passed on an inert variable cache: every real caller reads
# the resolver through `$( )`, a subshell, so nothing assigned inside it
# survives. This arm therefore resolves through `$( )` — red before the index
# was carried, green after.
: > "$GETLOG"; REG_RC=0
idx=$(_teams_registry_index)
for _ in 1 2 3; do : "$(_team_resolve_template startup "$idx")"; done
n=$(gets_of teams/index.json)
(( n == 1 )) \
  && ok_t 'T10 three resolves through $( ) with the index carried in = ONE index fetch' \
  || bad_t 'T10 the index is refetched per resolve — the carry does not survive the subshell' "index fetches=$n"

# ...and the control: WITHOUT the carry, each resolve must fetch it again. This
# is what makes T10 mean something rather than passing on a stubbed-out network.
: > "$GETLOG"
for _ in 1 2 3; do : "$(_team_resolve_template startup)"; done
n=$(gets_of teams/index.json)
(( n == 3 )) \
  && ok_t 'T10b control — an uncarried resolve fetches the index each time (so T10 is not vacuous)' \
  || bad_t 'T10b control failed: the uncarried path did not refetch, so T10 grades nothing' "index fetches=$n"

# --- T11..T13 `team ps` WITH NO SLUG: the loop must read the CLASS -----------
# Seams for the roster question only. registry_read/_compose_parse/cmd_compose_ps
# are what "is this roster installed" is made of; this block grades what the
# loop does when a template cannot be READ, so they are held constant.
# The real `fail` (src/lib/output.sh) EXITS. These arms drive cmd_team through
# `$( )`, so an exiting fail is both faithful and contained to the subshell —
# and it is what makes the refusal's exit code gradeable here at all.
fail() { printf 'error: %s\n' "$2" >&2; exit "$1"; }
registry_read()   { echo '{"agents":{"ceo":{}}}'; }
_compose_parse()  { echo '{"agents":{"ceo":{}}}'; }
cmd_compose_ps()  { echo "PS-RENDERED"; }

# T11 the happy path first: both templates resolve, so a roster IS reported and
# the whole command costs exactly one index fetch.
: > "$GETLOG"; REG_RC=0; BODY_RC=0
out=$( cmd_team ps 2>&1 ); rc=$?
n=$(gets_of teams/index.json)
if (( rc == 0 )) && [[ "$out" == *PS-RENDERED* ]] && (( n == 1 )); then
  ok_t 'T11 `team ps` with no slug reports the installed roster in ONE index fetch'
else
  bad_t 'T11 `team ps` with no slug is wrong or refetches the index' "rc=$rc fetches=$n out=$out"
fi

# T12 THE DEFECT: index fine, one template BODY unreachable, roster present.
# `|| continue` swallowed rc 4 and the command asserted no roster is installed.
: > "$GETLOG"; REG_RC=0; BODY_RC=4
out=$( cmd_team ps 2>&1 ); rc=$?
if (( rc != 0 )) && [[ "$out" == *"NOT a claim"* || "$out" == *"could not determine"* ]]; then
  ok_t 'T12 a body-fetch failure is reported as "could not determine", never as "no roster is installed"'
else
  bad_t 'T12 a transport failure comes out as the claim that no roster is installed' "rc=$rc out=$out"
fi
case "$out" in
  *"no complete team roster"*) bad_t 'T12b the refusal still asserts absence on a transport failure' "$out" ;;
  *) ok_t 'T12b the refusal text does not assert absence' ;;
esac

# T13 and it names the CLASS, not just "something went wrong".
case "$out" in
  *"body could not be fetched"*) ok_t 'T13 the refusal names the failure class the diagnostic carries' ;;
  *) bad_t 'T13 the refusal does not name the class (_teams_index_diag/body wording missing)' "$out" ;;
esac

# T14 control — one unreadable template must not hide a roster that IS readable.
# `from-the-future` is v9 and skipped by schema; make only IT unfetchable and
# `startup` must still be reported, and the command must still succeed.
: > "$GETLOG"; REG_RC=0; BODY_RC=0
_teams_get_ok=$(declare -f _teams_get)
_teams_get() {
  local url="$1" out="$2"
  local rel="${url#https://raw.githubusercontent.com/5dive-ai/character-packs/main/}"
  printf '%s\n' "$rel" >> "$GETLOG"
  [[ "$rel" == teams/from-the-future.5dive.yaml ]] && return 4
  [[ -f "$TMP/reg/$rel" ]] || return 1
  cp "$TMP/reg/$rel" "$out"
}
out=$( cmd_team ps 2>&1 ); rc=$?
if (( rc == 0 )) && [[ "$out" == *PS-RENDERED* ]]; then
  ok_t 'T14 control — one unreadable template does not hide the rosters that ARE readable'
else
  bad_t 'T14 one unreadable template suppressed a readable roster' "rc=$rc out=$out"
fi
eval "$_teams_get_ok"

echo "-----"
echo "team_registry_unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
