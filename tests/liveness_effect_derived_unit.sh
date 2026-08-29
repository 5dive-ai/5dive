#!/usr/bin/env bash
# Isolated unit harness for `5dive liveness` — effect-derived liveness, the v0.23
# headline (DIVE-3778).
#
# THE DEFECT THIS GRADES. Every liveness read the fleet had before this command
# answers "is something present?" — a unit is active, a pgrep matches, a pane
# says a word. All of them read GREEN through DIVE-3726/3748 (dead poller),
# DIVE-3723 (a seat at a login screen holding the only startable row), dev3's
# four rows held for three days on an expired quota, and DIVE-3711 (exit 0 having
# written nothing). The capability under test replaces presence with EFFECT: a
# seat is alive only against a timestamped artifact IT wrote, and a probe that
# could not run is a third verdict — `not-reached` — that never folds into green.
#
# WHY THE MUTATION ARMS ARE THE POINT. "A seat with a fresh artifact reads alive"
# is also what a build that returns `alive` unconditionally looks like, and "an
# unmeasurable seat reads not-reached" is also what a build with no third state
# at all looks like on a box where nothing is ever unreadable. So three mutations
# run against the same fixtures, in BOTH directions:
#   A  the third state folds UP into `alive`      -> the false green the theme is named after
#   B  freshness is unconditionally true          -> a three-day-dead seat certifies as alive
#   C  the third state folds DOWN into `no-effect`-> a working seat is accused because OUR probe broke
# Each must turn a specific green arm RED while leaving the others alone, and
# each is asserted to have actually APPLIED (a no-op substitution and a vacuous
# arm are both all-green, DIVE-3455 class).
#
# Isolation: throwaway STATE_DIR / TASKS_DB / AUDIT_LOG, no root, no network, no
# process probes. Run: bash tests/liveness_effect_derived_unit.sh
# DIVE-2211: name the tree this harness grades — a green log from a stale
# checkout and one from origin/main are otherwise byte-identical.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/liveness-effect-derived-unit.XXXXXX)" || {
  printf 'FAIL - mktemp: could not create a work dir; nothing was graded\n' >&2; exit 1; }
# DIVE-2692: fires on every exit path (incl. early precondition-fail exits) and
# folds in cleanup so the two EXIT traps cannot clobber each other. chmod first —
# arm 5 deliberately makes a dir unreadable and rm would otherwise leave it.
trap 'rc=$?; chmod -R u+rwX "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh \
         cmd_liveness.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
REGISTRY="$STATE_DIR/agents.json"
AUDIT_LOG="$STATE_DIR/agent-audit.log"
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init >/dev/null 2>&1

# ---- fixtures -------------------------------------------------------------
# Stamps are written in the store's own format (unqualified UTC, exactly what
# datetime('now') produces) rather than through the CLI, because the property
# under test is how the READER dates an artifact.
utc() { date -u -d "@$(( $(date +%s) + $1 ))" '+%Y-%m-%d %H:%M:%S'; }
iso() { date    -d "@$(( $(date +%s) + $1 ))" -Iseconds; }

seed_board_done()  { db "INSERT INTO tasks(ident,title,status,assignee,done_at)    VALUES('$1','a row','done','$2',$(sqlq "$3"));" >/dev/null 2>&1; }
seed_board_start() { db "INSERT INTO tasks(ident,title,status,assignee,started_at) VALUES('$1','a row','in_progress','$2',$(sqlq "$3"));" >/dev/null 2>&1; }
seed_board_touch() { db "INSERT INTO tasks(ident,title,status,assignee,updated_at) VALUES('$1','a row','todo','$2',$(sqlq "$3"));" >/dev/null 2>&1; }
seed_ledger()      { db "INSERT INTO lifecycle_events(kind,actor,idem_key,ts) VALUES('$1','$2','k-$RANDOM$RANDOM',$(sqlq "$3"));" >/dev/null 2>&1; }
seed_audit()       { jq -cn --arg u "$1" --arg c "$2" --arg t "$3" '{ts:$t,user:$u,cmd:$c,result:"ok",code:0,args:[]}' >>"$AUDIT_LOG"; }

