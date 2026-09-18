#!/usr/bin/env bash
# Two message-order defects in the task verbs, graded against REAL built bundles.
#
# A. A REFUSED CLOSE SAID THE APPENDED RESULT WAS KEPT. `_task_guard_result_over_closed`
#    composes `prev + seam + new` and said "this row already carried a result and it was
#    PRESERVED, not replaced — N bytes kept above your text" at the moment it composed it.
#    Every close guard that can still refuse runs AFTER that point (the merge-pending guard,
#    DIVE-4520; done-before-pr-merged, DIVE-1830). So on a refused close the operator read a
#    sentence asserting a write, then a refusal, and the row's result was byte-identical to
#    before. Measured twice on 2026-09-18 at 7597 and 9237 bytes, both unchanged; two makers
#    believed their post-delivery notes were on the row.
#
# B. A VERIFY FAIL READ AS A CLI CRASH. `warn` does not set the reported flag (only `fail`
#    does), so the DIVE-2598 backstop saw `task verify`'s non-zero exit with nothing claimed
#    and printed "exited 1 without reporting a reason. This is a bug in the CLI, not a
#    refusal … Please file it: 5dive bug." over a FAIL verdict that had just been recorded
#    correctly on the row.
#
# WHY THE BUNDLE AND NOT A SOURCED TREE. Both defects are properties of what the OPERATOR
# SEES from a whole process: A is an ordering between a warn and a refusal that exits, and B
# is the EXIT-trap backstop, which does not run at all when a harness calls cmd_* in-process.
# A sourced fixture would grade neither. So every arm below runs a built bundle as its own
# process, in the shape tests/a2a_rounds_json_unit.sh and
# tests/silent_nonzero_exit_backstop_unit.sh established, and each defect gets a MUTANT
# bundle — the fix reverted, nothing else — that must show the defect live.
# DIVE-2211: name the tree this harness grades. Sourced BEFORE the cd, from BASH_SOURCE, so
# the tree named is the one this FILE lives in rather than $PWD.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
TMP="$(mktemp -d /tmp/task-message-before-write.XXXXXX)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

command -v sqlite3 >/dev/null 2>&1 || { printf 'PRECONDITION-FAILED: sqlite3 is required\n'; exit 1; }

# --- bundles: the shipped one, and one per reverted fix ----------------------
build_from() { # <src-dir-or-ROOT> <out> -> 0 on success
  ( cd "$1" && BUILD_OUT="$2" ./build.sh ) >"$TMP/build.log" 2>&1
}
BIN="$TMP/5dive-fixed"
build_from "$ROOT" "$BIN" || { printf 'PRECONDITION-FAILED: build.sh did not produce a bundle\n'; sed -n '1,20p' "$TMP/build.log"; exit 1; }

# A MUTANT IS THE SHIPPED BUNDLE WITH ONE LINE REVERTED. Not a rebuilt tree: build.sh
# stamps the source commit and refuses to run outside a git checkout, and a copied .git is
# both slow and a second thing that can differ. The bundle is a concatenation of src/, so
# the fixed line is in it verbatim — substituting it there makes the differential provably
# one line, which a rebuild can only assert about its inputs.
mutant() { # mutant <out> <perl-expr> — prints the changed-line count on stdout
  local out="$1" expr="$2"
  cp "$BIN" "$out"; chmod +x "$out"
  perl -0pi -e "$expr" "$out"
  diff "$BIN" "$out" | grep -c '^[<>]'
}

# --- fixtures ----------------------------------------------------------------
OLD='ORIGINAL RESULT TEXT — written by the first writer.'
NEW='ADDED BY THE SECOND WRITER.'
PR=https://github.com/5dive-ai/5dive/pull/998

seed() { # <state-dir> — a row whose close is REFUSED, and an ordinary open row
  local sd="$1"; local dbf="$sd/tasks/tasks.db"
  mkdir -p "$sd/tasks"
  STATE_DIR="$sd" "$BIN" task ls >/dev/null 2>&1   # let the CLI create the schema it owns
  sqlite3 "$dbf" "
    INSERT INTO tasks(ident,title,status,created_by,assignee,maker_agent,verifier,
      graded_at,graded_by,graded_verdict,delivery_ref,result)
    VALUES('DIVE-900','refused close','in_progress','luca','dev','dev','quinn',
      '2026-09-17 09:00:00','quinn','pass','$PR','$OLD');
    INSERT INTO tasks(ident,title,status,created_by,assignee,result)
    VALUES('DIVE-901','ordinary open row','in_progress','luca','dev','$OLD');
    INSERT INTO tasks(ident,title,status,created_by,assignee)
    VALUES('DIVE-902','a row to verify','in_progress','luca','dev');" 2>/dev/null
}

