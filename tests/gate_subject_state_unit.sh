#!/usr/bin/env bash
# DIVE-2414 — the subject-state reader, and the two directions it is pointed.
#
# WHAT THIS GRADES, and why the arms are shaped this way. The defect is not a
# missing feature, it is WRONG EVIDENCE: a gate was flagged "likely shipped,
# verify+close" because a commit naming its ROW landed, while its live human ask
# was about a different item (DIVE-2382). So the arms that matter are the ones
# that were ALREADY PASSING before the change — the withholds. An arm that only
# proves "a merged subject flags" signs off on a wider nudge, not a narrower one.
#
#   E1-E8  the subject EXTRACTOR: intentional signal accepted, mention rejected.
#          E3 is DIVE-2382's own ask, verbatim in shape: it cites a PR it is not
#          about, and a mention-predicate retires a live approval on it.
#   R1-R6  the READER: every gh state mapped, and NO git call on any path.
#   V1-V5  the verdict roll-up precedence (OPEN > UNKNOWN > MERGED).
#   H1-H4  direction (a), the heartbeat gate sweep: open subject VETOES a
#          row-commit flag; merged subject flags on subject evidence; a
#          no-subject gate keeps DIVE-1140 behaviour and names its evidence class.
#   C1-C3  direction (b), the cited-not-delivered gap: state READ and reported,
#          never refused, cap announced.
#
# Fixtures use reserved fakes only (CLAUDE.md): fake idents DIVE-9001/9002, fake
# slug example/repo. Runs on a throwaway tasks.db, stubs gh/git/send. No network.
# Run: bash tests/gate_subject_state_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/gate-subject.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_agent.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
set +e
tasks_db_init

PASS=0; FAIL=0
ok_()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad_()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
is()    { [[ "$2" == "$3" ]] && ok_ "$1" || bad_ "$1" "want [$3] got [$2]"; }
has()   { [[ "$2" == *"$3"* ]] && ok_ "$1" || bad_ "$1" "want substring [$3] in [$2]"; }
hasnt() { [[ "$2" != *"$3"* ]] && ok_ "$1" || bad_ "$1" "did NOT want [$3] in [$2]"; }

# --- stubs -------------------------------------------------------------------
# GIT TRIPWIRE. The whole point of the reader is that it reads the SUBJECT, never
# the row's commit stream — so `git` is not merely unused here, it is an ERROR to
# call. Any invocation lands in this file and the arms assert it is empty.
GIT_CALLS="$TMP/git-calls"; : >"$GIT_CALLS"
git() { printf 'git %s\n' "$*" >>"$GIT_CALLS"; return 1; }

# gh stub: state comes from a per-PR table the arms write. `gh pr view --json ...`
# is called through _gate_pr_state, which asks for state,mergedAt,rollup joined
# by "|" — we answer in that shape.
GH_TABLE="$TMP/gh-table"; : >"$GH_TABLE"        # lines: <slug>|<n>|<state>|<rollup>
gh_set() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-SUCCESS}" >>"$GH_TABLE"; }
GH_CALLS="$TMP/gh-calls"; : >"$GH_CALLS"
gh() {
  printf 'gh %s\n' "$*" >>"$GH_CALLS"
  local n="" slug="" want_view=0 a
  for a in "$@"; do
    case "$a" in
      view) want_view=1 ;;
      --repo) slug="NEXT" ;;
      *) if [[ "$slug" == "NEXT" ]]; then slug="$a"
         elif [[ "$want_view" == 1 && -z "$n" && "$a" =~ ^[0-9]+$ ]]; then n="$a"; fi ;;
    esac
  done
  local row; row=$(grep -F "${slug}|${n}|" "$GH_TABLE" | head -1)
  [[ -n "$row" ]] || return 1
  local st="${row#*|*|}"; st="${st%%|*}"
  local roll="${row##*|}"
  local merged="null"; [[ "$st" == "MERGED" ]] && merged="2026-07-30T00:00:00Z"
  printf '%s|%s|%s\n' "$st" "$merged" "$roll"
}
timeout() { shift; "$@"; }   # strip the timeout wrapper, run the stub
# CREDENTIAL STUB (DIVE-2530). The gh COMMAND above is stubbed; the CREDENTIAL was
# not, and that is a different thing. `_gate_subject_verdict` takes the token as a
# PARAMETER, so the V arms below are deterministic — they pass `tok` or `''` by hand.
# The H arms do not: they go through `_hb_gate_shipped_sweep`, which resolves the
# token itself via `_gate_gh_token`. That made them read whatever credential the
# HOST happened to have.
# MEASURED 2026-07-31 (CI job 91163957248): identical commit, identical command,
# 34/0 on the control-plane host and 30/4 on the pristine runner, every failure
# carrying `subject=no-gh-token`. cmd_task.sh short-circuits on an empty token
# BEFORE gh is called, so the stub above was never reached and the H2 family could
# not arrive at the state it asserts. A harness that reads an ambient credential is
# measuring the environment, not the subject (DIVE-1919).
# Non-empty on purpose, and the same literal the V arms pass, so both halves of the
# file agree about what "has a token" means. The no-token path keeps its own
# coverage at V5, where the empty value is passed EXPLICITLY rather than inherited.
_gate_gh_token() { printf 'tok'; }
command() { builtin command "$@"; }
export -f 2>/dev/null || true

