#!/usr/bin/env bash
# DIVE-4424 — A GATE INSIDE ITS LEAD-REVIEW HOLD IS MARKED, NOT COUNTED.
#
# THE REPORT. lodar, Telegram 2026-09-13, on exact-swallow running 0.36.0: "you
# hold a human gate for 30 minutes for review before pinging a human but it still
# activates human inbox in telegram. is it a bug or feature". Both — shipped as
# designed (DIVE-4365 part 2 holds the PUSH and nothing else, and says so in its
# own comment), and the design is wrong for the phone: every listing surface still
# rendered the held gate as "needs you", which on a phone is indistinguishable
# from the ping that was deliberately withheld.
#
# WHAT THIS FILE GRADES, and the distinction it must not blur: that the gate is
# still LIVE and still ANSWERABLE during the hold (nothing here may hide one),
# while being LABELLED with its holder and EXCLUDED from the needs-you count.
# "Absent" and "present but marked" are different outcomes and only one is the
# fix — so every listing arm asserts BOTH directions, never just the count.
#
# TELEGRAM ABSENT, on purpose: the gate rail's safety property is that a human can
# see and clear a gate from the box with no bot, no token and no network
# (tests/gate_parity_smoke.sh's premise). The digest arm is therefore a SOURCE
# arm — see its comment for why that is the honest form here and not a dodge.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.."
: "${FIVEDIVE_TEST:=1}"; export FIVEDIVE_TEST
CLI="${CLI:-./5dive}"
TMP=$(mktemp -d)
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
export STATE_DIR="$TMP"
export TASKS_DIR="$TMP/tasks"
export TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID FIVEDIVE_TELEGRAM_TOKEN 2>/dev/null || true
export TELEGRAM_BOT_TOKEN="" TELEGRAM_CHAT_ID=""

