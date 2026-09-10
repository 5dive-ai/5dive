#!/usr/bin/env bash
# TIER: core
# DIVE-4176 — THE HUMAN-ASK READABILITY CHECK IS A REFUSAL, NOT AN IGNORED WARNING.
#
# lodar, 2026-08-12: "I cannot understand most of the tech stuff when I got to my
# human gate". The check has existed as a warning since DIVE-3661 and is ignored:
# the parent row DIVE-4150 was warned that its 34-word ask "will render cut" and
# was filed anyway, unchanged. A warning delivered to a headless filer is read by
# nobody. This grades the refusal that replaced it.
#
# EVERY REFUSAL IS PAIRED WITH A CONTROL THAT MUST STILL FILE. The cheap way to
# pass "the unreadable ask was refused" is for cmd_task_need to be unreachable,
# mis-sourced or refusing everything, and a lone red exit cannot tell that apart
# from the rule working. The controls are the load-bearing half here:
#
#   * a tier-1 (lead-routed) gate with the SAME unreadable ask must still file —
#     that gate is read by an AGENT, and refusing it would bounce 83% of the
#     30-day tier-1 corpus over a rule about a reader who is not on that gate;
#   * the lodar-readable asks that survived the 30-day replay must still file,
#     verbatim, or the refusal is a redesign rather than a tightening;
#   * the English neighbours of each jargon shape (out-of-band, read/write,
#     19/19, a bare token budget) must not be read as jargon.
#
# Assertions read the RECORD (need_type / status / audit rows) as well as the
# exit status, because a refusal that exits non-zero AFTER writing the gate would
# pass an rc-only assertion while leaving the ping it refused standing.
#
# Run: bash tests/gate_ask_readability_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-ask-readability.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init
_tasks_db_migrate