# run <seat> [window-min] -> JSON on stdout; the exit code lands in $RCFILE.
# Callers use `j=$(run x)`, which is a SUBSHELL — a plain `RC=$?` assigned inside
# `run` would die with it and every rc assertion below would silently read 0,
# i.e. would pass on a build that never returns a nonzero code at all.
RCFILE="$TMP/last-rc"
run() {
  local seat="$1" win="${2:-60}"
  JSON_MODE=0
  cmd_liveness --json "--agent=${seat}" "--window=${win}" 2>/dev/null
  printf '%s' "$?" >"$RCFILE"
}
rc_last() { cat "$RCFILE" 2>/dev/null; }
verdict_of() { run "$1" "${2:-60}" | jq -r '.data.seats[0].verdict'; }

# --- 0. the stamp reader pins the store's unqualified format to UTC ----------
# Reading `2026-01-01 00:00:00` as LOCAL time is an hours-wide error, and on any
# box west of UTC it errs in the direction that INVENTS freshness. A wrong
# reader here would make every arm below pass for the wrong reason.
want=$(date -u -d '2026-01-01 00:00:00 UTC' +%s)
got=$(_liv_epoch '2026-01-01 00:00:00')
[[ "$got" == "$want" ]] \
  && ok_t "an unqualified store stamp is read as UTC, not as local time" \
  || bad_t "unqualified stamp is UTC" "got '$got', want '$want' — a skewed reader invents or destroys freshness"
got=$(_liv_epoch "$(date -d '@1767225600' -Iseconds)")
[[ "$got" == "1767225600" ]] \
  && ok_t "an offset-carrying audit stamp is read at its own offset" \
  || bad_t "ISO stamp keeps its offset" "got '$got', want 1767225600"
_liv_epoch "" >/dev/null 2>&1 \
  && bad_t "an empty stamp is rejected" "_liv_epoch '' succeeded — an absent stamp would become an epoch" \
  || ok_t "an empty stamp is rejected rather than dated"

# --- 1. a closed row this seat wrote is proof of life -----------------------
seed_board_done DIVE-8001 alpha "$(utc -300)"
j=$(run alpha); rc1=$(rc_last)
[[ "$(jq -r '.data.seats[0].verdict' <<<"$j")" == "alive" ]] \
  && ok_t "a seat that closed a row 5m ago is alive" \
  || bad_t "board effect -> alive" "verdict=$(jq -r '.data.seats[0].verdict' <<<"$j")"
[[ "$(jq -r '.data.seats[0].evidence.source' <<<"$j")" == "board" ]] \
  && [[ "$(jq -r '.data.seats[0].evidence.artifact' <<<"$j")" == DIVE-8001* ]] \
  && ok_t "the verdict NAMES the artifact that dated it (DIVE-8001), so an operator can check it by hand" \
  || bad_t "evidence names the artifact" "evidence=$(jq -c '.data.seats[0].evidence' <<<"$j") — an unnamed 'alive' is another unfalsifiable claim"
(( rc1 == 0 )) && ok_t "an all-alive fleet exits 0" || bad_t "rc 0 when alive" "rc=$rc1"

# --- 2. the ledger alone is enough (a seat can be alive with no board row) ---
seed_ledger task.done beta "$(utc -120)"
[[ "$(verdict_of beta)" == "alive" ]] \
  && [[ "$(run beta | jq -r '.data.seats[0].evidence.source')" == "ledger" ]] \
  && ok_t "a durable-action ledger row alone proves life (source=ledger)" \
  || bad_t "ledger effect -> alive" "$(run beta | jq -c '.data.seats[0]')"

# --- 3. the audit log alone is enough --------------------------------------
seed_audit agent-gamma 'task ls' "$(iso -60)"
[[ "$(verdict_of gamma)" == "alive" ]] \
  && [[ "$(run gamma | jq -r '.data.seats[0].evidence.source')" == "audit" ]] \
  && ok_t "an audit row written by this seat's uid alone proves life (source=audit)" \
  || bad_t "audit effect -> alive" "$(run gamma | jq -c '.data.seats[0]')"

# --- 4. STALE is not alive: every probe ran and found nothing in the window --
# This is dev3's incident: four rows held for three days, every presence signal
# green. The seat's last effect is real and OLD, which is the whole finding.
seed_board_done DIVE-8004 delta "$(utc -259200)"
seed_ledger task.start delta "$(utc -259200)"
seed_audit agent-delta 'task show' "$(iso -259200)"
j=$(run delta); rc4=$(rc_last)
[[ "$(jq -r '.data.seats[0].verdict' <<<"$j")" == "no-effect" ]] \
  && ok_t "a seat whose last artifact is 3 days old reads no-effect, not alive" \
  || bad_t "stale -> no-effect" "verdict=$(jq -r '.data.seats[0].verdict' <<<"$j")"
