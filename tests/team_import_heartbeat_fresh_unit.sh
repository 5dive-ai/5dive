#!/usr/bin/env bash
# DIVE-7780 — a team import leaves its lead keeping context and starts every
# other seat fresh.
#
# lodar, 2026-11-05: "why all 6 on non fresh hb?" — a marketplace trading desk
# came up with FRESH=no on all six seats, because `agent create` enrols with the
# box default (fresh off) and nothing on the import path changed it.
#
# Same rig as team_kickoff_lang_unit.sh: the REAL cmd_compose_up over a real
# two-seat spec; only provisioning is stubbed (the stub enrols each created seat
# exactly as `agent create` does: heartbeat on, fresh false). The verdict is read
# with the REAL built `5dive heartbeat ls`, the surface the row was measured on.

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; [[ -n "${KEEP_TMP:-}" ]] || rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
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
  || { bad_t 'F0 the CLI does not build — every arm is vacuous' ''; exit 1; }

export STATE_DIR="$TMP/state" TASKS_DB="$TMP/state/tasks/tasks.db"
export REGISTRY="$STATE_DIR/agents.json"
export FIVEDIVE_HARNESS=1 FIVEDIVE_NO_HUMAN_SEND=1 FIVE_WIP_CAP=0

# `agent create`/`agent import` stub: enrol the seat the way create does
# (cmd_heartbeat_on with no --fresh). NOHB_SEAT=<name> leaves that one unenrolled,
# as `--no-heartbeat` or a failed enrolment would.
SELF="$TMP/self.sh"
cat > "$SELF" <<EOF
#!/usr/bin/env bash
a=("\$@"); [[ "\${a[0]:-}" == --json ]] && a=("\${a[@]:1}")
case "\${a[0]:-} \${a[1]:-}" in
  "agent create"|"agent import")
    n="\${a[2]}"; hb='{enabled:true, everyMin:30, fresh:false, lastRunAt:0}'
    [[ "\$n" == "\${NOHB_SEAT:-}" ]] && hb=null   # a seat create left unenrolled
    tmp=\$(mktemp); jq --arg n "\$n" ".agents[\\\$n] = {type:\"claude\", heartbeat:\$hb}" "$REGISTRY" > "\$tmp" && mv "\$tmp" "$REGISTRY"
    exit 0 ;;
  "agent "*|"org "*|"browser "*) exit 0 ;;
esac
exec "$BIN" "\$@"
EOF
chmod +x "$SELF"

reset_box() {
  rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR/tasks"
  printf '{"schemaVersion":2,"agents":{}}\n' > "$REGISTRY"
}

write_spec() {
  cat > "$TMP/team.yaml" <<'YAML'
version: "2"
agents:
  desk:
    type: claude
    role: "Lead"
  reviewer:
    type: claude
    role: "Reviewer"
    reports_to: desk
YAML
}

# $1 = team key ("" = a bare `up`, which is not a team import).
run_up() {
  local key="$1"; shift
  (
    cd "$ROOT/src" || exit 1
    for f in header.sh lib/*.sh; do . "./$f"; done
    . ./cmd_task.sh; . ./cmd_heartbeat.sh; . ./cmd_loop_pack.sh; . ./cmd_compose.sh
    ensure_state() { :; }
    registry_write() { cat > "$REGISTRY"; }
    persona_append_block() { :; }
    _skill_list_json() { printf '[]'; }
    _compose_self() { printf '%s' "$SELF"; }
    JSON_MODE=1
    COMPOSE_TEAM_KEY="$key"
    cmd_compose_up -f "$TMP/team.yaml" --start-now "$@"
  ) 2>"$TMP/up.err"
}
# FRESH column of the real `heartbeat ls` for one seat ("" = not listed).
fresh_of() { "$BIN" heartbeat ls 2>/dev/null | awk -v n="$1" '$1==n{print $4}'; }

# --- F1-F2: a team import ---------------------------------------------------
reset_box; write_spec
run_up trading >/dev/null
"$BIN" heartbeat ls > "$TMP/ls.txt" 2>&1
[[ "$(fresh_of desk)" == "no" ]] \
  && ok_t 'F1 team import: heartbeat ls shows FRESH no for the lead (desk) — it keeps its context' \
  || bad_t 'F1 lead is not FRESH no' "$(cat "$TMP/ls.txt") err=$(tail -3 "$TMP/up.err")"
[[ "$(fresh_of reviewer)" == "yes" ]] \
  && ok_t 'F2 team import: heartbeat ls shows FRESH yes for the other seat (reviewer) — every task starts fresh' \
  || bad_t 'F2 non-lead is not FRESH yes' "$(cat "$TMP/ls.txt") err=$(tail -3 "$TMP/up.err")"
jq -e '.agents.desk.heartbeat.enabled and .agents.reviewer.heartbeat.enabled
       and .agents.desk.heartbeat.everyMin == 30 and .agents.reviewer.heartbeat.everyMin == 30' "$REGISTRY" >/dev/null \
  && ok_t 'F3 only the mode moved: both seats stay enrolled at their cadence' \
  || bad_t 'F3 enrolment or cadence changed' "$(jq -c '.agents' "$REGISTRY")"
grep -q 'start(s) each task fresh' "$TMP/up.err" \
  && ok_t 'F4 the import says which seats start fresh' \
  || bad_t 'F4 no line naming the fresh seats' "$(tail -5 "$TMP/up.err")"

# --- F5: a bare `up` (not a team import) keeps the box default --------------
reset_box; write_spec
run_up "" >/dev/null
[[ "$(fresh_of desk)|$(fresh_of reviewer)" == "no|no" ]] \
  && ok_t 'F5 a bare up (no team import) leaves every seat at the default FRESH no' \
  || bad_t 'F5 bare up changed the heartbeat default' "$("$BIN" heartbeat ls 2>&1)"

# --- F6: a seat that was already on the box is not this import's to change --
reset_box; write_spec
jq '.agents.reviewer = {type:"claude", heartbeat:{enabled:true, everyMin:30, fresh:false, lastRunAt:0}}' \
  "$REGISTRY" > "$TMP/r" && mv "$TMP/r" "$REGISTRY"
run_up trading >/dev/null
[[ "$(fresh_of desk)|$(fresh_of reviewer)" == "no|no" ]] \
  && ok_t 'F6 an agent already on the box (adopted, not created) keeps the setting its owner gave it' \
  || bad_t 'F6 import changed an adopted seat' "$("$BIN" heartbeat ls 2>&1)"

# --- F7: a seat with no heartbeat is not enrolled by the fresh pass ---------
reset_box; write_spec
NOHB_SEAT=reviewer run_up trading >/dev/null
jq -e '.agents.reviewer != null and .agents.reviewer.heartbeat == null' "$REGISTRY" >/dev/null \
  && ok_t 'F7 a seat created with no heartbeat stays unenrolled (the pass sets a mode, it never enrols)' \
  || bad_t 'F7 the pass enrolled an unenrolled seat' "$(jq -c '.agents' "$REGISTRY")"

echo "-----"
echo "team_import_heartbeat_fresh_unit: $pass passed, $fail failed"
(( fail == 0 ))
