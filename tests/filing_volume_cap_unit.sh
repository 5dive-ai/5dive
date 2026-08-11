#!/usr/bin/env bash
# TIER: core — the per-filer daily filing budget, ENFORCED (DIVE-3245).
#
# WHY IT EXISTS. lodar's instinct was to forbid verifiers from filing low/medium
# rows. main measured it first and the target was wrong: verifiers filed 10 of
# 1092 low/medium rows in a month, and main filed 577. Of the 1092, 245 were
# cancelled. main already had a filing cap in his own directives and it was not
# binding — "a rule nobody enforces is detection, not control."
#
# THE TWO ARMS THAT MATTER, and they are the two halves of one question, because
# a cap that never fires and a cap that fires on everyone both print no complaints:
#   fires    a filer over budget, at low/medium, is REFUSED with a non-zero rc
#   spares   the same board does NOT refuse urgent/high, and does not refuse a
#            filer at a normal day's volume
#
# NO BYPASS. There is deliberately no flag and no env override — an env-tunable
# cap is the bypass spelled differently, and invisible in the record. So this
# harness trips the REAL threshold by seeding real rows, which is also why it
# cannot be fooled by a cap that was quietly loosened.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# DIVE_TEST_SRC lets tests/filing_volume_cap_mutation.sh run this whole harness
# against a MUTATED copy of src/ — the connection proof. Without it a mutation
# harness can only re-read the file it just edited, which proves nothing about
# whether these arms are wired to the code.
SRC="${DIVE_TEST_SRC:-$ROOT/src}"
TMP=$(mktemp -d /tmp/filing-volume-cap.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
chk() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fi
}

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
# The cap governs the SHARED board, so it only applies to the shared board
# (_task_filing_cap_store_is_prod). Declare this fixture as prod or every arm
# below is vacuous — the cap would decline to enforce and each "refused" arm
# would be measuring the fence, not the rule.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
# Do not write fixture rows into the production fleet audit log (DIVE-3228).
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
tasks_db_init; _tasks_db_migrate >/dev/null 2>&1

