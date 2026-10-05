#!/usr/bin/env bash
# TIER: core
# DIVE-5465 — THE HUMAN-GATE PING QUOTES THE EXACT TEXT IT ASKS A PERSON TO APPROVE.
#
# lodar, TG 2026-10-03, on DIVE-5464's ping ("An outside project asked to join your
# public self-hosted agents list and meets every rule. /task_5662"): "how can i
# reply to this human gate notification if I dont see any details?" The drafted
# reply he was being asked to approve sat in the row body. `task need --quote` /
# `--quote-file` now stores that text ON THE GATE and every single-gate ping prints
# it as a quoted block under the ask, before /task_<n>.
#
#   F1-F4  THE FILING. --quote lands on the gate record; --quote-file also pins the
#          file (absolute path + sha256); a re-filed gate WITHOUT --quote clears
#          both, so a new ask never inherits the last one's text; --quote and
#          --quote-file together are refused (pass the prose once).
#   H1-H4  THE HELPER's rule. No quote = nothing. A quote renders verbatim, every
#          line prefixed. Over ~600 characters it is NOT truncated (a cut text is a
#          different text) — the ping says how long it is and points to /task_<n>.
#   W1-W5  THE WIRING, both single-gate composers: the first delivery
#          (_task_need_notify_deliver) and the /inbox re-send (_task_inbox_send).
#          W1 is the grader's named control: --quote="X" -> the rendered text holds
#          X verbatim. W3 is its negative: no quote -> the ask line still ends in
#          " /task_<n>" on ONE line and no quote marker appears anywhere.
#   S1-S8  STALE. The approval is of THAT text: editing the pinned copy after
#          filing makes an approve refused (gate stays open, audited), a deny still
#          lands, an untouched copy approves normally. DIVE-5572: the pin is a copy
#          the gate owns, so deleting the FILER's draft dir no longer blocks the
#          approve (S5); a pinned copy that is itself gone fails closed and says
#          "gone", not "edited" (S7-S8).
#   D1     /task_<n> (task show) carries the whole quote — the place the over-cap
#          ping points to.
#
# Isolation matches the sibling gate harnesses: src/ libs sourced into a throwaway
# STATE_DIR, the live shared tasks.db is never touched, nothing leaves the box.
# Run: bash tests/gate_quote_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC="${GRTC_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/gate-quote.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_agent.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable)\n' >&2
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

