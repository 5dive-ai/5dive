#!/usr/bin/env bash
# ── routing receipt (DIVE-3499) ────────────────────────────────────────────────
#
# WHY THIS EXISTS. Every "I routed you a row, please look at it" a2a ping is a
# missing capability wearing the shape of a message. Measured case (2026-08-16):
# ops put a full triage of PR #635 on DIVE-3330's body, the row was ALREADY todo
# and ALREADY assignee=dev2 — and ops pinged main's non-fresh window anyway,
# because nothing told the SENDER that the handoff had landed. It could not tell
# "dev2 will pick this up" from "this vanished", so it told a human-shaped seat
# as insurance. The general case runs the other way too: a verifier bouncing a
# row cannot see the maker now owns it, so it pings to close the gap.
#
# The fix is not to police the channel. It is to answer the question the ping was
# asking, in the output of the verb that did the routing: WHO owns it now, WHERE
# it sits in that seat's queue, and WHEN that seat next wakes.
#
# ── HARD CONSTRAINT (lodar, 2026-08-16 16:47Z), and it binds this file ────────
#
#   "it shoulnt be enfoced on the 5dive layer - because you may break the a2a"
#
# ADDITIVE ONLY. This code may add OUTPUT. It may NOT add a refusal, a new exit
# code, a new precondition, or any new way for a routing verb to fail. The test,
# applied to every line below: if this path can return non-zero where it returned
# zero before, it is out of scope. A receipt that cannot be computed prints
# nothing and changes no status.
#
# That is why `routing_receipt` runs its body in a SUBSHELL with stderr closed
# and `|| true` on the outside: a subshell contains an `exit`, a `set -e` abort,
# a missing `jq`, an unreadable registry and an unreachable board alike. There is
# no path from anything in here to the caller's exit status.
#
# An earlier pass at this row built a REFUSAL in the send path instead. It was
# withdrawn (quinn, iteration 1) for breaking exactly the constraint above. Do
# not reintroduce a guard here; the receipt removes the REASON to ping, which is
# the whole mechanism.

# How far down the recipient's queue we are willing to look for the row. A seat
# with more than this many runnable todos has a queue-depth problem, not a
# receipt problem — past the scan we say "beyond position N" rather than guess.
_RR_QUEUE_SCAN_LIMIT=200

# routing_receipt <ident> <owner> [<what-happened>]
#
# Prints ONE human line naming all three facts. Human output only: in JSON mode
# a stray line on stdout would corrupt the object `ok` emits, and the sender this
# exists for is an agent reading the verb's prose. Deliberately no JSON field —
# adding one changes a contract other verbs snapshot, and buys nothing for the
# reflex being removed.
routing_receipt() {
  ( _routing_receipt_render "$@" ) 2>/dev/null || true
  return 0
}

_routing_receipt_render() {
  local ident="${1:-}" owner="${2:-}" what="${3:-now owns it}"
  [[ -n "$ident" && -n "$owner" ]] || return 0
  (( JSON_MODE )) && return 0
  local pos wake
  pos=$(_routing_receipt_queue_pos "$ident" "$owner")
  wake=$(_routing_receipt_next_wake "$owner")
  printf 'handoff: %s %s · %s · %s\n' "$owner" "$what" "$pos" "$wake"
}

# Where the row sits in the order the dispatcher will actually hand work to this
# seat — NOT a raw COUNT(*). `_hb_pick_tasks` is the dispatcher's own selection
# (priority, then critical-path depth, then id, dep-blocked rows excluded), so
# reusing it is what makes "position 1 of 4" a prediction rather than a decoration.
# Calling it also means the two cannot drift: if the ordering rule changes, this
# changes with it.
_routing_receipt_queue_pos() {
  local ident="$1" owner="$2"
  declare -F _hb_pick_tasks >/dev/null 2>&1 || { echo "queue position: unknown"; return 0; }
  local id
  id=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$ident");" 2>/dev/null || echo "")
  [[ -n "$id" ]] || { echo "queue position: unknown"; return 0; }
  local ids n=0 hit=0 row
  ids=$(_hb_pick_tasks "$owner" "$_RR_QUEUE_SCAN_LIMIT" 2>/dev/null || echo "")
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    n=$(( n + 1 ))
    [[ "$row" == "$id" ]] && hit=$n
  done <<<"$ids"
  if (( hit > 0 )); then
    echo "queue position: ${hit} of ${n}"
  elif (( n > 0 )); then
    # Not in the dispatch list: in_progress, blocked by a dep, or a non-standard
    # kind. Say WHICH of those rather than printing a number that would be wrong
    # — a false "position 1" is worse than an honest miss, because the sender
    # would stop asking on the strength of it.
    local st blocked
    st=$(db "SELECT COALESCE(status,'') FROM tasks WHERE id=${id};" 2>/dev/null || echo "")
    blocked=$(db "SELECT COUNT(*) FROM task_deps d JOIN tasks b ON b.id=d.blocked_by
                   WHERE d.task_id=${id} AND b.status NOT IN ('done','cancelled');" 2>/dev/null || echo 0)
    if [[ "${blocked:-0}" != "0" ]]; then
      echo "queue position: waiting on ${blocked} unfinished dependency(ies), behind ${n} runnable"
    else
      echo "queue position: not queued (status ${st:-unknown}), behind ${n} runnable"
    fi
  else
    echo "queue position: 1 of 1 (nothing else queued for ${owner})"
  fi
}

