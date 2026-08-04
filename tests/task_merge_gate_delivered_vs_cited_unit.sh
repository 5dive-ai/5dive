#!/usr/bin/env bash
# TIER: nightly — 10.0s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-1965 isolated unit harness — a PR the task DELIVERED vs a PR it REPORTS ON.
#
# The merge-gate's subject was "a PR mentioned in the result/body". That predicate
# cannot tell "I shipped this" from "I am writing about this", and review, triage,
# audit, hygiene and coordination closes cite other tasks' pull requests as a matter
# of course. While off-repo bare refs silently failed to resolve (pre-DIVE-1963) the
# confusion was COSMETIC: a cited PR produced a wrong UNVERIFIED sentence and nothing
# worse. The moment a bare `#N` resolves in the repo it actually lives in, a cited
# OPEN PR lands on the REFUSAL path and every close that mentions another task's open
# PR becomes unclosable without `--force-merge-gate` — a fleet-wide close blocker on
# exactly the task class that cross-references the most. Hence: land this FIRST.
#
# The rule (Marcus's steer): delivery comes from a STRUCTURED, INTENTIONAL signal —
# `delivery_ref`, a `Branch:` line, a `Delivered:` line, or a shipping verb adjacent
# to the reference. Never from "a number appeared in the text". The DEFAULT is CITED.
#
# What is pinned here:
#   1. THE INVARIANT: a close naming its own merged+green delivery AND citing two
#      unrelated OPEN PRs closes cleanly — unrefused AND unstamped;
#   2. a cited OPEN / merged-RED PR does not refuse, a DELIVERED one still does
#      (the DIVE-1922 coverage this must not trade away);
#   3. a cited unresolvable / ambiguous ref does not stamp the record, a delivered
#      one still does — the marker keeps disclosing only THIS task's non-verdicts;
#   4. the `Delivered:` line binds a ref that carries no phrase at all;
#   5. a negated verb ("not merged yet") is not a delivery claim;
#   6. citations are ANNOUNCED (warn + audit row), never silently dropped — that
#      line is the guard on this change's one coverage cost;
#   7. cited refs do not consume the 5-ref cap and crowd out the real delivery;
#   8. a declared delivery_ref means prose citations are never judged at all.
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh is STUBBED on PATH.
# Run: bash tests/task_merge_gate_delivered_vs_cited_unit.sh  (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-delivered-unit.XXXXXX)"

# Repo-aware gh stub, identical in shape to the DIVE-1955 harness: a PR number
# exists in a specific repo, never in the abstract.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'ARGS=%s\n' "$*" >>"$GH_ARGS_LOG"
if [[ "$1" == "auth" && "$2" == "token" ]]; then printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; [[ -n "${GH_STUB_AUTH_TOKEN:-}" ]] || exit 1; exit 0; fi
a=("$@"); expr='.'; repo=""; i=0
while [[ $i -lt ${#a[@]} ]]; do
  case "${a[$i]}" in
    -q)      expr="${a[$((i+1))]}"; i=$((i+2)) ;;
    -q*)     expr="${a[$i]#-q}";    i=$((i+1)) ;;
    --repo)  repo="${a[$((i+1))]}"; i=$((i+2)) ;;
    *)       i=$((i+1)) ;;
  esac