AUDIT="$TMP/audit.calls"; : >"$AUDIT"
audit_log() { printf '%s\n' "$*" >>"$AUDIT"; }
task_need_notify() { return 0; }     # filing precondition, never an observable
_gate_proof_enforced() { return 1; }
_gate_uid_to_agent() { printf ''; }
addt() { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
col()  { db "SELECT COALESCE($2,'<NULL>') FROM tasks WHERE id=${1};"; }
file_gate() { # <id> [extra need flags...]
  local id="$1"; shift
  ( cmd_task_need "$id" --type=approval --ask="Post this reply on the public thread?" \
      --recommend="approve" --tier=1 "$@" ) >/dev/null 2>&1
}
age() { db "UPDATE tasks SET need_asked_at=datetime('now','-2 hours') WHERE id=${1};"; }

QX='Thanks for the PR! Acme meets every rule, merging now.
Second line: welcome aboard.'

# ==================== F: THE FILING ==========================================
F=$(addt --assignee=dev -- "fixture quote gate")
file_gate "$F" --quote="$QX"
[[ "$(col "$F" need_quote)" == "$QX" ]] \
  && ok_t "F1 --quote is stored verbatim ON THE GATE record" \
  || bad_t "F1 --quote is stored verbatim ON THE GATE record" "got [$(col "$F" need_quote)]"
[[ "$(col "$F" need_quote_file)" == "<NULL>" ]] \
  && ok_t "F1b an inline --quote pins no file (the text itself is the record)" \
  || bad_t "F1b an inline --quote pins no file" "got [$(col "$F" need_quote_file)]"

DRAFT="$TMP/draft-reply.md"; printf '%s\n' "$QX" >"$DRAFT"
FF=$(addt --assignee=dev -- "fixture quote-file gate")
file_gate "$FF" --quote-file="$DRAFT"
_want_sha=$(printf '%s\n' "$QX" | sha256sum | cut -d' ' -f1)
_ffident=$(db "SELECT ident FROM tasks WHERE id=$FF;")
_ffpin="$TASKS_DIR/gate-quotes/${_ffident}.md"
[[ "$(col "$FF" need_quote_file)" == "$_ffpin" && "$(col "$FF" need_quote_sha)" == "$_want_sha" ]] \
  && ok_t "F2 --quote-file pins a DURABLE copy under the task store (not the filer's path) and its sha256" \
  || bad_t "F2 --quote-file pins a durable copy and its sha256" "file=[$(col "$FF" need_quote_file)] want=[$_ffpin] sha=[$(col "$FF" need_quote_sha)] want=$_want_sha"
cmp -s "$DRAFT" "$_ffpin" \
  && ok_t "F2b the pinned copy holds the draft's exact bytes (trailing newline included)" \
  || bad_t "F2b the pinned copy differs from the draft" "$(ls -l "$_ffpin" 2>&1)"
FS=$(addt --assignee=dev -- "fixture quote-file stdin")
printf 'from stdin\n' | file_gate "$FS" --quote-file=-
_fsident=$(db "SELECT ident FROM tasks WHERE id=$FS;")
[[ "$(col "$FS" need_quote_file)" == "$TASKS_DIR/gate-quotes/${_fsident}.md" ]] && [[ "$(cat "$TASKS_DIR/gate-quotes/${_fsident}.md")" == "from stdin" ]] \
  && ok_t "F2c --quote-file=- (stdin) is pinned too: the copy is what gets re-read" \
  || bad_t "F2c a stdin draft was not pinned" "file=[$(col "$FS" need_quote_file)]"

# F3: a re-filed gate without --quote must not inherit the previous ask's text.
R=$(addt --assignee=dev -- "fixture refile")
file_gate "$R" --quote-file="$DRAFT"
( cmd_task_need "$R" --withdraw ) >/dev/null 2>&1
db "UPDATE tasks SET status='in_progress', need_type=NULL, need_asked_at=NULL WHERE id=${R} AND need_type IS NOT NULL;" 2>/dev/null
file_gate "$R"
[[ "$(col "$R" need_quote)" == "<NULL>" && "$(col "$R" need_quote_file)" == "<NULL>" && "$(col "$R" need_quote_sha)" == "<NULL>" ]] \
  && ok_t "F3 a gate re-filed WITHOUT --quote clears the quote, the pinned file and the sha" \
  || bad_t "F3 a gate re-filed WITHOUT --quote clears the quote" "quote=[$(col "$R" need_quote)] file=[$(col "$R" need_quote_file)]"

B=$(addt --assignee=dev -- "fixture both")
_o=$( cmd_task_need "$B" --type=approval --ask="x?" --recommend=approve --tier=1 --quote="a" --quote-file="$DRAFT" 2>&1 )
[[ "$(col "$B" need_type)" == "<NULL>" && "$_o" == *"conflicts with"* ]] \
  && ok_t "F4 --quote and --quote-file together are refused before any gate is filed" \
  || bad_t "F4 --quote and --quote-file together are refused" "need_type=$(col "$B" need_type) out=${_o:0:200}"
E=$(addt --assignee=dev -- "fixture empty")
_o=$( cmd_task_need "$E" --type=approval --ask="x?" --recommend=approve --tier=1 --quote="" 2>&1 )
[[ "$(col "$E" need_type)" == "<NULL>" ]] \
  && ok_t "F4b an EMPTY --quote is refused (it is indistinguishable from no quote)" \
  || bad_t "F4b an EMPTY --quote is refused" "out=${_o:0:200}"

# ==================== H: THE HELPER ==========================================
N=$(addt --assignee=dev -- "fixture no quote")
file_gate "$N"
[[ -z "$(_task_gate_quote_block "$N")" ]] \
  && ok_t "H1 a gate with no quote renders no block at all" \
  || bad_t "H1 a gate with no quote renders no block" "got [$(_task_gate_quote_block "$N")]"
_blk=$(_task_gate_quote_block "$F")
[[ "$_blk" == *"│ Thanks for the PR! Acme meets every rule, merging now."* && "$_blk" == *"│ Second line: welcome aboard."* ]] \
  && ok_t "H2 the quote renders verbatim, every line prefixed as a quoted block" \
  || bad_t "H2 the quote renders verbatim, every line prefixed" "got [$_blk]"
_blkf=$(_task_gate_quote_block "$FF")
[[ "$_blkf" == "$_blk" ]] \
  && ok_t "H3 a --quote-file draft with a trailing newline renders identically (no empty quoted line)" \
  || bad_t "H3 a trailing newline renders an extra line" "file:[$_blkf] inline:[$_blk]"
L=$(addt --assignee=dev -- "fixture long")
_long=$(printf 'word %.0s' $(seq 1 200))   # 1000 chars
file_gate "$L" --quote="$_long"
_lb=$(_task_gate_quote_block "$L")
[[ "$_lb" == *"too long for this message"* && "$_lb" != *"word word"* ]] \
  && ok_t "H4 a quote over one phone screen is NOT truncated — the ping says so instead" \
  || bad_t "H4 an over-cap quote is truncated or printed" "got [${_lb:0:200}]"
[[ -z "$(_task_gate_quote_block 999999)" && -z "$(_task_gate_quote_block '')" && -z "$(_task_gate_quote_block 'x;1')" ]] \
  && ok_t "H5 a missing, empty or non-numeric row id renders nothing" \
  || bad_t "H5 a bad row id renders something"

# ==================== W: THE WIRING ==========================================
CAPTURED=""
_task_send_owner() { CAPTURED="$1"; TASK_SEND_DELIVERED=1; TASK_SEND_MESSAGE_IDS="901"; return 0; }
_task_owner_channel() { TASK_CH_TOKEN=stub; TASK_CH_ACCESS=/dev/null; TASK_CH_TYPE=claude; TASK_CH_AGENT=t; return 0; }
_task_gate_preview_channel() { _task_owner_channel; }
deliver() { # <id>
  local ident; ident=$(db "SELECT ident FROM tasks WHERE id=$1;"); age "$1"; CAPTURED=""
  _task_need_notify_deliver "$ident" approval "Post this reply on the public thread?" "" "approve" "" "" "" >/dev/null 2>&1
  printf '%s' "$CAPTURED"
}

# W1: the grader's named control — --quote="X" and X is in the rendered text.
X1=$(addt --assignee=dev -- "fixture X")
file_gate "$X1" --quote="X"
_w1=$(deliver "$X1")
[[ "$_w1" == *"│ X"* ]] \
  && ok_t "W1 a gate filed with --quote=\"X\": the FIRST delivery's text contains X verbatim" \
  || bad_t "W1 the first delivery does not carry the quote" "text: ${_w1:0:400}"
_w=$(deliver "$F")
_ask_pos=$(awk -v s="$_w" 'BEGIN{print index(s, "Post this reply")}')
_q_pos=$(awk -v s="$_w" 'BEGIN{print index(s, "│ Thanks for the PR")}')
_t_pos=$(awk -v s="$_w" 'BEGIN{print index(s, "/task_'"$F"'")}')
(( _ask_pos > 0 && _q_pos > _ask_pos && _t_pos > _q_pos )) \
  && ok_t "W2 placement: ask, then the quoted text, then /task_<n>" \
  || bad_t "W2 placement: ask, then the quoted text, then /task_<n>" "ask@${_ask_pos} quote@${_q_pos} link@${_t_pos}"
_w3=$(deliver "$N")
if [[ "$_w3" == *"Post this reply on the public thread? /task_${N}"* && "$_w3" != *"📝"* && "$_w3" != *"│"* ]]; then
  ok_t "W3 NEGATIVE: with no --quote the ask and /task_<n> share one line and no quote marker appears"
else
  bad_t "W3 NEGATIVE: a no-quote gate changed shape" "text: ${_w3:0:400}"
fi

_IT="$TMP/inbox.txt"
run_batch() { # <ident>
  : >"$_IT"
  (
    require_root() { :; }
    _task_send_owner() { printf '%s' "$1" >"$_IT"; TASK_SEND_DELIVERED=1; TASK_SEND_MESSAGE_IDS="901"; return 0; }
    _task_inbox_send "" "ident=$(sqlq "$1")" "ORDER BY created_at"
  ) >/dev/null 2>&1
  cat "$_IT" 2>/dev/null
}
_b=$(run_batch "$(db "SELECT ident FROM tasks WHERE id=$F;")")
_bq=$(awk -v s="$_b" 'BEGIN{print index(s, "│ Thanks for the PR")}')
_bt=$(awk -v s="$_b" 'BEGIN{print index(s, "/task_'"$F"'")}')
(( _bq > 0 && _bt > _bq )) \
  && ok_t "W4 the /inbox re-send carries the same quote, before /task_<n>" \
  || bad_t "W4 the /inbox re-send does not carry the quote" "text: ${_b:0:400}"
_bn=$(run_batch "$(db "SELECT ident FROM tasks WHERE id=$N;")")
[[ -n "$_bn" && "$_bn" == *"public thread? /task_${N}"* && "$_bn" != *"│"* ]] \
  && ok_t "W5 NEGATIVE: the /inbox re-send of a no-quote gate is unchanged (ask + /task_<n> on one line)" \
  || bad_t "W5 NEGATIVE: the /inbox re-send of a no-quote gate changed" "text: ${_bn:0:400}"

# ==================== S: STALE — what was approved is what posts =============
S=$(addt --assignee=dev -- "fixture stale")
SD="$TMP/stale-draft.md"; printf 'the reply as shown\n' >"$SD"
file_gate "$S" --quote-file="$SD"
_spin=$(col "$S" need_quote_file)
printf 'the reply, edited after the ask\n' >"$_spin"
: >"$AUDIT"
_o=$( cmd_task_answer "$S" --value=approved --human 2>&1 )
[[ "$(col "$S" need_answered_at)" == "<NULL>" && "$_o" == *"edited since"* ]] \
  && ok_t "S1 an APPROVE after the PINNED COPY was edited is refused and the gate stays open" \
  || bad_t "S1 a stale approve was applied" "answered=$(col "$S" need_answered_at) out=${_o:0:300}"
grep -q "gate.approval-stale-quote" "$AUDIT" \
  && ok_t "S2 ...and the refusal is audited as gate.approval-stale-quote" \
  || bad_t "S2 no stale-quote audit row" "$(cat "$AUDIT")"
( cmd_task_answer "$S" --value=denied --human ) >/dev/null 2>&1
[[ "$(col "$S" need_answer)" == "denied" ]] \
  && ok_t "S3 a DENY on the same stale gate still lands (declining is always safe)" \
  || bad_t "S3 a deny on a stale gate was refused" "answer=$(col "$S" need_answer)"
U=$(addt --assignee=dev -- "fixture unchanged")
UD="$TMP/unchanged.md"; printf 'unchanged reply\n' >"$UD"
file_gate "$U" --quote-file="$UD"
( cmd_task_answer "$U" --value=approved --human ) >/dev/null 2>&1
[[ "$(col "$U" need_answer)" == "approved" ]] \
  && ok_t "S4 CONTROL: an approve on an UNCHANGED draft lands normally" \
  || bad_t "S4 an approve on an unchanged draft was refused" "answer=$(col "$U" need_answer)"
# S5 — DIVE-5572's PURPOSE. lodar's Approve on DIVE-5556 was refused because the
# filer's draft sat in its session scratchpad, deleted when the session ended.
G=$(addt --assignee=dev -- "fixture scratchpad gone")
GDIR="$TMP/scratchpad-session"; mkdir -p "$GDIR"; printf 'drafted in a scratchpad\n' >"$GDIR/reply.md"
file_gate "$G" --quote-file="$GDIR/reply.md"
rm -rf "$GDIR"
( cmd_task_answer "$G" --value=approved --human ) >/dev/null 2>&1
[[ "$(col "$G" need_answer)" == "approved" ]] \
  && ok_t "S5 the filer's draft dir is DELETED after filing: the approve still lands (the gate pinned its own copy)" \
  || bad_t "S5 an approve was refused because the filer's draft dir is gone" "answer=$(col "$G" need_answer) file=$(col "$G" need_quote_file)"
GP=$(addt --assignee=dev -- "fixture pinned copy gone")
GPD="$TMP/pinned-gone.md"; printf 'soon gone\n' >"$GPD"
file_gate "$GP" --quote-file="$GPD"
rm -f "$(col "$GP" need_quote_file)"
_o=$( cmd_task_answer "$GP" --value=approved --human 2>&1 )
[[ "$(col "$GP" need_answered_at)" == "<NULL>" ]] \
  && ok_t "S7 the PINNED COPY itself gone still fails closed (cannot show unchanged is not unchanged)" \
  || bad_t "S7 an approve over a deleted pinned copy was applied" "answer=$(col "$GP" need_answer)"
[[ "$_o" == *"is gone from"* && "$_o" != *"edited since"* ]] \
  && ok_t "S8 ...and says the draft is GONE, not that it was edited" \
  || bad_t "S8 a missing pinned copy is reported as edited" "out=${_o:0:300}"
( cmd_task_answer "$X1" --value=approved --human ) >/dev/null 2>&1
[[ "$(col "$X1" need_answer)" == "approved" ]] \
  && ok_t "S6 an inline --quote gate (no pinned file) approves normally" \
  || bad_t "S6 an inline --quote gate could not be approved" "answer=$(col "$X1" need_answer)"

# ==================== D: /task_<n> carries the whole text ====================
_d=$( JSON_MODE=0 cmd_task_show "$L" 2>/dev/null )
[[ "$_d" == *"quote (the exact text being approved):"* && "$_d" == *"$_long"* ]] \
  && ok_t "D1 task show (/task_<n>) prints the whole quote the over-cap ping points to" \
  || bad_t "D1 task show does not print the quote" "$(printf '%s' "$_d" | grep -n quote | head -3)"
_dn=$( JSON_MODE=0 cmd_task_show "$N" 2>/dev/null )
[[ -n "$_dn" && "$_dn" != *"quote (the exact"* && "$_dn" != *"quote pinned"* ]] \
  && ok_t "D2 NEGATIVE: task show of a no-quote gate prints no quote line" \
  || bad_t "D2 task show of a no-quote gate changed" "$(printf '%s' "$_dn" | grep -n quote | head -3)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
