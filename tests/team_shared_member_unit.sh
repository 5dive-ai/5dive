#!/usr/bin/env bash
# DIVE-5769 — ONE CHARACTER, ONCE PER BOX, SHARED ACROSS TEAMS, NEVER CLONED.
#
# THE DEFECT (lodar, 2026-10-07). Theo in one team, then a second team that
# needs Theo: `team import` adopted a same-persona agent only when he was SOLO,
# so an org-bound Theo was namespaced around and the second team got
# `<prefix>-theo` — same persona, same face, a second memory.
#
# WHAT IS PINNED:
#   section 1  team A (Theo a member) + team B whose LEAD seat is pack theo:
#              exactly one theo-pack agent, a member of both teams; his org line
#              is not re-wired; B's members report to him; A's members are not
#              B's; B's role is ADDED to his instructions inside a fenced block;
#              `project ls --json` lists both memberships; the JSON says shared
#   section 2  re-importing B is idempotent: nothing provisioned, no second block
#   section 3  team leave B theo -> refused (he leads B); team leave on a member
#              keeps him in A; team rm B with a shared lead keeps him in A and
#              strips B's block; agent rm fires him from every team
#   section 4  team B whose MEMBER seat is named `theo`: shared, no clone
#   section 5  a legacy team (no membership rows) is frozen from its org subtree
#              BEFORE the second import wires anybody under the shared agent
#   section 6  CONTROLS: a real name clash still namespaces; a virgin box is
#              unchanged
#
# NEGATIVE CONTROL: this file copied onto the pre-change tree (origin/main
# 18240fd8) goes red at S4 with 2 theo-pack agents — `theo` and a clone named
# after B's lead seat, `lead` (S5: editor,lead,scout,social,theo,vesper).
#
# COVERAGE LIMIT: child `agent import/create/start/config/org set/task add` calls
# go to a recorder (org set mirrored into agents_org, import records the pack in
# the registry), and persona files are plain files in $TMP. No unix user is made.
#
# Run: bash tests/team_shared_member_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154
trap 'rc=$?; [[ -n "${KEEP_TMP:-}" ]] || rm -rf "${TMP:-}"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - team_shared_member_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

for f in src/header.sh src/lib/error_codes.sh src/lib/output.sh src/lib/validation.sh \
         src/lib/state.sh src/lib/audit.sh src/lib/registry.sh src/lib/tasks_db.sh \
         src/lib/actor.sh src/lib/models.sh src/task/routing.sh src/cmd_compose.sh \
         src/cmd_project.sh src/cmd_org.sh src/cmd_agent_lifecycle.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
set +e

TMP="$(mktemp -d /tmp/team-shared-member.XXXXXX)"
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$TMP/registry.json"; ENV_DIR="$TMP/env"
JSON_MODE=0
mkdir -p "$TASKS_DIR" "$ENV_DIR"
tasks_db_init

PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

# Team A: the 5dive-team shape — Theo is a MEMBER under the lead.
cat > "$TMP/diveteam.5dive.yaml" <<'YAML'
version: "2"
team:
  slug: diveteam
agents:
  vesper:
    pack: vesper
    role: "Chief of Staff"
  theo:
    pack: theo
    role: "Writer"
    reports_to: vesper
    instructions: "Send drafts to `vesper`."
  scout:
    role: "Scout"
    reports_to: vesper
YAML
# Team B: the content-studio shape — the LEAD seat is named by role, pack theo.
cat > "$TMP/content.5dive.yaml" <<'YAML'
version: "2"
team:
  slug: content
agents:
  lead:
    pack: theo
    role: "Head of Content"
    instructions: "Run the content calendar."
    goals:
      - "Plan this month's content calendar"
  editor:
    role: "Editor"
    reports_to: lead
    instructions: "Send edits to the lead: `5dive agent send lead \"...\"`."
  social:
    role: "Social"
    reports_to: lead
YAML
# Team C: Theo as a MEMBER seat named `theo`.
cat > "$TMP/studio.5dive.yaml" <<'YAML'
version: "2"
team:
  slug: studio
agents:
  boss:
    role: "CEO"
  theo:
    pack: theo
    role: "Copywriter"
    reports_to: boss
