#!/usr/bin/env bash
# DIVE-3173: `5dive self-update` restarted every running agent unit with NO idle
# predicate. DIVE-3172 made the restart conditional on the payload actually
# moving, which zeroes out CLI-only nights; this harness grades the OTHER half —
# the nights when the payload genuinely moved and someone is mid-task.
#
# Two ways this fix can be wrong, and they fail in opposite directions:
#
#   KILLS WORK    — the predicate reads a busy agent as free and restarts it
#                   mid-turn. That is the original bug, so every uncertain
#                   reading (unreadable board, unreadable stamp, unreadable pane)
#                   must take the SAME branch as "busy".
#   NEVER FIRES   — the restart is deferred and then forgotten, and the agent
#                   runs on the old payload indefinitely. The ticket calls this
#                   the worse bug of the two: a plugin fix ships and never loads,
#                   silently. So the deferral must be a durable RECORD swept by
#                   an unconditional caller, not a conditional that only skips.
#
# Hermetic in the shape DIVE-2042/DIVE-3172 established: the block is extracted
# VERBATIM from src/cmd_selfupdate.sh between its fence markers and run as the
# SHIPPED BYTES against temp directories. No systemd, no board, no agent is
# touched — `systemctl`/`db`/`sqlq`/`_hb_agent_idle` are stubbed per arm, which
# is also what lets the positive control (criterion 3) reach a verdict inside
# this session instead of waiting on a nightly cron
# ([[a-criterion-only-a-cron-can-satisfy-has-no-verdict-yet]]).
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NO `2>/dev/null` — the helper's
# stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

block="$(sed -n '/^# >>> DIVE-3173 deferred restart for a busy agent/,/^# <<< DIVE-3173 deferred restart for a busy agent/p' \
  src/cmd_selfupdate.sh)"
if [[ -n "$block" ]] && grep -q '_pending_restart_decide()' <<<"$block" \
   && grep -q '_pending_restart_sweep()' <<<"$block" \
   && grep -q '_agent_busy_state()' <<<"$block"; then
  ok_t "deferral block is extractable from src/cmd_selfupdate.sh"
else
  bad_t "deferral block missing" "markers '# >>> / # <<< DIVE-3173 deferred restart for a busy agent' not found"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

WORK="$(mktemp -d)"; export PENDING_RESTART_DIR="$WORK/pending"

# ---------------------------------------------------------------- decision arms
# The decision is a pure function of four readings, so it is graded directly.
# `rd <marked> <started> <busy> <now> <maxdefer>` echoes the verdict.
rd() { ( eval "$block"; _pending_restart_decide "$@" ); }

NOW=1000000
if [[ "$(rd 500 0 busy "$NOW" 0)" == defer ]]; then
  ok_t "DEFER: the agent holds an in_progress row — this is the whole ticket"
else
  bad_t "a busy agent was not deferred" "verdict was '$(rd 500 0 busy "$NOW" 0)' — this is the KILLS WORK failure"
fi
if [[ "$(rd 500 0 unknown "$NOW" 0)" == defer ]]; then
  ok_t "DEFER: an unreadable board takes the same branch as busy (not knowing != free)"
else
  bad_t "an unreadable board was treated as idle" "unknown must never fold into idle — KILLS WORK"
fi
if [[ "$(rd 500 0 idle "$NOW" 0)" == fire ]]; then
  ok_t "FIRE: the row left in_progress — the restart is taken at the boundary"
else
  bad_t "an idle agent was not restarted" "the NEVER FIRES failure: the deferral would be permanent"
fi
# Cleared by observation: any restart later than the mark already loaded the new
# payload (operator bounce, crash restart, plugin /restart).
if [[ "$(rd 500 900 busy "$NOW" 0)" == already-bounced ]]; then
  ok_t "ALREADY-BOUNCED: a unit that came up after the mark has the payload, busy or not"
else
  bad_t "a restarted unit stayed marked" "the marker would fire a second, pointless bounce"
fi
if [[ "$(rd 500 400 idle "$NOW" 0)" == fire ]]; then
  ok_t "a unit start BEFORE the mark does not satisfy it (ordering is read, not presence)"
else
  bad_t "an older unit start cleared the marker" "the payload update would be dropped silently"
