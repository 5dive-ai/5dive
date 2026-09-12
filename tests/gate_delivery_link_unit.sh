#!/usr/bin/env bash
# TIER: core
# DIVE-4381 — THE HUMAN-GATE PING CARRIES THE BOUND PR LINK.
#
# lodar, Telegram 2026-09-12, after DIVE-4366's "needs you" ping reached him:
# "shouldnt this link be in human gate notification for convenience?" — the row
# held the PR URL in `delivery_ref` the whole time and the message never read the
# column, so answering meant a second tap into /task_<id> or asking a bot for the
# URL. That is the autonomy surface visibly rough on the one screen a founder
# actually sees.
#
# WHAT IS PINNED HERE, and why each half exists:
#
#   L1-L7  THE HELPER's rule. `delivery_ref` is a free TEXT column: rows carry
#          bare branch names and PR numbers in it as well as URLs. The line is
#          keyed on a literal http(s):// prefix, and every non-URL shape must
#          emit NOTHING — a rendered dead link is worse than no link, because the
#          human taps it before finding out. L7 is the absent-row control: a
#          helper that emitted on a missing id would decorate every gate.
#
#   W1-W6  THE WIRING, and it is the half that matters. A helper nobody calls is
#          a suite grading itself, and this ticket's whole content is that two
#          render sites read the column. W1-W3 drive the FIRST delivery
#          (_task_need_notify_deliver); W4-W6 drive the /inbox BATCH re-send
#          through the real `_task_inbox_send`, which composes its own text and
#          would stay link-less under a suite that only graded the notify site
#          (the measured shape of DIVE-3661's I10/I11:
#          community/wiki/a-regression-arm-must-land-on-the-render-path-the-acceptance-names.md).
#          Both sites get a NEGATIVE arm: a row with no delivery_ref must render
#          byte-identically to before — no orphan line, no empty line.
#
#   R1-R5  THE RE-NAG BATCH (_hb_gate_renag_batch_one, DIVE-1490's +1h/24h
#          reminder) — the THIRD composer, found on iteration 1's bounce. It is
#          the path this row's motivation describes best: a gate that has SAT is
#          when "which PR was this?" gets asked. It was invisible to a grep for
#          `_task_gate_ask_line` because it inlines substr(ask,1,240) instead.
#          Because the loop renders MANY rows in ONE message, these arms prove
#          PER-ROW attachment, not mere presence: R4/R5 drive a MIXED batch (one
#          row with a URL, one without) and require exactly ONE link, inside the
#          right row's bullet block.
#
#   T1-T2  THE TYPE RULE, taken deliberately on this row and graded so a later
#          narrowing is a visible choice rather than a drift. The line is keyed
#          on the row holding a bound PR, NOT on the gate's type: a decision gate
#          about a change is answered by reading the same diff. T2 is the secret
#          case — the minted drop link says where a credential GOES, the review
#          link says what to LOOK at, so on a row that has both they coexist.
#
# Isolation matches the sibling gate harnesses: src/ libs sourced into a throwaway
# STATE_DIR, the live shared tasks.db is never touched, nothing leaves the box.
# Fixture chat id is the reserved fake 1234567890; fixture URLs point at the
# repo's own PRs, which are not a person's identifier.
# Run: bash tests/gate_delivery_link_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC="${GRTC_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/gate-delivery-link.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh \
         cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

task_need_notify() { return 0; }
audit_log() { :; }

PR_URL="https://github.com/5dive-ai/5dive/pull/913"