res_of() { sqlite3 "$1/tasks/tasks.db" "SELECT COALESCE(result,'') FROM tasks WHERE ident='$2';" 2>/dev/null; }

runsd() { # runsd <bundle> <state-dir> <args...> -> RC, OUT, ERR
  local b="$1"; local sd="$2"; shift 2
  OUT="$(STATE_DIR="$sd" "$b" "$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
  return 0
}

KEPT_RE='bytes kept above your text'
BACKSTOP_RE='without reporting a reason'

# =============================================================================
# A. THE REFUSED CLOSE
# =============================================================================
SD="$TMP/state-a"; seed "$SD"
before="$(res_of "$SD" DIVE-900)"
[[ "$before" == "$OLD" ]] \
  && ok_t "A0 PRECONDITION: the row carries the first writer's result (${#before} bytes)" \
  || bad_t "A0 fixture" "result is [${before:0:80}]"

runsd "$BIN" "$SD" task done DIVE-900 --append-result --result="$NEW"
(( RC != 0 )) \
  && ok_t "A1 the close is REFUSED (rc=$RC) — this row is graded PASS and waiting on a merge" \
  || bad_t "A1 close must be refused" "rc=$RC out=[${OUT:0:200}] err=[${ERR:0:200}]"
after="$(res_of "$SD" DIVE-900)"
[[ "$after" == "$before" ]] \
  && ok_t "A2 ...and NOTHING was written: the result is byte-identical, ${#after} bytes" \
  || bad_t "A2 result must be unchanged" "before=${#before}B after=${#after}B"
[[ ! "$ERR" =~ $KEPT_RE ]] \
  && ok_t "A3 THE FIX: the refusal does NOT claim 'bytes kept above your text' — the sentence that was false is gone" \
  || bad_t "A3 refused close must not claim a write" "stderr=[${ERR:0:400}]"
[[ "$ERR" != *"PRESERVED, not replaced"* ]] \
  && ok_t "A3b ...nor 'PRESERVED, not replaced', which is the same claim in the other half of the sentence" \
  || bad_t "A3b" "stderr=[${ERR:0:400}]"
[[ -n "$ERR" ]] \
  && ok_t "A4 ...and the refusal still SAYS something: silence would be a different defect" \
  || bad_t "A4 refusal must print a reason" "stderr empty"

# THE POSITIVE CONTROL. Without this, A3 passes on a build that simply deleted the message.
runsd "$BIN" "$SD" task done DIVE-901 --result="$NEW"
(( RC == 0 )) \
  && ok_t "A5 POSITIVE CONTROL: an ordinary open row carrying a result closes (rc 0)" \
  || bad_t "A5 control close must succeed" "rc=$RC err=[${ERR:0:300}]"
[[ "$ERR" =~ $KEPT_RE ]] \
  && ok_t "A6 ...and THERE the message IS printed — the fix defers the claim, it does not delete it" \
  || bad_t "A6 successful close must still say it" "stderr=[${ERR:0:400}]"
a901="$(res_of "$SD" DIVE-901)"
[[ "$a901" == *"$OLD"* && "$a901" == *"$NEW"* && "$a901" == *"appended"* ]] \
  && ok_t "A7 ...and the row really does carry both texts under a dated seam (${#a901} bytes)" \
  || bad_t "A7 seam" "result=[${a901:0:200}]"
[[ "${#a901}" -gt "${#OLD}" ]] \
  && ok_t "A8 ...so the byte count the message reports is a claim about a write that happened" \
  || bad_t "A8" "len=${#a901}"

# =============================================================================
# B. THE VERIFY FAIL
# =============================================================================
runsd "$BIN" "$SD" task verify DIVE-902 --cmd=false --no-done
(( RC == 1 )) \
  && ok_t "B1 a failing grade command still exits 1, so a shell caller can branch on the verdict" \
  || bad_t "B1 rc must stay 1" "rc=$RC err=[${ERR:0:300}]"
