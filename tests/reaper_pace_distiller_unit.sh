#!/usr/bin/env bash
# TIER: core — ~1s, pure string/awk grading plus one `env -i` child. No DB, no
# network, no `ps` of a real seat, nothing killed (every reaper arm is
# `--dry-run`), and no box path is read: arm Z is the control that proves it.
#
# DIVE-584 — three defects from the 2026-09-21 report, one per section. Each
# section ends with a MUTANT arm that re-introduces the defect against the SAME
# fixture and asserts the old answer, so a green here cannot be vacuous.
#
# WHAT A GREEN HERE MUST MEAN
#   A. `task done` no longer reaps a systemd unit that merely runs under the
#      seat's uid. `ps -u <seat>` is a UID question; unit membership is a CGROUP
#      question, and the two disagree exactly where `mp-staging.service`
#      (`php -S` under `sh -c`) died. The DIVE-3503 runaway — a `nohup` shell
#      reparented to pid 1 — stays in its unit's cgroup and is still collected,
#      which is the arm that keeps this fix from being a regression.
#   B. The pacing floor's WEEKLY verdict is fenced at the weekly window's own
#      drift rate (4h — DIVE-4777 narrowed it from the 24h this first shipped
#      with), not the 5-hour window's (600s). The 5-hour verdict is
#      unmoved — arm B3 is the one that fails if someone "simplifies" the two
#      fences back into one.
#   C. The distiller child gets the seat token even when its uid CANNOT read the
#      credential files. Graded on the property itself: the child is pointed at
#      paths that do not exist (the state a sandboxed seat is in, with no
#      chmod and no root needed) and must still see the variable.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# No `2>/dev/null` — the helper's stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dive584.XXXXXX")"
trap 'rc=$?; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }
is()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$3], got [$2]"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] does not contain [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "[$2] contains [$3]" ;; *) ok "$1" ;; esac; }

# The account-reading cache is a FILE cache whose default lives in STATE_DIR
# (/var/lib/5dive). Point it at the scratch tree BEFORE grader_pool.sh is
# sourced, so this harness can never read — or poison — a running host's
# pacing state, and so it needs no box path to run at all (DIVE-4731).
export FIVE_PACE_READING_CACHE_DIR="$TMPD/pace-reading"

# ═════════════════════════════ A — the reaper ═════════════════════════════
. src/lib/reap.sh

echo "== A: cgroup membership is the reaper's scope, not the uid =="

# v2: one line, `0::<path>`. The seat's own unit.
CG_V2_SEAT=$'0::/system.slice/system-5dive\\x2dagent.slice/5dive-agent@marcus.service'
REF_V2_SEAT='/system.slice/system-5dive\x2dagent.slice/5dive-agent@marcus.service'
# v1: several controllers, same path. Still the seat's unit.
CG_V1_SEAT=$'12:pids:/system.slice/system-5dive\\x2dagent.slice/5dive-agent@marcus.service\n1:name=systemd:/system.slice/system-5dive\\x2dagent.slice/5dive-agent@marcus.service'
# The victim of the incident: a service with User=agent-marcus, its own unit.
CG_SERVICE=$'0::/system.slice/mp-staging.service'
# A sibling seat. Same slice family, different instance.
CG_OTHER_SEAT=$'0::/system.slice/5dive-agent@quinn.service'
# A user session — what a hand-run shell lands in.
CG_USER=$'0::/user.slice/user-1001.slice/session-3.scope'
# DIVE-4777. The `claude` seat, which `_reap_at_task_boundary` ADMITS and which
# has no `5dive-agent@` unit at all: 16 such units exist on the box and none is
# its. These are the real strings, measured 2026-09-21.
CG_CLAUDE=$'0::/user.slice/user-1000.slice/user@1000.service/init.scope'
REF_CLAUDE='/user.slice/user-1000.slice/user@1000.service/init.scope'
# A `claude`-uid process in a service of its own — shares the uid, not the seat.
CG_CLAUDE_SVC=$'0::/system.slice/zerohuman.service'
# A child scope nested under the seat's reference cgroup.
CG_NESTED=$'0::/system.slice/system-5dive\\x2dagent.slice/5dive-agent@marcus.service/task.scope'