fi
if [[ "$(rd 0 900 idle "$NOW" 0)" == fire ]]; then
  ok_t "marked_at=0 (unstamped) is never 'already bounced'"
else
  bad_t "an unstamped marker was cleared by any unit start" "NEVER FIRES, silently"
fi
# The ceiling SURFACES a stuck deferral; it must not force the restart, because
# forcing is the bug the row exists to remove.
if [[ "$(rd 500 0 busy $((500 + 24*3600)) $((24*3600)))" == overdue ]]; then
  ok_t "OVERDUE: a deferral past the ceiling is called out (still not forced)"
else
  bad_t "a day-old deferral stayed silent" "'deferred forever' must not be indistinguishable from 'done'"
fi
if [[ "$(rd 500 0 busy $((500 + 24*3600)) $((24*3600)))" != fire ]]; then
  ok_t "OVERDUE does not restart a busy agent — the ceiling is loud, not lethal"
else
  bad_t "the ceiling forced a restart on a busy agent" "this reintroduces the exact bug DIVE-3173 fixes"
fi

# ------------------------------------------------------------------ marker arms
mk() { ( eval "$block"; _pending_restart_mark "$@" ); }
at() { ( eval "$block"; _pending_restart_marked_at "$@" ); }

if mk alice "payload changed" && [[ -f "$PENDING_RESTART_DIR/alice" ]] \
   && [[ "$(at alice)" =~ ^[0-9]+$ ]] \
   && [[ "$( ( eval "$block"; _pending_restart_reason alice ) )" == "payload changed" ]]; then
  ok_t "the marker is a durable FILE carrying the stamp and the reason"
else
  bad_t "marker not written or unreadable" "a conditional that cannot outlive the process cannot defer anything"
fi
# A corrupt stamp must read as "marked now", never as 0 — with 0, any unit start
# looks later and the decision returns already-bounced, dropping the restart.
printf 'marked_at=garbage\nreason=x\n' > "$PENDING_RESTART_DIR/bob"
_bob="$(at bob)"
if [[ "$_bob" =~ ^[0-9]+$ ]] && (( _bob > 1000000000 )); then
  ok_t "a corrupt stamp reads as 'marked now', not as 0 (fails toward keeping the debt)"
else
  bad_t "a corrupt stamp read as '$_bob'" "0 would let any unit start clear the marker — NEVER FIRES"
fi
if [[ "$(at nosuchagent 2>/dev/null; echo "rc=$?")" == "rc=1" ]]; then
  ok_t "an absent marker is a non-zero read, not an empty success"
else
  bad_t "an absent marker did not fail" "the sweep would process agents that owe nothing"
fi

# ------------------------------------------------------------ busy-state arms
# `db`/`sqlq` absent => unknown. This is the shape the block runs in when it is
# reached from a context that never initialised the task store.
bs() { ( eval "$1"; eval "$block"; _agent_busy_state "${2:-x}" ); }
if [[ "$(bs ':' alice)" == unknown ]]; then
  ok_t "no task store reachable => unknown (which defers), never idle"
else
  bad_t "a missing task store did not read as unknown" "KILLS WORK on any box where the store is unreachable"
fi
if [[ "$(bs 'db(){ echo 2; }; sqlq(){ printf "%s" "$1"; }' alice)" == busy ]]; then
  ok_t "a row in in_progress reads busy"
else
  bad_t "an in_progress row did not read busy" "the predicate is inverted"
fi
if [[ "$(bs 'db(){ echo 0; }; sqlq(){ printf "%s" "$1"; }' alice)" == idle ]]; then
  ok_t "zero in_progress rows reads idle"
else
  bad_t "an agent with no open row did not read idle" "NEVER FIRES: nothing would ever be restarted"
fi
if [[ "$(bs 'db(){ return 1; }; sqlq(){ printf "%s" "$1"; }' alice)" == unknown ]]; then
  ok_t "a failing query reads unknown, not idle"
else
  bad_t "a failing query did not read unknown" "KILLS WORK whenever the board errors"
fi
if [[ "$(bs 'db(){ echo "Error: no such table"; }; sqlq(){ printf "%s" "$1"; }' alice)" == unknown ]]; then
  ok_t "a non-numeric answer reads unknown, not idle"