seed_gate() { # <ident> <need_type> <delivery_ref> [needs_capability]
  db "INSERT INTO tasks (ident, title, status, priority, assignee, created_by, need_type, tier,
                         ask, delivery_ref, needs_capability, need_asked_at)
      VALUES ($(sqlq "$1"),'t','blocked','high','dev','main',$(sqlq "$2"),2,
              'look at this and decide', $( [[ -n "${3:-}" ]] && sqlq "$3" || printf 'NULL'),
              $( [[ -n "${4:-}" ]] && sqlq "$4" || printf 'NULL'), datetime('now','-2 hours'));"
}
rid() { db "SELECT id FROM tasks WHERE ident=$(sqlq "$1");"; }
# need_asked_at is seeded two hours back on purpose: DIVE-4154's undo window holds
# the PUSH for a freshly filed gate, and a held ping composes no text at all — a
# suite seeded with `datetime('now')` reads every wiring arm as an empty message
# and passes its NEGATIVE arms vacuously. Two hours is past every window, which is
# also the real shape of the /inbox re-send these arms grade.

# ==================== L: THE HELPER'S RULE ===================================
# Every arm is the SAME gate row with only delivery_ref changed, so a pass can
# only come from the column and never from the row's type, tier or ask.
seed_gate DIVE-9401 approval "$PR_URL"
L=$(rid DIVE-9401)

[[ "$(_task_gate_delivery_link_line "$L")" == "🔗 Review: ${PR_URL}" ]] \
  && ok_t "L1 an https delivery_ref renders one tappable review line" \
  || bad_t "L1 an https delivery_ref renders one tappable review line" "got [$(_task_gate_delivery_link_line "$L")]"

db "UPDATE tasks SET delivery_ref='http://example.com/pr/1' WHERE id=${L};"
[[ "$(_task_gate_delivery_link_line "$L")" == "🔗 Review: http://example.com/pr/1" ]] \
  && ok_t "L2 a plain http delivery_ref renders too (the predicate is the scheme, not the host)" \
  || bad_t "L2 a plain http delivery_ref renders too" "got [$(_task_gate_delivery_link_line "$L")]"

db "UPDATE tasks SET delivery_ref=NULL WHERE id=${L};"
[[ -z "$(_task_gate_delivery_link_line "$L")" ]] \
  && ok_t "L3 a NULL delivery_ref emits nothing at all" \
  || bad_t "L3 a NULL delivery_ref emits nothing at all" "got [$(_task_gate_delivery_link_line "$L")]"

db "UPDATE tasks SET delivery_ref='' WHERE id=${L};"
[[ -z "$(_task_gate_delivery_link_line "$L")" ]] \
  && ok_t "L4 an empty delivery_ref emits nothing at all" \
  || bad_t "L4 an empty delivery_ref emits nothing at all" "got [$(_task_gate_delivery_link_line "$L")]"

# The shape that makes the URL predicate load-bearing rather than decorative:
# a branch name and a bare PR number are both real delivery_ref contents, and
# neither is tappable.
for _bad in 'dive-4381-gate-link' '913' '5dive-ai/5dive#913' 'ftp://example.com/x'; do
  db "UPDATE tasks SET delivery_ref=$(sqlq "$_bad") WHERE id=${L};"
  [[ -z "$(_task_gate_delivery_link_line "$L")" ]] \
    && ok_t "L5 a non-URL delivery_ref [${_bad}] renders NO dead link" \
    || bad_t "L5 a non-URL delivery_ref [${_bad}] renders NO dead link" "got [$(_task_gate_delivery_link_line "$L")]"
done

db "UPDATE tasks SET delivery_ref='   ' WHERE id=${L};"
[[ -z "$(_task_gate_delivery_link_line "$L")" ]] \
  && ok_t "L6 an all-whitespace delivery_ref is still nothing" \
  || bad_t "L6 an all-whitespace delivery_ref is still nothing" "got [$(_task_gate_delivery_link_line "$L")]"

# L7 the absent-row control. Without it, a helper that ignored its argument and
# printed unconditionally would pass L1 and be caught by nothing else here.
[[ -z "$(_task_gate_delivery_link_line 999999)" && -z "$(_task_gate_delivery_link_line "")" \
   && -z "$(_task_gate_delivery_link_line 'x; DROP TABLE tasks')" ]] \
  && ok_t "L7 a missing, empty or non-numeric row id emits nothing" \
  || bad_t "L7 a missing, empty or non-numeric row id emits nothing"