[[ "$ERR" == *"verify FAIL (exit 1)"* ]] \
  && ok_t "B2 ...and says so: 'verify FAIL (exit 1)'" || bad_t "B2 FAIL line" "stderr=[${ERR:0:300}]"
[[ ! "$ERR" =~ $BACKSTOP_RE ]] \
  && ok_t "B3 THE FIX: it is NOT also reported as 'exited 1 without reporting a reason'" \
  || bad_t "B3 backstop must not fire on a reported FAIL" "stderr=[${ERR:0:500}]"
[[ "$ERR" != *"This is a bug in the CLI"* && "$ERR" != *"5dive bug"* ]] \
  && ok_t "B4 ...so a recorded verdict no longer tells the operator to file a bug" \
  || bad_t "B4 bug-report advice must be gone" "stderr=[${ERR:0:500}]"

# =============================================================================
# MUTANTS — each fix reverted on its own, nothing else, and the defect must return
# =============================================================================
MBIN_A="$TMP/5dive-mut-a"
mdiff=$(mutant "$MBIN_A" 's/^      defer_write_note "\$ident: this row already carried/      warn "\$ident: this row already carried/m')
[[ "$mdiff" == "2" ]] \
  && ok_t "MA0 MUTANT A is the shipped bundle with the deferral turned back into an immediate warn — exactly one line different" \
  || bad_t "MA0 one-line differential" "changed lines=$mdiff"
