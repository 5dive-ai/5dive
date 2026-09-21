#!/usr/bin/env bash
# `task deliver` invoked from outside a git checkout REFUSES, and binds nothing.
#
# THE DEFECT this pins (DIVE-4733). DIVE-4634 made `task deliver` stamp
# delivery_repo_path + delivered_sha so `task grade-context` could hand the
# grader a bounded packet instead of a full row read; DIVE-4723 then pointed the
# standing verifier at that packet. When the command runs somewhere with no
# checkout under it, both columns land NULL — the packet cannot be built, and the
# grader silently falls back to the whole-row read that the two rows above exist
# to remove. Until this change that was a WARNING printed AFTER the binding
# UPDATE had already succeeded: the row was bound, the maker's next act was
# `task done` rather than a re-delivery, and nothing downstream ever noticed.
# Measured at grading on 2026-09-21: of six real rows sampled, DIVE-4719 was
# row-read for exactly this reason.
#
# WHAT THIS GRADES, and it is two claims, not one:
#   * the refusal fires (A), and
#   * it fires BEFORE the write, so a refused delivery leaves the row unbound (A2)
# — because a refusal that still stamps delivery_ref is the same defect wearing a
# non-zero exit code.
#
# Arm P is the precondition and it is not decoration: every A arm below asserts
# something about a directory with no git checkout under it, and if $TMP turned
# out to be inside a repository (or GIT_DIR leaked in from the caller's
# environment) they would all pass while measuring the ordinary in-checkout path.
#
# NO ROOT, NO NETWORK, NO INSTALL: TASKS_DB is a file in the tempdir, and the
# delivery reach probe is off through the product's own env seam.
#
#   bash tests/task_deliver_outside_checkout_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; cd /; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
REPO="$PWD"
SRC=src
TMP="$(mktemp -d /tmp/task-deliver-nocheckout.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/tasks_db.sh lib/broker.sh lib/actor.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
AUDIT_LOG="$TMP/audit.log"; : >"$AUDIT_LOG"
export FIVE_DELIVER_NO_REACH_PROBE=1
# A caller's git environment would follow us into the no-checkout directory and
# make `git rev-parse HEAD` succeed there — which is arm P's whole subject.
unset GIT_DIR GIT_WORK_TREE

# ok_t/bad_t, never ok/no: cmd_task_deliver calls the PRODUCT's ok() on success.
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

EVID='did the thing.
CHANGED: src/x.sh - one clause
CHECKED: bash tests/x_unit.sh 3 pass / 0 fail
DELIVERED-SHA: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
CI: green
CRITERIA: the one criterion -> the line above'
PR=https://github.com/5dive-ai/5dive/pull/1

