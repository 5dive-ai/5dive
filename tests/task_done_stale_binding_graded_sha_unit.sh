#!/usr/bin/env bash
# DIVE-8904 — the DIVE-2682 stale-binding refusal accepts a binding whose PR head
# IS the graded sha. The loop below is the one that refused ten rows on
# 11-19..11-20: delivery bound to PR X at it1 (the stamp `task deliver` writes),
# a reject, the maker pushes the fix to the SAME PR X and re-delivers with
# `task done` (no re-stamp), the verifier closes with `graded-sha: <X's head>`.
# DIVE-2057's shape (fix in a NEW PR Y, binding still X) must still refuse, and
# so must every case where the match is not MEASURED. The forge reads are the
# devteam plugin's (`_gate_pr_shas`), stubbed here: no network, no live tasks.db.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
as_agent() { local _w="$1"; shift; ( actor_seam_as "$_w"; "$@" ); }
SRC=src
TMP="$(mktemp -d /tmp/stale-binding-graded-unit.XXXXXX)"
mkdir -p "$TMP/bin"; printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"; chmod +x "$TMP/bin/sudo"
PATH="$TMP/bin:$PATH"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh \
         cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=0
mkdir -p "$TASKS_DIR"
set +e

P=0; F=0
ok(){ P=$((P+1)); echo "ok   - $1"; }
no(){ F=$((F+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "   ${2:0:400}"; }

X="https://github.com/5dive-ai/5dive/pull/9001"
HEAD_X="aaaaaaa1111111111111111111111111111111aa"
HEAD_Y="bbbbbbb2222222222222222222222222222222bb"
MERGE_X="ccccccc3333333333333333333333333333333cc"

# The plugin seam, as the devteam bundle supplies it. _gate_graded_sha is the
# plugin's parser verbatim (last labelled line wins, lowercase).
_gate_graded_sha() {
  local txt="${1:-}" line sha=""
  while IFS= read -r line; do
    if [[ "$line" =~ [Gg][Rr][Aa][Dd][Ee][Dd][-_\ ][Ss][Hh][Aa][[:space:]]*[:=][[:space:]]*([0-9a-fA-F]{7,40}) ]]; then
      sha="${BASH_REMATCH[1]}"
    fi
  done <<<"$txt"
  printf '%s' "${sha,,}"
}
_gate_pr_shas() { printf '%s' "${PR_SHAS-}"; }
_gate_gh_token() { printf ''; }
_gate_slug_from_url() { printf '5dive-ai/5dive'; }
_gate_version_vs_installed() { :; }
_gate_task_repo_slug() { printf "5dive-ai/5dive"; }
STALE="cannot close: its delivery binding"

# --- helper arms -------------------------------------------------------------
h() { PR_SHAS="$1" _task_binding_carries_graded_sha "$X" "$2"; echo $?; }
[ "$(h "$HEAD_X|" "graded-sha: ${HEAD_X:0:12}")" = 0 ] && ok "H1 graded-sha == bound PR head -> current" || no "H1 head match"
[ "$(h "$HEAD_X|$MERGE_X" "graded-sha: ${MERGE_X}")" = 0 ] && ok "H2 graded-sha == bound PR merge commit -> current" || no "H2 merge match"
[ "$(h "$HEAD_X|$MERGE_X" "graded-sha: ${HEAD_Y:0:12}")" = 1 ] && ok "H3 DIVE-2057: graded the NEW PR's head -> not current" || no "H3 2057 shape"
[ "$(h "$HEAD_X|" "PASS, merged")" = 1 ] && ok "H4 no graded-sha claim -> not current" || no "H4 no claim"
[ "$(h "" "graded-sha: ${HEAD_X:0:12}")" = 1 ] && ok "H5 forge read did not answer -> not current (fails closed)" || no "H5 unread"
[ "$(h "|" "graded-sha: ${HEAD_X:0:12}")" = 1 ] && ok "H6 both shas empty -> not current" || no "H6 empty pair"
[ "$(h "${HEAD_X^^}|" "graded-sha: ${HEAD_X:0:12}")" = 0 ] && ok "H7 case-insensitive compare" || no "H7 case"
( unset -f _gate_pr_shas; PR_SHAS="$HEAD_X|" _task_binding_carries_graded_sha "$X" "graded-sha: ${HEAD_X:0:12}" ); \
  [ $? = 1 ] && ok "H8 no devteam plugin -> not current" || no "H8 no plugin"

# --- the loop, through the core verbs ----------------------------------------
devteam_loaded() { return 0; }
tasks_db_init >/dev/null 2>&1
loop_row() {  # deliver(it1, stamped) -> reject -> maker `task done` re-delivery
  db "INSERT INTO tasks (title,status,assignee,verifier,kind,priority,created_by,body)
      VALUES ('loop row $1','in_progress','dev','quinn','standard','medium','quinn','b');" >/dev/null
  local id; id=$(db "SELECT id FROM tasks ORDER BY id DESC LIMIT 1;")
  db "UPDATE tasks SET delivery_ref=$(sqlq "$X"), delivered_at=datetime('now') WHERE id=$id;"
  _task_route_to_verifier "$id" quinn dev "it1 delivered on $X" 1 1 >/dev/null 2>&1   # what `task deliver` runs
  as_agent quinn cmd_task_reject "$id" --feedback="FINDING: x. FIX: y. VERIFY: z." >/dev/null 2>&1
  db "UPDATE tasks SET status='in_progress', assignee='dev' WHERE id=$id;"
  as_agent dev cmd_task_done "$id" --result="it2: fix pushed to the same PR $X" >/dev/null 2>&1
  echo "$id"
}
id=$(loop_row same)
read -r bi it st asg < <(db "SELECT COALESCE(delivery_ref_iteration,''), COALESCE(iteration,0), status, assignee FROM tasks WHERE id=$id;" | tr '|' ' ')
[[ -n "$bi" && "$bi" -lt "$it" && "$asg" == quinn ]] \
  && ok "L0 fixture reproduces the defect state: bind_iter=$bi < iteration=$it, row with quinn" \
  || no "L0 fixture state" "bind=$bi iter=$it st=$st asg=$asg"

out=$(PR_SHAS="$HEAD_X|$MERGE_X" as_agent quinn cmd_task_done "$id" --result="graded-sha: ${HEAD_X:0:12}
PASS" 2>&1)
grep -q "$STALE" <<<"$out" \
  && no "L1 same PR, graded-sha == its head: the stale-binding refusal does NOT fire" "$out" \
  || ok "L1 same PR, graded-sha == its head: the stale-binding refusal does NOT fire"
grep -q 'DIVE-8904' <<<"$out" && ok "L2 and the close says why the binding was accepted" || no "L2 accepted line" "$out"

id2=$(loop_row newpr)
out=$(PR_SHAS="$HEAD_X|$MERGE_X" as_agent quinn cmd_task_done "$id2" --result="graded-sha: ${HEAD_Y:0:12}
PASS on the new PR" 2>&1)
grep -q "$STALE" <<<"$out" \
  && ok "L3 DIVE-2057 shape (graded a NEW PR's head, binding still X) still refuses" \
  || no "L3 2057 still refuses" "$out"
[ "$(db "SELECT status FROM tasks WHERE id=$id2;")" != done ] && ok "L4 and the row stays open" || no "L4 row open"

id3=$(loop_row unread)
out=$(PR_SHAS="" as_agent quinn cmd_task_done "$id3" --result="graded-sha: ${HEAD_X:0:12}" 2>&1)
grep -q "$STALE" <<<"$out" \
  && ok "L5 forge unreadable: the refusal stands (fails closed)" || no "L5 unread refuses" "$out"

grep -q 'DIVE-8904' <<<"$out" && ok "L6 the refusal now names the graded-sha way out" || no "L6 refusal remedy" "$out"

echo "passed=$P failed=$F"
[ "$F" -eq 0 ]