else
  bad_t "a non-numeric answer did not read unknown" "KILLS WORK on a pre-migration board"
fi
# The query must be scoped to in_progress ONLY. A predicate that also counted
# `todo` would defer every agent with a queue forever — a permanent deferral
# wearing the shape of a fix.
if grep -q "status='in_progress'" <<<"$block" && ! grep -q "'todo'" <<<"$block"; then
  ok_t "the busy query is scoped to in_progress alone (a queued todo is not busy)"
else
  bad_t "the busy query is not scoped to in_progress" "counting todo defers every agent with a backlog, forever"
fi

# ------------------------------------------- the SESSION half of busy --------
# THE BOARD IS NOT THE SESSION. `_agent_busy_state` used to be only the board,
# so a seat mid-turn on chat-driven work and holding NO row — the normal shape
# for a Telegram-paired seat — answered `idle` and the nightly update restarted
# it mid-turn. The live reading is the one the heartbeat already trusts before
# every reclaim (`_hb_agent_native_state`: claude agents --json as the seat ->
# busy | idle | blocked:<why>, rc 1 when it cannot tell).
#
# `bsn <db-stub> <native-stub>` composes the two readings independently, which is
# the whole point: the defect lives in the cell where the board says idle and the
# session says busy, and only an independent cross can construct it.
BOARD_IDLE='db(){ echo 0; }; sqlq(){ printf "%s" "$1"; }'
BOARD_BUSY='db(){ echo 3; }; sqlq(){ printf "%s" "$1"; }'
bsn() { ( eval "$1"; eval "$2"; eval "$block"; _agent_busy_state "${3:-alice}" ); }

if [[ "$(bsn "$BOARD_IDLE" '_hb_agent_native_state(){ printf busy; }')" == busy ]]; then
  ok_t "THE DEFECT'S CELL: board idle + session BUSY reads busy — a seat mid-turn with nothing claimed is no longer restarted"
else
  bad_t "a mid-turn seat with no claimed row still read idle" \
        "got '$(bsn "$BOARD_IDLE" '_hb_agent_native_state(){ printf busy; }')' — KILLS WORK, and it is the shape every chat-driven seat has"
fi
if [[ "$(bsn "$BOARD_IDLE" '_hb_agent_native_state(){ printf "blocked:permission prompt"; }')" == busy ]]; then
  ok_t "blocked:* is busy too — a seat waiting on a prompt has a live turn behind it"
else
  bad_t "a blocked session read idle" "a permission prompt is not a task boundary"
fi
if [[ "$(bsn "$BOARD_IDLE" '_hb_agent_native_state(){ printf idle; }')" == idle ]]; then
  ok_t "board idle + session idle is still idle — NEVER FIRES stays closed, the restart is taken"
else
  bad_t "an idle seat was not restartable" "nothing would ever be bounced onto a new payload"
fi
# rc 1 is "no reading", and it must change NOTHING: a non-claude runtime, a
# `claude` too old for `agents --json`, or a split tree where the helper is not
# loaded all have to behave exactly as before this change.
if [[ "$(bsn "$BOARD_IDLE" '_hb_agent_native_state(){ return 1; }')" == idle ]]; then
  ok_t "an UNAVAILABLE session signal (rc 1) leaves the board's answer alone"
else
  bad_t "an unavailable signal changed the verdict" "every non-claude seat would stop taking payload updates"
fi
if [[ "$(bsn "$BOARD_IDLE" ':')" == idle ]]; then
  ok_t "the helper ABSENT entirely behaves as before — the guard is declare -F, not a call into the void"
else
  bad_t "an absent helper changed behaviour" "a missing function must not be a silent policy change"
fi
# An unreadable BOARD is not upgraded by a session reading: the two answer
# different questions, and `unknown` already defers.
if [[ "$(bsn 'db(){ return 1; }; sqlq(){ printf "%s" "$1"; }' '_hb_agent_native_state(){ printf idle; }')" == unknown ]]; then
  ok_t "an unreadable board stays UNKNOWN even when the session says idle — three values stay three"
else
  bad_t "unknown was folded into idle by the session reading" "KILLS WORK whenever the board errors"