SEND_LOG="$TMP/sent"; : >"$SEND_LOG"
cmd_send()            { printf '%s\n' "$*" >>"$SEND_LOG"; }
_task_agent_channel() { return 0; }
HB_LOG="$TMP/hblog"; : >"$HB_LOG"
_hb_log()             { printf '%s\n' "$*" >>"$HB_LOG"; }
AUD="$TMP/audit"; : >"$AUD"
_task_store_audit_log() { printf '%s\n' "$*" >>"$AUD"; return 0; }
# Single known repo, so a bare "#N" has one place to resolve.
_gate_repo_slugs()    { printf 'example/repo\n'; }

echo "== E: the subject extractor (intentional signal, not a mention) =="
is "E1 approve+bare ref is a subject" \
   "$(_gate_subject_refs_from_text 'Approve PR #12 so this can land?')" "|12"
is "E2 Subject: line is a subject" \
   "$(_gate_subject_refs_from_text 'Subject: https://github.com/example/repo/pull/12')" "example/repo|12"
# DIVE-2382's own ask: it cites a PR it is NOT about. A mention-predicate here
# retires a live approval. This arm is the reason the extractor exists at all.
is "E3 DIVE-2382 shape — 'already in review as PR #335' is NOT a subject" \
   "$(_gate_subject_refs_from_text 'Approve loosening the tier-2 human floor so a decision you state in prose clears a gate? The other five items are ours, and fix #5 is already in review as PR #335.')" ""
is "E4 bare mention is not a subject" \
   "$(_gate_subject_refs_from_text 'Context: PR #12 exists.')" ""
is "E5 negation rejected" \
   "$(_gate_subject_refs_from_text 'This is not merged — PR #12 still pending.')" ""
is "E6 post-cue 'needs your approval'" \
   "$(_gate_subject_refs_from_text 'PR #12 needs your approval before Friday.')" "|12"
is "E7 sign-off cue with connector" \
   "$(_gate_subject_refs_from_text 'Please sign off on PR #12.')" "|12"
is "E8 report verb 'shipped as' is not a subject" \
   "$(_gate_subject_refs_from_text 'Shipped as PR #12.')" ""

echo "== R: the reader (states mapped; git never called) =="
gh_set example/repo 101 MERGED SUCCESS
gh_set example/repo 102 OPEN SUCCESS
gh_set example/repo 103 MERGED FAILURE
gh_set example/repo 104 CLOSED SUCCESS
is "R1 merged+green -> MERGED" \
   "$(printf 'example/repo|101\n' | _gate_ref_states tok DIVE-9001 example/repo)" "101|MERGED|example/repo"
is "R2 open -> OPEN" \
   "$(printf 'example/repo|102\n' | _gate_ref_states tok DIVE-9001 example/repo)" "102|OPEN|example/repo"
is "R3 merged+red stays DISTINCT from merged" \
   "$(printf 'example/repo|103\n' | _gate_ref_states tok DIVE-9001 example/repo)" "103|MERGED-RED|example/repo"
is "R4 closed-unmerged -> CLOSED" \
   "$(printf 'example/repo|104\n' | _gate_ref_states tok DIVE-9001 example/repo)" "104|CLOSED|example/repo"
has "R5 no such PR -> UNRESOLVED, naming the scope searched" \
   "$(printf '|999\n' | _gate_ref_states tok DIVE-9001 '')" "999|UNRESOLVED|"
is "R6 the reader made NO git call" "$(cat "$GIT_CALLS")" ""

echo "== V: verdict precedence =="
is "V1 no ref named -> NO-SUBJECT" \
   "$(_gate_subject_verdict 'Which of A or B should we pick?' tok DIVE-9001 example/repo)" "NO-SUBJECT"
has "V2 merged subject -> MERGED" \
    "$(_gate_subject_verdict 'Approve PR #101 to land?' tok DIVE-9001 example/repo)" "MERGED|#101 in example/repo"
has "V3 open subject -> OPEN" \
    "$(_gate_subject_verdict 'Approve PR #102 to land?' tok DIVE-9001 example/repo)" "OPEN|#102 in example/repo"
has "V4 OPEN wins over a merged sibling" \
    "$(_gate_subject_verdict 'Approve PR #101 and merge PR #102?' tok DIVE-9001 example/repo)" "OPEN|"
has "V5 no credential is UNKNOWN, never an accept" \
    "$(_gate_subject_verdict 'Approve PR #101?' '' DIVE-9001 example/repo)" "UNKNOWN|no-gh-token"