CAP="$_TASK_FILING_DAILY_CAP"
# BEHAVIOURAL, not a grep of the source. A source grep would still pass if the
# assignment were `${_TASK_FILING_DAILY_CAP:-15}` — which is exactly the bypass
# this row forbids, spelled so it reads like a default. Export a hostile value
# and re-source: the constant must survive it.
_cap_under_env=$( SRC="$SRC" _TASK_FILING_DAILY_CAP=999 bash -c '
  set +e
  for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
           lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
           lib/tasks_db.sh lib/actor.sh cmd_task.sh; do . "$SRC/$f" 2>/dev/null; done
  printf "%s" "$_TASK_FILING_DAILY_CAP"' 2>/dev/null )
chk "the cap is a CONSTANT: a hostile env value does NOT raise it" "15" "$_cap_under_env"

# ---- BECOMING A FILER, BY UID AND NOT BY ARGV ------------------------------
# DIVE-3245 it.2. The first cut of this harness drove every arm through `--from`,
# which is THE SAME DOOR THE BYPASS USED — so a suite that was green end to end
# could not see that one fresh `--from` token filed unlimited rows. A harness that
# reaches the rule the way the exploit does cannot grade the exploit.
#
# So a fixture filer is now a UNIX PRINCIPAL: pin the two seams the resolver reads
# (`_gate_caller_uid`, `_gate_passwd_stream`, the DIVE-2518/1413 pattern already
# used by tests/gate_sudo_uid_forge_unit.sh) and let the real derivation ladder run.
# The names are deliberately NOT registered agents, so the registry rung declines
# and the `agent-*` passwd rung answers — deterministic on any host, and it means
# these arms exercise the shipped ladder rather than a stub of it.
AS_UN=""; AS_UID=""
_gate_caller_uid() { printf '%s' "${AS_UID:-$EUID}"; }
_gate_passwd_stream() {
  [[ -n "$AS_UN" && -n "$AS_UID" ]] && printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$AS_UN" "$AS_UID" "$AS_UID" "$AS_UN"
  printf '%s\n' "$(</etc/passwd)"
}
declare -A _FILER_UID=(); _NEXT_UID=90001
as_filer() { # <board-name> — become the unix principal that DERIVES to this name
  local who="$1"
  [[ -n "${_FILER_UID[$who]:-}" ]] || { _FILER_UID[$who]=$_NEXT_UID; _NEXT_UID=$((_NEXT_UID+1)); }
  AS_UN="agent-$who"; AS_UID="${_FILER_UID[$who]}"
}
# Liveness on the seam itself: if this ever stops deriving what it claims to, every
# arm below is measuring nothing, and it would do so SILENTLY.
chk "the fixture seam really derives the board name from the uid" "heavy" \
    "$( as_filer heavy; task_actor "" )"

seed() { # <derived-filer> <n> <priority> [age-hours] [created-by-claim]
  # Seeds stamp BOTH columns the way `task add` does: `created_by` is the claim
  # (defaulting to the filer when there is none) and `derived_actor` is the measured
  # truth. A seed that wrote only `created_by` could not tell the two apart, which
  # is the whole question this file now grades.
  local who="$1" n="$2" pri="$3" age="${4:-1}" claim="${5:-$1}" i
  for (( i=0; i<n; i++ )); do
    db "INSERT INTO tasks (title,body,priority,assignee,created_by,derived_actor,kind,status,created_at)
        VALUES ('seeded row $who $i','','$pri','$claim','$claim','$who','standard','todo',
                datetime('now','-${age} hours'));" >/dev/null 2>&1
  done
}
# add_as <derived-filer> <priority> <title> [claim]
# With no <claim> the invocation carries no `--from` at all. With one, the claim and
# the derivation DISAGREE on purpose — that disagreement is the exploit, and it is
# now something the harness can express instead of something it was blind to.
add_as() {
  ( JSON_MODE=0; as_filer "$1"
    if [[ -n "${4:-}" ]]; then cmd_task_add "$3" --priority="$2" --from="$4"
    else cmd_task_add "$3" --priority="$2"; fi ) 2>&1
}
rc_of() { add_as "$@" >/dev/null 2>&1; printf '%s' "$?"; }

# ---- a filer at a NORMAL day's volume is untouched --------------------------
# The median filer's worst rolling-24h on the real board is 4.5, and ten of
# fourteen filers never exceed 6. This arm is the one that proves the cap is not
# simply always-on — without it, every "refused" arm below is satisfied by a
# rule that refuses everything.
seed quiet 6 medium 2
chk "a filer at 6/24h (above the real median) files fine" "0" "$(rc_of quiet medium 'ordinary finding')"

# ---- the cap FIRES ----------------------------------------------------------
seed heavy "$CAP" medium 2
out=$(add_as heavy medium 'one row too many')
chk "at the cap, a medium row is REFUSED" "1" "$(grep -c 'filing cap' <<<"$out")"
chk "and the refusal is non-zero rc, not a warning" "$E_VALIDATION" "$(rc_of heavy medium 'another one')"
chk "low is capped too, not just medium" "1" \
    "$(add_as heavy low 'a low one' | grep -c 'filing cap')"

# ---- what the refusal SAYS is the product ----------------------------------
# A refusal that only names the limit buys silence, not judgement.
chk "it names the ALTERNATIVE, not just the limit (the row body)" "1" \
    "$(grep -c 'BODY of the row you found it on' <<<"$out")"
chk "it points at the wiki for durable knowledge" "1" "$(grep -c 'community/wiki' <<<"$out")"
chk "it states there is NO bypass flag" "1" "$(grep -c 'no bypass flag' <<<"$out")"
chk "it records the refused title rather than losing it" "1" \
    "$(grep -c 'REFUSED TITLE' <<<"$out")"
chk "and the title really is in policy_refusals" "1" \
    "$(db "SELECT COUNT(*) FROM policy_refusals WHERE detail LIKE '%one row too many%';")"

# ---- serious work is NEVER capped ------------------------------------------
# lodar, 2026-08-09: a quota that can block a SERIOUS finding will eventually eat
# one. The priority escape is the designed way out, and it is better than a flag
# because it is a claim about severity, recorded on the row.
chk "urgent is never capped, even far over budget" "0" "$(rc_of heavy urgent 'production is down')"
chk "high is never capped" "0" "$(rc_of heavy high 'a serious finding')"

# ---- the window is ROLLING, and old rows fall out of it ---------------------
# A calendar-day cap lets a burst straddle midnight and clear itself, which is
# the shape that produced the damage (one filer, 65 rows in a day).
seed stale "$CAP" medium 30
chk "rows older than 24h do NOT count toward the cap" "0" \
    "$(rc_of stale medium 'a fresh day')"

# ---- what must not be counted ----------------------------------------------
# A recurring instance is MATERIALIZED by the scheduler, not filed by a person.
# Counting it fires the cap on a cadence nobody chose that day.
seed tmpl "$CAP" medium 2
db "UPDATE tasks SET from_template_id=999 WHERE created_by='tmpl';" >/dev/null 2>&1
chk "template-materialized rows do NOT count toward their creator's cap" "0" \
    "$(rc_of tmpl medium 'a real filing on a template lane')"

# ---- the fence: a fixture store is not the shared board ---------------------
# Liveness in the other direction — the arms above are only meaningful because
# this fixture DECLARED itself prod. Undeclare it and the same over-budget filer
# files freely, which proves those refusals came from the rule, not the fence.
chk "off the shared board the cap declines to enforce" "0" \
    "$( FIVEDIVE_PROD_TASKS_DB="$TMP/not-the-board.db" rc_of heavy medium 'off-board filing' )"

# ---- THE KEY, NOT THE RULE (DIVE-3245 it.2) ---------------------------------
# Everything above this line perturbs the RULE — threshold, window, priority,
# template. All of it was green at a9618e4 and the cap still had a bypass, because
# the rule was never the weak part: the KEY was. `task_actor "$from"` returns the
# CLAIM, so the count and the stamp agreed with each other and neither agreed with
# reality. These arms grade the axis nobody thought to grade.
#
# `heavy` is at the cap from the arms above.
chk "a FRESH --from does NOT start a fresh budget (the reproduced bypass)" "$E_VALIDATION" \
    "$(rc_of heavy medium 'one argv token, unlimited rows' heavy-2)"
chk "and the refusal names the DERIVED filer, not the claim" "1" \
    "$(add_as heavy medium 'named by derivation' heavy-2 | grep -c 'heavy has filed')"
chk "--from=cli does not buy the unmeasurable-actor exemption" "$E_VALIDATION" \
    "$(rc_of heavy medium 'claiming the sentinel' cli)"
chk "--from=<a real quiet agent> does not launder an over-budget filer" "$E_VALIDATION" \
    "$(rc_of heavy medium 'borrowing a quiet name' quiet)"

# The inverse, and it is a DIFFERENT claim: the cap must key on the derivation
# rather than merely also-consult it. A filer who has personally filed nothing is
# untouched even while CLAIMING the name of a filer who is at the cap.
chk "the count follows the DERIVATION, not the claim: a fresh filer claiming 'heavy' files fine" "0" \
    "$(rc_of newcomer medium 'my first row today' heavy)"

# A uid-less relay principal (`council`, `telegram`) can only ever be NAMED, so its
# rows carry created_by=<principal> and derived_actor=<the seat that ran it>. The
# quota charges the seat — that is the entity it exists to bind, and it is the
# COALESCE precedence in _task_filer_low_med_24h stated as a behaviour.
seed relayer "$CAP" medium 2 council
chk "rows filed as a relay principal are charged to the SEAT that ran them" "$E_VALIDATION" \
    "$(rc_of relayer medium 'still my budget' council)"

# Rows predating the derived_actor column have no derivation recorded. Dropping
# them would hand every filer on the board an empty budget the day this ships, so
# created_by is the fallback — the only evidence those rows have.
seed legacy "$CAP" medium 2
db "UPDATE tasks SET derived_actor=NULL WHERE created_by='legacy';" >/dev/null 2>&1
chk "pre-column rows (derived_actor NULL) still count, via created_by" "$E_VALIDATION" \
    "$(rc_of legacy medium 'a row on a legacy board')"

# The sentinel exemption is KEPT and is now honest: `cli` means the uid genuinely
# did not resolve to a board actor (root, a build bot, a uid absent from passwd) —
# a state nothing can claim its way into. Derive as root and the exemption holds.
seed cli "$CAP" medium 2
chk "a genuinely unmeasurable actor is still exempt (derived cli, not claimed)" "0" \
    "$( AS_UN=""; AS_UID="0"; ( JSON_MODE=0; cmd_task_add 'a root cron row' --priority=medium ) >/dev/null 2>&1; printf '%s' "$?" )"

# ---- loop scaffolding does not spend its author's budget --------------------
# `task loop` INSERTs a run parent plus one row per step directly, at medium and
# kind=standard, so they never reach the materialization exemption. Uncounted:
# one decision produces N rows and a five-step loop would burn a third of the
# author's day.
#
# These fixture rows carry the `_LOOP_MARK` body marker AS WELL as the origin
# column, deliberately: they must be indistinguishable from real loop rows, so
# this arm stays green under both the old predicate and the new one. It is the
# "does the exemption work" question — and on its own it is exactly what let it.2
# ship a self-declared exemption. The adversarial half is below.
seed looper "$CAP" medium 2
db "UPDATE tasks SET origin='task-loop', body='[[5dive-loop:work]]' WHERE created_by='looper';" >/dev/null 2>&1
chk "loop-materialized rows do NOT count toward their author's cap" "0" \
    "$(rc_of looper medium 'a real filing on a loop lane')"

# ---- WHO ELSE CAN STAND IN THE EXEMPTION (DIVE-3245 it.3) -------------------
# it.1 fixed the KEY (count the derivation, not the claim). Both doors quinn found
# next left the key honest and edited the ROW SET instead: an honest actor counted
# over a population the caller controls. So every arm from here down asks the
# question no arm above it asks — not "does the exemption work" but "who else can
# assert membership in it".
#
# Door 1, measured at f3d4b8f: the exclusion read `body NOT LIKE '%[[5dive-loop:%'`
# and `--body` is an ordinary flag. 25 consecutive low rows carrying the marker
# filed over a full budget and the count read 0.
#
# THE ARM WALKS THE VOLUME rather than testing one row against a full budget, and
# the difference is the whole exploit. A self-declared exemption does not rescue a
# row from someone else's budget — it stops the filer's OWN rows from ever
# accumulating, so the count never rises and no row is ever the one too many. Only
# a filer who starts at zero and files past the cap can see that.
_marker_rc=0
for (( _i=0; _i<=CAP; _i++ )); do
  ( JSON_MODE=0; as_filer marker
    cmd_task_add "marker row $_i" --priority=low --body='[[5dive-loop:run]]'
  ) >/dev/null 2>&1
  _marker_rc=$?
done
chk "an ordinary filer CANNOT buy the loop exemption by writing the marker into --body" \
    "$E_VALIDATION" "$_marker_rc"

# Door 2, and it PREDATES the it.2 fix: `--materialized` was parsed off argv with
# no guard, so 20/20 low rows filed over the cap. The token is gone — an argv
# assertion now cannot even name the exemption, let alone reach it.
chk "an ordinary filer CANNOT assert --materialized on argv" "$E_USAGE" \
    "$( ( JSON_MODE=0; as_filer heavy
          cmd_task_add 'asserting the exemption' --priority=low --materialized
        ) >/dev/null 2>&1; printf '%s' "$?" )"