fi
# A board that says busy must not pay for a shell-out to confirm a deferral it
# already decided. Recorded as a file because "was it called" is not inferable.
NATIVE_CALLS="$WORK/native.calls"; : >"$NATIVE_CALLS"
if [[ "$(bsn "$BOARD_BUSY" '_hb_agent_native_state(){ printf 1 >>"$NATIVE_CALLS"; printf idle; }')" == busy ]] \
   && [[ ! -s "$NATIVE_CALLS" ]]; then
  ok_t "a BUSY board short-circuits: the session is never asked, so no sudo/exec is spent on a settled answer"
else
  bad_t "the busy board still called the native probe" "calls=[$(cat "$NATIVE_CALLS" 2>/dev/null)]"
fi

# MUTANT: drop the native case and the defect's cell reads idle again.
mut_block="$(printf '%s\n' "$block" | sed '/busy|blocked:\*) printf .busy/d')"
if [[ "$mut_block" != "$block" ]]; then
  ok_t "MUTANT: the native case is removable from the shipped block, so the strike-out below is real"
else
  bad_t "the mutation is a no-op" "the arm below would pass vacuously"
fi
mut_state="$( eval "$BOARD_IDLE"; _hb_agent_native_state(){ printf busy; }; eval "$mut_block"; _agent_busy_state alice )"
if [[ "$mut_state" == idle ]]; then
  ok_t "MUTANT: without the native case, board idle + session busy reads 'idle' again — the restart-mid-turn defect, live"
else
  bad_t "mutant must reproduce the defect" "got '$mut_state' — the arms above are vacuous"
fi

# THE HOST-PRISTINE CONTROL. CI has no /usr/local/bin/5dive, no /etc/5dive, no
# /var/lib/5dive and no sudo grant, so a predicate short-circuiting on one of
# those passes at a desk and reds on the runner. Asserted as a property of the
# shipped block rather than assumed.
if grep -qE '/usr/local/bin|/etc/5dive|/var/lib/5dive' <<<"$(sed -n '/^_agent_busy_state()/,/^}/p' src/cmd_selfupdate.sh)"; then
  bad_t "_agent_busy_state names an absolute host path" "it would short-circuit on the runner, where none of them exist"
else
  ok_t "_agent_busy_state reads no absolute host path — nothing in it can short-circuit on what CI does not install"
fi

# ------------------------------- POSITIVE CONTROL (acceptance criterion 3) -----
# One agent, one marker, three sweeps: parked mid-task -> NOT restarted; row
# closed -> restarted; then the marker is gone so it is not restarted twice.
# `systemctl`/`db`/`sqlq`/`_hb_agent_idle` are stubs; RESTARTS is the ledger.
sweep_with() { # <busy-count> <idle-rc> [unit-active:yes|no]
  # NOT named `n`: bash functions are dynamically scoped, and `_agent_busy_state`
  # declares its own `local n` before calling `db` — a stub reading `$n` would read
  # the CALLEE's empty local and every arm would grade `unknown` (which defers) no
  # matter what count this arm meant to inject. Both busy arms would then "pass"
  # while measuring nothing.
  local _BUSY_ROWS="$1" idle_rc="$2" active="${3:-yes}"
  (
    eval "$block"
    RESTARTS="$WORK/restarts"
    systemctl() {
      case "${1:-}" in
        is-active) [[ "$active" == yes ]] ;;
        show)      printf '\n' ;;                       # no ActiveEnterTimestamp => 0
        restart)   printf '%s\n' "${2:-}" >> "$RESTARTS" ;;
        *)         return 0 ;;
      esac
    }
    db(){ echo "$_BUSY_ROWS"; }; sqlq(){ printf '%s' "$1"; }
    _hb_agent_idle(){ return "$idle_rc"; }
    _pending_restart_sweep
    printf 'fired=%s deferred=%s cleared=%s\n' "$_PR_FIRED" "$_PR_DEFERRED" "$_PR_CLEARED"
  )
}
rm -rf "$PENDING_RESTART_DIR"; mk carol "payload changed" >/dev/null
RESTARTS="$WORK/restarts"; : > "$RESTARTS"

