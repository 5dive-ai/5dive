#!/usr/bin/env bash
# DIVE-3496 (iteration 2) — THE DELIVERY-TIME REACHABILITY TRIPWIRE.
#
# WHAT IT GRADES. `cmd_task_deliver` binds a delivery ref that the MERGE GATE will
# later be asked to read — one verb later, from the VERIFIER's seat, in a session
# the maker is not in. When that read comes back blind the gate cannot tell
# "cannot see" from "not merged", which is correct and is what makes it fail
# closed, but it means the verifier pays the whole discovery cost cold. Measured
# on DIVE-2192: two failed closes, an `/installation/repositories` enumeration, a
# `gh auth status` check and a wiki compile to reach "I am permanently unable to
# close this row", then a round-trip to learn the designed exit existed
# (community/wiki/a-grader-that-cannot-read-the-repo-cannot-close-the-row.md).
# The probe moves that to the moment the ref is bound, for one read-only query.
#
# THE PROPERTY THAT IS EASY TO GET WRONG, and R4 is here for it: the probe must
# assert READ REACH by the credential the gate will actually use — NOT membership
# in the ownership constant. `_gate_our_owners` is derived from `_gate_repo_slugs`
# and `lodar` IS one of our owners, which is exactly why `lodar/5dive-api` was
# gated and ungradeable at the same time for months. The two sets are unrelated,
# and only the first predicts nothing. R4 pins the pair: `lodar` is in the
# ownership list AND the probe still warns, so an ownership check could not
# possibly be standing in for the read.
#
# WARN-ONLY IS ALSO A GRADED PROPERTY (R2c/R2d). A delivery must not be refused
# because GitHub was briefly unreachable — that is the same fail-open/fail-closed
# question the gate answers one verb later, and the gate is where it belongs.
# Turning a transient network fault into a blocked handoff, on the one verb whose
# job is to get finished work off the maker's desk, would be a worse defect than
# the one being fixed.
#
# ISOLATION. src/ sourced into a throwaway STATE_DIR (the live tasks.db is NEVER
# touched); `gh` and `sudo` STUBBED on PATH, so no network call and no root. The
# token RESOLVER is overridden rather than exercised — what this file grades is
# the probe's routing decision, and `_gate_gh_token`'s own arms are graded by
# their own siblings (tests/task_merge_gate_selftest_unit.sh).
# Run: bash tests/task_deliver_reach_probe_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# MUST sit AFTER grading_tree.sh — it sources lib/env_isolation.sh, which clears
# inherited FIVE_* knobs, so an export above this line is silently wiped.
export FIVE_GATE_NO_ANON=1
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/deliver-reach-unit.XXXXXX)"
mkdir -p "$TMP/bin"

# --- stub gh: the CALLER'S credential, replaying the three measured outcomes.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'GH %s\n' "$*" >>"$GH_ARGS_LOG"
case "${GH_STUB_MODE:-blind_repo}" in
  ok)         printf '%s\n' "${GH_STUB_OUT:-MERGED}"; exit 0 ;;
  blind_repo) printf 'GraphQL: Could not resolve to a Repository with the name '"'"'lodar/5dive-api'"'"'. (repository)\n' >&2; exit 1 ;;
esac
exit 1
STUB
chmod +x "$TMP/bin/gh"

# --- stub sudo: the credential-free BOT rail (`sudo -n /usr/local/bin/5dive _gh_do`).
cat >"$TMP/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'BOT\n' >>"$GH_ARGS_LOG"
[[ "${BOT_STUB_RC:-0}" == "0" ]] || { printf 'gh: Not Found (HTTP 404)\n' >&2; exit "${BOT_STUB_RC}"; }
printf '%s' "${BOT_STUB_OUT:-MERGED}"
exit 0
STUB
chmod +x "$TMP/bin/sudo"

export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/tasks_db.sh lib/broker.sh lib/actor.sh \
         cmd_task.sh cmd_push.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e

# `_GATE_GH_DO` is a readonly path constant probed with `-x`, false on a runner
# with no installed CLI. Override the PROBE, not the path (same contract as the
# sibling blind-credential harness).
_gate_gh_bot_ok() { [[ "${BOT_STUB_AVAILABLE:-1}" == "1" ]]; }
# The probe must use whatever the GATE resolves. Pin it to a fixture so the arms
# grade the routing decision and not this runner's ambient credentials.
_gate_gh_token() { printf '%s' "${TOK_FIXTURE:-ghs_pinned_to_the_org}"; }

