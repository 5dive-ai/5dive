#!/usr/bin/env bash
# DIVE-5498 — one persona is one agent per box.
#
# THE DEFECT. Solo `theo` on the box, then `team import` of a team that declares
# theo: DIVE-4822's ladder saw a PARTIAL name clash, read it as "another team's
# roster", and namespaced the whole team — `diveteam-theo` next to `theo`. Two
# Theos, and every prose line saying "theo" (the template's `instructions:`, the
# pack's own CLAUDE.md) pointed at the solo one, which is in no team.
#
# WHAT IS PINNED:
#   section 1  the ladder: a SOLO agent of the SAME persona (registry pack slug ==
#              the spec's `pack:`) is adopted, not namespaced around; the three
#              negative controls (different pack, no pack record, already in
#              another team's org) still namespace, as DIVE-4822 ships
#   section 2  the org read that decides "solo", and that it fails CLOSED
#   section 3  the namespace rename reaches every place instructions and the
#              installed pack CLAUDE.md ADDRESS a teammate, and nothing else:
#              members named with plain words ("partner outreach") keep their prose
#   section 4  `team import` end to end with the provisioning verbs stubbed: the
#              solo theo JOINS (org edge, role block), only the missing members
#              are created, and no `<prefix>-theo` is provisioned
#
# COVERAGE LIMIT, said plainly: section 4 replaces the child `agent create/import/
# start/org set/task add` calls with a recorder, so no unix user is made. What is
# claimed is the set of verbs `team import` issues and the role text it writes.
#
# Run: bash tests/team_import_adopt_persona_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - team_import_adopt_persona_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck source=/dev/null
for f in src/lib/error_codes.sh src/lib/output.sh src/header.sh src/lib/validation.sh \
         src/lib/state.sh src/lib/audit.sh src/lib/registry.sh src/lib/tasks_db.sh \
         src/lib/actor.sh src/task/routing.sh src/cmd_compose.sh src/cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
set +e

TMP="$(mktemp -d /tmp/team-import-adopt.XXXXXX)"
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$TMP/registry.json"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
tasks_db_init

PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

cat > "$TMP/gtm.5dive.yaml" <<'YAML'
version: "2"
agents:
  olivia:
    pack: olivia
    role: "CEO"
  theo:
    pack: theo
    role: "CMO"
    reports_to: [olivia]
    instructions: "Hand launch copy to dude; escalate budget to olivia. Theo signs off."
  dude:
    pack: dude
    role: "Head of Community"
    reports_to: [theo]
    instructions: "Ask `theo` before any post. Never touch agent-theo's files."
YAML
SPEC="$(_compose_parse "$TMP/gtm.5dive.yaml")"
[[ -n "$SPEC" ]] && ok_t 'P0 the fixture parses (the arms below are not vacuous)' \
                 || bad_t 'P0 the fixture parses' 'empty spec'

REG_SOLO_THEO='{"agents":{"theo":{"pack":{"source":"marketplace","slug":"theo"}}}}'
REG_OTHER_THEO='{"agents":{"theo":{"pack":{"source":"marketplace","slug":"vesper"}}}}'
REG_BARE_THEO='{"agents":{"theo":{}}}'

# ============ 1. THE LADDER ==================================================
eq_t 'L1 solo theo of the SAME pack: the team adopts him, no namespace' \
     'adopt-solo|' "$(_team_choose_prefix gtm "$SPEC" "$REG_SOLO_THEO" "" olivia "")"
eq_t 'L1b …and he is the one name to re-wire' \
     'theo' "$(_compose_adoptable_solo "$SPEC" "$REG_SOLO_THEO" "" | paste -sd, -)"
eq_t 'L2 NEG: a DIFFERENT persona named theo still gets a namespace (DIVE-4822 unchanged)' \
     'namespaced|gtm' "$(_team_choose_prefix gtm "$SPEC" "$REG_OTHER_THEO" "" olivia "")"
eq_t 'L3 NEG: an agent with no pack record is not assumed to be the same persona' \
     'namespaced|gtm' "$(_team_choose_prefix gtm "$SPEC" "$REG_BARE_THEO" "" olivia "")"
eq_t 'L4 NEG: same persona but already in ANOTHER team is not taken out of its chart' \
     'namespaced|gtm' "$(_team_choose_prefix gtm "$SPEC" "$REG_SOLO_THEO" "" olivia $'theo\nceo')"
eq_t 'L5 CONTROL: a virgin box is still untouched' \
     'free|' "$(_team_choose_prefix gtm "$SPEC" '{"agents":{}}' "" olivia "")"
eq_t 'L6 CONTROL: the installed rung still wins over adoption' \
     'installed|gtm' "$(_team_choose_prefix gtm "$SPEC" "$REG_SOLO_THEO" gtm-olivia olivia "")"
REG_MIX='{"agents":{"theo":{"pack":{"slug":"theo"}},"dude":{"pack":{"slug":"vesper"}}}}'
eq_t 'L7 a solo match beside a REAL clash: the real clash still namespaces the roster' \
     'namespaced|gtm' "$(_team_choose_prefix gtm "$SPEC" "$REG_MIX" "" olivia "")"