_reap_cgroup_in_ref "$CG_V2_SEAT"    "$REF_V2_SEAT" && ok "cgroup v2, seat's own unit -> in"    || bad "cgroup v2, seat's own unit" "read as OUT"
_reap_cgroup_in_ref "$CG_V1_SEAT"    "$REF_V2_SEAT" && ok "cgroup v1, seat's own unit -> in"    || bad "cgroup v1, seat's own unit" "read as OUT"
_reap_cgroup_in_ref "$CG_NESTED"     "$REF_V2_SEAT" && ok "a scope nested under the seat -> in" || bad "a scope nested under the seat" "read as OUT"
_reap_cgroup_in_ref "$CG_SERVICE"    "$REF_V2_SEAT" && bad "service unit under the seat's uid" "read as IN — this is the incident" || ok "service unit under the seat's uid -> out"
_reap_cgroup_in_ref "$CG_OTHER_SEAT" "$REF_V2_SEAT" && bad "another seat's unit" "read as IN"   || ok "another seat's unit -> out"
_reap_cgroup_in_ref "$CG_USER"       "$REF_V2_SEAT" && bad "user session scope" "read as IN"    || ok "user session scope -> out"

# ── DIVE-4777: the seat the caller ADMITS but the old predicate could not name ──
# THE REGRESSION ARM. Against the pre-fix tree the first of these is a NO MATCH
# for every candidate, so the `claude` seat reaped nothing, permanently and
# without a word. "Fails closed" is a safety property only for the identifiers
# the predicate can match.
_reap_cgroup_in_ref "$CG_CLAUDE"     "$REF_CLAUDE"  && ok "the claude seat's own cgroup -> in"  || bad "the claude seat's own cgroup" "read as OUT — the DIVE-4776 hole"
_reap_cgroup_in_ref "$CG_CLAUDE_SVC" "$REF_CLAUDE"  && bad "a claude-uid service" "read as IN"  || ok "a claude-uid service (zerohuman) -> out"
_reap_cgroup_in_ref "$CG_V2_SEAT"    "$REF_CLAUDE"  && bad "an agent unit vs the claude ref" "read as IN" || ok "an agent unit is not in the claude ref -> out"

# Fails CLOSED. Every unreadable answer is OUT: no /proc, a pid that exited
# between `ps` and the read, a layout we do not recognise.
_reap_cgroup_in_ref ""               "$REF_V2_SEAT" && bad "empty cgroup text" "read as IN — must fail closed" || ok "empty cgroup text -> out (fails closed)"
_reap_cgroup_in_ref "$CG_V2_SEAT"    ""             && bad "empty reference" "read as IN"       || ok "empty reference -> out (fails closed)"
_reap_cgroup_in_ref $'1:cpu\n'       "$REF_V2_SEAT" && bad "unparseable cgroup text" "read as IN" || ok "unparseable cgroup text -> out (fails closed)"
# The boundary is a PATH COMPONENT, not a substring: a seat whose name is a
# prefix of another must not match it, and neither must a sibling scope whose
# name merely starts with the reference.
_reap_cgroup_in_ref "$CG_V2_SEAT" '/system.slice/system-5dive\x2dagent.slice/5dive-agent@marc.service' \
  && bad "prefix seat name" "matched marcus's unit" || ok "prefix seat name -> out"
_reap_cgroup_in_ref $'0::/system.slice/foo.service-extra' '/system.slice/foo.service' \
  && bad "sibling path sharing a string prefix" "read as IN" || ok "sibling path sharing a string prefix -> out"

