#!/usr/bin/env bash
# DIVE-5729 — a hired team asks first. On a team's FIRST start, every seeded goal
# and every declared loop is born blocked behind one kickoff row assigned to the
# lead; nothing runs until `team start` (minus --skip) or `team decline`.
#
# lodar, 2026-10-06: "some marketplace hired teams autostart with loops without
# asking a human if the lead's assumption is correct". Before this, `goals:` were
# filed live and `loops:` installed live on their cron.
#
# FUNCTIONAL, end to end where the host allows it: the REAL cmd_compose_up runs
# over a real YAML spec, against a real sqlite task store, and every `task` /
# `loop` call it shells out goes to the REAL built CLI. Only provisioning (agent
# create/start/config, org set) is stubbed: it would create unix users. The loop
# arms run the REAL recurring materializer (_hb_materialize_recurring) on a cron
# that is due every minute, so "zero loop runs" is measured, not inferred.
#
# NOT COVERED HERE, and named so nobody reads this file as covering it: the plan
# MESSAGE itself. It is the lead's act (an LLM following the kickoff row), so the
# structural half is graded here (exactly one kickoff, its body asks for ONE
# message of at most 60 words) and the message is graded on a real box.

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
  || { bad_t 'T0 the CLI does not build — every arm is vacuous' ''; exit 1; }

export STATE_DIR="$TMP/state" TASKS_DB="$TMP/state/tasks/tasks.db"
export REGISTRY="$STATE_DIR/agents.json"   # header.sh derives it from STATE_DIR
export FIVEDIVE_HARNESS=1 FIVEDIVE_NO_HUMAN_SEND=1 FIVE_WIP_CAP=0

# The stand-in for the CLI that `up` shells out to. Provisioning verbs register
# the agent and record the call; task/loop go to the real binary.
SELF="$TMP/self.sh"
cat > "$SELF" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/self.log"
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
  : > "$TMP/self.log"
}

# Names sort helper < lead, so the helper's goals are queued BEFORE the lead
# exists — the case that forces the deferral in _compose_wire_role.
cat > "$TMP/team.yaml" <<'YAML'
version: "2"
agents:
  lead:
    type: claude
    role: "Lead"
    goals: ["Find out what the owner sells"]
    loops:
      - id: weekly-brief
        title: "Weekly brief"
        cron: "* * * * *"
  helper:
    type: claude
    role: "Helper"
    reports_to: lead
    goals: ["Draft three posts"]
    loops:
      - id: daily-scan
        title: "Daily scan"
        cron: "* * * * *"
YAML