YAML
for f in diveteam content studio; do
  [[ -n "$(_compose_parse "$TMP/$f.5dive.yaml")" ]] && ok_t "P0 fixture $f parses" || bad_t "P0 fixture $f parses" empty
done

# ---- the recorder ------------------------------------------------------------
cat > "$TMP/fake5dive" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
if [[ "$1 $2" == "agent import" ]]; then
  n=""; for a in "$@"; do case "$a" in --as=*) n="${a#--as=}" ;; esac; done
  jq --arg n "$n" --arg p "$3" '.agents[$n] = {type:"claude", pack:{source:"marketplace", slug:$p}}' "$REGISTRY" > "$REGISTRY.t" && mv "$REGISTRY.t" "$REGISTRY"
fi
if [[ "$1 $2" == "agent create" ]]; then
  n=""; for a in "$@"; do case "$a" in --name=*) n="${a#--name=}" ;; esac; done
  [[ -n "$n" ]] || n="$3"
  jq --arg n "$n" '.agents[$n] = {type:"claude"}' "$REGISTRY" > "$REGISTRY.t" && mv "$REGISTRY.t" "$REGISTRY"
fi
if [[ "$1 $2" == "org set" ]]; then
  n="$3" r="" m=""
  for a in "$@"; do case "$a" in --role=*) r="${a#--role=}" ;; --manager=*) m="${a#--manager=}" ;; esac; done
  sqlite3 "$TASKS_DB" "INSERT INTO agents_org (name, role, reports_to) VALUES ('$n','$r',NULLIF('$m',''))
                       ON CONFLICT(name) DO UPDATE SET role='$r', reports_to=NULLIF('$m','');"
fi
exit 0
SH
chmod +x "$TMP/fake5dive"
export FAKE_LOG="$TMP/calls.log" REGISTRY TASKS_DB
_compose_self() { printf '%s' "$TMP/fake5dive"; }
ensure_state() { :; }
registry_write() { cat > "$REGISTRY"; }
# Persona files are plain files here; `sudo -u <user> <cmd>` runs <cmd> as us.
persona_target() { printf '%s/persona.%s.md' "$TMP" "$1"; }
persona_append_block() { printf '%s' "$3" >> "$TMP/persona.$1.md"; }
sudo() { if [[ "${1:-}" == "-u" ]]; then shift 2; fi; "$@"; }
remove_channel_secret() { :; }; delete_agent_user() { :; }; paperclip_unseed_for_profile() { :; }
systemctl() { return 0; }

_fresh_box() {  # <registry json>
  db "DELETE FROM team_members;"; db "DELETE FROM agents_org;"; db "DELETE FROM projects WHERE key<>'dive';"
  rm -rf "$STATE_DIR/teams" "$TMP"/persona.*
  printf '%s' "$1" > "$REGISTRY"; : > "$FAKE_LOG"
}
theo_n() { jq '[.agents[] | select(.pack.slug == "theo")] | length' "$REGISTRY"; }
members() { JSON_MODE=1 cmd_project_ls 2>/dev/null | jq -r --arg k "$1" '.data.projects[] | select(.key == $k) | .members | join(",")'; }

# ============ 1. A (theo a member) + B (theo-pack LEAD seat) ===================
_fresh_box '{"agents":{}}'
cmd_team import "$TMP/diveteam.5dive.yaml" >/dev/null 2>"$TMP/a.err"
eq_t 'S1 team A comes up with one theo' 'scout,theo,vesper|1' "$(jq -r '.agents | keys | join(",")' "$REGISTRY")|$(theo_n)"
eq_t 'S2 team A membership is recorded, lead first' 'vesper,scout,theo' "$(members diveteam | tr ',' '\n' | { read -r l; printf '%s,' "$l"; sort | paste -sd, -; })"