[[ "$(grep -c '^      warn "\$ident: this row already carried' "$MBIN_A")" == "1" ]] \
  && ok_t "MA0b ...the immediate warn is present exactly once" || bad_t "MA0b" ""
[[ "$(grep -c '^      defer_write_note "\$ident: this row already carried' "$MBIN_A")" == "0" ]] \
  && ok_t "MA0c ...and the deferral it replaces is GONE, so the revert is real and not an addition" || bad_t "MA0c" ""
bash -n "$MBIN_A" \
  && ok_t "MA0d ...and the mutant is still valid bash — a working CLI, not a syntax error" || bad_t "MA0d" ""
SDA="$TMP/state-mut-a"; seed "$SDA"
runsd "$MBIN_A" "$SDA" task done DIVE-900 --append-result --result="$NEW"
if (( RC != 0 )) && [[ "$ERR" =~ $KEPT_RE ]]; then
  ok_t "MA1 MUTANT — A3 is RED on it: the refused close claims 'bytes kept above your text'. The defect, live."
else
  bad_t "MA1 mutant must reproduce the defect" "rc=$RC stderr=[${ERR:0:400}]"
fi
[[ "$(res_of "$SDA" DIVE-900)" == "$OLD" ]] \
  && ok_t "MA2 ...over a result the mutant did not write either — which is exactly what made the sentence false" \
  || bad_t "MA2" ""
runsd "$MBIN_A" "$SDA" task done DIVE-901 --result="$NEW"
(( RC == 0 )) && [[ "$ERR" =~ $KEPT_RE ]] \
  && ok_t "MA3 ...while the SUCCEEDING close still says it on the mutant too — so A6 is green on it, and the mutant differs in exactly the refused case" \
  || bad_t "MA3 mutant must keep the success path" "rc=$RC stderr=[${ERR:0:300}]"

# ANCHORED ON ITS OWN COMMENT, not on the bare line: three `mark_reported` calls share this
# indent in the bundle, and an unanchored substitution removed a DIFFERENT verb's — the
# mutant then failed to reproduce the banner and the first run of this file reported MB1 red
# for the wrong reason. A mutant that edits something other than the fix grades nothing.
MBIN_B="$TMP/5dive-mut-b"
anchor='only the false crash report goes.'
[[ "$(grep -c "$anchor" "$BIN")" == "1" ]] \
  && ok_t "MB0 the mutation's anchor is unique in the shipped bundle, so it can only remove THIS call" \
  || bad_t "MB0 anchor must be unique" "hits=$(grep -c "$anchor" "$BIN")"
bdiff=$(mutant "$MBIN_B" 's/(only the false crash report goes\.\n)      mark_reported\n/$1/m')
[[ "$bdiff" == "1" ]] \
  && ok_t "MB0a MUTANT B is the shipped bundle minus that one mark_reported — exactly one line different" \
  || bad_t "MB0a one-line differential" "changed lines=$bdiff"
[[ "$(grep -c '^      mark_reported$' "$MBIN_B")" == "$(( $(grep -c '^      mark_reported$' "$BIN") - 1 ))" ]] \
  && ok_t "MB0b ...one fewer mark_reported than the shipped bundle, and the other two are untouched" \
  || bad_t "MB0b count" "fixed=$(grep -c '^      mark_reported$' "$BIN") mutant=$(grep -c '^      mark_reported$' "$MBIN_B")"
grep -A1 "$anchor" "$MBIN_B" | grep -q 'mark_reported' \
  && bad_t "MB0c the anchor must no longer be followed by mark_reported" "" \
  || ok_t "MB0c ...and the call that followed the anchor is the one that is gone"
bash -n "$MBIN_B" && ok_t "MB0d ...and still valid bash" || bad_t "MB0d" ""
SDB="$TMP/state-mut-b"; seed "$SDB"
runsd "$MBIN_B" "$SDB" task verify DIVE-902 --cmd=false --no-done
if (( RC != 0 )) && [[ "$ERR" =~ $BACKSTOP_RE ]]; then
  ok_t "MB1 MUTANT — B3 is RED on it: the FAIL verdict is reported as an unexplained CLI bug. The defect, live."
else
  bad_t "MB1 mutant must reproduce the banner" "rc=$RC stderr=[${ERR:0:500}]"
fi
[[ "$ERR" == *"verify FAIL (exit 1)"* ]] \
  && ok_t "MB2 ...while the verdict line prints on the mutant too — the banner sat ON TOP of a correct message, not instead of one" \
  || bad_t "MB2" "stderr=[${ERR:0:400}]"

# =============================================================================
# The deferral must not leak: a note is dropped, never carried to another verb.
# =============================================================================
[[ "$(grep -c '_FIVE_WRITE_NOTES=()' "$ROOT/src/task/status.sh")" == "1" ]] \
  && ok_t "C1 the guard CLEARS any note deferred earlier in the same process, so a stale byte count cannot be flushed by a later verb's success" \
  || bad_t "C1 guard must reset the deferral" ""
# C2/C2b PIN THE PLACEMENT, and they exist because iteration 1 of this fix got it wrong.
# Flushing from `ok()` looks like the one clean single point — and `ok` is a two-letter
# name the SUITE ITSELF redefines as a PASS counter. tests/task_result_loss_open_row_unit.sh
# shadows it and then calls cmd_task_done in-process, so the product's `ok` never ran and
# the announcement disappeared from the very harness that exists to pin it (5 arms red).
# A flush point a caller can shadow is not a flush point.
c2_calls=$(grep -n '_five_flush_write_notes' "$ROOT/src/lib/output.sh" \
           | grep -vE ':[[:space:]]*#' | grep -vc '_five_flush_write_notes()')
[[ "$c2_calls" == "0" ]] \
  && ok_t "C2 output.sh DEFINES the flush and calls it nowhere — in particular not from ok(), which the test suite shadows" \
  || bad_t "C2 output.sh must define but not call the flush" "call sites in output.sh=$c2_calls"
awk '/^ok\(\) \{/{i=1} i&&/_five_flush_write_notes/{found=1} i&&/^\}/{i=0} END{exit !found}' "$ROOT/src/lib/output.sh" \
  && bad_t "C2b ok() must not flush — a harness that redefines ok() would silence the announcement" "" \
  || ok_t "C2b ...confirmed by reading ok()'s own body: the flush is not in it"
nsites=$(grep -rc '_five_flush_write_notes' "$ROOT/src/task/" | awk -F: '{n+=$2} END{print n}')
[[ "$nsites" -ge 8 ]] \
  && ok_t "C2c the flush is called at the WRITE SITES instead ($nsites of them), which fire both in-process and in a real process" \
  || bad_t "C2c write-site coverage" "sites=$nsites"
[[ "$(grep -c 'defer_write_note' "$BIN")" -ge 2 ]] \
  && ok_t "C3 ...and both halves are in the SHIPPED bundle, not only in src/" || bad_t "C3 bundle wiring" ""

printf -- '-----\n'
printf 'task_message_before_write: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