chk "and the row it tried to file does not exist" "0" \
    "$(db "SELECT COUNT(*) FROM tasks WHERE title='asserting the exemption';")"

# The other direction, and it is a separate claim: closing a door must not brick
# the room. The exemption exists because a cap firing halfway through a plan
# leaves a HALF-materialized one, which is the worse failure. `task_add_materialized`
# is the derived door the six internal writers call, and it still opens.
chk "the DERIVED door still exempts: an over-budget filer materializing files fine" "0" \
    "$( ( JSON_MODE=0; as_filer heavy
          task_add_materialized 'a materialized child' --priority=medium
        ) >/dev/null 2>&1; printf '%s' "$?" )"

# And the writer must really MARK them, or the exclusion above is dead code and the
# overcount returns silently. Marking and exempting are two facts; a suite that
# only seeds the mark grades one of them.
_task_resolve_coordinator() { printf 'main'; }
cmd_send() { :; }
( as_filer looper
  cmd_task_loop_start --title='fixture loop' --steps='[{"label":"s1","agent":"looper"}]'
) >/dev/null 2>&1
chk "task loop start MARKS the rows it materialises (run parent + step)" "2" \
    "$(db "SELECT COUNT(*) FROM tasks WHERE origin='task-loop' AND title IN ('fixture loop','s1');")"

printf -- '-----\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