# --- stubs: nothing leaves the box -------------------------------------------
cmd_send()               { return 0; }
_task_agent_channel()    { return 0; }
_task_send_owner()       { return 0; }
task_need_notify()       { return 0; }
_task_gate_retire_buttons() { return 0; }
audit_log()              { return 0; }
AUDIT_ROWS="$TMP/audit_rows"; : >"$AUDIT_ROWS"
_task_store_audit_log()  { printf '%s\n' "$*" >>"$AUDIT_ROWS"; return 0; }
# No lead above the filer: keeps the eng-ship / curation / --discusses downgrades
# out of these cases, so a tier that survives to the readability arm survived for
# the reason the case is about. Asserted live in case D1 rather than assumed.
_gate_route_reviewer()   { printf ''; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
has_t() { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] does not contain [$3]"; fi; }
no_t()  { if [[ "$2" != *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] unexpectedly contains [$3]"; fi; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }

N=0
seed() { N=$((N+1)); db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status)
      VALUES ('$1', '${2:-a plain internal row}', 'medium', 'dev', 'main', 'standard', 'todo');"; }

RC=0; OUT=""
file_gate() { local id="$1"; shift; OUT=$( (cmd_task_need "$id" --from=dev "$@") 2>&1 ); RC=$?; }

# A readable, human-facing ask lifted verbatim from the 30-day corpus. Used as
# the control everywhere a case needs "the same gate, minus the defect".
GOOD="Two AI workers have been signed out since July. Sign them back in, or retire them?"

# ============ PRECONDITION: the subject is live ==============================
# Without this, every refusal below is indistinguishable from cmd_task_need
# being unreachable in this harness.
seed LIVE-1
file_gate LIVE-1 --type=manual --ask="$GOOD" --tier=2
eq_t "PRECONDITION: a readable tier-2 gate files (rc 0)" "$RC" "0"
eq_t "PRECONDITION: ... and the row is a real tier-2 gate" \
     "$(field LIVE-1 need_type)|$(field LIVE-1 tier)" "manual|2"

# ============ A. the classifier itself, at unit level =======================
# Graded directly as well as through the command: a term the classifier cannot
# name is a refusal message that cannot be acted on (the DIVE-2224 lesson).
for probe in "DIVE-3164:ident" "PR #566:ident" "head e131860:sha" \
             "/home/claude/projects/5dive:path" "origin/main:path" \
             "deploy.yml:path" "dive-3664-server-held-pair:branch" \
             "--force:flag" "servers.held_at:snake" "mergePullRequest:camel"; do
  _p="${probe%:*}"; _want="${probe##*:}"
  _got=$(_gate_ask_jargon_term "approve the $_p change" 2>/dev/null) || _got="CLEAN"
  eq_t "A: '$_p' classifies as $_want" "${_got%%:*}" "$_want"
done

# The English neighbours. Each of these is a shape one arm of the classifier
# would eat if it were written the obvious way, and each appears in the corpus.
for eng in "an out-of-band end-to-end decision" \
           "give the agents read/write access to the tracker" \
           "all 19/19 checks are green" \
           "this row spent 5000000 tokens of its budget" \
           "should we ship the one-tap company import"; do
  _got=$(_gate_ask_jargon_term "$eng" 2>/dev/null) || _got="CLEAN"
  eq_t "A-eng: plain English survives — \"${eng:0:34}…\"" "$_got" "CLEAN"
done
eq_t "A-count: the word counter counts words, not characters" \
     "$(_gate_ask_word_count "one two three four five")" "5"

# ============ B. the refusal fires on a human-facing gate ===================
# B1 — over the word cap. This is DIVE-4150's own ask shape: it was WARNED and
# filed anyway, which is the defect this row closes.
LONG="Approve merging the dunning HOLD pre-merge because it stops deleting a churned payer's box and instead powers it off for the seven day grace window which still bills us and that is the tradeoff here"
seed CAP-1
file_gate CAP-1 --type=approval --ask="$LONG" --tier=2
[[ "$RC" != "0" ]] && ok_t "B1: an over-length human-facing ask is REFUSED" \
  || bad_t "B1: an over-length human-facing ask is REFUSED" "rc=$RC out=$OUT"
has_t "B1b: the refusal says how long it ran" "$OUT" "the cap is 25"
eq_t  "B1c: NO gate was written by the refused filing" "$(field CAP-1 need_type)" "∅"
eq_t  "B1d: the task was not moved to blocked" "$(field CAP-1 status)" "todo"
has_t "B1e: the refusal is audited" "$(cat "$AUDIT_ROWS")" "task need ask-readability refused"

# B2 — internal vocabulary, INSIDE the word cap. The two arms must be
# independent, or a short jargon ask files and the rule only ever measured length.
seed JAR-1
file_gate JAR-1 --type=approval --ask="Approve merging DIVE-3164 at head e39ad3a?" --tier=2
[[ "$RC" != "0" ]] && ok_t "B2: a SHORT ask naming an ident is refused too" \
  || bad_t "B2: a SHORT ask naming an ident is refused too" "rc=$RC out=$OUT"
has_t "B2b: the refusal NAMES the offending token" "$OUT" "DIVE-3164"
has_t "B2c: ... and its class" "$OUT" "an ident"

# B3 — --options are buttons the human reads, so they are held to the same rule.
seed OPT-1
file_gate OPT-1 --type=decision --ask="Ship the cheaper plan now, or wait for the test?" \
          --options="merge dive-4176-ask-readability|hold" --tier=2
[[ "$RC" != "0" ]] && ok_t "B3: an unreadable --options value is refused" \
  || bad_t "B3: an unreadable --options value is refused" "rc=$RC out=$OUT"
has_t "B3b: ... and the refusal says it was the options" "$OUT" "--options contains"

# B4 — the refusal must be a REDIRECT, not a dead end: it names the exits.
has_t "B4: the refusal names the rewrite as the wanted exit" "$OUT" "rewrite the ask"
has_t "B4b: the refusal names --tier=1"  "$OUT" "--tier=1"
has_t "B4c: the refusal names --ask-ok"  "$OUT" "--ask-ok"

# ============ C. the exits the refusal names actually work =================
seed EX-1
file_gate EX-1 --type=approval --ask="$LONG" --tier=2 \
          --ask-ok="the exact release string is the subject of the question"
eq_t "C1: the named escape works — the same gate files with --ask-ok (rc 0)" "$RC" "0"
eq_t "C1b: ... and it really did reach the human tier" "$(field EX-1 tier)" "2"
has_t "C1c: the escape is audited, so the exception is countable" \
      "$(cat "$AUDIT_ROWS")" "task need ask-readability escaped"
has_t "C1d: ... and the filer is told it was recorded" "$OUT" "readability escape ACCEPTED"

# A declaration with no substance buys nothing — same rule as --discusses and
# --rubber-stamp-ok. Otherwise --ask-ok=x is a silent opt-out of the whole row.
seed EX-2
file_gate EX-2 --type=approval --ask="$LONG" --tier=2 --ask-ok="urgent"
[[ "$RC" != "0" ]] && ok_t "C2: a substanceless --ask-ok is REFUSED" \
  || bad_t "C2: a substanceless --ask-ok is REFUSED" "rc=$RC out=$OUT"

# ============ D. the population that MUST still file =======================
# D1 — THE CONTROL THIS WHOLE HARNESS RESTS ON. The same unreadable ask, routed
# to a lead instead of the human, must file untouched: 264 of the 319 tier-1 asks
# in the 30-day corpus carry this vocabulary, and they are read by an agent.
seed KEEP-1
file_gate KEEP-1 --type=decision --ask="Merge DIVE-3164 at head e39ad3a from origin/main?" \
          --options="merge|hold" --tier=1
eq_t "D1: the SAME jargon ask files at tier 1 (rc 0) — agents read those" "$RC" "0"
eq_t "D1b: ... and it is really a tier-1 gate, not a downgraded one" "$(field KEEP-1 tier)" "1"
# Scoped to the readability rows: other audit families legitimately name this
# task, so a bare grep for the ident would pass on the wrong evidence.
eq_t "D1c: ... and no readability refusal was audited for it" \
     "$(grep -c 'ask-readability.*task=KEEP-1' "$AUDIT_ROWS")" "0"

# D2..D6 — the lodar-readable corpus, verbatim from the 30-day replay's survivor
# list. If the refusal reds any of these it is a redesign, not a tightening,
# which is the check the row required before shipping.
i=0
while IFS= read -r good; do
  [[ -n "$good" ]] || continue
  i=$((i+1)); seed "GOOD-$i"
  file_gate "GOOD-$i" --type=manual --ask="$good" --tier=2
  eq_t "D2.$i: corpus survivor still files — \"${good:0:44}…\"" "$RC" "0"
done <<'CORPUS'
Two AI workers have been signed out since July. Sign them back in, or retire them?
Give the agents write access to our error tracker? Read-only today, so crashes get re-investigated repeatedly.
Forty minutes today clears ten stuck rows. May agents buy the throwaway test server needed?
A returning customer bought a cheaper plan but kept bigger hardware. Which one should change?
Ten minutes on your phone today to switch chat setup on for customers?
CORPUS

# D1d — THE ROUTED TIER-2 CONTROL. A tier-2 approval/manual/access gate that is
# ROUTED to a lead or to the task's verifier is read by an AGENT, not by lodar,
# so the rule must not reach it either. Without this case the refusal regresses
# tests/gate_access_lead_clear_unit.sh, whose access gate legitimately asks a
# LEAD to "push branch dive-3212-openclaw-harness-30s" — which it did, before
# this scope was narrowed. The harness's global stub returns no lead (that is
# what makes every other case land on the human), so the lead is granted for the
# length of this case only, and the case asserts the stub really did flip.
seed ROUTED-1
_gate_route_reviewer() { printf 'main'; }
eq_t "D1d-pre: the lead stub is live (or this case proves nothing)" \
     "$(_gate_route_reviewer dev)" "main"
file_gate ROUTED-1 --type=access --ask="Push branch dive-3212-openclaw-harness-30s and open the PR?"
eq_t "D1d: a ROUTED tier-2 gate with the same jargon still files (rc 0)" "$RC" "0"
eq_t "D1d2: ... and it really was tier 2, not downgraded past the rule" "$(field ROUTED-1 tier)" "2"
_gate_route_reviewer() { printf ''; }
eq_t "D1d3: the stub is restored for the cases below" "$(_gate_route_reviewer dev)" ""

# D3 — a DECLARED human capability is human-facing even before the DIVE-2241
# re-assert runs, so the rule must reach it. Without this case the check could be
# skipped by filing --tier=1 --needs=human_tap and still page the human.
seed NEEDS-1
file_gate NEEDS-1 --type=decision --ask="Approve merging DIVE-3164 at head e39ad3a?" \
          --options="merge|hold" --tier=1 --needs=human_tap
[[ "$RC" != "0" ]] && ok_t "D3: a DECLARED human-capability gate is checked even at --tier=1" \
  || bad_t "D3: a DECLARED human-capability gate is checked even at --tier=1" "rc=$RC out=$OUT"

# ============ E. the advisory half stays advisory ==========================
# The consequence-first rule has no honest mechanical predicate; the proxy is
# "the ask asks a question", and 2 of the 26 corpus survivors are legitimate
# imperatives. It must WARN and must not refuse — this case is what stops a
# later tightening from turning a style note into a bounced manual gate.
seed ADV-1
file_gate ADV-1 --type=manual --ask="Please try one agent-file import on your box, picking another runtime." --tier=2
eq_t  "E1: an imperative ask still FILES (rc 0)" "$RC" "0"
has_t "E1b: ... and is warned about the missing question" "$OUT" "states an instruction rather than asking a question"

# ============ F. the gate the PRODUCT files must pass its own rule ==========
# `task reject` at the iteration cap files a --type=manual gate that parks the
# stuck loop on the paired human. That ask is written by delivery.sh, not by a
# filer, and nothing else grades it — so when it carried the row's ident and the
# verifier's raw feedback it was refused by this very rule, which made `reject`
# itself fail at the cap (caught in CI on this branch, not in review). The arm
# reads the SHIPPED string out of the source rather than restating it, so a later
# edit that reintroduces machine vocabulary reds here instead of in production.
ESC_ASK=$(grep -A1 'cmd_task_need "\$id" --type=manual --from=' "$SRC/task/delivery.sh" \
          | sed -n 's/.*--ask="\(.*\)"$/\1/p')
[[ -n "$ESC_ASK" ]] \
  && ok_t "F0: the escalation ask was located in delivery.sh (or arm F proves nothing)" \
  || bad_t "F0: escalation ask not found in delivery.sh" "grep found nothing — the call shape moved"
# Substitute the call site's live variables with REALISTIC values — an ident, a
# count, a cap, a verifier's raw feedback — because the jargon this rule refuses
# arrives through exactly those slots, not through the prose around them. Any $
# left after this means a new slot appeared that the arm is not filling, and the
# arm must red rather than grade a half-expanded string.
ESC_ASK="${ESC_ASK//\$\{iter\}/3}"
ESC_ASK="${ESC_ASK//\$\{maxi\}/3}"
ESC_ASK="${ESC_ASK//\$ident/DIVE-4176}"
ESC_ASK="${ESC_ASK//\$\{ident\}/DIVE-4176}"
ESC_ASK="${ESC_ASK//\$\{feedback:-none\}/CI is red on core-pristine at head 777e23a9, see tests/gate_ask_readability_unit.sh}"
[[ "$ESC_ASK" != *'$'* ]] \
  && ok_t "F0b: every shell expansion in it was substituted (no \$… left half-graded)" \
  || bad_t "F0b: unsubstituted expansion left in the escalation ask" "ask='$ESC_ASK'"
seed ESC-1
file_gate ESC-1 --type=manual --ask="$ESC_ASK" --tier=2
eq_t "F1: the iteration-cap escalation gate the product files is READABLE (rc 0)" "$RC" "0"
eq_t "F2: ... and it really was filed, not swallowed" "$(field ESC-1 need_type)" "manual"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
