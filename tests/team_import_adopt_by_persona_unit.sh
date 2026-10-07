#!/usr/bin/env bash
# DIVE-5606 — a team seat named by ROLE is filled by the PERSONA already on the box.
#
# THE DEFECT. DIVE-5498 adopted a solo agent only when its NAME was the seat's
# name. The startup template names its lead seat `ceo:` with `pack: olivia`
# (DIVE-5263), so solo `olivia` + `team import startup` made a second Olivia
# called `ceo` (same pack, same persona hash), and cmo/devops reported to the
# clone while the real Olivia stood outside the team. Measured on a customer-
# shaped box 2026-10-05.
#
# WHAT IS PINNED:
#   section 1  _compose_seat_adoptions: one solo agent of the seat's pack fills
#              it under its own name; several fill nothing and are reported; an
#              org-bound agent, an agent named like another seat, and a pack two
#              seats declare are never taken
#   section 2  `team import startup` end to end (provisioning verbs recorded):
#              no `ceo`, olivia holds role CEO, cmo/devops report to olivia, no
#              role block addresses `ceo`, olivia keeps her own model, the JSON
#              says who filled which seat, and a re-import creates nothing
#   section 3  negative controls: no olivia -> `ceo` is created as before; an
#              olivia already in another team leads this one too and is not
#              re-wired out of her chart (DIVE-5769 reversed the old `ceo` clone)
#
# COVERAGE LIMIT, said plainly: section 2 replaces the child `agent create/import/
# start/config/org set/task add` calls with a recorder (org set is mirrored into
# the test's own agents_org so a re-import sees the chart), so no unix user is
# made. What is claimed is the set of verbs `team import` issues and the role
# text it writes.
#
# Run: bash tests/team_import_adopt_by_persona_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - team_import_adopt_by_persona_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

for f in src/lib/error_codes.sh src/lib/output.sh src/header.sh src/lib/validation.sh \
         src/lib/state.sh src/lib/audit.sh src/lib/registry.sh src/lib/tasks_db.sh \
         src/lib/actor.sh src/lib/models.sh src/task/routing.sh src/cmd_compose.sh src/cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
set +e

TMP="$(mktemp -d /tmp/team-import-persona.XXXXXX)"
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$TMP/registry.json"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
tasks_db_init

PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

# The marketplace's teams/startup.5dive.yaml, cut to what this row grades: the
# lead seat is named by ROLE and carries Olivia's pack. The cmo line addresses
# the lead the way a real instruction does.
cat > "$TMP/startup.5dive.yaml" <<'YAML'
version: "2"
team:
  slug: startup
agents:
  ceo:
    pack: olivia
    role: "CEO"
    model: opus
    effort: high
    instructions: "On top of the pack: you are this company's CEO."
  cmo:
    role: "CMO"
    model: opus
    reports_to: ceo
    instructions: "Report results up to the CEO: `5dive agent send ceo \"...\"`, or @ceo in a thread."
  devops:
    role: "DevOps"
    reports_to: ceo
    instructions: "Escalate outages to the CEO (`ceo`)."
  researcher:
    role: "Competitor Researcher"
    reports_to: cmo
  creative:
    role: "Creative"
    reports_to: cmo
YAML
SPEC="$(_compose_parse "$TMP/startup.5dive.yaml")"
[[ -n "$SPEC" ]] && ok_t 'P0 the fixture parses (the arms below are not vacuous)' \
                 || bad_t 'P0 the fixture parses' 'empty spec'

REG_SOLO_OLIVIA='{"agents":{"olivia":{"type":"codex","pack":{"source":"marketplace","slug":"olivia"}}}}'

# ============ 1. WHICH SEAT IS FILLED BY WHOM =================================
eq_t 'A1 solo olivia (pack olivia) fills the ceo seat under her own name' \
     '{"adopt":{"ceo":"olivia"},"ambiguous":[]}' "$(_compose_seat_adoptions "$SPEC" "$REG_SOLO_OLIVIA" "")"