done
rkey() { local k="${1##*/}"; printf '%s' "${k//[^A-Za-z0-9]/_}"; }
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  ref="$3"
  if [[ -z "$repo" && "$ref" == https://github.com/* ]]; then repo=$(printf '%s' "$ref" | cut -d/ -f4,5); fi
  n="${ref##*/}"
  fx="GH_STUB_PR_$(rkey "$repo")_${n}"; json="${!fx:-}"
  [[ -n "$json" ]] || exit 1
  printf '%s' "$json" | jq -r "$expr" 2>/dev/null; exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  ff="GH_STUB_LIST_FAIL_$(rkey "$repo")"; [[ -n "${!ff:-}" ]] && exit 1
  lx="GH_STUB_PRLIST_$(rkey "$repo")"
  printf '%s' "${!lx:-[]}" | jq -r "$expr" 2>/dev/null; exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"
# sudo must be stubbed or the token resolver reaches the HOST's real gh login.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"; chmod +x "$TMP/bin/sudo"
export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh \
         cmd_task.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
# DIVE-2054: "task.merge-gate-ambiguous" / "task.merge-gate-reported-on" are now
# routed through _task_store_audit_log (STORE IDENTITY fence, DIVE-2010) —
# declare this fixture store as prod so the audit-row assertions below keep
# exercising the real path.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
task_need_notify() { :; }
_task_close_notify() { :; }
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
export GH_STUB_AUTH_TOKEN="tok"
export FIVE_GATE_REPOS="5dive-ai/5dive,lodar/5dive-api,lodar/5dive-frontend"

OPEN_X='{"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"title":"unrelated","headRefName":"unrelated"}'
MERGED_OK='{"state":"MERGED","mergedAt":"2026-07-25T02:52:00Z","statusCheckRollup":[{"conclusion":"SUCCESS"}],"title":"unrelated","headRefName":"unrelated"}'
MERGED_RED='{"state":"MERGED","mergedAt":"2026-07-25T02:52:00Z","statusCheckRollup":[{"conclusion":"FAILURE"}],"title":"unrelated","headRefName":"unrelated"}'

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
seed()     { db "DELETE FROM tasks WHERE ident='$1';
                 INSERT INTO tasks (ident, title, body, status, created_by, assignee)
                   VALUES ('$1','t',$(sqlq "${2:-}"),'in_progress','main','main');"; }
statusof() { db "SELECT status FROM tasks WHERE ident='$1';"; }
resultof() { db "SELECT COALESCE(result,'') FROM tasks WHERE ident='$1';"; }
refusals() { db "SELECT COUNT(*) FROM policy_refusals WHERE ident='$1';"; }
run_done() { OUT=$(cmd_task_done "$@" 2>&1); RC=$?; }
clear_fx() { unset "${!GH_STUB_PR_@}" "${!GH_STUB_PRLIST_@}" "${!GH_STUB_LIST_FAIL_@}" 2>/dev/null; }

# --- 1. the classifier itself -------------------------------------------------
# The whole change rests on this predicate, so its vocabulary is pinned by name
# rather than being inferred from the end-to-end cases below.
d_case() { # <name> <expected> <text>
  local got; got=$(_gate_delivery_refs_from_text "$3" | paste -sd, -)
  [[ "$got" == "$2" ]] && ok_t "delivery classifier: $1" \
                       || bad_t "delivery classifier: $1" "want [$2] got [$got]"
}
d_case 'a shipping verb immediately before the ref IS a delivery claim' '|6'   'merged as PR #6'
d_case 'the verb may sit further left in the sentence'                 '|156' 'SHIPPED and VERIFIED on the rolled binary. Merged as PR #156 into v0.15.4.'
d_case 'a pull URL keeps its own owner/repo when claimed'  'lodar/5dive-api|6' 'landed in https://github.com/lodar/5dive-api/pull/6'
d_case 'a `Delivered:` line needs no phrasing at all'    '5dive-ai/5dive|156' 'Delivered: https://github.com/5dive-ai/5dive/pull/156'
d_case 'the predicate may follow the ref'                              '|6'   'PR #6 was merged this morning'
d_case 'first-person possession counts'                                '|6'   'my PR #6 is the delivery'
d_case 'a bare "see <url>" is a CITATION, not a delivery'              ''     'see https://github.com/lodar/5dive-api/pull/6'
d_case 'comparison prose is a CITATION'                                ''     'Same defect class as PR #150, which is merged and green.'
d_case 'a supersede note is a CITATION'                                ''     'Superseded by the rewrite; PR #148 was abandoned.'
d_case 'a bug-report reference is a CITATION'                          ''     'Fixes the crash reported in PR #12.'
d_case 'an audit enumeration is all CITATIONS'                         ''     'Audit: api PR #10 OPEN, api PR #17 OPEN, frontend PR #16 OPEN'
d_case 'a NEGATED verb is not a delivery claim'                        ''     'not merged yet - PR #6'
d_case '"unmerged" must not read as "merged"'                          ''     'unmerged: PR #6'
d_case 'the delivery is picked out of a text that also cites others'   '|168' 'Shipped as PR #168. Blocked work still cites PR #10 and PR #17.'

# --- 2. THE INVARIANT (Marcus, stated before the code existed) ----------------
# "A close whose result names its own merged+green delivery AND cites two unrelated
# OPEN PRs must close cleanly, unstamped and unrefused." Both halves matter: OPEN is
# the refusal path, and an unstamped record is what makes the DIVE-1955 marker mean
# something. This is the exact shape DIVE-1955's own close had.
clear_fx
export GH_STUB_PR_5dive_168="$MERGED_OK"
export GH_STUB_PR_5dive_api_10="$OPEN_X"
export GH_STUB_PR_5dive_api_17="$OPEN_X"
: >"$AUDIT_CALLS"
seed INV-1
run_done INV-1 --result='Shipped as PR #168, merged and green. Follow-ups still open: PR #10 and PR #17 in the api repo.'
if [[ $RC -eq 0 && "$(statusof INV-1)" == "done" && "$(refusals INV-1)" == "0" \
      && "$(resultof INV-1)" != *UNVERIFIED* ]]; then
  ok_t 'INVARIANT: own merged+green delivery + two cited OPEN PRs closes clean, unstamped, unrefused'
else
  bad_t 'the DIVE-1965 invariant' "rc=$RC status=$(statusof INV-1) refusals=$(refusals INV-1) result=[$(resultof INV-1)]"
fi
grep -q 'task.merge-gate-reported-on' "$AUDIT_CALLS" \
  && ok_t 'the set-aside citations are audited, so a mis-read delivery is findable' \
  || bad_t 'reported-on audit row' "$(cat "$AUDIT_CALLS")"

# --- DIVE-2062: OFF the prod store, the SAME reported-on row writes NO row ----
# The case above only ever ran ON the prod store (FIVEDIVE_PROD_TASKS_DB was
# declared at the top of this file and never unset) — per the DIVE-2054
# verifier pass (dev3, 2026-07-26) this suite reached the site but only ever on
# its ALLOWED side. This proves the WITHHELD side too, and that it is announced.
unset _TASK_STORE_AUDIT_FENCED
clear_fx
export GH_STUB_PR_5dive_168="$MERGED_OK"
export GH_STUB_PR_5dive_api_10="$OPEN_X"
export GH_STUB_PR_5dive_api_17="$OPEN_X"
: >"$AUDIT_CALLS"
seed INVOFF-1
out=$(FIVEDIVE_PROD_TASKS_DB="$TMP/somewhere-else/tasks.db" cmd_task_done INVOFF-1 \
  --result='Shipped as PR #168, merged and green. Follow-ups still open: PR #10 and PR #17 in the api repo.' \
  2>"$TMP/offstore.err"); rc=$?
[[ $rc -eq 0 && "$(statusof INVOFF-1)" == "done" ]] \
  && ok_t 'off-store: the close itself still proceeds (fail-open on the WRITE side)' \
  || bad_t 'off-store close still proceeds' "rc=$rc status=$(statusof INVOFF-1)"
[[ ! -s "$AUDIT_CALLS" ]] \
  && ok_t 'off the prod store, task.merge-gate-reported-on writes NO audit row' \
  || bad_t 'off-store must not audit' "$(cat "$AUDIT_CALLS")"
grep -q "telemetry withheld" "$TMP/offstore.err" \
  && ok_t 'the withholding is ANNOUNCED, not silent' \
  || bad_t 'fence must announce' "err=$(cat "$TMP/offstore.err")"
unset _TASK_STORE_AUDIT_FENCED

# --- 3. a cited OPEN PR alone does not block the close ------------------------
# The fleet-wide close blocker this ticket exists to prevent: a pure triage/audit
# close that enumerates other tasks' open PRs and delivers nothing of its own.
clear_fx; export GH_STUB_PR_5dive_api_10="$OPEN_X"
seed CITE-1
run_done CITE-1 --result='Triage: DIVE-1809 is still waiting on PR #10 in the api repo. No code from me.'
if [[ $RC -eq 0 && "$(statusof CITE-1)" == "done" && "$(refusals CITE-1)" == "0" \
      && "$(resultof CITE-1)" != *UNVERIFIED* && "$OUT" == *CITED* ]]; then
  ok_t 'a triage close citing an OPEN PR it did not ship closes, and says so out loud'
else
  bad_t 'cited OPEN must not refuse' "rc=$RC status=$(statusof CITE-1) refusals=$(refusals CITE-1) out=$OUT"
fi

# --- 4. ...but a DELIVERED open PR still refuses (DIVE-1922 does not regress) --
clear_fx; export GH_STUB_PR_5dive_api_10="$OPEN_X"
seed DEL-1
run_done DEL-1 --result='merged as PR #10'
[[ $RC -ne 0 && "$(statusof DEL-1)" == "in_progress" && "$OUT" == *"#10"*OPEN* ]] \
  && ok_t 'the SAME open PR, claimed as the delivery, still refuses the close' \
  || bad_t 'delivered OPEN must refuse' "rc=$RC status=$(statusof DEL-1) out=$OUT"

# --- 5. the same split on the merged-but-RED path -----------------------------
clear_fx; export GH_STUB_PR_5dive_api_12="$MERGED_RED"
seed REDC-1
run_done REDC-1 --result='Post-mortem of the smoke failure in PR #12 (another task delivered it).'
[[ $RC -eq 0 && "$(statusof REDC-1)" == "done" ]] \
  && ok_t 'a post-mortem CITING a merged-RED PR closes — it is not this task to answer for' \
  || bad_t 'cited merged-red must not refuse' "rc=$RC status=$(statusof REDC-1) out=$OUT"
seed REDD-1
run_done REDD-1 --result='landed in PR #12'
[[ $RC -ne 0 && "$(statusof REDD-1)" == "in_progress" && "$OUT" == *"#12"*RED* ]] \
  && ok_t 'the same merged-RED PR, claimed as the delivery, still refuses' \
  || bad_t 'delivered merged-red must refuse' "rc=$RC status=$(statusof REDD-1) out=$OUT"

# --- 6. the UNVERIFIED stamp keeps disclosing only THIS task's non-verdicts ----
# An unresolvable ref is a real non-verdict when it is the delivery, and no question
# at all when it is a citation. Same input, different claim.
clear_fx
seed UNRESC-1
run_done UNRESC-1 --result='Fixes the crash reported in PR #12.'
if [[ $RC -eq 0 && "$(resultof UNRESC-1)" == 'Fixes the crash reported in PR #12.' ]]; then
  ok_t 'an unresolvable CITATION leaves the record pristine — nothing was claimed about it'
else
  bad_t 'cited unresolvable must not stamp' "rc=$RC result=[$(resultof UNRESC-1)]"
fi
seed UNRESD-1
run_done UNRESD-1 --result='landed in PR #12'
[[ $RC -eq 0 && "$(resultof UNRESD-1)" == *"merge-gate: UNVERIFIED"* ]] \
  && ok_t 'an unresolvable DELIVERY still stamps the record UNVERIFIED (DIVE-1955 intact)' \
  || bad_t 'delivered unresolvable must stamp' "rc=$RC result=[$(resultof UNRESD-1)]"

# --- 7. ...and the same split for AMBIGUOUS ----------------------------------
clear_fx
export GH_STUB_PR_5dive_6="$MERGED_OK"
export GH_STUB_PR_5dive_api_6="$OPEN_X"
: >"$AUDIT_CALLS"
seed AMBC-1
run_done AMBC-1 --result='Related prior art: PR #6.'
if [[ $RC -eq 0 && "$(resultof AMBC-1)" != *UNVERIFIED* ]] \
   && ! grep -q 'task.merge-gate-ambiguous' "$AUDIT_CALLS"; then
  ok_t 'a colliding bare #N that is only CITED is not resolved, not audited ambiguous, not stamped'
else
  bad_t 'cited ambiguous' "rc=$RC result=[$(resultof AMBC-1)] audit=$(cat "$AUDIT_CALLS")"
fi
: >"$AUDIT_CALLS"
seed AMBD-1
run_done AMBD-1 --result='merged as PR #6'
grep -q 'task.merge-gate-ambiguous' "$AUDIT_CALLS" && [[ "$(resultof AMBD-1)" == *AMBIGUOUS* ]] \
  && ok_t 'the same collision, claimed as the delivery, is still AMBIGUOUS + audited + stamped' \
  || bad_t 'delivered ambiguous' "result=[$(resultof AMBD-1)] audit=$(cat "$AUDIT_CALLS")"

# --- 8. the `Delivered:` line is the structured escape ------------------------
# The maker's way out when the phrasing heuristic would read their delivery as prose:
# a declaration, not a turn of phrase. Sibling of `Branch:` (DIVE-1462) and `Repo:`
# (DIVE-1955), and the reason the fallback is not heuristic-only.
clear_fx; export GH_STUB_PR_5dive_api_10="$OPEN_X"
seed ESCAPE-1 'Delivered: https://github.com/lodar/5dive-api/pull/10'
run_done ESCAPE-1 --result='all wrapped up'
[[ $RC -ne 0 && "$OUT" == *"#10"*OPEN* ]] \
  && ok_t 'a `Delivered:` body line binds a ref that carries no shipping phrase at all' \
  || bad_t 'Delivered: line' "rc=$RC out=$OUT"

# --- 9. negation is not a delivery claim --------------------------------------
clear_fx; export GH_STUB_PR_5dive_api_10="$OPEN_X"
seed NEG-1
run_done NEG-1 --result='Handing off: PR #10 is not merged yet, dev3 owns it now.'
[[ $RC -eq 0 && "$(statusof NEG-1)" == "done" ]] \
  && ok_t 'a handoff note saying a PR is NOT merged does not read as shipping it' \
  || bad_t 'negated verb' "rc=$RC status=$(statusof NEG-1) out=$OUT"

# --- 10. citations do not consume the 5-ref cap -------------------------------
# A silent cap that let five cited PRs crowd out the real delivery would turn this
# change into a coverage hole, not a fix. The delivery is named LAST on purpose.
clear_fx
export GH_STUB_PR_5dive_api_10="$OPEN_X"; export GH_STUB_PR_5dive_api_17="$OPEN_X"
export GH_STUB_PR_5dive_frontend_16="$OPEN_X"; export GH_STUB_PR_5dive_20="$OPEN_X"
export GH_STUB_PR_5dive_21="$OPEN_X";          export GH_STUB_PR_5dive_22="$OPEN_X"
seed CAP-1
run_done CAP-1 --result='Sweep: PR #10, PR #17, PR #16, PR #20, PR #21 all still open. My own work: merged as PR #22.'
[[ $RC -ne 0 && "$OUT" == *"#22"* ]] \
  && ok_t 'five citations do not crowd the delivery out of the 5-ref budget' \
  || bad_t 'cap must count judged refs only' "rc=$RC out=$OUT"

# --- 11. a declared delivery_ref means prose citations are never judged -------
# The strongest binding short-circuits the text gate entirely; pinned so a future
# refactor cannot quietly route declared closes back through the prose scan.
clear_fx
export GH_STUB_PR_5dive_168="$MERGED_OK"; export GH_STUB_PR_5dive_api_10="$OPEN_X"
seed DREF-1
db "UPDATE tasks SET delivery_ref='https://github.com/5dive-ai/5dive/pull/168' WHERE ident='DREF-1';"
run_done DREF-1 --result='Also reviewed PR #10, still open.'
[[ $RC -eq 0 && "$(statusof DREF-1)" == "done" && "$(refusals DREF-1)" == "0" ]] \
  && ok_t 'a declared delivery_ref closes over a cited OPEN PR without consulting the prose' \
  || bad_t 'declared path must ignore citations' "rc=$RC status=$(statusof DREF-1) out=$OUT"

# --- 12. DIVE-1975: the OTHER consumer of the same predicate -----------------
# `task merge-audit` reads delivery_ref + result + body exactly like the gate above,
# but it BLOCKS NOTHING — a human reads it. So the safe default inverts: the gate
# skips what it cannot bind to this task, the sweep must still PRINT it and merely
# label it. A filter here would rebuild the DIVE-1955 blindness one layer down and
# harder to see, because the sweep would come back clean while the work it exists to
# find sat unmerged behind a maker's phrasing.
#
# Every arm below is DIFFERENTIAL — the same PR number, in the same repo, resolved
# by the same stub — so a hardcoded label (either one) fails at least one of them.
# The audit scans the whole store, so the earlier arms' rows are cleared first and
# only these five exist while it runs.
clear_fx
db "DELETE FROM tasks;"
export GH_STUB_PR_5dive_api_10="$OPEN_X"
export GH_STUB_PR_5dive_168="$MERGED_OK"
seed_done() { # <ident> <result> [delivery_ref]
  db "DELETE FROM tasks WHERE ident='$1';
      INSERT INTO tasks (ident, title, body, result, delivery_ref, status, created_by, assignee, done_at)
        VALUES ('$1','t','',$(sqlq "$2"),$(sqlq_or_null "${3:-}"),'done','main','main',datetime('now'));"
}
audit_line() { printf '%s\n' "$AUD_OUT" | grep -E "^$1[[:space:]]"; }

seed_done AUD-CITE  'Fixes the crash reported in https://github.com/lodar/5dive-api/pull/10.'
seed_done AUD-SHIP  'Shipped as https://github.com/lodar/5dive-api/pull/10.'
seed_done AUD-COL   'Closed out the follow-ups.' 'https://github.com/lodar/5dive-api/pull/10'
seed_done AUD-PLAIN 'Closed out the follow-ups. https://github.com/lodar/5dive-api/pull/10'
seed_done AUD-GREEN 'Merged as https://github.com/5dive-ai/5dive/pull/168.'
AUD_OUT=$(cmd_task_merge_audit --limit=50 2>&1); AUD_RC=$?

# THE LOAD-BEARING HALF: a citation of another task's OPEN PR is REPORTED, not
# dropped — and it is not reported as this task's own unmerged work either.
if [[ "$(audit_line AUD-CITE)" == *"#10"*"OPEN"*"cited"* ]]; then
  ok_t 'merge-audit: a cited OPEN PR is REPORTED and labelled `cited` — never filtered out'
else
  bad_t 'a cited ref must still appear in the sweep' "rc=$AUD_RC line=[$(audit_line AUD-CITE)]"
fi
# ...and the same ref, same repo, same stub, asserted as a delivery, labels the
# other way. This pair is what makes the arm above mean something.
if [[ "$(audit_line AUD-SHIP)" == *"#10"*"OPEN"*"delivered"* ]]; then
  ok_t 'merge-audit: the same PR asserted with a shipping verb labels `delivered`'
else
  bad_t 'an asserted delivery must label delivered' "line=[$(audit_line AUD-SHIP)]"
fi
# The delivery_ref COLUMN never reaches the gate's prose classifier (a declared ref
# routes to the declared gate), but it is the strongest delivery assertion we have
# and it IS part of this row's text. AUD-COL and AUD-PLAIN carry byte-identical
# prose and differ ONLY in the column, so this cannot pass on the phrasing.
if [[ "$(audit_line AUD-COL)" == *delivered* && "$(audit_line AUD-PLAIN)" == *cited* ]]; then
  ok_t 'merge-audit: a bound delivery_ref labels `delivered` where identical prose alone labels `cited`'
else
  bad_t 'the delivery_ref column must fold into the delivered set' \
        "col=[$(audit_line AUD-COL)] plain=[$(audit_line AUD-PLAIN)]"
fi
# Labelling must not change WHAT is reported: a merged+green ref is still no finding.
[[ -z "$(audit_line AUD-GREEN)" ]] \
  && ok_t 'merge-audit: labelling did not turn a merged+green delivery into a finding' \
  || bad_t 'merged+green must stay silent' "line=[$(audit_line AUD-GREEN)]"
# The summary counts both populations, so "4 findings" cannot hide a 3/1 split.
[[ "$AUD_OUT" == *"2 delivered by the task, 2 only cited"* ]] \
  && ok_t 'merge-audit: the summary line reports the delivered/cited split' \
  || bad_t 'summary must carry both counts' "out=$AUD_OUT"
# A `cited` label that reads as "already dismissed" is the filter we refused to
# write, executed by the reader. The note has to say it is a label.
[[ "$AUD_OUT" == *"It is a LABEL, not a"*filter* ]] \
  && ok_t 'merge-audit: the note tells the reader `cited` is a label and not a filter' \
  || bad_t 'the label must be announced as a label' "out=$AUD_OUT"

# --json carries the same split, per row and in the totals — the dashboard and any
# scripted consumer read this, not the columns.
JSON_MODE=0
AUD_JSON=$(cmd_task_merge_audit --limit=50 --json 2>/dev/null); JSON_MODE=0
j() { printf '%s' "$AUD_JSON" | jq -r ".data|$1" 2>/dev/null; }
[[ "$(j '.rows[]|select(.ident=="AUD-CITE").origin')" == "cited" \
&& "$(j '.rows[]|select(.ident=="AUD-SHIP").origin')" == "delivered" \
&& "$(j '.rows[]|select(.ident=="AUD-COL").origin')"  == "delivered" ]] \
  && ok_t 'merge-audit --json: every row carries its own `origin`' \
  || bad_t '--json rows must carry origin' "json=$AUD_JSON"
[[ "$(j '.delivered')" == "2" && "$(j '.cited')" == "2" && "$(j '.findings')" == "4" ]] \
  && ok_t 'merge-audit --json: delivered + cited are totalled and sum to findings' \
  || bad_t '--json totals must carry the split' "json=$AUD_JSON"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
