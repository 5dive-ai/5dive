#!/usr/bin/env bash
# DIVE-6484 — a new team's kickoff in the owner's language.
#
# lodar, 2026-10-18: "we ship a team on oinoa with initial task ? but its in
# English even if user speaks Russian". The kickoff is the first row the OWNER
# sees in the app's Tasks tab, so its title is in their language and written to
# them; the body stays the lead's English instructions plus which language to
# write in. Order: --lang, the template's lang:, the lead's paired chat, en.
#
# Same rig as team_plan_first_unit.sh: the REAL cmd_compose_up over a real
# spec and a real sqlite store; `task add` goes to the REAL built CLI; only
# provisioning is stubbed. The team-import arm stubs `up` itself and grades
# what `team import` forwards to it.

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; [[ -n "${KEEP_TMP:-}" ]] || rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc TMP=$TMP"' EXIT
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

for t in sqlite3 jq python3; do
  command -v "$t" >/dev/null || { printf 'SKIP - %s unavailable\n' "$t"; exit 0; }
done
python3 -c 'import yaml' 2>/dev/null || { printf 'SKIP - PyYAML unavailable\n'; exit 0; }

BIN="$TMP/5dive"
( cd "$ROOT" && BUILD_OUT="$BIN" ./build.sh >/dev/null 2>&1 ) \
  || { bad_t 'L0 the CLI does not build — every arm is vacuous' ''; exit 1; }

export STATE_DIR="$TMP/state" TASKS_DB="$TMP/state/tasks/tasks.db"
export REGISTRY="$STATE_DIR/agents.json"
export FIVEDIVE_HARNESS=1 FIVEDIVE_NO_HUMAN_SEND=1 FIVE_WIP_CAP=0

SELF="$TMP/self.sh"
cat > "$SELF" <<EOF
#!/usr/bin/env bash
a=("\$@"); [[ "\${a[0]:-}" == --json ]] && a=("\${a[@]:1}")
case "\${a[0]:-} \${a[1]:-}" in
  "agent create"|"agent import")
    n="\${a[2]}"
    tmp=\$(mktemp); jq --arg n "\$n" '.agents[\$n] = {type:"claude", heartbeat:{enabled:true}}' "$REGISTRY" > "\$tmp" && mv "\$tmp" "$REGISTRY"
    exit 0 ;;
  "agent "*|"org "*|"browser "*) exit 0 ;;
esac
exec "$BIN" "\$@"
EOF
chmod +x "$SELF"

reset_box() {
  rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR/tasks"
  printf '{"schemaVersion":2,"agents":{}}\n' > "$REGISTRY"
  : > "$TMP/persona.log"
}

write_spec() { # [lang-line]
  { [[ -n "${1:-}" ]] && printf '%s\n' "$1"
    cat <<'YAML'
version: "2"
agents:
  lead:
    type: claude
    role: "Lead"
    goals: ["Find out what the owner sells"]
  helper:
    type: claude
    role: "Helper"
    reports_to: lead
    goals: ["Draft three posts"]
YAML
  } > "$TMP/team.yaml"
}