# ============ 2. WHO IS SOLO =================================================
db "INSERT INTO agents_org (name) VALUES ('ceo');"
db "INSERT INTO agents_org (name, reports_to) VALUES ('cmo','ceo');"
db "INSERT INTO agents_org (name, role) VALUES ('lonely-lead','Lead');"
db "INSERT INTO agents_org (name) VALUES ('theo');"
eq_t 'S1 org-bound = has a manager, has a report, or holds an org role' \
     'ceo,cmo,lonely-lead' "$(_compose_org_bound | sort | paste -sd, -)"
eq_t 'S2 a bare agents_org row (a hire that was never placed) is SOLO' \
     '' "$(_compose_org_bound | grep -xF theo)"
_bound_fail=$( db() { return 1; }
               printf '%s' '{"agents":{"theo":{},"kai":{}}}' > "$REGISTRY"
               _compose_org_bound | sort | paste -sd, - )
eq_t 'S3 an org read that FAILS reports every agent as bound (fails closed)' 'kai,theo' "$_bound_fail"
rm -f "$REGISTRY"

# ============ 3. A NAMESPACE REACHES THE PROSE ===============================
MAP="$(_compose_prefix_map "$SPEC" gtm)"
eq_t 'R1 the prefix map covers every declared name' \
     '{"dude":"gtm-dude","olivia":"gtm-olivia","theo":"gtm-theo"}' "$(jq -cS . <<<"$MAP")"
_in='Ask `theo` before any post; `5dive agent send dude x`, @olivia. --to=theo --manager dude; task assign DIVE-1 theo. Never touch agent-theo, gtm-theo, theo.md or a@theo.com. Theo, theorem, ask theo.'
_want='Ask `gtm-theo` before any post; `5dive agent send gtm-dude x`, @gtm-olivia. --to=gtm-theo --manager gtm-dude; task assign DIVE-1 gtm-theo. Never touch agent-theo, gtm-theo, theo.md or a@theo.com. Theo, theorem, ask theo.'
eq_t 'R2 only addresses are rewritten (`name`, @name, agent send, --to/--manager, task assign); bare words, paths, prefixed and capitalised names are not' \
     "$_want" "$(printf '%s' "$_in" | _compose_rename_text "$MAP")"
eq_t 'R3 the rewrite is idempotent (a re-run changes nothing)' \
     "$_want" "$(printf '%s' "$_want" | _compose_rename_text "$MAP")"
eq_t 'R4 CONTROL: an empty map leaves prose byte-identical' \
     "$_in" "$(printf '%s' "$_in" | _compose_rename_text '{}')"

# The role block, through the REAL writer: persona_append_block captured.
persona_append_block() { printf '%s' "$3" > "$TMP/block.$1"; }
PSPEC="$(_compose_apply_name_prefix "$SPEC" gtm)"
( COMPOSE_NAME_MAP="$MAP"; _compose_write_role_md "$PSPEC" gtm-dude "$TMP" )
_blk=$(cat "$TMP/block.gtm-dude" 2>/dev/null)
[[ "$_blk" == *'Ask `gtm-theo` before any post'* && "$_blk" != *'Ask `theo` '* ]] \
  && ok_t 'R5 under a namespace the written instructions name gtm-theo, not theo' \
  || bad_t 'R5 namespaced instructions' "block=${_blk:0:200}"
( COMPOSE_NAME_MAP=""; _compose_write_role_md "$SPEC" dude "$TMP" )
[[ "$(cat "$TMP/block.dude")" == *'Ask `theo` before any post'* ]] \
  && ok_t 'R6 CONTROL: with no namespace the instructions are written as declared' \
  || bad_t 'R6 un-namespaced instructions unchanged' "$(cat "$TMP/block.dude")"

# The installed pack CLAUDE.md, rewritten in place.
sudo() { shift 2; "$@"; }               # `sudo -u <user> cmd` -> cmd
persona_target() { printf '%s/persona.%s.md' "$TMP" "$1"; }
printf 'You are dude. Your lead is theo: `5dive agent send theo`; @olivia runs the company.\n' > "$TMP/persona.gtm-dude.md"
_compose_rename_persona_file gtm-dude claude "$MAP" >/dev/null 2>&1
eq_t 'R7 the pack CLAUDE.md addresses the namespaced teammates; its prose is untouched' \
     'You are dude. Your lead is theo: `5dive agent send gtm-theo`; @gtm-olivia runs the company.' "$(cat "$TMP/persona.gtm-dude.md")"

# R8: members named with plain words. The two lines are byte-for-byte from the
# marketplace (teams/distribution.5dive.yaml, teams/startup.5dive.yaml); under a
# cs- prefix they must survive, while an address to the same name moves.
CMAP='{"outreach":"cs-outreach","creative":"cs-creative","scout":"cs-scout","editor":"cs-editor"}'
_prose='      Draft maintainer, newsletter and partner outreach from verified derivatives.
      directs: landing sections, ad creative, post art. Match the brand voice; ship
      - "Create the brand kit + 3 launch-ready ad creatives."