out="$(sweep_with 1 0 yes)"
if [[ "$out" == "fired=0 deferred=1 cleared=0" ]] && [[ ! -s "$RESTARTS" ]] \
   && [[ -f "$PENDING_RESTART_DIR/carol" ]]; then
  ok_t "POSITIVE CONTROL 1/3: an agent parked mid-task is NOT restarted, and keeps its marker"
else
  bad_t "a busy agent was restarted by the sweep" "sweep said '$out', restarts: $(tr '\n' ' ' < "$RESTARTS")"
fi

out="$(sweep_with 0 0 yes)"
if [[ "$out" == "fired=1 deferred=0 cleared=0" ]] \
   && grep -qx '5dive-agent@carol.service' "$RESTARTS"; then
  ok_t "POSITIVE CONTROL 2/3: once the row leaves in_progress the SAME marker fires the bounce"
else
  bad_t "an idle agent's deferred restart never fired" "sweep said '$out', restarts: $(tr '\n' ' ' < "$RESTARTS") — the NEVER FIRES failure"
fi

out="$(sweep_with 0 0 yes)"
if [[ "$out" == "fired=0 deferred=0 cleared=0" ]] && [[ $(wc -l < "$RESTARTS") -eq 1 ]]; then
  ok_t "POSITIVE CONTROL 3/3: the fired marker is gone — no second bounce on the next sweep"
else
  bad_t "the sweep restarted the agent twice" "sweep said '$out', restarts: $(tr '\n' ' ' < "$RESTARTS")"
fi

# The board says the row closed; the SESSION may still be finishing the turn that
# closed it. A non-idle pane defers — the marker survives, so waiting costs
# nothing and bouncing one second into the closing turn costs the same work.
rm -rf "$PENDING_RESTART_DIR"; mk dave "payload changed" >/dev/null; : > "$RESTARTS"
out="$(sweep_with 0 1 yes)"
if [[ "$out" == "fired=0 deferred=1 cleared=0" ]] && [[ ! -s "$RESTARTS" ]]; then
  ok_t "an idle BOARD with a non-idle PANE still defers (the boundary is not the end of the turn)"
else
  bad_t "a mid-turn agent was bounced" "sweep said '$out' — the pane guard is not applied"
fi

# END TO END, through the real sweep rather than the predicate alone: the board
# is idle, the SESSION is mid-turn, and the bounce must not happen. This is the
# arm that grades what `5dive update` actually does on a chat-driven seat — the
# predicate arms above would all pass against a sweep that never consulted it.
rm -rf "$PENDING_RESTART_DIR"; mk frank "payload changed" >/dev/null; : > "$RESTARTS"
out="$(
  (
    eval "$block"
    RESTARTS="$WORK/restarts"
    systemctl() {
      case "${1:-}" in
        is-active) return 0 ;;
        show)      printf '\n' ;;
        restart)   printf '%s\n' "${2:-}" >> "$RESTARTS" ;;
        *)         return 0 ;;
      esac
    }
    db(){ echo 0; }; sqlq(){ printf '%s' "$1"; }   # board: no claimed row
    _hb_agent_native_state(){ printf busy; }        # session: mid-turn
    _hb_agent_idle(){ return 0; }                   # pane would have said idle
    _pending_restart_sweep
    printf 'fired=%s deferred=%s\n' "$_PR_FIRED" "$_PR_DEFERRED"
  )
)"
if [[ "$out" == "fired=0 deferred=1" ]] && [[ ! -s "$RESTARTS" ]] \
   && [[ -f "$PENDING_RESTART_DIR/frank" ]]; then
  ok_t "E2E: the SWEEP defers a seat whose board is idle but whose session is mid-turn, and keeps the marker"
else
  bad_t "the sweep bounced a mid-turn seat with no claimed row" \
        "sweep='$out' restarts: $(tr '\n' ' ' < "$RESTARTS") — this is the nightly update killing a turn"
fi

# A stopped unit has nothing to bounce: it loads the new payload on its next
# start. Without this an auto-slept agent (DIVE-1858 stops the unit) holds a
# marker forever and every sweep counts a debt that can never be paid.
rm -rf "$PENDING_RESTART_DIR"; mk erin "payload changed" >/dev/null; : > "$RESTARTS"
out="$(sweep_with 0 0 no)"
if [[ "$out" == "fired=0 deferred=0 cleared=1" ]] && [[ ! -s "$RESTARTS" ]] \
   && [[ ! -f "$PENDING_RESTART_DIR/erin" ]]; then
  ok_t "a stopped unit clears its marker instead of being woken by the sweep"