P=0; F=0
ok(){ P=$((P+1)); echo "ok   - $1"; }
no(){ F=$((F+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "   ${2:0:400}"; }

reset_stubs() {
  export GH_STUB_MODE=blind_repo GH_STUB_OUT=MERGED
  export BOT_STUB_OUT=MERGED BOT_STUB_RC=0 BOT_STUB_AVAILABLE=1
  export TOK_FIXTURE=ghs_pinned_to_the_org
  unset FIVE_DELIVER_NO_REACH_PROBE
  : >"$GH_ARGS_LOG"
}

seedv() { # $1=assignee $2=verifier -> echoes the row id
  tasks_db_init >/dev/null 2>&1
  db "INSERT INTO tasks (title,status,assignee,verifier,kind,priority,created_by)
      VALUES ('t','in_progress','$1',$(sqlq "$2"),'standard','medium','main');" >/dev/null 2>&1
  db "SELECT id FROM tasks ORDER BY id DESC LIMIT 1;"
}
dref() { db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=$1;"; }

READABLE=https://github.com/5dive-ai/5dive/pull/673
BLIND=https://github.com/lodar/5dive-api/pull/110

# --- R1. THE QUIET PATH: a ref the gate's credential can read says nothing -----
# The tripwire's cost is a warning nobody needed, so the arm that keeps it usable
# is the one proving it stays silent on the ordinary delivery. Note the stub
# answers OPEN, not MERGED: the probe asks whether the ref is READABLE, never
# whether it merged — a delivery is normally bound BEFORE the merge, and a probe
# that demanded MERGED here would warn on essentially every honest delivery.
reset_stubs; export GH_STUB_MODE=ok GH_STUB_OUT=OPEN
id=$(seedv dev "")
out=$( cmd_task_deliver "$id" --pr="$READABLE" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "R1a a readable ref delivers cleanly (rc=0)" || no "R1a clean delivery" "rc=$rc $out"
grep -q 'cannot READ the delivery ref' <<<"$out" && no "R1b silent on a readable ref" "$out" || ok "R1b no warning on a readable ref"
grep -q '^GH ' "$GH_ARGS_LOG" && ok "R1c the probe DID run (it is not silent by never asking)" || no "R1c probe ran" "$(cat "$GH_ARGS_LOG")"
[ "$(dref "$id")" = "$READABLE" ] && ok "R1d delivery_ref stamped" || no "R1d delivery_ref stamped" "$(dref "$id")"

# --- R2. THE FIX: an unreadable ref warns, and the delivery still stands -------
reset_stubs; export GH_STUB_MODE=blind_repo BOT_STUB_RC=1
id=$(seedv dev "")
out=$( cmd_task_deliver "$id" --pr="$BLIND" 2>&1 ); rc=$?
grep -q 'cannot READ the delivery ref' <<<"$out" && ok "R2a an unreadable ref WARNS at deliver time" || no "R2a warns on an unreadable ref" "$out"
grep -qF "$BLIND" <<<"$out" && ok "R2b the warning names the ref" || no "R2b warning names the ref" "$out"
[ "$rc" -eq 0 ] && ok "R2c WARN-ONLY: the delivery is not refused (rc=0)" || no "R2c delivery not refused" "rc=$rc $out"
[ "$(dref "$id")" = "$BLIND" ] && ok "R2d WARN-ONLY: the ref is still bound" || no "R2d ref still bound" "$(dref "$id")"
grep -q 'task verify' <<<"$out" && ok "R2e the warning names the designed exit (task verify --cmd)" || no "R2e names the exit" "$out"
grep -q 'merge-base --is-ancestor' <<<"$out" && ok "R2f and spells the proof that needs no GitHub" || no "R2f spells the proof" "$out"
# THE SUBSHELL ARM. `_state=$(_gate_gh ...)` would run the gate in a subshell and
# its `_GATE_GH_LAST_ERR` would die there — the same trap this iteration fixes one
# level down — leaving the reader a warning with no cause attached.
grep -q 'Rail says:' <<<"$out" && ok "R2g the rail's reason survives into the warning" || no "R2g rail reason present" "$out"
grep -q 'cannot see this repository' <<<"$out" && ok "R2h and the reason is the real one, not a placeholder" || no "R2h real reason" "$out"

# --- R3. IT USES THE GATE'S RAIL SELECTION, NOT A NARROWER ONE ----------------
# Caller credential blind, bot rail answers: post-#673 the GATE can read this ref,
# so the probe must NOT warn. A probe that only tried the caller's own token would
# cry wolf on every lodar/* delivery from a verifier-shaped seat.
reset_stubs; export GH_STUB_MODE=blind_repo BOT_STUB_RC=0 BOT_STUB_OUT=MERGED
id=$(seedv dev "")
out=$( cmd_task_deliver "$id" --pr="$BLIND" 2>&1 ); rc=$?
grep -q 'BOT' "$GH_ARGS_LOG" && ok "R3a the probe escalates exactly as the gate does" || no "R3a probe escalates" "$(cat "$GH_ARGS_LOG")"
grep -q 'cannot READ the delivery ref' <<<"$out" && no "R3b no warning when the GATE can read it" "$out" || ok "R3b no warning when the GATE can read it"
[ "$rc" -eq 0 ] && ok "R3c delivery clean" || no "R3c delivery clean" "rc=$rc $out"

# --- R4. OWNERSHIP IS NOT READ REACH ------------------------------------------
# The pair, asserted together so neither half can be vacuous: lodar IS in the
# ownership constant, AND the probe still warns about lodar/5dive-api. An
# ownership test could not produce this result, so it cannot be what is running.
reset_stubs; export GH_STUB_MODE=blind_repo BOT_STUB_RC=1
_gate_our_owners | grep -qx 'lodar' \
  && ok "R4a positive control: 'lodar' IS one of our owners (_gate_our_owners)" \
  || no "R4a lodar is in the ownership constant" "$(_gate_our_owners | tr '\n' ' ')"
id=$(seedv dev "")
out=$( cmd_task_deliver "$id" --pr="$BLIND" 2>&1 )
grep -q 'cannot READ the delivery ref' <<<"$out" \
  && ok "R4b …and an OWNED-but-unreadable ref warns anyway (read reach, not ownership)" \
  || no "R4b owned-but-unreadable warns" "$out"

# --- R5. THE ROUTED RAIL ------------------------------------------------------
# `cmd_task_deliver` forks on `verifier != assignee` and the routed arm RETURNS
# early. A probe placed below the fork would miss the one shape that matters most
# — the row that is actually being handed to a verifier. Same omission
# DIVE-2476's review caught on the result guard; measured here rather than argued.
reset_stubs; export GH_STUB_MODE=blind_repo BOT_STUB_RC=1
id=$(seedv dev quinn)
out=$( cmd_task_deliver "$id" --pr="$BLIND" 2>&1 ); rc=$?
grep -q 'cannot READ the delivery ref' <<<"$out" && ok "R5a the ROUTED rail probes too" || no "R5a routed rail probes" "$out"
[ "$rc" -eq 0 ] && ok "R5b the routed handoff still completes (rc=0)" || no "R5b routed handoff completes" "rc=$rc $out"
[ "$(db "SELECT assignee FROM tasks WHERE id=$id;")" = "quinn" ] && ok "R5c the row still routed to the verifier" || no "R5c routed to verifier" "$(db "SELECT assignee FROM tasks WHERE id=$id;")"

# --- R6. THE ESCAPE HATCH -----------------------------------------------------
# Offline runs and harnesses need an off switch; it must not be able to let
# anything through, because the gate does its own read at close regardless.
reset_stubs; export GH_STUB_MODE=blind_repo BOT_STUB_RC=1 FIVE_DELIVER_NO_REACH_PROBE=1
id=$(seedv dev "")
out=$( cmd_task_deliver "$id" --pr="$BLIND" 2>&1 ); rc=$?
grep -q 'cannot READ the delivery ref' <<<"$out" && no "R6a FIVE_DELIVER_NO_REACH_PROBE=1 silences the probe" "$out" || ok "R6a FIVE_DELIVER_NO_REACH_PROBE=1 silences the probe"
grep -q '^GH ' "$GH_ARGS_LOG" && no "R6b …and spends no request" "$(cat "$GH_ARGS_LOG")" || ok "R6b …and spends no request"
[ "$rc" -eq 0 ] && ok "R6c delivery unaffected" || no "R6c delivery unaffected" "rc=$rc $out"
[ "$(dref "$id")" = "$BLIND" ] && ok "R6d ref still bound with the probe off" || no "R6d ref bound" "$(dref "$id")"

# --- R7. BUDGET ---------------------------------------------------------------
# One read-only query per delivery on the quiet path. `task deliver` is a
# once-per-iteration verb, so this is the whole cost of the tripwire.
reset_stubs; export GH_STUB_MODE=ok GH_STUB_OUT=OPEN
id=$(seedv dev "")
cmd_task_deliver "$id" --pr="$READABLE" >/dev/null 2>&1
n=$(grep -c '^GH ' "$GH_ARGS_LOG")
[ "$n" = "1" ] && ok "R7a exactly one caller query on the quiet path" || no "R7a one query" "got $n"
[ "$(grep -c '^BOT$' "$GH_ARGS_LOG")" = "0" ] && ok "R7b and no second rail is touched when the first answers" || no "R7b no second rail" "$(cat "$GH_ARGS_LOG")"

printf '\n%d passed, %d failed\n' "$P" "$F"
[ "$F" -eq 0 ] || exit 1