The scout reads; the editor cuts.'
eq_t 'R8 plain-word member names in prose survive a prefix byte-for-byte' \
     "$_prose" "$(printf '%s' "$_prose" | _compose_rename_text "$CMAP")"
eq_t 'R9 the same names used as addresses are renamed' \
     'agent send cs-outreach "draft"; `cs-creative`; @cs-scout; --to=cs-editor' \
     "$(printf '%s' 'agent send outreach "draft"; `creative`; @scout; --to=editor' | _compose_rename_text "$CMAP")"

# ============ 4. `team import` END TO END (provisioning verbs recorded) ======
# A recorder stands in for every child `5dive <verb>` call. `agent create/import`
# also registers the agent, so the registry reflects what was provisioned.
cat > "$TMP/fake5dive" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
if [[ "$1 $2" == "agent import" || "$1 $2" == "agent create" ]]; then
  n=""; for a in "$@"; do case "$a" in --as=*) n="${a#--as=}" ;; --name=*) n="${a#--name=}" ;; esac; done
  [[ -n "$n" ]] || n="$3"
  jq --arg n "$n" '.agents[$n] = {}' "$REGISTRY" > "$REGISTRY.t" && mv "$REGISTRY.t" "$REGISTRY"
fi
exit 0
SH
chmod +x "$TMP/fake5dive"
export FAKE_LOG="$TMP/calls.log" REGISTRY
_compose_self() { printf '%s' "$TMP/fake5dive"; }
ensure_state() { :; }
db "DELETE FROM agents_org;"
printf '%s' "$REG_SOLO_THEO" > "$REGISTRY"
: > "$FAKE_LOG"; rm -f "$TMP"/block.*
_imp_out=$(cmd_team import "$TMP/gtm.5dive.yaml" 2>&1); _imp_rc=$?
eq_t 'E1 the import succeeds' 0 "$_imp_rc"
eq_t 'E2 exactly one theo on the box, and no namespaced copy' \
     'dude,olivia,theo' "$(jq -r '.agents | keys | join(",")' "$REGISTRY")"
grep -qE '^agent (import|create) .*theo' "$FAKE_LOG" \
  && bad_t 'E3 theo is NOT re-provisioned' "$(grep -E 'theo' "$FAKE_LOG")" \
  || ok_t 'E3 theo is NOT re-provisioned (he keeps his home and memory)'
grep -qx 'org set theo --role=CMO --manager=olivia' "$FAKE_LOG" \
  && ok_t 'E4 the adopted theo is placed in the team: role CMO, reports to olivia' \
  || bad_t 'E4 adopted theo org edge' "$(grep 'org set' "$FAKE_LOG")"
[[ "$(cat "$TMP/block.theo" 2>/dev/null)" == *"You report to **olivia**"* ]] \
  && ok_t 'E5 his instructions get the team role block' \
  || bad_t 'E5 adopted theo role block' "$(cat "$TMP/block.theo" 2>/dev/null)"
[[ "$(cat "$TMP/block.dude" 2>/dev/null)" == *"You report to **theo**"* ]] \
  && ok_t 'E6 every teammate addresses that same theo' \
  || bad_t 'E6 dude reports to theo' "$(cat "$TMP/block.dude" 2>/dev/null)"
[[ "$_imp_out" == *"join this team"* && "$_imp_out" != *"belong(s) to another team"* ]] \
  && ok_t 'E7 the output says theo joined, not that he belongs to another team' \
  || bad_t 'E7 output wording' "${_imp_out:0:400}"

# NEG: theo already in another team's chart -> namespaced, theo untouched. A
# fresh box: the import above recorded this template as installed, and the
# installed rung (correctly) beats every collision arm.
db "DELETE FROM projects;"; db "DELETE FROM agents_org;"
db "INSERT INTO agents_org (name) VALUES ('ceo');"
db "INSERT OR REPLACE INTO agents_org (name, reports_to, role) VALUES ('theo','ceo','CMO');"
printf '%s' '{"agents":{"ceo":{},"theo":{"pack":{"slug":"theo"}}}}' > "$REGISTRY"
: > "$FAKE_LOG"
cmd_team import "$TMP/gtm.5dive.yaml" >/dev/null 2>&1
eq_t 'E8 NEG: theo in another team -> the roster comes up namespaced beside him' \
     'ceo,gtm-dude,gtm-olivia,gtm-theo,theo' "$(jq -r '.agents | keys | join(",")' "$REGISTRY")"
grep -qE '^org set theo ' "$FAKE_LOG" \
  && bad_t 'E9 NEG: the other team keeps its theo' "$(grep 'org set theo' "$FAKE_LOG")" \
  || ok_t 'E9 NEG: the other team keeps its theo (no org set on him)'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
SUMMARY_PRINTED=1
[[ "$FAIL" == "0" ]]
