#!/usr/bin/env bash
# TIER: core — 13.1s measured (DIVE-4619, agent-dev seat): fits the 300s PR core.
# Isolated unit harness; no root, no network.
# DIVE-4619 — A STANDING CONDITION IS SAID ONCE, ON `doctor`, NOT ON EVERY CLOSE.
#
# The DIVE-1935/1955 repo scan stamps and audits every close it could not verify,
# and that is right. What it also did was print the same four-sentence warning on
# every close, and on a box whose credential cannot see part of the repo set that
# sentence does not change: luca's box measured 45 of 57 closes over three days
# carrying an identical `partial-repo-scan-6-of-11`, so the one close that needed
# a second look was indistinguishable from the 44 that did not.
#
# What this grades, and it is deliberately both halves:
#   A. the DURABLE record does not get thinner — N closes still produce N audit
#      rows and N UNVERIFIED stamps, and no close goes silent;
#   B. the human-facing text collapses — the full explanation once, a one-line
#      pointer after, and an immediate re-announce when anything about the
#      condition changes.
#
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh and sudo are STUBBED.
# Run: bash tests/task_merge_gate_standing_notice_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# Must sit AFTER grading_tree.sh: lib/env_isolation.sh clears inherited FIVE_*
# knobs, so an export above it is wiped and the harness reaches the real network.
export FIVE_GATE_NO_ANON=1
# Three repos, not eleven: the arms below assert counts and a `0-of-N` label, and
# a fixture that hardcodes the production list would drift the day a repo is added.
export FIVE_GATE_REPOS="5dive-ai/5dive lodar/5dive-api lodar/5dive-frontend"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-standing-notice-unit.XXXXXX)"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/sudo" <<'SUDOSTUB'
#!/usr/bin/env bash
exit 1
SUDOSTUB
chmod +x "$TMP/bin/sudo"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "token" ]]; then printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; exit 0; fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  # A repo named in GH_STUB_BLIND declines with gh's own words; everything else
  # answers an empty listing (a scan that RAN and found nothing).
  repo=""; prev=""
  for a in "$@"; do
    [[ "$prev" == "--repo" ]] && { repo="$a"; break; }
    [[ "$a" == --repo=* ]] && { repo="${a#--repo=}"; break; }
    prev="$a"
  done
  if [[ -n "${GH_STUB_BLIND:-}" && " ${GH_STUB_BLIND} " == *" ${repo} "* ]]; then
    printf '%s\n' "${GH_STUB_BLIND_ERR:-GraphQL: Could not resolve to a Repository with the name '${repo}'.}" >&2
    exit 1
  fi
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh \
         cmd_task.sh cmd_doctor.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
task_need_notify() { :; }
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
export GH_STUB_AUTH_TOKEN="tok"