seed() { # -> echoes the row id
  tasks_db_init >/dev/null 2>&1
  db "INSERT INTO tasks (title,status,assignee,verifier,kind,priority,created_by,review_mode)
      VALUES ('t','in_progress','dev','','standard','medium','main','check');" >/dev/null 2>&1
  db "SELECT id FROM tasks ORDER BY id DESC LIMIT 1;"
}
dref() { db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=$1;"; }
dsha() { db "SELECT COALESCE(delivered_sha,'') FROM tasks WHERE id=$1;"; }

# --- P) PRECONDITIONS, in both directions ------------------------------------
NOREPO="$TMP/nowhere"; mkdir -p "$NOREPO"
cd "$NOREPO"
if git rev-parse HEAD >/dev/null 2>&1; then
  bad_t "P0: the no-checkout directory really has no checkout" "git rev-parse HEAD SUCCEEDS in $NOREPO — every A arm below would grade the ordinary in-checkout path"
else
  ok_t "P0: PRECONDITION — $NOREPO is not inside any git checkout (the A arms are not vacuous)"
fi
cd "$REPO"
if git rev-parse HEAD >/dev/null 2>&1; then
  ok_t "P1: ... and the repo root IS one, so P0 measured the directory and not a broken git"
else
  bad_t "P1: the repo root is a git checkout" "git rev-parse HEAD fails at $REPO too — P0 proves nothing"
fi

# --- B) BASELINE: the in-checkout delivery is untouched ----------------------
cd "$REPO"
idb=$(seed)
out=$( cmd_task_deliver "$idb" --pr="$PR" --result="$EVID" 2>&1 ); rc=$?
[[ "$rc" == "0" && "$(dref "$idb")" == "$PR" ]] \
  && ok_t "B0: a delivery from INSIDE a checkout still succeeds and binds the ref (this change does not break the ordinary path)" \
  || bad_t "B0: the in-checkout delivery succeeds" "rc=$rc ref=$(dref "$idb") out=${out:0:400}"
[[ "$(dsha "$idb")" =~ ^[0-9a-f]{40}$ ]] \
  && ok_t "B1: ... and records a 40-hex delivered sha, so 'task grade-context' can materialize its tree" \
  || bad_t "B1: the in-checkout delivery records a sha" "delivered_sha='$(dsha "$idb")'"

# --- A) OUTSIDE a checkout: refuse, and write NOTHING ------------------------
cd "$NOREPO"
ida=$(seed)
out=$( cmd_task_deliver "$ida" --pr="$PR" --result="$EVID" 2>&1 ); rc=$?
[[ "$rc" != "0" ]] \
  && ok_t "A0: a delivery from outside a checkout is REFUSED (non-zero exit) — this is the defect, gone" \
  || bad_t "A0: the no-checkout delivery is refused" "rc=$rc out=${out:0:400}"
{ [[ -z "$(dref "$ida")" ]] && [[ -z "$(dsha "$ida")" ]]; } \
  && ok_t "A1: ... and NOTHING was written: the row is still unbound, so the refusal landed BEFORE the UPDATE" \
  || bad_t "A1: the refused delivery binds nothing" "delivery_ref='$(dref "$ida")' delivered_sha='$(dsha "$ida")' — a refusal that still stamps the ref is the same defect with a non-zero exit"
grep -q 'DIVE-4733' <<<"$out" \
  && ok_t "A2: the refusal is attributable (names DIVE-4733)" \
  || bad_t "A2: the refusal names its row" "${out:0:400}"
{ grep -qi 'cd' <<<"$out" && grep -q 'force-no-checkout' <<<"$out"; } \
  && ok_t "A3: ... and prints BOTH exits the maker has: the cd that fixes it, and the audited waiver" \
  || bad_t "A3: the refusal names the remedy and the waiver" "${out:0:400}"

# --- W) THE AUDITED EXIT -----------------------------------------------------
idw=$(seed)
out=$( cmd_task_deliver "$idw" --pr="$PR" --result="$EVID" --force-no-checkout="the PR is in a repo not cloned here" 2>&1 ); rc=$?
[[ "$rc" == "0" && "$(dref "$idw")" == "$PR" ]] \
  && ok_t "W0: --force-no-checkout=<why> lets the same delivery through and binds the ref" \
  || bad_t "W0: the waiver proceeds" "rc=$rc ref=$(dref "$idw") out=${out:0:400}"
grep -q 'not cloned here' <<<"$out" \
  && ok_t "W1: ... and the reason is echoed, so it is on the record the grader reads rather than swallowed" \
  || bad_t "W1: the waiver echoes its reason" "${out:0:400}"
[[ -z "$(dsha "$idw")" ]] \
  && ok_t "W2: ... and delivered_sha stays empty — the waiver waives the REFUSAL, it does not invent a sha" \
  || bad_t "W2: the waived delivery records no sha" "delivered_sha='$(dsha "$idw")'"

# W3 is the arm the `local` declaration exists for, and its SHAPE is the arm.
# A waiver held in a bare global outlives the command that set it, so a second
# delivery in the SAME shell would inherit it and be waived silently. The two
# calls therefore share one subshell here: the arms above each get their own
# `$( ... )`, and in that shape a leaked global dies with the subshell and this
# arm passes whether the declaration is local or not — measured, it was vacuous
# written that way. One subshell is also why the second call's refusal is read
# from the ROW rather than from `$?`: policy_refuse exits, so it ends the
# subshell and the exit status belongs to the pair, not to the second call.
#
# The leak is not reachable from the CLI (each `5dive task deliver` is its own
# process, and nothing else in-process calls cmd_task_deliver twice). This is
# scope hygiene with a test that can see it, not a live defect being fixed.
idn=$(seed); idw2=$(seed)
out=$( cmd_task_deliver "$idw2" --pr="$PR" --result="$EVID" --force-no-checkout="first, waived" 2>&1
       cmd_task_deliver "$idn"  --pr="$PR" --result="$EVID" 2>&1 )
[[ -z "$(dref "$idn")" ]] \
  && ok_t "W3: a waiver does NOT leak to the next delivery in the SAME shell — the second one is still refused and binds nothing" \
  || bad_t "W3: the waiver is per-invocation" "the second delivery bound ref=$(dref "$idn") after an earlier waived one in the same shell — a waiver held in a bare global waives every later delivery too"

# W4: a bare flag is a usage error, because the reason IS the exit.
idu=$(seed)
out=$( cmd_task_deliver "$idu" --pr="$PR" --result="$EVID" --force-no-checkout 2>&1 ); rc=$?
{ [[ "$rc" != "0" ]] && grep -q 'needs a reason' <<<"$out" && [[ -z "$(dref "$idu")" ]]; } \
  && ok_t "W4: a bare --force-no-checkout is a usage error naming what it needs, and binds nothing" \
  || bad_t "W4: the bare flag is refused" "rc=$rc out=${out:0:300}"

cd "$REPO"
printf '\n%s\n' "----- $PASS pass, $FAIL fail -----"
[[ "$FAIL" == "0" ]]