: > "$FAKE_LOG"
_b_out=$(JSON_MODE=1 cmd_team import "$TMP/content.5dive.yaml" 2>"$TMP/b.err"); _b_rc=$?
eq_t 'S3 team B imports' 0 "$_b_rc"
eq_t 'S4 ACCEPTANCE: exactly ONE theo-pack agent on the box after both teams' 1 "$(theo_n)"
eq_t 'S5 no namespaced clone, no `lead` seat agent' 'editor,scout,social,theo,vesper' "$(jq -r '.agents | keys | join(",")' "$REGISTRY")"
grep -qE '^agent (import|create) [^ ]*theo|--as=(lead|[a-z]+-theo)' "$FAKE_LOG" \
  && bad_t 'S6 theo is not re-provisioned' "$(grep -E 'theo|lead' "$FAKE_LOG")" \
  || ok_t 'S6 theo is not re-provisioned (one memory, one chat)'
eq_t 'S7 ACCEPTANCE: theo is a member of BOTH teams' 'content,diveteam' "$(_team_member_teams theo | sort | paste -sd, -)"
eq_t 'S8 team B is led by theo and lists him first' 'theo' "$(members content | cut -d, -f1)"
eq_t 'S9 B members' 'editor,social,theo' "$(members content | tr ',' '\n' | sort | paste -sd, -)"
eq_t 'S10 A members are unchanged (B is not swallowed through theo)' 'scout,theo,vesper' "$(members diveteam | tr ',' '\n' | sort | paste -sd, -)"
grep -qE '^org set theo ' "$FAKE_LOG" \
  && bad_t 'S11 theo keeps his org line (still reports to vesper)' "$(grep 'org set theo' "$FAKE_LOG")" \
  || ok_t 'S11 B does not re-wire theo (no org set on him)'
eq_t 'S12 theo still reports to vesper in the org tree' 'vesper' "$(db "SELECT reports_to FROM agents_org WHERE name='theo';")"
eq_t 'S13 B members report to theo in the org tree' 'editor=theo,social=theo' "$(db "SELECT name||'='||reports_to FROM agents_org WHERE name IN ('editor','social') ORDER BY name;" | paste -sd, -)"
_p="$(cat "$TMP/persona.theo.md" 2>/dev/null)"
[[ "$_p" == *'<!-- 5dive team: content -->'*'## Also on team content — role: Head of Content'*'Run the content calendar.'*'You lead this team'*'<!-- /5dive team: content -->'* ]] \
  && ok_t 'S14 B role is ADDED to theo, fenced, saying he leads it' \
  || bad_t 'S14 theo persona block' "${_p:0:600}"
[[ "$_p" == *'## Role: Writer'* ]] && ok_t 'S15 his team-A role block is still there' || bad_t 'S15 team-A role kept' "${_p:0:300}"
_ed="$(cat "$TMP/persona.editor.md" 2>/dev/null)"
[[ "$_ed" == *'agent send theo'* && "$_ed" != *'agent send lead'* ]] \
  && ok_t 'S16 editor is told to address theo, not `lead`' || bad_t 'S16 editor addresses' "${_ed:0:400}"
eq_t 'S17 the JSON marks theo as shared' '[{"agent":"theo","seat":"lead","role":"Head of Content","pack":"theo","shared":true}]' \
     "$(jq -c '.data.adopted' <<<"$_b_out" 2>/dev/null)"
grep -qE '^agent config theo set (model|effort)=' "$FAKE_LOG" \
  && bad_t 'S18 theo keeps his own model' "$(grep 'agent config theo' "$FAKE_LOG")" || ok_t 'S18 theo keeps his own model/effort'
# A shared LEAD still gets DIVE-5729's plan-first hold, and B's goal for him is
# queued behind it. (The recorder files no kickoff row, so the hold reports it
# could not open — the queued count is what this arm reads; S19b files it live.)
[[ "$(cat "$TMP/b.err")" == *"the lead 'theo'"*"1 seeded goal(s)"* ]] \
  && ok_t "S19 B's seeded goal for theo is queued behind his plan-first hold" || bad_t 'S19 goal for theo' "$(grep -i goal "$TMP/b.err")"
[[ "$(cat "$TMP/b.err")" == *"the same theo joins this team too"* ]] \
  && ok_t 'S20 the import says theo joins B too' || bad_t 'S20 wording' "$(head -c 800 "$TMP/b.err")"

