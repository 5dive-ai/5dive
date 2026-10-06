#!/usr/bin/env bash
# DIVE-5664 (exact-swallow, 2026-10-06): `task add --verifier=codex-iris` was
# accepted because the org chart named codex-iris, though no such agent was
# registered. The row was pinned review_mode=seat:codex-iris, the grader pool
# skips a pinned non-pool seat by design, and `task verifier <id> codex-elm` moved
# the verifier but left review_mode on the dead seat. The agent fixed it with
# raw sqlite.
#   G0  CONTROL: the chart still widens --assignee (an org-only name is accepted
#       there), so the refusal below is scoped to graders, not a roster change
#   G1  task add --verifier=<chart-only> is refused, no row written
#   G2  task add --review=<chart-only> is refused the same way
#   G3  task add --verifier=<registered> still files, pinned seat:<it>
#   G4  task verifier <id> <chart-only> is refused, the row unchanged
#   G5  task verifier re-points a pinned row: verifier AND review_mode move
#   G6  a row that is not seat-pinned keeps its review_mode
#   G7  an unreadable registry still refuses nothing (fail-open kept)
# Run: bash tests/task_grader_seat_registered_unit.sh
set -uo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
TMP="$(mktemp -d /tmp/task-grader-seat-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  source "src/$f"
done
STATE_DIR="$TMP"; REGISTRY="$STATE_DIR/agents.json"
TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
JSON_MODE=1
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
roster_reset() { _TASK_ROSTER=""; _TASK_ROSTER_STATE=""; _TASK_ROSTER_REG=""; _TASK_ROSTER_WARNED=""; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }
count() { db "SELECT COUNT(*) FROM tasks WHERE title=$(sqlq "$1");"; }

tasks_db_init
printf '{"agents":{"dev":{"type":"claude"},"quinn":{"type":"claude"},"codex-elm":{"type":"codex"},"main":{"type":"claude"}}}\n' > "$REGISTRY"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator'),('codex-iris','main','builder');"
roster_reset

# --- G0: the chart still widens an assignee -----------------------------------
out=$(cmd_task_add "G0 chart assignee" --assignee=codex-iris --no-verify 2>&1); rc=$?
[[ $rc -eq 0 && "$(count "G0 chart assignee")" == 1 ]] \
  && ok_t "G0 CONTROL --assignee=<chart-only> is still accepted (the chart widens lanes)" || bad_t "G0 assignee" "rc=$rc $out"

# --- G1/G2: a chart-only grader is refused at add -----------------------------
roster_reset
out=$(cmd_task_add "G1 chart verifier" --assignee=dev --verifier=codex-iris 2>&1); rc=$?
[[ $rc -eq $E_VALIDATION && "$out" == *"--verifier='codex-iris' is on the org chart but is not a registered agent"* && "$(count "G1 chart verifier")" == 0 ]] \
  && ok_t "G1 --verifier=<chart-only> is refused, no row written" || bad_t "G1 verifier" "rc=$rc rows=$(count "G1 chart verifier") $out"
roster_reset
out=$(cmd_task_add "G2 chart review" --assignee=dev --review=codex-iris 2>&1); rc=$?
[[ $rc -eq $E_VALIDATION && "$out" == *"codex-iris"*"not a registered agent"* && "$(count "G2 chart review")" == 0 ]] \
  && ok_t "G2 --review=<chart-only> is refused the same way" || bad_t "G2 review" "rc=$rc $out"

# --- G3: a registered grader still files, pinned ------------------------------
roster_reset
out=$(cmd_task_add "G3 real reviewer" --assignee=dev --review=quinn 2>&1); rc=$?
id3=$(db "SELECT ident FROM tasks WHERE title='G3 real reviewer';")
[[ $rc -eq 0 && "$(field "$id3" verifier)|$(field "$id3" review_mode)" == "quinn|seat:quinn" ]] \
  && ok_t "G3 --review=<registered> files, verifier=quinn review_mode=seat:quinn" || bad_t "G3 file" "rc=$rc $(field "$id3" verifier)|$(field "$id3" review_mode) $out"

# --- G4: task verifier refuses a chart-only seat, row unchanged ---------------
roster_reset
out=$(cmd_task_verifier "$id3" codex-iris 2>&1); rc=$?
[[ $rc -eq $E_VALIDATION && "$out" == *"not a registered agent"* && "$(field "$id3" verifier)|$(field "$id3" review_mode)" == "quinn|seat:quinn" ]] \
  && ok_t "G4 task verifier <id> <chart-only> is refused; verifier and review_mode unchanged" || bad_t "G4" "rc=$rc $(field "$id3" verifier)|$(field "$id3" review_mode) $out"

# --- G5: the re-point moves the pinned seat too -------------------------------
roster_reset
out=$(cmd_task_verifier "$id3" codex-elm 2>&1); rc=$?
[[ $rc -eq 0 && "$(field "$id3" verifier)|$(field "$id3" review_mode)" == "codex-elm|seat:codex-elm" ]] \
  && ok_t "G5 task verifier re-points a pinned row: verifier AND review_mode=seat:codex-elm" || bad_t "G5" "rc=$rc $(field "$id3" verifier)|$(field "$id3" review_mode) $out"

# --- G6: a row that is not seat-pinned keeps its mode -------------------------
roster_reset
cmd_task_add "G6 pool row" --assignee=dev --review=temp >/dev/null 2>&1
id6=$(db "SELECT ident FROM tasks WHERE title='G6 pool row';")
before=$(field "$id6" review_mode)
cmd_task_verifier "$id6" quinn >/dev/null 2>&1
[[ "$before" != "∅" && "$before" != seat:* && "$(field "$id6" review_mode)" == "$before" && "$(field "$id6" verifier)" == quinn ]] \
  && ok_t "G6 a '$before' row gets the verifier and keeps review_mode=$before" || bad_t "G6" "before=$before after=$(field "$id6" review_mode) v=$(field "$id6" verifier)"

# --- G7: an unreadable registry refuses nothing -------------------------------
printf 'not json' > "$REGISTRY"; roster_reset
out=$(cmd_task_add "G7 unmeasured" --assignee=dev --verifier=codex-iris 2>&1); rc=$?
[[ $rc -eq 0 && "$(count "G7 unmeasured")" == 1 ]] \
  && ok_t "G7 an unparseable registry still refuses nothing (fail-open kept)" || bad_t "G7" "rc=$rc $out"

printf '\ntask grader-seat registered unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