echo "== A: the reference cgroup is RESOLVED, not formatted from the seat name =="
# Our OWN seat resolves through /proc/self/cgroup — the only resolution that is
# correct for `claude` and `agent-*` alike.
_REAP_SELF_CGROUP_CMD=fake_self; fake_self() { printf '%s' "$CG_CLAUDE"; }
# `\x2d` is systemd's escaping of the `-` in the slice name, so the fixture must
# emit it LITERALLY — `printf '%s'`, never a format string printf would unescape.
AGENT_SLICE='/system.slice/system-5dive\x2dagent.slice'
_REAP_UNIT_CGROUP_CMD=fake_unit; fake_unit() { printf '%s/%s' "$AGENT_SLICE" "$1"; }
USER=claude
is "own seat (claude) resolves to its own cgroup" "$(_reap_seat_ref_cgroup claude)" "$REF_CLAUDE"
USER=agent-marcus
# Same branch for an `agent-*` seat: /proc/self/cgroup, not the unit name — the
# stub returns the same fixture, so a match here IS the self branch being taken.
is "own seat (agent-*) takes the self branch too" "$(_reap_seat_ref_cgroup marcus)" "$REF_CLAUDE"
# Another seat: systemd is ASKED for the unit's control group.
is "another seat resolves through systemd" "$(_reap_seat_ref_cgroup quinn)" \
   '/system.slice/system-5dive\x2dagent.slice/5dive-agent@quinn.service'
# Unresolvable -> empty -> nothing is reaped (checked at the call site below).
fake_unit() { printf ''; }
is "an unknown unit resolves to nothing" "$(_reap_seat_ref_cgroup nosuch)" ""
fake_unit() { printf '%s/%s' "$AGENT_SLICE" "$1"; }

