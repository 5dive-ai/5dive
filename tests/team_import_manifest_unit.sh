#!/usr/bin/env bash
# DIVE-5038 — a team import tells every role where its manifest is.
#
# THE DEFECT. Every Distribution role is told to "read every channel's tier from
# distribution.channels", and SCHEMA-v2 says the roles read whatever the file
# says at the time they run. But a slug import resolved the template into
# `$(mktemp -d)/<slug>.5dive.yaml`, never persisted it, and no seat was told any
# path at all. Found on a fresh customer box (DIVE-5034): after import, grepping
# every seat's instructions and the state dir for the manifest path returned
# nothing, so the Head/Publisher could not know which channels are AUTO,
# APPROVAL or HUMAN — and a guess on a HUMAN channel is a post nobody approved.
#
# WHAT IS PINNED. A SLUG import driven through the real resolver (only the
# network fetch is replaced): the template lands at one stable per-team path,
# that file carries the imported tiers, every role's appended instructions name
# exactly that path, `team ps` prints it, and a re-import never overwrites a
# manifest the owner has edited. Negative control: a bare `up -f` (no team)
# writes no manifest line, so plain specs stay byte-identical.
#
# COVERAGE LIMIT, said plainly: agents are not provisioned (that needs real unix
# users) — `agent create` goes to a recorder and the persona write is captured
# in place of the seat's CLAUDE.md. "A real seat can open the file" rests on its
# mode (0644 in an a+rx dir under $STATE_DIR, which seats already traverse), and
# that mode is asserted here; the seat-side read is not.
#
# Run: bash tests/team_import_manifest_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - team_import_manifest_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

for f in src/lib/error_codes.sh src/lib/output.sh src/header.sh src/lib/validation.sh \
         src/lib/state.sh src/lib/audit.sh src/lib/registry.sh src/lib/tasks_db.sh \
         src/lib/actor.sh src/lib/marketplace.sh src/task/routing.sh src/cmd_compose.sh \
         src/cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
# The sourced CLI turns errexit ON; several helpers legitimately end on a false
# [[ ]] — same reason every sibling team harness does this.
set +e

TMP="$(mktemp -d /tmp/team-import-manifest.XXXXXX)"
STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
tasks_db_init

PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

# Reserved fakes only; _compose_parse hard-errors on an unset ${VAR}.
export TEAM_AUTH_PROFILE=fixture
export TEAM_TG_TOKEN='1234567890:AAAAfake-not-a-real-bot-token'

FIX="$ROOT/tests/fixtures/team-templates"

# ---- the ONE network call is replaced; the resolver above it is real --------
mkdir -p "$TMP/reg/teams"
cp "$FIX/index.json" "$TMP/reg/teams/index.json"
cp "$FIX/distribution.5dive.yaml" "$TMP/reg/teams/distribution.5dive.yaml"
REG_BASE="$(_teams_registry_base)"
_teams_get() {
  local rel="${1#"$REG_BASE"/}"
  [[ -f "$TMP/reg/$rel" ]] || return 1
  cp "$TMP/reg/$rel" "$2"
}

# ---- provisioning seams: a recorder CLI and a captured persona write --------
cat >"$TMP/fake5dive" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REC"
exit 0
SH
chmod +x "$TMP/fake5dive"
export REC="$TMP/rec.log"; : > "$REC"
_compose_self()   { printf '%s' "$TMP/fake5dive"; }
ensure_state()    { :; }
ensure_state_ro() { :; }
registry_read()   { printf '%s' '{"agents":{}}'; }
PERSONA="$TMP/persona"; mkdir -p "$PERSONA"
persona_append_block() { printf '%s' "$3" >> "$PERSONA/$1.md"; }

WANT="$STATE_DIR/teams/distribution.5dive.yaml"
ROLES="$(jq -r '.agents | keys[]' <<<"$(_compose_parse "$FIX/distribution.5dive.yaml")" | sort)"
NROLES="$(grep -c . <<<"$ROLES")"

# ============ 0. PRECONDITIONS — the arms below are not vacuous ==============
if [[ "$NROLES" == 7 ]] && grep -q 'distribution.channels' "$FIX/distribution.5dive.yaml"; then
  ok_t 'M0 the distribution fixture has its seven roles and the policy block they are told to read'
else
  bad_t 'M0 precondition failed — every arm below is vacuous' "roles=$NROLES"