else
  bad_t "a stopped unit was restarted or held a marker forever" "sweep said '$out'"
fi

# ------------------------------------------------------------- wiring arms ----
# Every arm above grades a function. These grade that the SHIPPED callers use it
# — without them the harness would pass against dead code.
if grep -q 'busy="$(_agent_busy_state "$name")"' src/cmd_selfupdate.sh \
   && grep -q '_pending_restart_mark "$name" "$why"' src/cmd_selfupdate.sh; then
  ok_t "cmd_self_update asks the predicate and records the deferral before restarting"
else
  bad_t "cmd_self_update does not consult the predicate" "the restart loop is still unconditional — every arm above grades dead code"
fi
if grep -q 'deferred+=("$name")' src/cmd_selfupdate.sh \
   && grep -q 'deferred:\$d' src/cmd_selfupdate.sh; then
  ok_t "a deferral is reported separately from a skip (the payload DID move for these)"
else
  bad_t "deferrals are not reported" "an owed restart would be invisible in the nightly log"
fi
# TWO callers, and neither is a new timer: `heartbeat tick` observes the boundary,
# and the next `self-update` pays off anything the tick missed (or a box whose
# tick is off). A single caller would make the deferral depend on one mechanism
# being armed — the NEVER FIRES failure with extra steps.
if grep -q '_pending_restart_sweep' src/cmd_heartbeat.sh \
   && grep -c '_pending_restart_sweep' src/cmd_selfupdate.sh | grep -qv '^1$'; then
  ok_t "the sweep has two independent callers: the heartbeat tick and self-update itself"
else
  bad_t "the sweep has fewer than two callers" "a deferral that depends on one armed timer is the NEVER FIRES failure"
fi
if sed -n '/_hb_autosleep_sweep "\$now"/,/_pending_restart_sweep/p' src/cmd_heartbeat.sh \
     | grep -q '_pending_restart_sweep'; then
  ok_t "the tick's pending-restart pass runs after the autosleep pass (a just-slept unit is seen stopped)"
else
  bad_t "sweep ordering in the tick is not as documented" "an agent could be slept and immediately woken"
fi
if grep -q '_pending_restart_sweep || _hb_log' src/cmd_heartbeat.sh; then
  ok_t "the tick isolates the pass — a failure here cannot abort the wake loop"
else
  bad_t "the pending-restart pass is not isolated in the tick" "the heartbeat-never-woke bug class"
fi
# REGRESSION ARM, and it is not hypothetical — the first cut of this change broke
# tests/heartbeat_tier_head_of_line_unit.sh (32/0 -> 18/14) and
# tests/heartbeat_dispatcher_claim_unit.sh exactly here. The counters live with
# the sweep in src/cmd_selfupdate.sh, ~10 harnesses drive the tick with only
# src/cmd_heartbeat.sh sourced, and an unset read under `set -u` is FATAL: the
# summary line took down the whole wake loop it was summarising.
_sum="$(grep -n 'pending-restart\] pass done' src/cmd_heartbeat.sh)"
_cnt="$(sed -n '/_pending_restart_sweep || _hb_log/,/pass done/p' src/cmd_heartbeat.sh)"
# A read is safe only as ${_PR_X:-0}: anything else (a brace read with no default,
# or a bare $_PR_X) is the fatal one.
_bad="$( { grep -oE '\$\{_PR_[A-Z]+[^}]*\}' <<<"$_cnt" | grep -v ':-' ; grep -oE '\$_PR_[A-Z]+' <<<"$_cnt"; } )"
if [[ -n "$_sum" && -z "$_bad" ]]; then
  ok_t "the tick's summary reads every counter with a :- default (an unset read under set -u would abort the wake loop)"
else
  bad_t "the tick reads a pending-restart counter without a default" \
        "a harness that sources only cmd_heartbeat.sh dies on the unbound variable — measured, 32/0 -> 18/14. Unguarded read(s): $_bad"
fi

echo; echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