(( rc4 == 4 )) \
  && ok_t "a no-effect seat exits 4 — the finding is loud, not a footnote in the body" \
  || bad_t "rc 4 on no-effect" "rc=$rc4"
[[ "$(jq -r '.data.seats[0].unreadableSources' <<<"$j")" == "0" ]] \
  && ok_t "no-effect is only claimed when all 3 probes actually RAN (unreadableSources=0)" \
  || bad_t "no-effect implies a complete read" "unreadableSources=$(jq -r '.data.seats[0].unreadableSources' <<<"$j")"

# --- 5. the THIRD STATE: nothing could be read -----------------------------
# Both stores are moved out of reach. The seat may be perfectly healthy; we
# cannot say. The one thing this must never render is green.
REAL_DB="$TASKS_DB"; REAL_AUDIT="$AUDIT_LOG"
TASKS_DB="$TMP/nowhere/tasks.db"; AUDIT_LOG="$TMP/nowhere/audit.log"
j=$(run epsilon); rc5=$(rc_last)
v5=$(jq -r '.data.seats[0].verdict' <<<"$j")
[[ "$v5" == "not-reached" ]] \
  && ok_t "a seat whose every probe failed reads NOT-REACHED — the distinct third state" \
  || bad_t "unmeasurable -> not-reached" "verdict=$v5"
[[ "$v5" != "alive" ]] \
  && ok_t "NOT-REACHED does not fold into green (the false-green the theme is named after)" \
  || bad_t "not-reached is not alive" "an unmeasurable seat certified as alive — this is DIVE-3726 with extra steps"
[[ "$v5" != "no-effect" ]] \
  && ok_t "NOT-REACHED does not fold into no-effect either — a broken probe is not an accusation" \
  || bad_t "not-reached is not no-effect" "a working seat would be reported dead because OUR probe broke"
(( rc5 == 3 )) \
  && ok_t "an unmeasured seat exits 3 — nonzero, and distinguishable from no-effect's 4" \
  || bad_t "rc 3 on not-reached" "rc=$rc5"
[[ "$(jq -r '.data.seats[0].unreadableSources' <<<"$j")" == "3" ]] \
  && [[ "$(jq -r '.data.seats[0].degraded|length' <<<"$j")" == "3" ]] \
  && ok_t "all 3 dead probes are named in degraded[] with their reason" \
  || bad_t "degraded names the failed probes" "$(jq -c '.data.seats[0].degraded' <<<"$j")"
TASKS_DB="$REAL_DB"; AUDIT_LOG="$REAL_AUDIT"

# --- 6. positive evidence outranks a broken probe --------------------------
seed_audit agent-zeta 'task done' "$(iso -30)"
REAL_DB="$TASKS_DB"; TASKS_DB="$TMP/nowhere/tasks.db"
j=$(run zeta)
[[ "$(jq -r '.data.seats[0].verdict' <<<"$j")" == "alive" ]] \
  && (( $(jq -r '.data.seats[0].degraded|length' <<<"$j") == 2 )) \
  && ok_t "one readable source with a fresh artifact is alive even with 2 probes down, and the degradation is still recorded" \
  || bad_t "fresh evidence beats a degraded probe set" "$(jq -c '.data.seats[0]' <<<"$j")"
TASKS_DB="$REAL_DB"

# --- 7. stale-plus-degraded is NOT-REACHED, not no-effect ------------------
# The direction people get wrong. The board says nothing recent; the audit probe
# never ran. We do not know, so we must not accuse.
seed_board_done DIVE-8007 eta "$(utc -259200)"
seed_ledger task.done eta "$(utc -259200)"
REAL_AUDIT="$AUDIT_LOG"; AUDIT_LOG="$TMP/nowhere/audit.log"
v7=$(verdict_of eta)
[[ "$v7" == "not-reached" ]] \
  && ok_t "stale readable sources + one dead probe = NOT-REACHED (the missing probe could have held the effect)" \
  || bad_t "stale + degraded -> not-reached" "verdict=$v7 — 'no-effect' here is an accusation we cannot support"