db "UPDATE tasks SET delivery_ref=$(sqlq "$PR_URL") WHERE id=${L};"

# ==================== W: THE WIRING (both render paths) ======================
CAPTURED=""; CAPTURED_KB=""
_task_send_owner() { CAPTURED="$1"; CAPTURED_KB="${2:-}"; TASK_SEND_DELIVERED=1; TASK_SEND_MESSAGE_IDS="901"; return 0; }
_task_owner_channel() { TASK_CH_TOKEN=stub; TASK_CH_ACCESS=/dev/null; TASK_CH_TYPE=claude; TASK_CH_AGENT=t; return 0; }

CAPTURED=""
_task_need_notify_deliver DIVE-9401 approval "approve the change" "" "" "" "" "" >/dev/null 2>&1
_first="$CAPTURED"
[[ "$_first" == *"🔗 Review: ${PR_URL}"* ]] \
  && ok_t "W1 the FIRST gate delivery carries the bound PR link" \
  || bad_t "W1 the FIRST gate delivery carries the bound PR link" "text: ${_first:0:400}"

# Placement is part of the fix, not decoration: the human reads the ask, then the
# thing to look at, then how to clear it. Asserted as an ORDER so a line that
# lands after the CTA (or below the options) is a red, not a silent re-shuffle.
_ask_pos=$(awk -v s="$_first" 'BEGIN{print index(s, "/task_")}')
_link_pos=$(awk -v s="$_first" 'BEGIN{print index(s, "🔗 Review:")}')
(( _ask_pos > 0 && _link_pos > _ask_pos )) \
  && ok_t "W2 the link sits directly under the ask / task deep link" \
  || bad_t "W2 the link sits directly under the ask / task deep link" "ask@${_ask_pos} link@${_link_pos}"

# W3 THE NEGATIVE. A row with no bound PR must render exactly as it did before
# this ticket: no label, no orphan emoji, no empty line where the link would be.
seed_gate DIVE-9402 approval ""
CAPTURED=""
_task_need_notify_deliver DIVE-9402 approval "approve the change" "" "" "" "" "" >/dev/null 2>&1
if [[ "$CAPTURED" != *"🔗"* && "$CAPTURED" != *"Review:"* && "$CAPTURED" != *$'\n\n\n'* ]]; then
  ok_t "W3 a gate on a row with NO delivery_ref renders no link and no blank line"
else
  bad_t "W3 a gate on a row with NO delivery_ref renders no link and no blank line" "text: ${CAPTURED:0:400}"
fi

# W4-W6 THE BATCH RE-SEND. `_task_inbox_send` composes its own text rather than
# calling _task_need_notify_deliver, so W1-W3 grade ONE of the two places a gate
# is rendered. A re-nag is exactly when a gate has sat long enough for "which PR
# was this?" to be the question, so a link-less re-nag is the live failure.
# Three stubs neutralise PRECONDITIONS of reaching the render loop (root, the
# DIVE-1506 prod-DB fence, the paired channel) and none of them the emitted text.
# The subshell is required: `_task_inbox_send` finishes through `ok`, which exits.
_IT="$TMP/inbox.txt"
run_batch() { # <ident>
  : >"$_IT"
  (
    require_root() { :; }
    _task_send_owner() { printf '%s' "$1" >"$_IT"; TASK_SEND_DELIVERED=1; TASK_SEND_MESSAGE_IDS="901"; return 0; }
    FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
    _task_inbox_send "" "ident=$(sqlq "$1")" "ORDER BY created_at"
  ) >/dev/null 2>&1
  cat "$_IT" 2>/dev/null
}

_bt=$(run_batch DIVE-9401)
[[ "$_bt" == *"🔗 Review: ${PR_URL}"* ]] \
  && ok_t "W4 the /inbox BATCH re-send carries the same bound PR link" \
  || bad_t "W4 the /inbox BATCH re-send carries the same bound PR link" "text: ${_bt:0:400}"