echo "== A: the acting reaper, on a fabricated table =="
# One row per process. PID 9001 is the incident's victim, 9002 the runaway the
# reaper exists for, 9003 the same runaway AFTER reparenting to pid 1 (nohup),
# 9004 a sibling seat's shell that happens to share nothing but the class.
_reap_seat_table() {
  printf '%s\t%s\t%s\t%s\n' \
    9001 1    4000 'sh -c exec php -S 0.0.0.0:8080 -t /srv/mp-staging' \
    9002 9100 4000 'sh -c while true; do sleep 5; pgrep -f something; done' \
    9003 1    4000 'sh -c while :; do sleep 1; done' \
    9004 9200 4000 'sh -c tail -f /var/log/other.log'
}
# The cgroup fixture, per pid. This is what `_REAP_CGROUP_CMD` exists for.
fixture_cgroup() {
  case "$1" in
    9001) printf '%s' "$CG_SERVICE"    ;;   # the service — must be spared
    9002) printf '%s' "$CG_V2_SEAT"    ;;   # in the unit — must be reaped
    9003) printf '%s' "$CG_V1_SEAT"    ;;   # reparented to pid 1, still in the unit
    9004) printf '%s' "$CG_OTHER_SEAT" ;;   # another seat's unit — must be spared
    *)    printf ''                    ;;
  esac
}
_REAP_CGROUP_CMD=fixture_cgroup
# The pass resolves its reference once; `agent-marcus` is not this runner's own
# seat, so it takes the systemd branch, stubbed above.
USER=someone-else
# `_reap_stale_shells` asks `id -u <seat_user>` to refuse an unknown seat. The
# fixture seat does not exist on any runner, so the lookup is stubbed — this is
# the ONLY host fact the section needs, and stubbing it is what keeps the
# harness pristine-CI safe.
id() { if [[ "${1:-}" == "-u" && $# -gt 1 ]]; then return 0; fi; command id "$@"; }

reap_report() { rm -f "$TMPD/victims"; _reap_stale_shells agent-marcus --min-age=0 --dry-run --reason=t --victims-file="$TMPD/victims" 2>"$TMPD/reap.err"; }

n=$(reap_report)
err=$(cat "$TMPD/reap.err")
is  "reaper counts exactly the two shells inside the seat's unit" "$n" "2"
has "the runaway in the unit is named"            "$err" "pid=9002"
has "the reparented runaway is still collected"   "$err" "pid=9003"
hasnt "the service under the seat's uid is spared" "$err" "pid=9001"
hasnt "another seat's shell is spared"             "$err" "pid=9004"
has "the spared-by-cgroup count is reported, not silent" "$err" "2 process(es) of uid agent-marcus left alone"
has "the message names the resolved cgroup, not a unit name" "$err" "5dive-agent@marcus.service)"
# The audit row's new payload: a count cannot be traced back to what died.
# The victim list has to cross a command substitution to reach the audit row —
# every call site invokes the reaper inside `$( )`, so a global cannot carry it.
victims=$(cat "$TMPD/victims" 2>/dev/null || printf '')
has "victims survive the caller's subshell" "$victims" "9002:"
has "victims carry the command line"        "$victims" "pgrep -f something"
hasnt "the spared service is not in the audit list" "$victims" "9001:"
if grep -q 'victims=${victims:-none}' src/lib/reap.sh; then
  ok "call site: the audit row carries the victim list"
else
  bad "call site: the audit row carries the victim list" "not found in src/lib/reap.sh"
fi

# DIVE-4777: an UNRESOLVABLE reference still reaps nothing — but says so. The
# pre-fix shape of this exact state (the `claude` seat) was a wordless 0.
fake_unit() { printf ''; }
n_blind=$(reap_report); err_blind=$(cat "$TMPD/reap.err")
is  "unresolvable reference reaps nothing (fails closed)" "$n_blind" "0"
has "…and says so instead of being silent" "$err_blind" "no resolvable cgroup, nothing reaped"
fake_unit() { printf '%s/%s' "$AGENT_SLICE" "$1"; }

echo "== A: MUTANT — uid membership, the pre-fix behaviour =="
# Re-introduce the defect in the narrowest possible way: membership becomes the
# uid again. If the guard were not load-bearing, this would change nothing.
_reap_in_cgroup() { return 0; }
n_mut=$(reap_report)
err_mut=$(cat "$TMPD/reap.err")
is  "MUTANT: uid-scoped reaper takes all four" "$n_mut" "4"
has "MUTANT: it kills the service — the incident" "$err_mut" "pid=9001"
if [[ "$n_mut" == "$n" ]]; then bad "MUTANT differential" "mutant and fixed tree agree ($n) — arm A is vacuous"; else ok "MUTANT differential: fixed=$n mutant=$n_mut"; fi
unset -f _reap_in_cgroup id _reap_seat_table

# The fix must be WIRED, not merely defined: the call site has to consult it.
if grep -q '_reap_in_cgroup "$pid" "$ref_cgroup"' src/lib/reap.sh; then
  ok "call site: the candidate loop consults the RESOLVED cgroup"
else
  bad "call site: the candidate loop consults the RESOLVED cgroup" "not found in src/lib/reap.sh"
fi
# DIVE-4777 MUTANT, the exact pre-fix predicate: a formatted unit-name literal.
# It answers identically for `agent-*` and is wrong for `claude` — which is why
# 46 arms were green while one admitted seat reaped nothing.
_reap_cgroup_in_ref_pre() { [[ -n "$1" && -n "$2" ]] || return 1; [[ "$1" == *"/5dive-agent@$2.service"* ]]; }
if _reap_cgroup_in_ref_pre "$CG_CLAUDE" claude; then
  bad "MUTANT: the pre-fix literal predicate" "matched the claude seat — the fixture is wrong"
else
  ok "MUTANT: the pre-fix literal predicate reads the claude seat as OUT (the defect)"
fi
_reap_cgroup_in_ref_pre "$CG_V2_SEAT" marcus \
  && ok "MUTANT: …while answering correctly for agent-marcus (why the suite was green)" \
  || bad "MUTANT: agent-marcus under the pre-fix predicate" "read as OUT"
unset -f _reap_cgroup_in_ref_pre

# ═══════════════════ B — the weekly pacing fence ═══════════════════
echo "== B: the weekly window is fenced at its own drift rate =="
# shellcheck source=/dev/null
. src/task/grader_pool.sh

NOW=1789294364
FUTURE=$(( NOW + 4*86400 ))        # the weekly window has not turned over
US=$'\037'
reading() { # <age-seconds> <sevenResetsAt>
  printf '{"asOf":%s,"fiveHourPct":21,"fiveResetsAt":%s,"sevenDayPct":64,"sevenResetsAt":%s}' \
    "$(( NOW - $1 ))" "$(( NOW + 3600 ))" "$2"
}
pair() { printf '%s' "$1" | _grader_reading_pair "$NOW"; }

p=$(pair "$(reading 60 "$FUTURE")")
is "fresh reading: both windows"            "$p" "21${US}64"
p=$(pair "$(reading 700 "$FUTURE")")
is "700s: 5h blind, weekly measured"        "$p" "${US}64"
p=$(pair "$(reading 10800 "$FUTURE")")
is "3h: 5h blind, weekly measured"          "$p" "${US}64"
p=$(pair "$(reading 14399 "$FUTURE")")
is "just inside 4h: weekly still measured"  "$p" "${US}64"
# DIVE-4777 reversed in place: 86399s used to be INSIDE the fence and is now
# outside it. The arm is kept (not deleted) with its reason corrected, so the
# narrowing is the thing that is graded rather than silently unpinned.
p=$(pair "$(reading 86399 "$FUTURE")")
is "24h: nothing — the old fence is gone"   "$p" ""
p=$(pair "$(reading 18000 "$FUTURE")")
is "5h: nothing — past the weekly fence"    "$p" ""
p=$(pair "$(reading -600 "$FUTURE")")
is "a reading from the future is nothing"   "$p" ""
# The reset fence is untouched and still outranks the age fence: a percentage
# from a window that has already turned over is not a statement about this week.
p=$(pair "$(reading 10800 "$(( NOW - 10 ))")")
is "3h but the weekly window turned over"   "$p" "${US}"

echo "== B: the floor's own weekly reader =="
fixture_reading() { printf '%s' "$FIXTURE_RL"; }
_PACE_READING_JSON_CMD=fixture_reading
FIXTURE_RL=$(reading 10800 "$FUTURE")
is "_pace_account_seven: 3h old -> the value, not blind" "$(_pace_account_seven acct "$NOW")" "64${US}${FUTURE}"
FIXTURE_RL=$(reading 18000 "$FUTURE")
is "_pace_account_seven: 5h old -> blind"                "$(_pace_account_seven acct "$NOW")" ""
FIXTURE_RL=$(reading 10800 "$(( NOW - 10 ))")
is "_pace_account_seven: turned-over window -> blind"    "$(_pace_account_seven acct "$NOW")" ""

echo "== B: MUTANT — one fence for both windows, the pre-fix behaviour =="
_GRADER_READING_WEEKLY_MAX_AGE="$_GRADER_READING_MAX_AGE"
FIXTURE_RL=$(reading 10800 "$FUTURE")
is "MUTANT: 3h weekly reads blind again"  "$(_pace_account_seven acct "$NOW")" ""
is "MUTANT: 3h pair is empty again"       "$(pair "$(reading 10800 "$FUTURE")")" ""
_GRADER_READING_WEEKLY_MAX_AGE=14400
is "fence restored"                       "$(_pace_account_seven acct "$NOW")" "64${US}${FUTURE}"
# DIVE-4777: the NUMBER is the finding, so it is pinned at its source. ~0.6 %/h
# of weekly drift over 24h is ~14 points against _GRADER_FLOOR_7D=90; over 4h it
# is ~2.4. A future widening has to argue past this arm.
if grep -qE '^_GRADER_READING_WEEKLY_MAX_AGE="\$\{_GRADER_READING_WEEKLY_MAX_AGE:-\$\{QUOTA_SNAPSHOT_WEEKLY_MAX_AGE:-14400\}\}"$' src/task/grader_pool.sh; then
  ok "the weekly fence default is 14400s (4h), not 86400s"
else
  bad "the weekly fence default is 14400s (4h), not 86400s" "src/task/grader_pool.sh does not read 14400"
fi
# The two fences must not be the same number, or B3 grades nothing.
if (( _GRADER_READING_WEEKLY_MAX_AGE > _GRADER_READING_MAX_AGE )); then
  ok "the weekly fence is wider than the 5-hour fence"
else
  bad "the weekly fence is wider than the 5-hour fence" "weekly=$_GRADER_READING_WEEKLY_MAX_AGE 5h=$_GRADER_READING_MAX_AGE"
fi

# ═════════════════ C — the distiller child's credentials ═════════════════
echo "== C: the child is handed the token it cannot read =="
# The helpers are EXTRACTED by name rather than sourcing cmd_heartbeat.sh, which
# is not a sourceable unit. The extraction is also the existence assertion: on a
# tree without the fix there is nothing to extract and every arm below is red.
extract_fn() { # <file> <fn-name>
  awk -v fn="$2" 'index($0, fn "() {") == 1 { p = 1 } p { print } p && $0 == "}" { exit }' "$1"
}
{ grep -E '^_HB_DISTILLER_ENV_VARS=' src/cmd_heartbeat.sh
  extract_fn src/cmd_heartbeat.sh _hb_distiller_seed_env
  extract_fn src/cmd_heartbeat.sh _hb_distiller_preserve_list
} > "$TMPD/hb_fns.sh"
# shellcheck source=/dev/null
. "$TMPD/hb_fns.sh"

SHARED="$TMPD/anthropic.env"
PROFILE="$TMPD/marcus-auth.env"
printf 'ANTHROPIC_API_KEY=shared-key\nANTHROPIC_BASE_URL=https://example.invalid\n' > "$SHARED"
printf 'CLAUDE_CODE_OAUTH_TOKEN=profile-token\nANTHROPIC_API_KEY=profile-key\n'     > "$PROFILE"
MISSING_A="$TMPD/does-not-exist-a.env"
MISSING_B="$TMPD/does-not-exist-b.env"

pl() { ( _hb_distiller_seed_env "$@" >/dev/null 2>&1; _hb_distiller_preserve_list ); }
is "both files readable -> all four names preserved" \
   "$(pl "$SHARED" "$PROFILE")" "ANTHROPIC_API_KEY,CLAUDE_CODE_OAUTH_TOKEN,ANTHROPIC_BASE_URL"
is "shared only -> no OAuth token in the list" \
   "$(pl "$SHARED" "$MISSING_B")" "ANTHROPIC_API_KEY,ANTHROPIC_BASE_URL"
# NEITHER readable is the sandboxed seat's state. Empty list -> sudo is invoked
# with no --preserve-env at all, and `memory consolidate` reports
# distiller_unauthed (DIVE-4562) instead of the child inventing a reason.
is "neither readable -> empty list (the unauthed reason)" \
   "$(pl "$MISSING_A" "$MISSING_B")" ""
# EnvironmentFile ORDER: shared first, the profile overlay last (DIVE-4648).
is "profile overlay wins over the shared connector" \
   "$( ( _hb_distiller_seed_env "$SHARED" "$PROFILE" >/dev/null 2>&1; printf '%s' "${ANTHROPIC_API_KEY:-}" ) )" "profile-key"
# An unreadable file is skipped, never an error: this runs under the heartbeat's
# errexit-free lane but must not return non-zero either.
( _hb_distiller_seed_env "$MISSING_A" "$MISSING_B" >/dev/null 2>&1 ) && ok "an absent file is skipped, rc 0" || bad "an absent file is skipped, rc 0" "returned non-zero"

echo "== C: the property — a child that cannot read the files still gets the token =="
# `sudo --preserve-env=<names>` emulated with `env -i` plus exactly those names,
# and the child is handed paths that DO NOT EXIST — the same state a sandboxed
# uid is in when it cannot read the real ones. No chmod, no root, no box path.
child_out() {
  ( _hb_distiller_seed_env "$@" >/dev/null 2>&1
    pe=$(_hb_distiller_preserve_list)
    declare -a kv=()
    IFS=',' read -r -a names <<<"$pe"
    for nm in "${names[@]}"; do [ -n "$nm" ] && kv+=("$nm=${!nm}"); done
    env -i PATH="$PATH" "${kv[@]}" bash -c \
      'set -a; [ -r "$1" ] && . "$1"; [ -r "$2" ] && . "$2"; set +a; printf "%s|%s" "${ANTHROPIC_API_KEY:-NONE}" "${CLAUDE_CODE_OAUTH_TOKEN:-NONE}"' \
      _ "$MISSING_A" "$MISSING_B" )
}
is "child with unreadable credential files still gets both" \
   "$(child_out "$SHARED" "$PROFILE")" "profile-key|profile-token"

echo "== C: MUTANT — source in the child only, the pre-fix behaviour =="
# The pre-fix call, verbatim in shape: nothing seeded in the parent, the child
# sources two paths it cannot read, and both `[ -r ]` tests are false.
mutant_out=$( env -i PATH="$PATH" bash -c \
  'set -a; [ -r "$1" ] && . "$1"; [ -r "$2" ] && . "$2"; set +a; printf "%s|%s" "${ANTHROPIC_API_KEY:-NONE}" "${CLAUDE_CODE_OAUTH_TOKEN:-NONE}"' \
  _ "$MISSING_A" "$MISSING_B" )
is "MUTANT: child sources what it cannot read -> no credential" "$mutant_out" "NONE|NONE"

# WIRED, not merely defined.
if grep -q 'preserve-env="$_hb_pe"' src/cmd_heartbeat.sh; then
  ok "call site: the consolidate lane passes --preserve-env"
else
  bad "call site: the consolidate lane passes --preserve-env" "not found in src/cmd_heartbeat.sh"
fi
if grep -q '_hb_distiller_seed_env "$sharedenv" "$authenv"' src/cmd_heartbeat.sh; then
  ok "call site: the lane seeds as root before sudo"
else
  bad "call site: the lane seeds as root before sudo" "not found in src/cmd_heartbeat.sh"
fi

# ═══════════ Z — the pristine-CI control (DIVE-562 / #1010) ═══════════
echo "== Z: control — nothing above needs a 5dive install =="
# CI has no /usr/local/bin/5dive, no /etc/5dive, no /var/lib/5dive and no sudo
# grant. A predicate that short-circuits on a box path passes at a desk and
# fails on the runner, so the absence is asserted rather than assumed.
for boxpath in /usr/local/bin/5dive /etc/5dive /var/lib/5dive; do
  if [[ -e "$boxpath" ]]; then
    printf '  note %s exists here; the arms above never read it (they are fixture-driven)\n' "$boxpath"
  fi
done
# Re-run the three load-bearing predicates with every box path overridden to a
# directory that does not exist. Same answers, or the harness is host-dependent.
( export CONNECTORS_DIR="$TMPD/nope/connectors" STATE_DIR="$TMPD/nope/state" \
         ENV_DIR="$TMPD/nope/agents.d" SELF_BIN="$TMPD/nope/5dive"
  r=0
  _reap_cgroup_in_ref "$CG_SERVICE" "$REF_V2_SEAT" && r=1
  _reap_cgroup_in_ref "$CG_V2_SEAT" "$REF_V2_SEAT" || r=1
  _reap_cgroup_in_ref "$CG_CLAUDE"  "$REF_CLAUDE"  || r=1
  [[ "$(printf '%s' "$(reading 10800 "$FUTURE")" | _grader_reading_pair "$NOW")" == "${US}64" ]] || r=1
  [[ -z "$(_hb_distiller_preserve_list)" ]] || r=1
  exit $r ) && ok "every predicate answers the same with no 5dive install present" \
            || bad "every predicate answers the same with no 5dive install present" "a box path is load-bearing"

printf '\n%s pass / %s fail\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
exit 0