AUDIT_LOG="$REAL_AUDIT"

# --- 8. another seat's effects do not date THIS seat ----------------------
seed_board_done DIVE-8008 theta "$(utc -60)"
seed_ledger task.done theta "$(utc -60)"
seed_audit agent-theta 'task done' "$(iso -60)"
[[ "$(verdict_of iota)" == "no-effect" ]] \
  && ok_t "a busy neighbour does not make an idle seat alive (attribution is per-seat)" \
  || bad_t "effects are attributed" "verdict=$(verdict_of iota) — the probe is matching rows it should not"

# --- 9. updated_at is NOT an effect of the assignee -----------------------
# A third party editing the row bumps updated_at. Accepting it would let anyone
# else's edit certify a dead seat as alive — presence-by-proxy, one layer down.
seed_board_touch DIVE-8009 kappa "$(utc -30)"
[[ "$(verdict_of kappa)" == "no-effect" ]] \
  && ok_t "a fresh updated_at on the seat's row is not an effect it wrote (someone else's edit cannot certify it)" \
  || bad_t "updated_at is not an effect" "verdict=$(verdict_of kappa)"

# --- 10. no presence signal is consulted, structurally -------------------
# An assertion about the SOURCE, because the failure mode is someone helpfully
# adding a pgrep back in a year and every behavioural arm above still passing.
# Comments and the usage heredoc are stripped first — both legitimately NAME the
# signals this command refuses to read, and matching them would make the arm
# unfixably red (and tempt whoever hits it to delete the guard).
PRESENCE_RE='\b(pgrep|systemctl|capture-pane|is-active)\b|\btmux\b|\bps -[eaf]'
liv_code() { sed -e '/^_liv_usage() {/,/^}$/d' -e 's/#.*$//' "$SRC/cmd_liveness.sh"; }
if liv_code | grep -nE "$PRESENCE_RE" >/dev/null; then
  bad_t "no presence probe in the implementation" \
    "$(liv_code | grep -nE "$PRESENCE_RE" | head -3)"
else
  ok_t "the implementation consults no process table, unit state, tmux session or pane scrape outside its comments"
fi
# ...and the guard is not vacuous: it fires on a line that DOES probe presence.
if printf 'foo() { pgrep -u "$u" -f bar; }\n' | grep -nE "$PRESENCE_RE" >/dev/null; then
  ok_t "CONTROL: the presence-probe guard fires on a real pgrep line, so its green above is a measurement"
else
  bad_t "presence guard control" "the regex matches nothing at all — arm 10 is vacuous"
fi

# --- 11. an unreadable ROSTER is itself a not-reached --------------------
# registry_read()'s empty-body fallback makes "no registry" and "no agents" look
# identical; a fleet-wide pass over zero seats is the cheapest false green there
# is. The checked read must surface it and it must cost the exit code.
seed_board_done DIVE-8011 claude "$(utc -60)"
out=$( JSON_MODE=0; cmd_liveness --json --window=60 2>/dev/null ); rc11=$?
[[ "$(jq -r '.data.roster' <<<"$out")" == "not-reached" ]] \
  && (( rc11 == 3 )) \
  && ok_t "an absent agent registry renders roster=not-reached and exits 3, even though the one seat it could see is alive" \
  || bad_t "roster not-reached is loud" "roster=$(jq -r '.data.roster' <<<"$out") rc=$rc11 summary=$(jq -c '.data.summary' <<<"$out")"
printf '{"agents":{"delta":{"type":"claude"}}}\n' >"$REGISTRY"
out=$( JSON_MODE=0; cmd_liveness --json --window=60 2>/dev/null ); rc11b=$?
[[ "$(jq -r '.data.roster' <<<"$out")" == "read" ]] \
  && [[ "$(jq -r '.data.summary.noEffect' <<<"$out")" == "1" ]] \
  && (( rc11b == 4 )) \
  && ok_t "with a readable registry the roster reads and the fleet verdict is the seats' own (1 no-effect -> rc 4)" \
  || bad_t "readable roster grades the seats" "roster=$(jq -r '.data.roster' <<<"$out") rc=$rc11b summary=$(jq -c '.data.summary' <<<"$out")"
rm -f "$REGISTRY"