# DIVE-5769: olivia in another team fills the seat too — SHARED (no re-wire, N2b).
eq_t 'A2 olivia already in another team fills the seat (shared, DIVE-5769)' \
     '{"ceo":"olivia"}' "$(_compose_seat_adoptions "$SPEC" "$REG_SOLO_OLIVIA" $'olivia\nboss' | jq -c .adopt)"
_two='{"agents":{"olivia":{"pack":{"slug":"olivia"}},"liv":{"pack":{"slug":"olivia"}}}}'
eq_t 'A3 two solo Olivias: neither is picked' \
     '{}' "$(_compose_seat_adoptions "$SPEC" "$_two" "" | jq -c .adopt)"
eq_t 'A3b …and the seat is reported with both names' \
     'ceo|olivia|liv,olivia' "$(_compose_seat_adoptions "$SPEC" "$_two" "" | jq -r '.ambiguous[0] | "\(.seat)|\(.pack)|\(.agents | sort | join(","))"')"
eq_t 'A4 NEG: an agent of a DIFFERENT pack never fills the seat' \
     '{}' "$(_compose_seat_adoptions "$SPEC" '{"agents":{"olivia":{"pack":{"slug":"vesper"}}}}' "" | jq -c .adopt)"
eq_t 'A5 NEG: an olivia-pack agent NAMED like another seat keeps that name' \
     '{}' "$(_compose_seat_adoptions "$SPEC" '{"agents":{"cmo":{"pack":{"slug":"olivia"}}}}' "" | jq -c .adopt)"
eq_t 'A6 a seat whose own name is on the box is the same-name path, not this one' \
     '{}' "$(_compose_seat_adoptions "$SPEC" '{"agents":{"ceo":{"pack":{"slug":"olivia"}},"olivia":{"pack":{"slug":"olivia"}}}}' "" | jq -c .adopt)"
_dup="$(jq -c '.agents.cmo.pack = "olivia"' <<<"$SPEC")"
eq_t 'A7 a pack two seats declare is skipped (one agent cannot fill both)' \
     '{}' "$(_compose_seat_adoptions "$_dup" "$REG_SOLO_OLIVIA" "" | jq -c .adopt)"
_mapped="$(_compose_apply_seat_map "$SPEC" '{"ceo":"olivia"}')"
eq_t 'A8 the seat map renames the seat and every reports_to edge pointing at it' \
     'cmo,creative,devops,olivia,researcher|olivia|olivia|cmo' \
     "$(jq -r '"\(.agents | keys | join(","))|\(.agents.cmo.reports_to)|\(.agents.devops.reports_to)|\(.agents.creative.reports_to)"' <<<"$_mapped")"
eq_t 'A9 the mapped roster has olivia as its single root' 'olivia' "$(_compose_spec_root "$_mapped")"

# ============ 2. `team import startup` END TO END =============================
cat > "$TMP/fake5dive" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
if [[ "$1 $2" == "agent import" || "$1 $2" == "agent create" ]]; then
  n=""; for a in "$@"; do case "$a" in --as=*) n="${a#--as=}" ;; --name=*) n="${a#--name=}" ;; esac; done
  [[ -n "$n" ]] || n="$3"
  jq --arg n "$n" '.agents[$n] = {}' "$REGISTRY" > "$REGISTRY.t" && mv "$REGISTRY.t" "$REGISTRY"
fi
if [[ "$1 $2" == "org set" ]]; then
  n="$3" r="" m=""
  for a in "$@"; do case "$a" in --role=*) r="${a#--role=}" ;; --manager=*) m="${a#--manager=}" ;; esac; done
  sqlite3 "$TASKS_DB" "INSERT INTO agents_org (name, role, reports_to) VALUES ('$n','$r','$m')
                       ON CONFLICT(name) DO UPDATE SET role='$r', reports_to='$m';"
fi
exit 0
SH
chmod +x "$TMP/fake5dive"
export FAKE_LOG="$TMP/calls.log" REGISTRY TASKS_DB
_compose_self() { printf '%s' "$TMP/fake5dive"; }
ensure_state() { :; }
persona_append_block() { printf '%s' "$3" > "$TMP/block.$1"; }