seed()     { db "INSERT INTO tasks (ident, title, status, created_by, assignee)
                   VALUES ('$1','t','in_progress','main','main');"; }
statusof() { db "SELECT status FROM tasks WHERE ident='$1';"; }
resultof() { db "SELECT COALESCE(result,'') FROM tasks WHERE ident='$1';"; }
# The result NAMES a PR on purpose: the DIVE-1955 stamp is gated on the close
# having a SUBJECT to verify (`_mg_had_subject`), so a close that named nothing is
# the one shape that cannot show the stamp half of this harness. `#99` resolves
# nowhere against the stub, which is the unverified-but-not-blocking state.
close_it() { cmd_task_done "$1" --no-pr --result="close under test, reporting on PR #99 (DIVE-2773: a first close must carry a reason)" 2>&1; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# =============================================================================
# T1 — THE MEASUREMENT FROM THE REPORT, REPRODUCED: ten closes on a box whose
# credential cannot see one of three repos.
# =============================================================================
export GH_STUB_BLIND="lodar/5dive-frontend"
: >"$AUDIT_CALLS"
FULL=0; SHORT=0; STAMPS=0
for i in $(seq 1 10); do
  seed "DIVE-46${i}0"
  OUT=$(close_it "DIVE-46${i}0")
  [[ "$OUT" == *"this close is UNVERIFIED, not verified-clean"* ]] && FULL=$((FULL+1))
  [[ "$OUT" == *"standing condition on this box, unchanged since the notice above"* ]] && SHORT=$((SHORT+1))
  [[ "$(resultof "DIVE-46${i}0")" == *"merge-gate: UNVERIFIED"* ]] && STAMPS=$((STAMPS+1))
done
ROWS=$(grep -c 'merge-gate-unverified' "$AUDIT_CALLS")

(( STAMPS == 10 )) \
  && ok_t "T1a the DURABLE record is unchanged: 10 closes -> 10 UNVERIFIED stamps on the rows" \
  || bad_t "T1a stamps per close" "stamps=$STAMPS"
(( ROWS == 10 )) \
  && ok_t "T1b 10 closes -> 10 audit rows (the throttle must never reach the audit rail)" \
  || bad_t "T1b audit rows per close" "rows=$ROWS calls=$(head -3 "$AUDIT_CALLS")"
(( FULL == 1 )) \
  && ok_t "T1c the four-sentence explanation is printed ONCE, not 10 times" \
  || bad_t "T1c full warning count" "full=$FULL"
(( SHORT == 9 )) \
  && ok_t "T1d the other 9 closes collapse to the one-line pointer" \
  || bad_t "T1d collapsed line count" "short=$SHORT"
# DIVE-1935's rule, and the thing a naive throttle breaks: an unverified close is
# audited, "never a silent one". Every close must still SAY unverified somewhere a
# person reading the terminal sees it.
seed DIVE-4699
OUT=$(close_it DIVE-4699)
[[ "$OUT" == *"UNVERIFIED"* ]] \
  && ok_t "T1e no close goes SILENT — a collapsed close still says UNVERIFIED on the terminal" \
  || bad_t "T1e collapsed close must not be silent" "out=$OUT"

# =============================================================================
# T2 — THE CONDITION CHANGING RE-ANNOUNCES IN FULL. A throttle that keys on too
# little is worse than none: it silences the report that differs.
# =============================================================================
export GH_STUB_BLIND="lodar/5dive-frontend lodar/5dive-api"   # 1 of 3 now, not 2 of 3
seed DIVE-4701
OUT=$(close_it DIVE-4701)
{ [[ "$OUT" == *"this close is UNVERIFIED, not verified-clean"* ]] && [[ "$OUT" == *"partial-repo-scan-1-of-3"* ]]; } \
  && ok_t "T2a coverage CHANGING (2-of-3 -> 1-of-3) re-announces in full immediately" \
  || bad_t "T2a coverage change re-announces" "out=$OUT"
seed DIVE-4702
OUT=$(close_it DIVE-4702)
[[ "$OUT" != *"this close is UNVERIFIED, not verified-clean"* ]] \
  && ok_t "T2b ...and the NEXT close at the new coverage collapses again" \
  || bad_t "T2b re-collapse after re-announce" "out=$OUT"

# =============================================================================
# T3 — THREE SITUATIONS, THREE SENTENCES. `partial-repo-scan-K-of-N` conflated a
# credential that sees some repos, one that sees none, and a scan that misread a
# rail that works. Each is a different person's to fix.
# =============================================================================
cls() { _gate_scan_class "$1" "${2:-}"; }
[[ "$(cls partial-repo-scan-6-of-11 "GraphQL: Could not resolve to a Repository")" == "credential-partial" ]] \
  && ok_t "T3a K-of-N with K>0 is credential-partial (the credential is short some repos)" \
  || bad_t "T3a K-of-N class" "got=$(cls partial-repo-scan-6-of-11 x)"
[[ "$(cls partial-repo-scan-0-of-11 "GraphQL: Could not resolve to a Repository with the name 'lodar/5dive-api'.")" == "credential-blind" ]] \
  && ok_t "T3b 0-of-N whose repos say they cannot be SEEN is credential-blind" \
  || bad_t "T3b 0-of-N blind class" "got=$(cls partial-repo-scan-0-of-11 'Could not resolve to a Repository')"
[[ "$(cls partial-repo-scan-0-of-11 "")" == "scan-silent" ]] \
  && ok_t "T3c 0-of-N with a rail held and NO reason from any repo is scan-silent (ours, not the operator's)" \
  || bad_t "T3c 0-of-N silent class" "got=$(cls partial-repo-scan-0-of-11 '')"
# The distinction that would be lost by a looser matcher: a rate limit carries
# HTTP 403 and is NOT a statement that the repository cannot be seen.
[[ "$(cls partial-repo-scan-0-of-11 "HTTP 403: API rate limit exceeded for user ID 4242")" == "scan-failed" ]] \
  && ok_t "T3d a rate limit is scan-failed, NOT a credential verdict (403 is not invisibility)" \
  || bad_t "T3d rate limit misclassified" "got=$(cls partial-repo-scan-0-of-11 'HTTP 403: API rate limit exceeded')"
[[ "$(cls no-gh-token "")" == "no-rail" && "$(cls query-failed "")" == "unreachable" ]] \
  && ok_t "T3e no-rail and unreachable keep their own classes (the pre-existing labels are not relabelled)" \
  || bad_t "T3e no-rail/unreachable classes" "no-gh-token=$(cls no-gh-token '') query-failed=$(cls query-failed '')"
# Every class must have a sentence; an unlabelled class renders as a blank in the
# warning, which is how a reader learns to skip it.
MISSING=""
for c in no-rail unreachable credential-partial credential-blind scan-failed scan-silent; do
  [[ -n "$(_gate_scan_class_says "$c")" ]] || MISSING="$MISSING $c"
done
[[ -z "$MISSING" ]] \
  && ok_t "T3f every class carries a plain-English sentence saying whose problem it is" \
  || bad_t "T3f classes without a sentence" "missing=$MISSING"

# =============================================================================
# T4 — THE AUDIT ROW CARRIES THE CLASS AND THE INVISIBLE REPOS. The count alone
# tells a later triage that a credential was short and nothing about what to grant.
# =============================================================================
grep -q 'class=credential-partial' "$AUDIT_CALLS" \
  && ok_t "T4a the audit row names the CLASS, not just the count" \
  || bad_t "T4a audit row class" "calls=$(grep -m1 merge-gate-unverified "$AUDIT_CALLS")"
grep -q 'invisible=lodar/5dive-frontend' "$AUDIT_CALLS" \
  && ok_t "T4b the audit row names WHICH repos declined" \
  || bad_t "T4b audit row invisible list" "calls=$(grep -m1 merge-gate-unverified "$AUDIT_CALLS")"

# =============================================================================
# T5 — `doctor` CARRIES IT ONCE, WITH THE REPOS AND THE CREDENTIAL.
# =============================================================================
DOCTOR_CHECKS='[]'; DOCTOR_REPAIR=0
doctor_check_gate_repo_visibility >/dev/null 2>&1
VIS=$(jq -r '[.[] | select(.name|startswith("merge-gate-repos"))]' <<<"$DOCTOR_CHECKS")
[[ "$(jq -r 'length' <<<"$VIS")" == "1" ]] \
  && ok_t "T5a doctor reports the condition ONCE for this seat, not once per close" \
  || bad_t "T5a doctor finding count" "vis=$VIS"
MSG=$(jq -r '.[0].message // ""' <<<"$VIS")
{ [[ "$(jq -r '.[0].severity' <<<"$VIS")" == "warn" ]] && [[ "$MSG" == *"lodar/5dive-frontend"* ]] \
  && [[ "$MSG" == *"1 of 3"* ]] && [[ "$MSG" == *"Instrument:"* ]]; } \
  && ok_t "T5b the finding names the invisible repos, the coverage and the credential it used" \
  || bad_t "T5b doctor finding content" "sev=$(jq -r '.[0].severity' <<<"$VIS") msg=$MSG"
[[ "$(jq -r '.[0].category' <<<"$VIS")" == "creds" ]] \
  && ok_t "T5c it is filed under creds, where a credential fact about the box belongs" \
  || bad_t "T5c doctor category" "vis=$VIS"

# T5d — AN ABSENT MEASUREMENT AND A MEASURED PASS MUST NOT READ THE SAME.
SAVED_TASKS_DIR="$TASKS_DIR"; TASKS_DIR="$TMP/no-such-dir"
DOCTOR_CHECKS='[]'
doctor_check_gate_repo_visibility >/dev/null 2>&1
{ [[ "$(jq -r '.[0].severity' <<<"$DOCTOR_CHECKS")" == "ok" ]] \
  && [[ "$(jq -r '.[0].message' <<<"$DOCTOR_CHECKS")" == *"not measured"* ]]; } \
  && ok_t "T5d a box with no reading reports 'not measured', never a clean bill" \
  || bad_t "T5d unmeasured box" "checks=$DOCTOR_CHECKS"
TASKS_DIR="$SAVED_TASKS_DIR"

# T5e — a scan that answered on EVERY repo clears the finding. A standing warning
# that cannot go back to ok is a warning people learn to ignore.
unset GH_STUB_BLIND
seed DIVE-4710
close_it DIVE-4710 >/dev/null 2>&1
DOCTOR_CHECKS='[]'
doctor_check_gate_repo_visibility >/dev/null 2>&1
{ [[ "$(jq -r '.[0].severity' <<<"$DOCTOR_CHECKS")" == "ok" ]] \
  && [[ "$(jq -r '.[0].message' <<<"$DOCTOR_CHECKS")" == *"all 3 configured repos"* ]]; } \
  && ok_t "T5e a full clean sweep clears the standing finding back to ok" \
  || bad_t "T5e clean sweep clears" "checks=$DOCTOR_CHECKS"

# =============================================================================
# T6 — CONTROL: the collapse is a THROTTLE, not a deletion. With the TTL at 0
# every close prints the full explanation again, which is the arm that would stay
# green if the warning had simply been removed... and T1c is the one that would
# not. The pair is what distinguishes "collapsed" from "gone".
# =============================================================================
export GH_STUB_BLIND="lodar/5dive-frontend"
FULL2=0
for i in 1 2 3; do
  seed "DIVE-472${i}"
  OUT=$(FIVE_GATE_NOTICE_TTL=0 close_it "DIVE-472${i}")
  [[ "$OUT" == *"this close is UNVERIFIED, not verified-clean"* ]] && FULL2=$((FULL2+1))
done
(( FULL2 == 3 )) \
  && ok_t "T6 control: FIVE_GATE_NOTICE_TTL=0 restores a full warning on every close (the text is throttled, not deleted)" \
  || bad_t "T6 TTL=0 control" "full=$FULL2"

# =============================================================================
# T7 — FAILS OPEN. A throttle that can silence the gate by breaking is a worse
# instrument than no throttle: an unwritable state dir prints every time.
# =============================================================================
SAVED_TASKS_DIR="$TASKS_DIR"; TASKS_DIR="/proc/nonexistent-5dive-4619"
DUE1=0; DUE2=0
_gate_notice_due "probe|same-key" && DUE1=1
_gate_notice_due "probe|same-key" && DUE2=1
TASKS_DIR="$SAVED_TASKS_DIR"
(( DUE1 == 1 && DUE2 == 1 )) \
  && ok_t "T7 an unwritable state dir prints the notice EVERY time (fails open, to the loud side)" \
  || bad_t "T7 throttle must fail open" "due1=$DUE1 due2=$DUE2"
# ...and the positive control for T7, so "always due" is not what the helper does
# everywhere: with a writable dir the second identical call is NOT due.
DUE3=0; DUE4=0
_gate_notice_due "probe|writable-key" && DUE3=1
_gate_notice_due "probe|writable-key" && DUE4=1
(( DUE3 == 1 && DUE4 == 0 )) \
  && ok_t "T7 positive control: with a writable dir the second identical notice is suppressed" \
  || bad_t "T7 positive control" "due3=$DUE3 due4=$DUE4"

echo "-----"
printf 'task_merge_gate_standing_notice_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