# --- 12. usage: a bad window is refused, not silently defaulted ----------
( JSON_MODE=0; cmd_liveness --window=0 --agent=alpha >/dev/null 2>&1 ); rc=$?
(( rc == E_USAGE )) && ok_t "--window=0 is a usage error, not a silently-substituted default" \
                     || bad_t "--window=0 refused" "rc=$rc (E_USAGE=$E_USAGE)"
( JSON_MODE=0; cmd_liveness --nonsense >/dev/null 2>&1 ); rc=$?
(( rc == E_USAGE )) && ok_t "an unknown flag is refused" || bad_t "unknown flag refused" "rc=$rc"

# --- 13. a non-zero verdict claims its reason (DIVE-2598 backstop) ---------
# Found in a real run of the BUILT bundle, not by any assertion above: rc 4/3 are
# deliberate verdicts, but an unreported non-zero exit makes the CLI append "the
# command did NOT run to completion and its effect is UNKNOWN" to a board that
# printed in full. Compiles is not works, and a green unit suite is not a run.
rm -f "$FIVE_REPORTED_FLAG"
_=$(run delta)
[[ -f "$FIVE_REPORTED_FLAG" ]] \
  && ok_t "a no-effect verdict marks itself REPORTED, so the exit-trap backstop does not call the run a CLI bug" \
  || bad_t "non-zero verdict claims its reason" "FIVE_REPORTED_FLAG unset after rc=$(rc_last) — the operator gets a 'effect is UNKNOWN' diagnostic over a complete board"
rm -f "$FIVE_REPORTED_FLAG"
REAL_DB="$TASKS_DB"; REAL_AUDIT="$AUDIT_LOG"
TASKS_DB="$TMP/nowhere/tasks.db"; AUDIT_LOG="$TMP/nowhere/audit.log"
_=$(run epsilon)
[[ -f "$FIVE_REPORTED_FLAG" ]] \
  && ok_t "a NOT-REACHED verdict marks itself reported too (rc 3 travels the same path as rc 4)" \
  || bad_t "not-reached claims its reason" "FIVE_REPORTED_FLAG unset after rc=$(rc_last)"
TASKS_DB="$REAL_DB"; AUDIT_LOG="$REAL_AUDIT"
rm -f "$FIVE_REPORTED_FLAG"
_=$(run alpha)
[[ -f "$FIVE_REPORTED_FLAG" ]] \
  && bad_t "CONTROL: rc 0 does not claim a reason" "the flag is set on a SUCCESSFUL run — the arms above would pass unconditionally" \
  || ok_t "CONTROL: an all-alive run sets no flag, so the two arms above measure the non-zero path specifically"

# ==== MUTATION A — the third state folds UP into alive ===================
eval "$(declare -f _liv_verdict | sed '1s/_liv_verdict/_liv_verdict_REAL/')"
_liv_verdict() {
  local fresh="${1:-0}" unreadable="${2:-0}"
  if (( fresh > 0 || unreadable > 0 )); then printf 'alive\n'; return 0; fi
  printf 'no-effect\n'
}
declare -f _liv_verdict | grep -q 'fresh > 0 || unreadable > 0' \
  && ok_t "MUTATION A applied (a no-op substitution and a vacuous arm are both all-green)" \
  || bad_t "MUTATION A applied" "the substitution did not take; the arms below prove nothing"
REAL_DB="$TASKS_DB"; REAL_AUDIT="$AUDIT_LOG"
TASKS_DB="$TMP/nowhere/tasks.db"; AUDIT_LOG="$TMP/nowhere/audit.log"
[[ "$(verdict_of epsilon)" == "alive" ]] \
  && ok_t "MUTATION A: with the fold, the unmeasurable seat certifies as ALIVE — arm 5 is RED, so its green was the third state's doing" \
  || bad_t "MUTATION A turns arm 5 red" "verdict=$(verdict_of epsilon) — arm 5 passes without the third state and proves nothing"
TASKS_DB="$REAL_DB"; AUDIT_LOG="$REAL_AUDIT"
[[ "$(verdict_of delta)" == "no-effect" ]] \
  && ok_t "MUTATION A: the stale-but-readable seat is UNAFFECTED — the mutation is scoped to the third state, not to grading at large" \
  || bad_t "MUTATION A leaves arm 4 green" "verdict=$(verdict_of delta)"