_fresh_box() {  # <registry json>
  db "DELETE FROM agents_org;"; db "DELETE FROM projects;"
  rm -rf "$STATE_DIR/teams" "$TMP"/block.*
  printf '%s' "$1" > "$REGISTRY"; : > "$FAKE_LOG"
}

_fresh_box "$REG_SOLO_OLIVIA"
_imp_out=$(JSON_MODE=1 cmd_team import "$TMP/startup.5dive.yaml" 2>"$TMP/imp.err"); _imp_rc=$?
eq_t 'E1 the import succeeds' 0 "$_imp_rc"
eq_t 'E2 one Olivia on the box, and no ceo clone' \
     'cmo,creative,devops,olivia,researcher' "$(jq -r '.agents | keys | join(",")' "$REGISTRY")"
grep -qE '^agent (import|create) .*(olivia|ceo)' "$FAKE_LOG" \
  && bad_t 'E3 olivia is NOT re-provisioned and no ceo is made' "$(grep -E 'olivia|ceo' "$FAKE_LOG")" \
  || ok_t 'E3 olivia is NOT re-provisioned and no ceo is made (she keeps her home, memory and bot)'
eq_t 'E4 olivia holds the CEO role, with no manager' \
     'CEO|' "$(db "SELECT role||'|'||COALESCE(reports_to,'') FROM agents_org WHERE name='olivia';" | sed 's/ coordinator//')"
eq_t 'E5 cmo and devops report to olivia' \
     'cmo=olivia,devops=olivia' "$(db "SELECT name||'='||reports_to FROM agents_org WHERE name IN ('cmo','devops') ORDER BY name;" | paste -sd, -)"
_addr=$(grep -lE '`ceo`|@ceo|agent send ceo|\*\*ceo\*\*|--manager=ceo' "$TMP"/block.* 2>/dev/null)
[[ -z "$_addr" ]] && ok_t 'E6 no teammate role block addresses `ceo`' \
                  || bad_t 'E6 no `ceo` address in role blocks' "$_addr: $(cat $_addr | head -c 300)"
_cmo=$(cat "$TMP/block.cmo" 2>/dev/null)
[[ "$_cmo" == *'`5dive agent send olivia "..."`'* && "$_cmo" == *'@olivia'* && "$_cmo" == *'You report to **olivia**'* \
   && "$_cmo" == *'the CEO'* ]] \
  && ok_t 'E7 cmo is told to address olivia; "the CEO" prose is kept' \
  || bad_t 'E7 cmo role block' "${_cmo:0:400}"
[[ "$(cat "$TMP/block.olivia" 2>/dev/null)" == *"this company's CEO"* ]] \
  && ok_t 'E8 olivia gets the CEO role instructions' \
  || bad_t 'E8 olivia role block' "$(cat "$TMP/block.olivia" 2>/dev/null)"
grep -qE '^agent config olivia set (model|effort)=' "$FAKE_LOG" \
  && bad_t 'E9 olivia keeps her own model' "$(grep 'agent config olivia' "$FAKE_LOG")" \
  || ok_t 'E9 olivia keeps her own harness model (the seat model: opus is not pinned on her)'
grep -qE '^agent config cmo set model=' "$FAKE_LOG" \
  && ok_t 'E9b CONTROL: a new seat still gets its declared model' \
  || bad_t 'E9b cmo model set' "$(grep 'agent config' "$FAKE_LOG")"
eq_t 'E10 the JSON result names who fills which seat' \
     '[{"agent":"olivia","seat":"ceo","role":"CEO","pack":"olivia","shared":false}]' "$(jq -c '.data.adopted' <<<"$_imp_out" 2>/dev/null)"
eq_t 'E11 …and created counts only the new members' '4' "$(jq -r '.data.created' <<<"$_imp_out" 2>/dev/null)"
[[ "$(cat "$TMP/imp.err")" == *"olivia fills that seat under its own name"* ]] \
  && ok_t 'E12 the import says olivia fills the ceo seat' \
  || bad_t 'E12 output wording' "$(head -c 600 "$TMP/imp.err")"