run_up() {
  (
    cd "$ROOT/src" || exit 1
    for f in header.sh lib/*.sh; do . "./$f"; done
    . ./cmd_task.sh; . ./cmd_heartbeat.sh; . ./cmd_loop_pack.sh; . ./cmd_compose.sh
    ensure_state() { :; }
    registry_write() { cat > "$REGISTRY"; }
    persona_append_block() { printf '%s\n' "$3" >> "$TMP/persona.log"; }
    _skill_list_json() { printf '[]'; }
    _compose_self() { printf '%s' "$SELF"; }
    JSON_MODE=1
    cmd_compose_up -f "$TMP/team.yaml" "$@"
  ) 2>"$TMP/up.err"
}
q() { sqlite3 "$TASKS_DB" "$1" 2>/dev/null; }
kick_rows() { q "SELECT ident||'|'||title FROM tasks WHERE body LIKE 'team kickoff: lead (5dive.yaml)%';"; }
kick_body() { q "SELECT body FROM tasks WHERE body LIKE 'team kickoff: lead (5dive.yaml)%';"; }

RU="Согласовать с вами план команды до начала работы"
EN="Agree the team's plan with you before work starts"
ZH="开始工作前与你确认团队计划"

# --- L1-L4: --lang=ru ------------------------------------------------------
reset_box; write_spec
run_up --lang=ru >/dev/null
rows=$(kick_rows)
[[ "$rows" == *"|$RU" && "$(wc -l <<<"$rows")" == 1 ]] \
  && ok_t "L1 up --lang=ru files ONE kickoff titled «$RU»" \
  || bad_t 'L1 ru title' "rows=$rows err=$(tail -3 "$TMP/up.err")"
grep -q 'Write to your owner in Russian, the language they use.' <<<"$(kick_body)" \
  && ok_t 'L2 the kickoff body tells the lead to write to the owner in Russian' \
  || bad_t 'L2 body does not name Russian' "$(kick_body | sed -n 3,4p)"
grep -q 'Write to your owner in Russian' "$TMP/persona.log" \
  && grep -q "start none of it" "$TMP/persona.log" \
  && ok_t "L3 the lead's First start block names Russian and arrives WHOLE (not cut at the apostrophe)" \
  || bad_t 'L3 persona block' "$(cat "$TMP/persona.log")"
k1="${rows%%|*}"
run_up --lang=en >/dev/null; run_up >/dev/null
rows=$(kick_rows)
[[ "$rows" == "$k1|$RU" ]] \
  && ok_t "L4 a re-run (another --lang, then none) finds the same kickoff $k1 by its marker — no duplicate" \
  || bad_t 'L4 re-run duplicated or retitled the kickoff' "rows=$rows"

# --- L5-L6: no flag, no template lang, unpaired lead -> English -------------
reset_box; write_spec
run_up >/dev/null
rows=$(kick_rows)
[[ "$rows" == *"|$EN" && "$(wc -l <<<"$rows")" == 1 ]] \
  && ok_t "L5 no --lang and an unpaired lead: the kickoff is titled «$EN»" \
  || bad_t 'L5 en default' "rows=$rows"
grep -q 'Write to your owner in English' <<<"$(kick_body)" \
  && ok_t 'L6 ... and its body names English' || bad_t 'L6 en body' ''
k1="${rows%%|*}"
run_up --lang=ru >/dev/null
[[ "$(kick_rows)" == "$k1|$EN" ]] \
  && ok_t "L7 a re-run with --lang=ru finds the English kickoff $k1 — no second, Russian one" \
  || bad_t 'L7 duplicate across languages' "rows=$(kick_rows)"

# --- L8-L9: the template's lang -------------------------------------------
reset_box; write_spec 'lang: zh'
run_up >/dev/null
[[ "$(kick_rows)" == *"|$ZH" ]] && ok_t "L8 a template's top-level lang: zh titles it «$ZH»" || bad_t 'L8 template lang' "$(kick_rows)"
reset_box; write_spec $'team:\n  lang: ru'
run_up --lang=en >/dev/null
[[ "$(kick_rows)" == *"|$EN" ]] && ok_t 'L9 --lang beats the template (team.lang: ru, --lang=en -> English)' || bad_t 'L9 precedence' "$(kick_rows)"

# --- L10: the lead's paired chat -------------------------------------------
reset_box; write_spec
(
  cd "$ROOT/src" || exit 1
  for f in header.sh lib/*.sh; do . "./$f"; done
  . ./cmd_task.sh; . ./cmd_compose.sh
  _seat_owner_lang() { [[ "$1" == lead ]] && printf ru || printf en; }
  printf '%s|%s' "$(_compose_kickoff_lang '{}' lead)" "$(_COMPOSE_LANG=zh _compose_kickoff_lang '{}' lead)"
) > "$TMP/l10" 2>/dev/null
[[ "$(cat "$TMP/l10")" == "ru|zh" ]] \
  && ok_t "L10 with no flag and no template lang, a lead paired in Russian gets ru; a flag still wins" \
  || bad_t 'L10 paired fallback' "$(cat "$TMP/l10")"

# --- L11: an unknown language is refused before anything is made -----------
reset_box; write_spec
run_up --lang=fr >/dev/null; rc=$?
(( rc != 0 )) && [[ -z "$(kick_rows)" ]] && grep -q 'unknown --lang' "$TMP/up.err" \
  && ok_t 'L11 up --lang=fr is refused (unknown --lang) and files nothing' \
  || bad_t 'L11 bad lang' "rc=$rc err=$(cat "$TMP/up.err")"

# --- L12-L13: team import forwards --lang to up -----------------------------
reset_box; write_spec
(
  cd "$ROOT/src" || exit 1
  for f in header.sh lib/*.sh; do . "./$f"; done
  . ./cmd_task.sh; . ./cmd_compose.sh
  ensure_state() { :; }
  cmd_compose_up() { printf 'UP %s\n' "$*" > "$TMP/up.args"; return 0; }
  cmd_team import acme --template="$TMP/team.yaml" --lang=ru
) >/dev/null 2>&1
grep -q -- '--lang=ru' "$TMP/up.args" 2>/dev/null \
  && ok_t 'L12 team import --lang=ru hands --lang=ru to up' \
  || bad_t 'L12 team import did not forward --lang' "$(cat "$TMP/up.args" 2>/dev/null)"
"$BIN" team import acme --template="$TMP/team.yaml" --lang=de >/dev/null 2>"$TMP/ti.err"; rc=$?
(( rc != 0 )) && grep -q 'unknown --lang' "$TMP/ti.err" \
  && ok_t 'L13 team import --lang=de is refused as an unknown language' \
  || bad_t 'L13 team import bad lang' "rc=$rc $(cat "$TMP/ti.err")"

echo "-----"
echo "pass=$pass fail=$fail"
(( fail == 0 ))