[[ "$(verdict_of alpha)" == "alive" ]] \
  && ok_t "MUTATION A: a genuinely alive seat is unaffected" \
  || bad_t "MUTATION A leaves arm 1 green" "verdict=$(verdict_of alpha)"

# ==== MUTATION C — the third state folds DOWN into no-effect ============
# The other direction, and the one a careless fix produces: everything unknown
# gets called dead. Arm 5's "not no-effect" assertion is the only thing that
# catches it, so that assertion is what gets mutation-tested here.
_liv_verdict() {
  local fresh="${1:-0}"
  if (( fresh > 0 )); then printf 'alive\n'; return 0; fi
  printf 'no-effect\n'
}
declare -f _liv_verdict | grep -q 'unreadable' \
  && bad_t "MUTATION C applied" "the mutant still consults the unreadable count; it did not take" \
  || ok_t "MUTATION C applied (the unreadable count is gone from the verdict)"
TASKS_DB="$TMP/nowhere/tasks.db"; AUDIT_LOG="$TMP/nowhere/audit.log"
v=$(verdict_of epsilon)
[[ "$v" == "no-effect" ]] \
  && ok_t "MUTATION C: without the third state the unmeasurable seat is ACCUSED (no-effect) — arm 5's second assertion is RED" \
  || bad_t "MUTATION C turns arm 5 red" "verdict=$v"
TASKS_DB="$REAL_DB"; AUDIT_LOG="$REAL_AUDIT"

# ==== MUTATION B — freshness is unconditionally true ==================
eval "$(declare -f _liv_verdict_REAL | sed '1s/_liv_verdict_REAL/_liv_verdict/')"
eval "$(declare -f _liv_is_fresh | sed '1s/_liv_is_fresh/_liv_is_fresh_REAL/')"
_liv_is_fresh() { return 0; }
declare -f _liv_is_fresh | grep -q 'now - e' \
  && bad_t "MUTATION B applied" "the window test is still present; the mutant did not take" \
  || ok_t "MUTATION B applied (the window test is gone)"
[[ "$(verdict_of delta)" == "alive" ]] \
  && ok_t "MUTATION B: with no window, the 3-day-dead seat certifies as ALIVE — arm 4 is RED, so its green was the window's doing" \
  || bad_t "MUTATION B turns arm 4 red" "verdict=$(verdict_of delta) — arm 4 passes without a freshness test"

# ---- restore, and prove the restore took --------------------------------
eval "$(declare -f _liv_is_fresh_REAL | sed '1s/_liv_is_fresh_REAL/_liv_is_fresh/')"
now=$(date +%s)
_liv_is_fresh "$(( now - 10 ))" "$now" 60 \
  && ok_t "freshness restored: a 10s-old artifact inside a 60s window is fresh" \
  || bad_t "freshness restored (positive)" "the restore left a resolver that rejects a fresh stamp"
_liv_is_fresh "$(( now - 600 ))" "$now" 60 \
  && bad_t "freshness restored (negative)" "the restored resolver accepts a 10m-old stamp in a 60s window — a weaker transcription, not production" \
  || ok_t "freshness restored to the PRODUCTION test, not a permissive snapshot (a 10m-old stamp is still stale)"
_liv_is_fresh "$(( now + 300 ))" "$now" 60 \
  && ok_t "restored resolver keeps the clock-skew rule: a future stamp is an effect, not death" \
  || bad_t "clock-skew rule survives restore" "a skewed writer would be reported dead fleet-wide"
[[ "$(_liv_verdict 0 1)" == "not-reached" && "$(_liv_verdict 0 0)" == "no-effect" && "$(_liv_verdict 1 1)" == "alive" ]] \
  && ok_t "verdict restored across all three states, so nothing added below runs against a mutant" \
  || bad_t "verdict restored" "0/1=$(_liv_verdict 0 1) 0/0=$(_liv_verdict 0 0) 1/1=$(_liv_verdict 1 1)"
[[ "$(verdict_of alpha)" == "alive" && "$(verdict_of delta)" == "no-effect" ]] \
  && ok_t "end-to-end re-run after every restore reproduces arm 1 and arm 4" \
  || bad_t "post-restore end-to-end" "alpha=$(verdict_of alpha) delta=$(verdict_of delta)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