eq_t 'E13 the team is recorded as led by olivia' \
     'olivia' "$(db "SELECT lead_agent FROM projects WHERE key='startup';")"
eq_t 'E14 the seat is recorded for a re-import' \
     '{"ceo":"olivia"}' "$(jq -c . "$STATE_DIR/teams/startup.seats.json" 2>/dev/null)"

: > "$FAKE_LOG"
cmd_team import "$TMP/startup.5dive.yaml" >/dev/null 2>"$TMP/imp2.err"
eq_t 'E15 re-import is idempotent: nothing created, still no ceo' \
     'cmo,creative,devops,olivia,researcher' "$(jq -r '.agents | keys | join(",")' "$REGISTRY")"
grep -qE '^agent (import|create) ' "$FAKE_LOG" \
  && bad_t 'E16 re-import provisions nothing' "$(grep -E '^agent (import|create)' "$FAKE_LOG")" \
  || ok_t 'E16 re-import provisions nothing (and does not namespace the roster)'

( COMPOSE_TEAM_MANIFEST="$STATE_DIR/teams/startup.5dive.yaml"
  _compose_parse() { printf '%s' "$SPEC"; }
  systemctl() { echo active; }
  JSON_MODE=1 cmd_compose_ps -f "$TMP/startup.5dive.yaml" 2>"$TMP/ps.err" ) > "$TMP/ps.json"
eq_t 'E17 team ps lists olivia in the seat, nothing missing' \
     'cmo,creative,devops,olivia,researcher|0' \
     "$(jq -r '[.data.agents[].name] | sort | join(",")' "$TMP/ps.json" 2>/dev/null)|$(jq '[.data.agents[] | select(.state == "missing")] | length' "$TMP/ps.json" 2>/dev/null)"

# ============ 3. NEGATIVE CONTROLS ===========================================
_fresh_box '{"agents":{}}'
cmd_team import "$TMP/startup.5dive.yaml" >/dev/null 2>&1
eq_t 'N1 NEG: no olivia on the box -> ceo is created exactly as before' \
     'ceo,cmo,creative,devops,researcher' "$(jq -r '.agents | keys | join(",")' "$REGISTRY")"
eq_t 'N1b …and cmo reports to ceo' 'ceo' "$(db "SELECT reports_to FROM agents_org WHERE name='cmo';")"
[[ ! -e "$STATE_DIR/teams/startup.seats.json" ]] \
  && ok_t 'N1c …and no seat map is recorded' || bad_t 'N1c no seat map' "$(cat "$STATE_DIR/teams/startup.seats.json")"

_fresh_box '{"agents":{"boss":{},"olivia":{"pack":{"slug":"olivia"}}}}'
db "INSERT INTO agents_org (name) VALUES ('boss');"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('olivia','CMO','boss');"
cmd_team import "$TMP/startup.5dive.yaml" >/dev/null 2>&1
eq_t 'N2 olivia in another team -> she leads this one too, no ceo clone (DIVE-5769)' \
     'boss,cmo,creative,devops,olivia,researcher' "$(jq -r '.agents | keys | join(",")' "$REGISTRY")"
grep -qE '^org set olivia ' "$FAKE_LOG" \
  && bad_t 'N2b the other team keeps its olivia' "$(grep 'org set olivia' "$FAKE_LOG")" \
  || ok_t 'N2b the other team keeps its olivia (no org set on her)'

_fresh_box "$REG_SOLO_OLIVIA"
cmd_team import "$TMP/startup.5dive.yaml" --prefix=acme >/dev/null 2>&1
eq_t 'N3 NEG: an explicit --prefix namespaces the roster and adopts nobody' \
     'acme-ceo,acme-cmo,acme-creative,acme-devops,acme-researcher,olivia' "$(jq -r '.agents | keys | join(",")' "$REGISTRY")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
SUMMARY_PRINTED=1
[[ "$FAIL" == "0" ]]