_bt2=$(run_batch DIVE-9402)
[[ -n "$_bt2" && "$_bt2" != *"🔗"* && "$_bt2" != *"Review:"* ]] \
  && ok_t "W5 the BATCH re-send of a link-less row carries no link" \
  || bad_t "W5 the BATCH re-send of a link-less row carries no link" "text: ${_bt2:0:400}"

# W6: the two surfaces must agree on the URL they show, since a human who sees
# one string on the ping and another on the re-nag has to decide which is real.
[[ "$(printf '%s' "$_first" | grep -o 'https\?://[^[:space:]]*' | head -1)" \
   == "$(printf '%s' "$_bt" | grep -o 'https\?://[^[:space:]]*' | head -1)" ]] \
  && ok_t "W6 both render paths show the identical URL" \
  || bad_t "W6 both render paths show the identical URL"

# ==================== T: THE TYPE RULE (declared, not narrowed) ==============
# T1 a DECISION gate — the shape a type-scoped implementation would drop. The
# line is keyed on the row holding a bound PR, because a decision about a change
# is answered by reading that change.
seed_gate DIVE-9403 decision "$PR_URL"
CAPTURED=""
_task_need_notify_deliver DIVE-9403 decision "which way" "A|B" "A" "" "" "" >/dev/null 2>&1
[[ "$CAPTURED" == *"🔗 Review: ${PR_URL}"* ]] \
  && ok_t "T1 a DECISION gate on a row with a bound PR gets the link too" \
  || bad_t "T1 a DECISION gate on a row with a bound PR gets the link too" "text: ${CAPTURED:0:400}"

# T2 a SECRET gate with a bound PR: the DIVE-2411 credential CTA and the review
# link are different questions (where the value goes vs. what to look at), so
# both stand. This also guards the drop-link copy against being displaced.
seed_gate DIVE-9404 secret "$PR_URL"
CAPTURED=""
_task_need_notify_deliver DIVE-9404 secret "hand over the credential" "" "" "" "" "" >/dev/null 2>&1
[[ "$CAPTURED" == *"🔗 Review: ${PR_URL}"* && "$CAPTURED" == *"credential"* ]] \
  && ok_t "T2 a SECRET gate keeps its credential CTA and gains the review link" \
  || bad_t "T2 a SECRET gate keeps its credential CTA and gains the review link" "text: ${CAPTURED:0:400}"

# ============ R: THE RE-NAG BATCH (the third composer) =======================
# Driven through the REAL _hb_gate_renag_batch_one. Only its EDGES are stubbed —
# the paired-channel precondition and the send sink — never the text it builds.
RENAG_T="$TMP/renag.txt"
_task_agent_channel() { TASK_CH_TYPE=claude; TASK_CH_TOKEN=x; TASK_CH_ACCESS=/dev/null; TASK_CH_AGENT=t; return 0; }
_task_send_gate_owner() { printf '%s' "$1" >"$RENAG_T"; TASK_SEND_DELIVERED=1; TASK_SEND_MESSAGE_IDS="901"; return 0; }
_hb_log() { :; }