# One process per run: the real compose + task + heartbeat sources, seams for the
# host-only parts. `$@` is passed to cmd_compose_up.
run_up() {
  (
    cd "$ROOT/src" || exit 1
    for f in header.sh lib/*.sh; do . "./$f"; done
    . ./cmd_task.sh; . ./cmd_heartbeat.sh; . ./cmd_loop_pack.sh; . ./cmd_compose.sh
    ensure_state() { :; }
    registry_write() { cat > "$REGISTRY"; }
    persona_append_block() { printf 'PERSONA %s %s\n' "$1" "$(grep -c '^## First start' <<<"$3")" >> "$TMP/self.log"; }
    _skill_list_json() { printf '[]'; }
    _compose_self() { printf '%s' "$SELF"; }
    JSON_MODE=1
    cmd_compose_up -f "$TMP/team.yaml" "$@"
  ) 2>"$TMP/up.err"
}
materialize() {
  (
    cd "$ROOT/src" || exit 1
    for f in header.sh lib/*.sh; do . "./$f"; done
    . ./cmd_task.sh; . ./cmd_heartbeat.sh
    tasks_db_init
    # Due now: a template that has never fired is evaluated from a minute ago.
    db "UPDATE tasks SET last_fired_at=datetime('now','-2 minutes') WHERE kind='recurring';"
    _hb_materialize_recurring "$(date -u +%s)"
  ) >/dev/null 2>&1
}
q() { sqlite3 "$TASKS_DB" "$1"; }
cli() { "$BIN" "$@"; }

# ---------------------------------------------------------------------------
# Arm 1 — before the owner answers: everything is held, nothing runs.
# ---------------------------------------------------------------------------
reset_box
out=$(run_up)
kick=$(jq -r '.data.held.kickoff // empty' <<<"$out")
[[ -n "$kick" ]] \
  && ok_t "T1 up on a first start reports a hold, kickoff $kick" \
  || bad_t 'T1 up reported no hold' "out=$out err=$(tail -5 "$TMP/up.err")"

n_kick=$(q "SELECT COUNT(*) FROM tasks WHERE body LIKE 'team kickoff: lead (5dive.yaml)%';")
[[ "$n_kick" == "1" ]] && ok_t 'T2 exactly ONE kickoff row (one plan, one ask)' || bad_t 'T2 kickoff count' "n=$n_kick"

row=$(q "SELECT assignee||'|'||status||'|'||COALESCE(parked_at,'') FROM tasks WHERE ident='$kick';")
[[ "$row" == "lead|todo|" ]] \
  && ok_t 'T3 the kickoff is the lead'"'"'s, todo and unparked at the end of the import (dispatchable)' \
  || bad_t 'T3 kickoff state' "row=$row"

held=$(q "SELECT COUNT(*) FROM task_deps d JOIN tasks k ON k.id=d.blocked_by JOIN tasks t ON t.id=d.task_id
          WHERE k.ident='$kick' AND t.status='blocked';")
seeded=$(q "SELECT COUNT(*) FROM tasks WHERE ident<>'$kick';")
[[ "$held" == "4" && "$seeded" == "4" ]] \
  && ok_t 'T4 all 2 goals + 2 loops are born blocked behind the kickoff, and nothing else was filed' \
  || bad_t 'T4 held set' "held=$held seeded=$seeded"

left=$(q "SELECT COUNT(*) FROM tasks WHERE ident<>'$kick' AND status<>'blocked';")
[[ "$left" == "0" ]] && ok_t 'T5 (a) zero seeded rows have left the held state' || bad_t 'T5 a seeded row is live' "n=$left"

materialize
runs=$(q "SELECT COUNT(*) FROM tasks WHERE from_template_id IS NOT NULL;")
[[ "$runs" == "0" ]] \
  && ok_t 'T6 (b) zero loop runs: the real materializer fires neither held template on a due cron' \
  || bad_t 'T6 a held loop fired' "runs=$runs"

grep -q 'one message\|ONE message' <<<"$(q "SELECT body FROM tasks WHERE ident='$kick';")" \
  && grep -q '60 words' <<<"$(q "SELECT body FROM tasks WHERE ident='$kick';")" \
  && ok_t 'T7 (c, structural) the kickoff asks the lead for ONE message of at most 60 words' \
  || bad_t 'T7 kickoff body does not bound the plan message' ''

grep -qx 'PERSONA lead 1' "$TMP/self.log" && ! grep -q 'PERSONA helper 1' "$TMP/self.log" \
  && ok_t 'T8 the lead'"'"'s standing instructions say what an owner'"'"'s yes is answering' \
  || bad_t 'T8 no persona block for the lead' "$(cat "$TMP/self.log")"

plan=$(cli --json team plan lead 2>/dev/null)
[[ "$(jq '.data.held | length' <<<"$plan")" == "4" && "$(jq -r '[.data.held[].kind] | sort | join(",")' <<<"$plan")" == "goal,goal,loop,loop" ]] \
  && ok_t 'T9 team plan lists the 4 held rows with their kinds' \
  || bad_t 'T9 team plan' "plan=$plan"

# ---------------------------------------------------------------------------
# Arm 2 — a skip that names something NOT held starts nothing (the typo arm).
# ---------------------------------------------------------------------------
cli team start lead --skip=DIVE-999 >/dev/null 2>&1; rc=$?
still=$(q "SELECT COUNT(*) FROM tasks WHERE ident<>'$kick' AND status='blocked';")
(( rc != 0 )) && [[ "$still" == "4" && "$(q "SELECT status FROM tasks WHERE ident='$kick';")" == "todo" ]] \
  && ok_t 'T10 --skip of a row that is not held is refused and releases NOTHING' \
  || bad_t 'T10 a bad --skip released work' "rc=$rc still=$still"

# ---------------------------------------------------------------------------
# Arm 3 — approval that drops one loop: that loop never runs, the rest do.
# ---------------------------------------------------------------------------
scan=$(q "SELECT ident FROM tasks WHERE kind='recurring' AND title='Daily scan';")
brief=$(q "SELECT ident FROM tasks WHERE kind='recurring' AND title='Weekly brief';")
rel=$(cli --json team start lead --skip="$scan" 2>/dev/null)
[[ "$(jq -r '.data.started' <<<"$rel")" == "3" && "$(jq -r '.data.left_off | join(",")' <<<"$rel")" == "$scan" ]] \
  && ok_t "T11 team start --skip=$scan starts 3 and leaves 1 off" \
  || bad_t 'T11 release counts' "rel=$rel"
[[ "$(q "SELECT status FROM tasks WHERE ident='$kick';")" == "done" ]] \
  && ok_t 'T12 the kickoff closes done' || bad_t 'T12 kickoff not closed' "$(q "SELECT status FROM tasks WHERE ident='$kick';")"
goals_live=$(q "SELECT COUNT(*) FROM tasks WHERE kind='standard' AND ident<>'$kick' AND status='todo';")
[[ "$goals_live" == "2" ]] && ok_t 'T13 both goals are todo (dispatchable)' || bad_t 'T13 goals' "n=$goals_live"
materialize
r_brief=$(q "SELECT COUNT(*) FROM tasks t JOIN tasks p ON p.id=t.from_template_id WHERE p.ident='$brief';")
r_scan=$(q "SELECT COUNT(*) FROM tasks t JOIN tasks p ON p.id=t.from_template_id WHERE p.ident='$scan';")
[[ "$r_brief" -ge 1 && "$r_scan" == "0" ]] \
  && ok_t "T14 the approved loop fires on the real materializer ($r_brief run) and the dropped one does not" \
  || bad_t 'T14 loop runs after release' "brief=$r_brief scan=$r_scan"
cli team plan lead >/dev/null 2>&1 && bad_t 'T15 team plan still finds a kickoff after release' '' \
  || ok_t 'T15 after release nothing is waiting (team plan says so)'

# Re-import of the now-running team: no second ask, nothing re-created, and the
# loop the owner dropped is NOT resurrected.
before=$(q "SELECT COUNT(*) FROM tasks WHERE from_template_id IS NULL;")
out2=$(run_up)
after=$(q "SELECT COUNT(*) FROM tasks WHERE from_template_id IS NULL;")
[[ "$(jq -r '.data.held' <<<"$out2")" == "null" && "$before" == "$after" ]] \
  && ok_t 'T16 a re-import after the yes asks nothing and files nothing (first start only)' \
  || bad_t 'T16 re-import' "held=$(jq -c '.data.held' <<<"$out2") before=$before after=$after"

# ---------------------------------------------------------------------------
# Arm 4 — decline: nothing starts.
# ---------------------------------------------------------------------------
reset_box
out=$(run_up); kick=$(jq -r '.data.held.kickoff // empty' <<<"$out")
cli team decline >/dev/null 2>&1
open=$(q "SELECT COUNT(*) FROM tasks WHERE status NOT IN ('done','cancelled');")
materialize
runs=$(q "SELECT COUNT(*) FROM tasks WHERE from_template_id IS NOT NULL;")
[[ -n "$kick" && "$open" == "0" && "$runs" == "0" && "$(q "SELECT COUNT(*) FROM tasks WHERE status='cancelled';")" == "4" ]] \
  && ok_t 'T17 team decline (no lead named, one team waiting) cancels all 4 and no loop runs' \
  || bad_t 'T17 decline' "kick=$kick open=$open runs=$runs"

# ---------------------------------------------------------------------------
# Arm 5 — the control: --start-now is the old behaviour, live at once.
# ---------------------------------------------------------------------------
reset_box
out=$(run_up --start-now)
[[ "$(jq -r '.data.held' <<<"$out")" == "null" \
   && "$(q "SELECT COUNT(*) FROM tasks WHERE status='todo';")" == "4" \
   && "$(q "SELECT COUNT(*) FROM task_deps;")" == "0" ]] \
  && ok_t 'T18 --start-now files all 4 live with no kickoff (the pre-DIVE-5729 behaviour, on request)' \
  || bad_t 'T18 --start-now' "out=$(jq -c '.data.held' <<<"$out") todo=$(q "SELECT COUNT(*) FROM tasks WHERE status='todo';")"

# ---------------------------------------------------------------------------
# Arm 6 — the task-store flags on their own.
# ---------------------------------------------------------------------------
reset_box
printf '{"schemaVersion":2,"agents":{"lead":{"type":"claude"}}}\n' > "$REGISTRY"
cli task add --assignee=lead -- "anchor" >/dev/null 2>&1
cli task done DIVE-1 --result="closed" >/dev/null 2>&1
cli task add --assignee=lead --held-by=DIVE-1 -- "behind a closed row" >/dev/null 2>&1; rc=$?
(( rc != 0 )) && [[ "$(q "SELECT COUNT(*) FROM tasks;")" == "1" ]] \
  && ok_t 'T19 --held-by a closed row is refused and writes nothing (it would never be released)' \
  || bad_t 'T19 held-by a closed row' "rc=$rc rows=$(q "SELECT COUNT(*) FROM tasks;")"
cli task add --assignee=lead --park="waiting" -- "no wake" >/dev/null 2>&1; rc=$?
(( rc != 0 )) && ok_t 'T20 --park without --park-wake is refused (DIVE-1357: a hold needs a revisit)' \
  || bad_t 'T20 --park with no wake accepted' "rc=$rc"

echo "-----"
echo "pass=$pass fail=$fail"
(( fail == 0 ))