has "V6 merged-but-RED is UNKNOWN, not retirable" \
    "$(_gate_subject_verdict 'Approve PR #103?' tok DIVE-9001 example/repo)" "UNKNOWN|"

echo "== H: direction (a) — the heartbeat gate sweep =="
_HB_GATE_SHIPPED_REPOS="5dive-cli"
mkgate() {  # <ident> <ask> ; returns the row id
  db "INSERT INTO tasks (ident,title,status,assignee,created_by,need_type,ask,need_asked_at,tier)
      VALUES ($(sqlq "$1"),'t','blocked','dev','dev','approval',$(sqlq "$2"),datetime('now'),2);"
  db "SELECT id FROM tasks WHERE ident=$(sqlq "$1");"
}
flagged() { db "SELECT CASE WHEN shipped_flag_at IS NULL THEN 'no' ELSE 'yes' END FROM tasks WHERE ident=$(sqlq "$1");"; }
# The row-level evidence is present in EVERY H arm: a commit naming the row landed.
# That is what makes H1 a veto arm rather than a coverage arm.
_hb_repo_grep_ident() { printf '5dive-cli abc1234 %s subject naming %s\n' "$(date -u +%s)" "$2"; }

g1=$(mkgate DIVE-9001 'Approve PR #102 before we merge?')   # subject OPEN
_hb_gate_shipped_sweep >/dev/null 2>&1
is "H1 open subject VETOES the row-commit flag" "$(flagged DIVE-9001)" "no"
# H1a (DIVE-2530): the OUTCOME above is reachable by two paths — vetoed-because-OPEN
# and withheld-because-UNREADABLE both leave flagged=no. On the tokenless runner H1
# went green while the state it exists to prove was never reached. Assert the REASON,
# so the arm can only pass on the path it names.
has "H1a and the veto names the OPEN subject, not an unreadable one" "$(cat "$HB_LOG")" "#102"
hasnt "H1a2 and it is NOT the unreadable path" "$(cat "$HB_LOG")" "no-gh-token"
has "H1b and says the row's commits are not evidence" "$(cat "$HB_LOG")" "NOT evidence about this gate"
# H1c is an ABSENCE assertion and absence assertions pass on EMPTY output (olivia,
# DIVE-2530): it cannot fail even if the sweep produced nothing at all, which makes it
# strictly weaker than H1 — H1 needs a wrong-but-present value, H1c needs nothing.
# The positive companion is what stops it staying green through a future breakage that
# SILENCES the sweep rather than mis-answering it.
is "H1c0 the sweep actually ran (positive companion for the absence arm)" \
   "$([[ -s "$HB_LOG" ]] && echo produced || echo empty)" "produced"
hasnt "H1c owner NOT nudged" "$(cat "$SEND_LOG")" "DIVE-9001"

: >"$HB_LOG"; : >"$SEND_LOG"
g2=$(mkgate DIVE-9002 'Approve PR #101 before we merge?')   # subject MERGED
_hb_gate_shipped_sweep >/dev/null 2>&1
is "H2 merged subject flags" "$(flagged DIVE-9002)" "yes"
has "H2b flag names SUBJECT evidence, not the row's commits" "$(cat "$AUD")" "evidence=subject-pr"
has "H2c owner nudge names the subject PR" "$(cat "$SEND_LOG")" "ASKS ABOUT is now merged"

: >"$HB_LOG"; : >"$SEND_LOG"
g3=$(mkgate DIVE-9003 'Which plan do you want, A or B?')    # NO subject
_hb_gate_shipped_sweep >/dev/null 2>&1
is "H3 no-subject gate keeps DIVE-1140 row-level flagging" "$(flagged DIVE-9003)" "yes"
has "H3b nudge names the evidence class as ROW-level" "$(cat "$SEND_LOG")" "evidence is ROW-level"
has "H3c audit records the evidence class" "$(cat "$AUD")" "evidence=row-commit"

: >"$HB_LOG"; : >"$SEND_LOG"
g4=$(mkgate DIVE-9004 'Approve PR #777 before we merge?')   # subject unreadable
_hb_gate_shipped_sweep >/dev/null 2>&1
is "H4 unreadable subject withholds the flag (no stamp, retries)" "$(flagged DIVE-9004)" "no"
has "H4b and says a non-verdict is not a negative" "$(cat "$HB_LOG")" "could NOT be read"

echo "== C: direction (b) — cited-not-delivered now READ, never judged =="
has "C1 cited open PR's state is reported" \
    "$(_gate_cited_state_note 'example/repo|102' tok DIVE-9001 example/repo)" "#102 OPEN in example/repo"
has "C2 no credential says so instead of implying clean" \
    "$(_gate_cited_state_note 'example/repo|102' '' DIVE-9001 example/repo)" "state NOT read"
has "C3 cap is announced, never silent" \
    "$(_gate_cited_state_note "$(printf 'example/repo|101\nexample/repo|102\nexample/repo|103\nexample/repo|104\n')" tok DIVE-9001 example/repo)" \
    "first 3 of 4 cited refs read"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