fi
f=$(_team_resolve_template distribution); rc=$?
if (( rc == 0 )) && [[ "$f" != "$STATE_DIR"/* ]] && grep -q 'slug: distribution' "$f"; then
  ok_t 'M0b a slug still resolves through the registry into a throwaway temp path (the shape that lost it)'
else
  bad_t 'M0b the slug did not resolve the way the defect needs' "rc=$rc file=$f"
fi

# ============ 1. a fresh-box import BY SLUG ==================================
cmd_team import distribution >"$TMP/import.out" 2>&1
if [[ -f "$WANT" ]]; then
  ok_t 'M1 the manifest is persisted at the stable per-team path'
else
  bad_t 'M1 no manifest at the stable path after a slug import' "$(tail -5 "$TMP/import.out")"
fi
if cmp -s "$FIX/distribution.5dive.yaml" "$WANT"; then
  ok_t 'M1b the persisted file IS the imported template (tiers included)'
else
  bad_t 'M1b the persisted manifest differs from the imported template' ''
fi
eq_t 'M1c its tiers read back from the persisted file (x is AUTO, linkedin APPROVAL)' \
     'AUTO APPROVAL' \
     "$(_compose_parse "$WANT" 2>/dev/null | jq -r '[.distribution.channels.x.permission, .distribution.channels.linkedin.permission] | join(" ")' 2>/dev/null)"
eq_t 'M1d file mode is 644 — every seat on the team can read it' '644' "$(stat -c %a "$WANT" 2>/dev/null)"
if [[ "$(stat -c %A "${WANT%/*}" 2>/dev/null)" == d??????r?x ]]; then
  ok_t 'M1e its directory is world-traversable'
else
  bad_t 'M1e the manifest directory is not world-traversable' "$(stat -c %A "${WANT%/*}" 2>/dev/null)"
fi

# ============ 2. EVERY role is told that one path ============================
named=0; missing=""
while IFS= read -r r; do
  if grep -qF "\`$WANT\`" "$PERSONA/$r.md" 2>/dev/null; then named=$((named+1)); else missing+=" $r"; fi
done <<<"$ROLES"
eq_t "M2 all $NROLES roles' appended instructions name the manifest path" "$NROLES" "$named"
[[ -z "$missing" ]] || bad_t 'M2b roles with no manifest line' "$missing"
others=$(cat "$PERSONA"/*.md 2>/dev/null | grep -o '/[^` ]*\.5dive\.yaml' | sort -u | grep -vxF "$WANT")
eq_t 'M2c and no role names any OTHER template path (e.g. the temp copy)' '' "$others"
eq_t 'M2d the manifest line is written exactly once per role' "$NROLES" \
     "$(cat "$PERSONA"/*.md | grep -c '^## Team manifest$')"

# ============ 3. team ps shows it ============================================
out=$(cmd_team ps distribution 2>/dev/null)
if grep -qxF "MANIFEST    $WANT" <<<"$out"; then
  ok_t 'M3 team ps <slug> prints the manifest path'
else
  bad_t 'M3 team ps does not print the manifest path' "$(head -3 <<<"$out")"
fi
JSON_MODE=1
eq_t 'M3b team ps --json carries it as .manifest' "$WANT" \
     "$(cmd_team ps distribution 2>/dev/null | jq -r '.. | objects | .manifest? // empty' 2>/dev/null | head -1)"
JSON_MODE=0

# ============ 4. a re-import never reverts the owner's edits =================
sed -i 's/x:        { cost_per_post_usd: 0.20, permission: AUTO,/x:        { cost_per_post_usd: 0.20, permission: HUMAN,/' "$WANT"
grep -q 'permission: HUMAN' "$WANT" || bad_t 'M4 precondition: the edit did not apply' ''
: > "$REC"; rm -f "$PERSONA"/*.md
cmd_team import distribution >"$TMP/reimport.out" 2>&1
if grep -q 'x: .*permission: HUMAN' "$WANT"; then
  ok_t 'M4 re-import keeps the owner-edited manifest (x stays HUMAN)'
else
  bad_t 'M4 re-import overwrote the edited manifest' ''
fi
if cmp -s "$FIX/distribution.5dive.yaml" "$WANT.incoming" && grep -q "$WANT.incoming" "$TMP/reimport.out"; then
  ok_t 'M4b the fresh template is left beside it as .incoming, and the output says so'
else
  bad_t 'M4b the re-import did not leave/announce the incoming template' "$(grep -i manifest "$TMP/reimport.out")"
fi

# ============ 5. NEGATIVE CONTROL: a bare `up` is unchanged ==================
rm -f "$PERSONA"/*.md
cmd_compose_up -f "$FIX/distribution.5dive.yaml" >/dev/null 2>&1
if [[ -n "$(ls "$PERSONA")" ]] && ! grep -q 'Team manifest' "$PERSONA"/*.md; then
  ok_t 'M5 NEGATIVE CONTROL: up -f (no team) writes role text and no manifest line'
else
  bad_t 'M5 a bare up wrote a manifest line, or wrote no role text at all' "$(ls "$PERSONA")"
fi

SUMMARY_PRINTED=1
printf '\n%s\n' "team_import_manifest_unit: pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