fails=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }
has() { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
# EVERY STORE READ AND WRITE IN THIS FILE WAITS ON A BUSY LOCK, exactly as the
# product's own `db()` does (src/lib/tasks_db.sh: `sqlite3 -cmd ".timeout 5000"`).
# DIVE-4461, and it is this harness's own fixture that creates the contention:
# `mkgate` shortens the gate hold to 1 SECOND, and the deliverer forks a DETACHED
# child per gate that sleeps that window and then WRITES (notify.sh — the still-
# live check, then a `gate_delivery_log` row; the send itself is refused in a
# fixture store, the write is not). Three gates, three children, all waking about
# a second in — which is the middle of the fixture block below. Every `$CLI` call
# here survives that because it goes through `db()`; a BARE `sqlite3` does not.
# It fails INSTANTLY with rc 5 and, under `set -e`, kills the run in `prepare`
# before a single arm is graded — twice on 2026-09-13, once from inside a merge
# group, where it ejected a graded-PASS PR that no author can re-run (DIVE-4461).
# A re-run cleared the symptom both times, which is what a missing busy_timeout
# looks like from the outside: green on an idle box, red under a loaded runner.
sq()  { sqlite3 -cmd ".timeout 5000" "$TASKS_DB" "$1"; }

# Fixture seats. Reserved fakes only — never a real identifier.
FILER="holdprobe-maker"
LEAD="holdprobe-lead"

# THE HOLD IS SHORTENED WHILE FILING, AND RESTORED BEFORE ANYTHING IS GRADED.
# `task need` forks a detached child that sleeps the whole window; at the real
# 1800s a bare run of this harness would leave three half-hour sleepers behind on
# the box. The override may only ever SHORTEN (the clamp in notify.sh — an
# unclamped one would be a write path to a sealed constant), so 1s is legal and
# 3000s would silently be ignored. It is unset again immediately: every assertion
# below must grade the SHIPPED window, not the harness's.
mkgate() { # <title> <extra task-need flags...>
  local title="$1"; shift
  $CLI task add "$title" --assignee="$FILER" >/dev/null
  local id; id=$(sq "SELECT ident FROM tasks WHERE title=$(printf "'%s'" "${title//\'/\'\'}");")
  [[ -n "$id" ]] || { bad "fixture: could not add '$title'"; return 1; }
  ( export _5DIVE_GATE_UNDO_WINDOW_SECS=1
    $CLI task need "$id" --type=manual --tier=2 --ask="$title: a person must do this by hand" "$@" ) >/dev/null 2>&1 || true
  printf '%s' "$id"
}
# Put a filed gate back into the exact state the deliverer leaves it in at t=0:
# never pinged, asked $1 seconds ago. Both columns, because the predicate reads
# both and a fixture that sets only one grades half the rule.
asked_ago() { sq "UPDATE tasks SET gate_pinged_at=NULL, need_asked_at=datetime('now','-$2 seconds') WHERE ident='$1';"; }

HELD=$(mkgate "lead hold fixture HELD") || true
PAST=$(mkgate "lead hold fixture PAST") || true
URG=$(mkgate  "lead hold fixture URGENT" --urgent) || true
[[ -n "${HELD:-}" && -n "${PAST:-}" && -n "${URG:-}" ]] || { bad "fixture rows missing"; echo "-----"; exit 1; }
# The org edge that makes a lead RESOLVE. Written AFTER the first task command,
# never before: `agents_org` is created by tasks_db_init, so an insert on a store
# no command has touched yet fails with "no such table" and the naming arms then
# grade the empty-lead fallback instead of a named seat. `org set` is the normal
# path and requires root, which a unit harness does not hold.
sq "INSERT OR REPLACE INTO agents_org (name, reports_to) VALUES ('$LEAD',NULL);"
sq "INSERT OR REPLACE INTO agents_org (name, reports_to) VALUES ('$FILER','$LEAD');"
[[ "$(sq "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name='$FILER';")" == "$LEAD" ]] \
  && ok "fixture: the org edge resolves a lead for the filer (the naming arms are not vacuous)" \
  || bad "fixture: no org edge — the lead will not resolve and the naming arms are vacuous"
# THE WAIT IS GRADED, not assumed. A later edit that drops the `.timeout` on `sq`
# would restore the DIVE-4461 flake, and a flake is invisible on an idle box — so
# the contention is MADE here, in the same block that used to die of it. A second
# connection holds the store's write lock for 0.6s (`BEGIN IMMEDIATE` on stdin,
# which sqlite3 keeps open while it waits for the next line — no sleeper process
# and no second language); `sq` must still land its write. The `if` is what makes
# this a graded FAIL rather than a second copy of the crash: a bare `sq` inside a
# condition is exempt from `set -e`, so removing the timeout reds this one arm and
# still runs the other thirty. Measured as the control — `sq` reverted to bare,
# nothing else touched: FAILED: 1, this arm, every other arm green.
{ printf 'BEGIN IMMEDIATE;\n'; sleep 0.6; printf 'ROLLBACK;\n'; } | sqlite3 "$TASKS_DB" >/dev/null 2>&1 &
_busyholder=$!
sleep 0.15
if sq "UPDATE tasks SET ident=ident WHERE ident='$HELD';" 2>/dev/null; then
  ok "fixture: a write lands while another connection holds the store — sq waits on BUSY (DIVE-4461)"
else
  bad "fixture: sq lost a write to a busy lock — the busy_timeout is gone and this file will abort under a loaded runner again"
fi
wait "$_busyholder" 2>/dev/null || true

asked_ago "$HELD" 60      # (a) one minute old — deep inside the 30-minute hold
asked_ago "$PAST" 7200    # (b) two hours old — long past it
asked_ago "$URG"  60      # (c) one minute old, but the filer said it cannot wait
# `--urgent` must actually have landed, or arm (c) grades nothing.
[[ "$(sq "SELECT COALESCE(gate_urgent,0) FROM tasks WHERE ident='$URG';")" == "1" ]] \
  && ok "fixture: the urgent row carries gate_urgent=1 (arm c is not vacuous)" \
  || bad "fixture: --urgent did not set gate_urgent — arm (c) would pass on a non-urgent row"

BOX=$($CLI task inbox 2>/dev/null || true)
J=$($CLI task inbox --json 2>/dev/null || true)
jn() { printf '%s' "$J" | jq -r "$1" 2>/dev/null || printf ''; }

# ── (a) a held gate: marked, present, and NOT counted ────────────────────────
has "$HELD" "$BOX" \
  && ok "(a) the held gate is still LISTED — marking, not hiding" \
  || bad "(a) the held gate vanished from 'task inbox'; the rejected alternative shipped"
has "with $LEAD until" "$BOX" \
  && ok "(a) it is rendered 'with $LEAD until hh:mm' and names the holder" \
  || bad "(a) no 'with <lead> until' marker: $(printf '%s' "$BOX" | tr '\n' '|')"
has "yours if unanswered" "$BOX" \
  && ok "(a) the marker says the gate still becomes the human's" \
  || bad "(a) the marker does not say the gate returns to the human"
# `data.inbox` KEEPS ITS MEANING. Lifting held rows out of it would fix every
# badge for free and is the JSON form of hiding — a consumer that under-reports
# without an error, and a gate that vanishes for half an hour and returns.
[[ "$(jn '[.data.inbox[].ident]|index("'"$HELD"'")')" != "null" ]] \
  && ok "(a) it is STILL in data.inbox — the exported array was not silently re-scoped" \
  || bad "(a) the held gate was lifted out of data.inbox; every consumer of that array now under-reports"
[[ "$(jn '.data.inbox[]|select(.ident=="'"$HELD"'")|.lead_hold.lead')" == "$LEAD" ]] \
  && ok "(a) the row itself carries lead_hold.lead — marked in place" \
  || bad "(a) the row carries no lead_hold.lead"
[[ -n "$(jn '.data.inbox[]|select(.ident=="'"$HELD"'")|.lead_hold.until')" ]] \
  && ok "(a) lead_hold.until is a machine-readable instant, not only the hh:mm a person reads" \
  || bad "(a) lead_hold has no until"
[[ "$(jn '[.data.lead_hold[].ident]|index("'"$HELD"'")')" != "null" ]] \
  && ok "(a) data.lead_hold is the held subset, for a renderer that wants only those" \
  || bad "(a) data.lead_hold does not contain the held gate"
# THE COUNT — the half of the report a marker alone does not fix.
NY=$(jn '.data.needs_you'); NI=$(jn '.data.inbox|length')
[[ "$NY" =~ ^[0-9]+$ && "$NI" =~ ^[0-9]+$ && "$NY" -lt "$NI" ]] \
  && ok "(a) data.needs_you ($NY) excludes the held gate while data.inbox still holds it ($NI)" \
  || bad "(a) needs_you ($NY) does not exclude the held gate from the badge count (inbox=$NI)"

# ── (b) past the hold: back to plain 'needs you' ─────────────────────────────
[[ "$(jn '.data.inbox[]|select(.ident=="'"$PAST"'")|has("lead_hold")')" == "false" ]] \
  && ok "(b) a gate past its hold carries NO lead_hold — it needs you" \
  || bad "(b) a gate past its hold is still marked as held"
[[ "$(jn '[.data.lead_hold[].ident]|index("'"$PAST"'")')" == "null" ]] \
  && ok "(b) and it is not in the held subset" \
  || bad "(b) a gate past its hold is still in data.lead_hold"
if grep -q "^.*${PAST}.*with ${LEAD} until" <<<"$BOX"; then
  bad "(b) a gate past its hold still carries the hold marker"
else
  ok "(b) no hold marker on a gate past its hold"
fi

# ── (c) urgent skips the hold, exactly as the ping does ──────────────────────
[[ "$(jn '.data.inbox[]|select(.ident=="'"$URG"'")|has("lead_hold")')" == "false" ]] \
  && ok "(c) an URGENT tier-2 gate needs you at once — the marking skips where the ping skips" \
  || bad "(c) an urgent gate was marked as held; the filer's explicit urgency was ignored"

# ── (d) the LEAD's own queue lists it as theirs ──────────────────────────────
# Before this row the held gate appeared in NO agent listing: the human's inbox
# claimed it and the lead's queue stopped at tier < 2, so the seat the review was
# handed to was never told. That is the half of the defect a count fix alone
# leaves behind.
LQ=$($CLI task queue --for="$LEAD" 2>/dev/null || true)
has "$HELD" "$LQ" \
  && ok "(d) 'task queue --for=$LEAD' lists the held gate — the reviewer can find its own review" \
  || bad "(d) the lead's queue does not list the gate held for it: $(printf '%s' "$LQ" | tr '\n' '|')"
has "$PAST" "$LQ" \
  && bad "(d) a tier-2 gate PAST its hold leaked into the lead's queue — the tier bound must return once the ping has fired" \
  || ok "(d) a tier-2 gate past its hold is not in the lead's queue (the tier bound is suspended by the hold only)"

# ── (e) the hold changes WHO READS IT FIRST, never who may clear it ──────────
# The clear itself cannot be exercised here and saying why matters more than the
# arm: a `manual` tier-2 gate is answerable only by a HUMAN — from Telegram or the
# dashboard, both refused to an agent principal by `task answer`'s standing check,
# which is the correct behaviour and predates this row. So the property graded is
# the one this change could actually have broken: that the answer path treats a
# HELD gate and an unheld one IDENTICALLY. Same refusal, same exit code, on two
# rows differing only in whether they are inside the hold.
# THE SIGNED-CLEAR PATH IS STUBBED, AND ITERATION 1 IS WHY. `task answer` reaches
# for a delegated signer first (src/task/answer.sh, `_task_answer_try_delegated`:
# `sudo -n /usr/local/bin/5dive _task_answer`), so on a seat that HOLDS the sudo
# grant the two invocations below go one way and on a seat without it they go
# another, and quinn's box — which holds none — produced a `warn: the signed clear
# (_task_answer) refused` in one message and not the other. An arm whose colour is
# a property of who ran it is not evidence about the diff, so the external is
# pinned the way every other external here is: a `sudo` that always refuses,
# ahead on PATH. That is also CI's environment and the strictest of the two, and
# it makes the comparison below mean what it says on every seat.
mkdir -p "$TMP/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo "sudo: a password is required" >&2' 'exit 1' > "$TMP/bin/sudo"
chmod +x "$TMP/bin/sudo"
# `command -v` reads bash's own hash table, which already holds the real sudo, so
# the check is made in a fresh shell — the same lookup the CLI's own child does.
[[ "$(PATH="$TMP/bin:$PATH" bash -c 'command -v sudo')" == "$TMP/bin/sudo" ]] \
  && ok "(e) fixture: the signed-clear external is stubbed, so this arm grades the tree and not the seat" \
  || bad "(e) fixture: the sudo stub is not ahead on PATH — arm (e) would grade the seat's sudo grant"
# `rc=$?` on the line AFTER an assignment is dead under `set -e` — the assignment
# itself is the failing command and the harness is killed before it reads $?.
ea=""; rca=0; eb=""; rcb=0
ea=$(PATH="$TMP/bin:$PATH" $CLI task answer "$HELD" --value="done by hand" 2>&1) || rca=$?
eb=$(PATH="$TMP/bin:$PATH" $CLI task answer "$PAST" --value="done by hand" 2>&1) || rcb=$?
[[ "$rca" == "$rcb" ]] \
  && ok "(e) 'task answer' returns the same exit code on a held gate as on an unheld one ($rca)" \
  || bad "(e) 'task answer' exits $rca on a held gate and $rcb on an unheld one — the hold reached the clear path"
# THE FULL-MESSAGE EQUALITY IS GONE ON PURPOSE, and the stub above is not the
# only reason. `task answer`'s output carries lines from the ENVIRONMENT as well
# as from the answer path — a sudo refusal, a first-use lecture, a delegation
# warning — and quinn's rejection is what a byte-for-byte comparison of those two
# transcripts is worth: it fired on a channel this diff does not own. What this
# arm means is narrower and is asserted directly: whatever the answer path says,
# it must not say it DIFFERENTLY because the gate is held, and it must never
# mention the hold at all. Same exit code above; no reference to the hold here.
for _m in "$ea" "$eb"; do
  if grep -qiE 'lead[- ]?hold|with .* until|yours if unanswered' <<<"$_m"; then
    bad "(e) 'task answer' mentions the lead hold to the person clearing the gate: $(printf '%s' "$_m" | grep -iE 'lead[- ]?hold|with .* until|yours if unanswered' | head -1)"
  else
    ok "(e) 'task answer' says nothing about the hold — it decides reading order, never standing"
  fi
done
# The answer path must not learn the hold exists at all.
if grep -nE '_task_gate_in_lead_hold|_task_gate_lead_hold' src/task/answer.sh >/dev/null 2>&1; then
  bad "(e) the answer path references the lead hold — the hold must decide reading order, never standing"
else
  ok "(e) the answer path carries no reference to the hold"
fi
# And an ANSWERED gate stops being held rather than lingering marked. Stamped
# directly, which is exactly what a human's tap lands on this row.
sq "UPDATE tasks SET need_answer='done by hand', need_answered_at=datetime('now'), need_answered_by='$LEAD' WHERE ident='$HELD';"
[[ "$($CLI task inbox --json 2>/dev/null | jq -r '[.data.lead_hold[].ident]|index("'"$HELD"'")' 2>/dev/null)" == "null" ]] \
  && ok "(e) once answered it leaves lead_hold — the predicate reads the live gate, not a stale flag" \
  || bad "(e) an ANSWERED gate is still reported as held"

# ── (f) tier 1 is not a lead review ─────────────────────────────────────────
# A tier-1 gate's DIVE-4154 window is a FILER's undo window and rings nobody's
# phone; treating it as a lead review would mark rows no human was ever shown.
T1=$($CLI task add "lead hold fixture TIER1" --assignee="$FILER" >/dev/null; sq "SELECT ident FROM tasks WHERE title='lead hold fixture TIER1';")
( export _5DIVE_GATE_UNDO_WINDOW_SECS=1
  $CLI task need "$T1" --type=approval --tier=1 --ask="lead hold fixture: approve this" --recommend="yes" ) >/dev/null 2>&1 || true
asked_ago "$T1" 60
[[ "$(sq "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$T1';")" == "1" ]] \
  && ok "fixture: the tier-1 row really is tier 1 (arm f is not vacuous)" \
  || bad "fixture: the tier-1 row is not tier 1 — arm (f) grades nothing"
J2=$($CLI task inbox --json 2>/dev/null || true)
[[ "$(printf '%s' "$J2" | jq -r '[.data.lead_hold[].ident]|index("'"$T1"'")' 2>/dev/null)" == "null" ]] \
  && ok "(f) a tier-1 gate is never reported as lead-held" \
  || bad "(f) a tier-1 gate was marked as held by a lead"

# ── (g) ONE wording, and the digest shares it ────────────────────────────────
# A SOURCE arm, and the honest form here rather than a dodge: the digest sends
# over Telegram, and this file's premise (and the parity smoke's) is that the rail
# is graded with Telegram ABSENT. What can be graded without a bot is the property
# that actually failed — three surfaces drifting into three wordings — and that is
# a call-site claim, not a network one. The behavioural half of the same claim is
# arm (a), which reads the rendered box.
for fn in cmd_task_inbox _task_inbox_send; do
  BODY=$(sed -n "/^${fn}()/,/^}/p" src/task/inbox.sh)
  [[ -n "$BODY" ]] || { bad "(g) $fn not found in src/task/inbox.sh (renamed?)"; continue; }
  grep -q '_task_gate_lead_hold_line' <<<"$BODY" \
    && ok "(g) $fn renders the held line by CALLING the shared renderer" \
    || bad "(g) $fn does not call _task_gate_lead_hold_line — a second wording of the hold"
done
# And no renderer restates the RULE. The hold is bash (a sealed constant, a kill
# switch, a clamped override, two urgency skips); a SQL copy of it in a listing is
# the DIVE-3171 two-copies shape the predicates at the top of inbox.sh refuse.
if grep -nE '_GATE_LEAD_REVIEW_HOLD_SECS|-31 minutes|-30 minutes' src/task/inbox.sh >/dev/null 2>&1; then
  bad "(g) src/task/inbox.sh restates the hold window instead of calling the predicate"
else
  ok "(g) no listing surface restates the hold window — they filter on idents the predicate chose"
fi

# ── (h) THE KEYBOARD-LESS VARIANT CARRIES THE HOLD LINE TOO ─────────────────
# DIVE-4412 (#927) landed `gate_text_plain` in this same loop while this branch
# was open: _mirror_post re-sends a gate as PLAIN TEXT when the Bot API rejects
# the keyboard, and that variant is composed separately. The merge of the two
# changes is a DECISION, not a mechanical resolution — a hold line appended only
# to `gate_text` would leave the fallback delivery path saying "needs you" about a
# gate the lead is still holding, which is precisely the lie this row removes,
# surviving on the one path #927 exists to fix. This arm pins the resolution so
# the two changes cannot silently un-integrate on a later rebase.
# SOURCE arm for arm (g)'s reason and one more: the send is refused outright in a
# fixture store by DIVE-1506's fail-closed chokepoint, so no assertion here can
# read a delivered message however the transport is stubbed.
BODY=$(sed -n "/^_task_inbox_send()/,/^}/p" src/task/inbox.sh)
if [[ -z "$BODY" ]]; then
  bad "(h) _task_inbox_send not found in src/task/inbox.sh (renamed?)"
else
  grep -q 'gate_text_plain="\$gate_text"' <<<"$BODY" \
    && ok "(h) the keyboard-less variant from DIVE-4412 is still composed here" \
    || bad "(h) gate_text_plain is gone from _task_inbox_send — #927's fallback variant was dropped in a merge"
  HOLDBLK=$(printf '%s' "$BODY" | sed -n '/_task_gate_lead_hold_line/,/^    fi$/p')
  grep -q 'gate_text+=' <<<"$HOLDBLK" \
    && ok "(h) the hold line is appended to the keyboard variant" \
    || bad "(h) the hold line never reaches gate_text — the ordinary gate message lost its marking"
  grep -q 'gate_text_plain+=' <<<"$HOLDBLK" \
    && ok "(h) and to the keyboard-less variant — a rejected keyboard cannot strip the marking" \
    || bad "(h) the hold line is appended to gate_text only: a human whose keyboard was rejected still reads the held gate as 'needs you' (DIVE-4412's fallback path)"
fi

echo "-----"
if (( fails )); then echo "FAILED: $fails"; exit 1; fi
echo "all lead-hold marking arms pass"