# DIVE-4342: does a DISPATCHER ACTUALLY EXIST on this box?
#
# `next wake: due now (dispatcher ticks every 5 min)` was printed unconditionally
# — the arithmetic only ever asked whether lastRun+everyMin had passed, never
# whether anything was going to run. On the box this was reported from,
# `systemctl list-timers` listed zero 5dive timers and the root crontab held no
# tick, so every receipt promised a wake that could not happen and `task doctor`
# said "4/4 seats carry a heartbeat" one line above "the supervisor tick is not
# armed". A heartbeat CONFIG is not a heartbeat DRIVER.
#
# Three states, and the third does not fold into either neighbour:
#   installed:<how>  we found the tick and can name where.
#   absent           every source we could read was readable and held nothing.
#   unknown:<why>    the place it normally lives is not readable from this uid
#                    (root's crontab), so we do not know. NOT "absent": telling
#                    an operator to wake every seat by hand on a box that is
#                    ticking fine is the same false claim in the other direction.
_routing_receipt_dispatcher() {
  local f hit=""
  # /etc/cron.d is world-readable on every box we install on.
  for f in /etc/cron.d/*; do
    [[ -r "$f" ]] || continue
    grep -qE '^[^#].*(5dive|five).*heartbeat[[:space:]]+tick' "$f" 2>/dev/null \
      && { printf 'installed:%s\n' "$f"; return 0; }
  done
  # A systemd timer, if one is how this box drives it.
  if command -v systemctl >/dev/null 2>&1; then
    # No matching timer is the normal case here, so the no-match path must be a
    # value, not a death (DIVE-2566/2603/2604).
    hit=$(systemctl list-timers --all --no-pager 2>/dev/null \
          | grep -oE '[[:alnum:]_.-]*(heartbeat|dispatch)[[:alnum:]_.-]*\.timer' | head -1) || hit=""
    [[ -n "$hit" ]] && { printf 'installed:%s\n' "$hit"; return 0; }
  fi
  # root's crontab — the usual home for the tick, and readable only as root.
  if [[ "$(id -u)" == "0" ]]; then
    if crontab -l -u root 2>/dev/null | grep -qE '^[^#].*heartbeat[[:space:]]+tick'; then
      printf 'installed:root crontab\n'; return 0
    fi
    printf 'absent\n'; return 0
  fi
  printf 'unknown:root crontab is not readable as %s\n' "$(id -un 2>/dev/null || echo "this uid")"
}

# When the dispatcher may next hand this seat a row. Same arithmetic as
# `heartbeat ls` (lastRunAt + everyMin*60 - now), stated here rather than
# imported because that value lives inside a display loop.
#
# "due now" is bounded by the cron driver's own tick — when there IS one. The
# line says which of those two facts it is standing on.
_routing_receipt_next_wake() {
  local owner="$1"
  command -v jq >/dev/null 2>&1 || { echo "next wake: unknown"; return 0; }
  local reg; reg=$(registry_read 2>/dev/null || echo "")
  [[ -n "$reg" ]] || { echo "next wake: unknown"; return 0; }
  local enabled everyMin lastRun now nextIn
  enabled=$(jq -r --arg n "$owner" '.agents[$n].heartbeat.enabled // false' <<<"$reg" 2>/dev/null || echo false)
  if [[ "$enabled" != "true" ]]; then
    # Not a failure and not a warning: plenty of seats are driven by hand or by
    # their own cron. It is still the answer to "when does this land", and it is
    # the one case where a sender legitimately may need to do something else.
    echo "next wake: no auto-wake (heartbeat off for ${owner})"
    return 0
  fi
  everyMin=$(jq -r --arg n "$owner" '.agents[$n].heartbeat.everyMin // 30' <<<"$reg" 2>/dev/null || echo 30)
  lastRun=$(jq -r --arg n "$owner" '.agents[$n].heartbeat.lastRunAt // 0' <<<"$reg" 2>/dev/null || echo 0)
  [[ "$everyMin" =~ ^[0-9]+$ ]] || everyMin=30
  [[ "$lastRun" =~ ^[0-9]+$ ]] || lastRun=0
  now=$(date +%s)
  nextIn=$(( lastRun + everyMin * 60 - now ))
  local disp; disp=$(_routing_receipt_dispatcher)
  case "$disp" in
    absent)
      # The seat is due and nothing will ever notice. Say the actionable thing,
      # not the arithmetic: this is the one branch where the sender genuinely
      # must do something else.
      echo "next wake: NO DISPATCHER INSTALLED on this box — nothing runs \`5dive heartbeat tick\`, so ${owner} will not be woken by a schedule. Wake it by hand: 5dive heartbeat wake-task <ident>"
      return 0 ;;
    unknown:*)
      if (( nextIn <= 0 )); then
        echo "next wake: due now, IF a dispatcher is installed — ${disp#unknown:}, so this receipt cannot confirm one runs. Check with: sudo crontab -l | grep 'heartbeat tick'"
      else
        echo "next wake: in ~$(( (nextIn + 59) / 60 ))m, IF a dispatcher is installed (${disp#unknown:})"
      fi
      return 0 ;;
  esac
  if (( nextIn <= 0 )); then
    echo "next wake: due now (dispatcher: ${disp#installed:})"
  else
    echo "next wake: in ~$(( (nextIn + 59) / 60 ))m (dispatcher: ${disp#installed:})"
  fi
}