seed_renag() { # <ident> <need_type> <delivery_ref> <recommend>
  db "INSERT INTO tasks (ident, title, status, priority, assignee, created_by, need_type,
                         tier, ask, recommend, need_options, delivery_ref, need_asked_at)
      VALUES ($(sqlq "$1"),'t','blocked','high','dev','main',$(sqlq "$2"),2,
              'look at this and decide', $(sqlq "$4"), 'A|B',
              $( [[ -n "${3:-}" ]] && sqlq "$3" || printf 'NULL'), datetime('now','-2 hours'));"
}
run_renag() { # <comma-separated row ids>
  : >"$RENAG_T"
  _hb_gate_renag_batch_one main "$1" "test" >/dev/null 2>&1
  cat "$RENAG_T" 2>/dev/null
}
# The batch is ONE message holding N bullets. Presence of the link in that blob
# says nothing about WHICH row it decorates, so every R assertion is made against
# the slice of the message belonging to one bullet: from its own `• [IDENT]` line
# up to (not including) the next one.
bullet_block() { # <text> <ident>
  printf '%s\n' "$1" | awk -v id="$2" '
    /^• \[/ { inb = ($0 ~ ("^• \\[" id "\\]")) }
    inb { print }'
}

seed_renag DIVE-9405 approval "$PR_URL" "Push it"
R_URL=$(rid DIVE-9405)
_rt=$(run_renag "$R_URL")
[[ "$_rt" == *"🔗 Review: ${PR_URL}"* ]] \
  && ok_t "R1 the +1h/24h RE-NAG batch carries the bound PR link" \
  || bad_t "R1 the +1h/24h RE-NAG batch carries the bound PR link" "text: ${_rt:0:500}"

# R2 PLACEMENT inside the bullet: the link is the bullet's FIRST continuation
# line (directly under `• ... /task_<id>`, above Recommended/Options) and carries
# the same two-space indent as those lines, so it reads as part of that row.
_blk=$(bullet_block "$_rt" DIVE-9405)
_l2=$(printf '%s\n' "$_blk" | sed -n '2p')
_rec_pos=$(printf '%s\n' "$_blk" | grep -n 'Recommended:' | head -1 | cut -d: -f1)
[[ "$_l2" == "  🔗 Review: ${PR_URL}" && "${_rec_pos:-0}" -gt 2 ]] \
  && ok_t "R2 the link is the bullet's first continuation line, indented, above Recommended" \
  || bad_t "R2 the link is the bullet's first continuation line, indented, above Recommended" \
          "line2=[${_l2}] recommended@${_rec_pos:-none}"

# R3 THE NEGATIVE: a link-less row in the re-nag renders exactly as before — no
# label, no orphan indent, no blank continuation line under the bullet.
seed_renag DIVE-9406 approval "" "Push it"
R_NONE=$(rid DIVE-9406)
_rt_none=$(run_renag "$R_NONE")
if [[ -n "$_rt_none" && "$_rt_none" != *"🔗"* && "$_rt_none" != *"Review:"* ]]; then
  ok_t "R3 a re-nag bullet for a row with NO delivery_ref carries no link"
else
  bad_t "R3 a re-nag bullet for a row with NO delivery_ref carries no link" "text: ${_rt_none:0:500}"
fi

# R4/R5 THE MIXED BATCH — the arm a presence-only test cannot make. Two rows in
# one message, one with a URL and one without: exactly ONE link in the whole
# message (R4), and it belongs to the row that holds the ref while the other
# bullet stays bare (R5). A call hoisted out of the loop, or one keyed on the
# wrong id, passes R1-R3 and dies here.
_rt_mix=$(run_renag "${R_URL},${R_NONE}")
_nlinks=$(printf '%s\n' "$_rt_mix" | grep -c '🔗 Review:')
[[ "$_nlinks" == "1" ]] \
  && ok_t "R4 a MIXED batch renders exactly one review link, not one per bullet" \
  || bad_t "R4 a MIXED batch renders exactly one review link, not one per bullet" \
          "links=${_nlinks} text: ${_rt_mix:0:600}"

_mix_url=$(bullet_block "$_rt_mix" DIVE-9405)
_mix_none=$(bullet_block "$_rt_mix" DIVE-9406)
if [[ "$_mix_url" == *"  🔗 Review: ${PR_URL}"* && "$_mix_none" != *"🔗"* \
      && "$(printf '%s\n' "$_mix_url" | sed -n '2p')" == "  🔗 Review: ${PR_URL}" ]]; then
  ok_t "R5 the link is attached to the bullet that owns the ref, not the other one"
else
  bad_t "R5 the link is attached to the bullet that owns the ref, not the other one" \
        "with-ref block: [${_mix_url}] | link-less block: [${_mix_none}]"
fi

printf '\n%s\n' "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