# ============ 2. RE-IMPORT IS IDEMPOTENT ======================================
: > "$FAKE_LOG"
cmd_team import "$TMP/content.5dive.yaml" >/dev/null 2>"$TMP/b2.err"
grep -qE '^agent (import|create) ' "$FAKE_LOG" \
  && bad_t 'R1 re-import provisions nothing' "$(grep -E '^agent (import|create)' "$FAKE_LOG")" \
  || ok_t 'R1 re-import provisions nothing'
eq_t 'R2 still one theo, same roster' '1|editor,scout,social,theo,vesper' "$(theo_n)|$(jq -r '.agents | keys | join(",")' "$REGISTRY")"
eq_t 'R3 B role block is not appended twice' 1 "$(grep -c '<!-- 5dive team: content -->' "$TMP/persona.theo.md")"
eq_t 'R4 membership unchanged' 'content,diveteam' "$(_team_member_teams theo | sort | paste -sd, -)"
: > "$FAKE_LOG"
cmd_team import "$TMP/diveteam.5dive.yaml" >/dev/null 2>"$TMP/a2.err"
grep -qE '^agent (import|create) |^org set theo ' "$FAKE_LOG" \
  && bad_t 'R5 re-importing A touches nobody' "$(cat "$FAKE_LOG")" || ok_t 'R5 re-importing A provisions and re-wires nobody'
[[ "$(cat "$TMP/a2.err")" != *"joins this team too"* ]] \
  && ok_t 'R6 a re-import of A does not call theo a newcomer' || bad_t 'R6 wording' "$(head -c 400 "$TMP/a2.err")"

# ============ 3. LEAVE / REMOVE TEAM / FIRE ===================================
_lv=$(JSON_MODE=1 cmd_team leave content theo 2>&1); _lv_rc=$?
[[ "$_lv_rc" != 0 && "$_lv" == *"leads team 'content'"* ]] \
  && ok_t 'L1 the lead cannot leave his team alone' || bad_t 'L1 lead leave refused' "rc=$_lv_rc $_lv"
eq_t 'L2 …and nothing changed' 'content,diveteam' "$(_team_member_teams theo | sort | paste -sd, -)"

_rm=$(JSON_MODE=1 cmd_team rm content 2>/dev/null)
eq_t 'L3 Remove team B keeps the shared lead (he is still in A)' 'diveteam' "$(_team_member_teams theo | paste -sd, -)"
eq_t 'L4 …and team B is gone from every surface (no members, no lead)' '|' "$(members content)|$(db "SELECT COALESCE(lead_agent,'') FROM projects WHERE key='content';")"
eq_t 'L5 …and it fired nobody' 'editor,scout,social,theo,vesper' "$(jq -r '.agents | keys | join(",")' "$REGISTRY")"
eq_t 'L6 …the receipt names who is still on the box' 'theo,editor,social' "$(jq -r '.data.kept | join(",")' <<<"$_rm" 2>/dev/null)"
[[ "$(cat "$TMP/persona.theo.md")" != *'team: content'* && "$(cat "$TMP/persona.theo.md")" == *'## Role: Writer'* ]] \
  && ok_t "L7 B's block is taken out of theo's instructions, A's role stays" || bad_t 'L7 strip' "$(cat "$TMP/persona.theo.md")"

# Theo as a MEMBER of two teams: leave one, then fire.
cmd_team import "$TMP/studio.5dive.yaml" >/dev/null 2>"$TMP/c.err"
eq_t 'M1 studio (theo seat named theo) shares him too: one theo' '1|diveteam,studio' "$(theo_n)|$(_team_member_teams theo | sort | paste -sd, -)"
eq_t 'M2 in studio he answers to boss, in the org tree still to vesper' 'boss|vesper' \
     "$(db "SELECT reports_to FROM team_members WHERE team='studio' AND agent='theo';")|$(db "SELECT reports_to FROM agents_org WHERE name='theo';")"
_lv=$(JSON_MODE=1 cmd_team leave studio theo 2>/dev/null)
eq_t 'M3 ACCEPTANCE: Remove from studio -> theo is still in diveteam' 'diveteam' "$(_team_member_teams theo | paste -sd, -)"
eq_t 'M4 …the receipt says where he still is' 'diveteam' "$(jq -r '.data.still_in | join(",")' <<<"$_lv" 2>/dev/null)"
cmd_team import "$TMP/studio.5dive.yaml" >/dev/null 2>&1
eq_t 'M4b …and the line a person reads says it once' "OK — theo left team 'studio' — still in diveteam" "$(cmd_team leave studio theo 2>/dev/null)"
eq_t 'M5 …and his org line is untouched (it never ran through studio)' 'vesper' "$(db "SELECT reports_to FROM agents_org WHERE name='theo';")"
cmd_team import "$TMP/studio.5dive.yaml" >/dev/null 2>&1
eq_t 'M6 re-adding him to studio is one import' 'diveteam,studio' "$(_team_member_teams theo | sort | paste -sd, -)"
eq_t 'M7 the fire warning names every team he is in (the app reads this)' 'diveteam,studio' \
     "$(JSON_MODE=1 cmd_project_ls | jq -r '[.data.projects[] | select(.members | index("theo")) | .key] | sort | join(",")')"
JSON_MODE=1 cmd_rm theo >/dev/null 2>"$TMP/rm.err"
eq_t 'M8 ACCEPTANCE: Fire -> theo is gone from both teams' '0|' "$(theo_n)|$(_team_member_teams theo | paste -sd, -)"
eq_t 'M9 …and from both lineups' 'scout,vesper|boss' "$(members diveteam | tr ',' '\n' | sort | paste -sd, -)|$(members studio)"

# ============ 5. LEGACY TEAM IS FROZEN BEFORE THE SECOND IMPORT ===============
_fresh_box '{"agents":{}}'
cmd_team import "$TMP/diveteam.5dive.yaml" >/dev/null 2>&1
db "DELETE FROM team_members;"   # a team imported before DIVE-5769
eq_t 'G0 the legacy team has no rows' '' "$(members diveteam)"
cmd_team import "$TMP/content.5dive.yaml" >/dev/null 2>&1
eq_t 'G1 the legacy team is frozen from its subtree, WITHOUT B (wired under theo after)' 'scout,theo,vesper' \
     "$(members diveteam | tr ',' '\n' | sort | paste -sd, -)"
eq_t 'G2 and theo is in both' 'content,diveteam' "$(_team_member_teams theo | sort | paste -sd, -)"

_fresh_box '{"agents":{}}'
cmd_team import "$TMP/diveteam.5dive.yaml" >/dev/null 2>&1; : > "$FAKE_LOG"
cmd_team import "$TMP/content.5dive.yaml" --start-now >/dev/null 2>&1
_s19b=$(grep -E '^task add ' "$FAKE_LOG" | grep -F "Plan this month's content calendar")
grep -qF -- '--assignee=theo' <<<"$_s19b" \
  && ok_t "S19b with --start-now, B's goal is filed for theo" || bad_t 'S19b goal filed' "$(grep '^task add' "$FAKE_LOG")"

# ============ 6. CONTROLS =====================================================
_fresh_box '{"agents":{}}'
cmd_team import "$TMP/content.5dive.yaml" >/dev/null 2>&1
eq_t 'C1 CONTROL: a virgin box gets the template as declared' 'editor,lead,social' "$(jq -r '.agents | keys | join(",")' "$REGISTRY")"
_fresh_box '{"agents":{"theo":{"type":"claude","pack":{"slug":"theo"}},"editor":{"type":"claude","pack":{"slug":"vesper"}},"boss2":{"type":"claude"}}}'
db "INSERT INTO agents_org (name, reports_to) VALUES ('boss2', NULL), ('theo','boss2'), ('editor','boss2');"
cmd_team import "$TMP/content.5dive.yaml" >/dev/null 2>&1
[[ "$(jq -r '.agents | keys | map(select(startswith("content-"))) | length' "$REGISTRY")" -gt 0 ]] \
  && ok_t 'C2 CONTROL: a real name clash (a different persona called editor) still namespaces' \
  || bad_t 'C2 clash namespaces' "$(jq -r '.agents | keys | join(",")' "$REGISTRY")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
SUMMARY_PRINTED=1
[[ "$FAIL" == "0" ]]
