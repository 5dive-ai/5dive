#!/usr/bin/env bash
# DIVE-4399: `5dive-refresh-plugins.sh --restart` was the path that still
# resurrected an operator-parked agent. `systemctl restart` on a stopped unit
# STARTS it, and this script never read `desiredState` — zero hits in the whole
# file. Measured on `5dive-teal-fox-cx43`: `katya`, parked, restarted nightly for
# roughly a month; masking the unit by hand was the only working defence.
#
# DIVE-4033 fixed this exact defect on this exact agent in src/cmd_selfupdate.sh
# and swept for siblings with `git grep -l desiredState -- src scripts`. This
# file sits at the REPO ROOT, outside that path filter, so the sweep structurally
# could not see it. A1 below is that lesson made mechanical: it re-runs the sweep
# WITHOUT a path filter and fails if any repo-root restart path is unguarded.
#
# Two ways this fix can be wrong, failing in OPPOSITE directions:
#
#   RESURRECTS — the check is absent, or consulted after the restart is
#                scheduled, and the parked agent comes back. The original bug.
#   FREEZES    — something merely UNKNOWN (no registry, no jq, corrupt JSON, an
#                agent absent from the file, no such field) reads as "parked" and
#                the whole fleet silently keeps running yesterday's plugins. That
#                is the worse direction here: this very script is where DIVE-3269
#                measured five staged plugins sitting an hour behind two merged
#                rows with no surface saying so.
#
# So every positive arm is paired with a NEGATIVE CONTROL that only passes
# because the skip does NOT fire on an unknown.
#
# Hermetic in the shape DIVE-4033/DIVE-3172/DIVE-3173 established: the block is
# extracted VERBATIM from 5dive-refresh-plugins.sh between its fence markers and
# run as the SHIPPED BYTES. `systemd-run` is shadowed by a PATH stub that only
# records its argv, so no unit, no agent and no registry outside $WORK is touched.
#
# Run: bash tests/refresh_plugins_parked_agent_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NO `2>/dev/null` — the helper's
# stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154  # rc is $? captured at trap time
trap 'rc=$?; rm -rf "${WORK:-}"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - refresh_plugins_parked_agent_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
SCRIPT="$ROOT/5dive-refresh-plugins.sh"

FENCE='DIVE-4399 an operator-parked agent stays parked (the plugin-refresh bounce)'
block="$(sed -n "/^# >>> ${FENCE//\//\\/}\$/,/^# <<< ${FENCE//\//\\/}\$/p" "$SCRIPT")"
if [[ -n "$block" ]] && grep -q '_agent_is_parked()' <<<"$block" \
   && grep -q '_restart_changed_agents()' <<<"$block"; then
  ok_t "E1 the parked block is extractable from 5dive-refresh-plugins.sh"
else
  bad_t "E1 parked block missing" "markers '# >>> / # <<< $FENCE' not found in $SCRIPT"
  echo; echo "$PASS passed, $FAIL failed"; SUMMARY_PRINTED=1; exit 1
fi

# The restart loop must live INSIDE the fence with the helper. A loop outside it
# would be absent from the bytes every arm below runs, so this harness would be
# grading a skip the box never reaches (DIVE-4033 makes the same demand of its
# own helper, and for the same reason).
if grep -q 'systemd-run' <<<"$block"; then
  ok_t "E2 the restart loop ships INSIDE the fence — these arms run the bytes the box runs"
else
  bad_t "E2 the restart loop is outside the fence" "the arms below would grade a skip that cannot fire in production"
fi

# The caller must actually route through the guarded function: a fenced block
# nothing calls is DIVE-1095's shape (a fix that shipped dormant).
if grep -qE '^\s*_restart_changed_agents "\$CHANGED_AGENTS"' "$SCRIPT" \
   && [[ "$(grep -c 'systemd-run --on-active=1 --collect' "$SCRIPT")" == 1 ]]; then
  ok_t "E3 --restart routes through the guarded function, and it is the file's ONLY scheduler call"
else
  bad_t "E3 an unguarded restart path survives in the script" \
        "callers: $(grep -n '_restart_changed_agents' "$SCRIPT" | tr '\n' '|') ; schedulers: $(grep -c 'systemd-run --on-active=1 --collect' "$SCRIPT")"
fi

WORK="$(mktemp -d)"
mkdir -p "$WORK/bin"
# A systemd-run that schedules nothing and records its argv. Shadowing PATH is
# how a restart is observed without a restart happening.
# `#!/bin/bash`, not `#!/usr/bin/env bash`: U5 empties PATH to reproduce a box
# with no jq, and `env` would not be found either — the stub would fail to exec
# and U5 would pass for the wrong reason (nothing scheduled because the STUB
# broke, read as "the fleet froze").
cat > "$WORK/bin/systemd-run" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_LOG:?}"
exit 0
STUB
chmod +x "$WORK/bin/systemd-run"

REG_STOPPED='{"agents":{"katya":{"desiredState":"stopped"},"nova":{"desiredState":"running"}}}'
REG_NOFIELD='{"agents":{"katya":{},"nova":{}}}'
REG_EMPTY='{"agents":{}}'
REG_CORRUPT='{"agents":{"katya":{"desiredState":"stop'

# run_restart <registry-body|MISSING> <changed-agents> [nojq]
# -> stdout of the shipped restart pass; $WORK/sched.log holds the scheduled units.
run_restart() {
  local body="$1" changed="$2" nojq="${3:-}"
  : > "$WORK/sched.log"
  (
    export STUB_LOG="$WORK/sched.log"
    if [[ "$nojq" == nojq ]]; then
      mkdir -p "$WORK/emptybin"; cp "$WORK/bin/systemd-run" "$WORK/emptybin/"
      # Shadowing PATH is the POINT — it reproduces a box with no jq without
      # uninstalling anything. Scoped to this subshell.
      # shellcheck disable=SC2123
      PATH="$WORK/emptybin"
    else
      PATH="$WORK/bin:$PATH"
    fi
    if [[ "$body" == MISSING ]]; then
      AGENTS_REGISTRY="$WORK/no-such-registry.json"
    else
      AGENTS_REGISTRY="$WORK/agents.json"; printf '%s' "$body" > "$AGENTS_REGISTRY"
    fi
    export PATH AGENTS_REGISTRY
    eval "$block"
    _restart_changed_agents "$changed"
  )
}
sched()   { cat "$WORK/sched.log" 2>/dev/null; }
bounced() { grep -q "5dive-agent@${1}.service" "$WORK/sched.log" 2>/dev/null; }

# ================================================================================
# P — the parked agent (RESURRECTS direction)
# ================================================================================
out="$(run_restart "$REG_STOPPED" "katya nova")"
if ! bounced katya; then
  ok_t "P1 a parked agent whose plugins changed is NOT scheduled for a restart"
else
  bad_t "P1 parked agent resurrected" "scheduled: $(sched)"
fi
if bounced nova; then
  ok_t "P2 NEGATIVE CONTROL — the running agent beside it still bounces (the skip is not a fleet-wide freeze)"
else
  bad_t "P2 running agent not bounced" "scheduled: $(sched | tr '\n' '|')  out: $(tr '\n' '|' <<<"$out")"
fi
if grep -q "parked: agent-katya" <<<"$out"; then
  ok_t "P3 the parked agent is named in the log, not silently dropped"
else
  bad_t "P3 no parked line" "out: $(tr '\n' '|' <<<"$out")"
fi
if grep -q "5dive agent stop katya" <<<"$out" && grep -q "5dive agent start katya" <<<"$out"; then
  ok_t "P4 the note names BOTH exits — a bare 'skipped' would read as a decision already taken"
else
  bad_t "P4 the note names fewer than both exits" "out: $(tr '\n' '|' <<<"$out")"
fi
if grep -q "^  parked_count: 1$" <<<"$out"; then
  ok_t "P5 parked_count is machine-readable and counts 1"
else
  bad_t "P5 parked_count wrong" "out: $(tr '\n' '|' <<<"$out")"
fi
if grep -q "parked_count: 0" <<<"$(run_restart "$REG_STOPPED" "nova")"; then
  ok_t "P6 parked_count: 0 is printed on a clean pass — an absent line cannot be told from a pass that never checked"
else
  bad_t "P6 no parked_count on a clean pass" "out: $(run_restart "$REG_STOPPED" nova | tr '\n' '|')"
fi
out="$(run_restart "$REG_STOPPED" "")"
if grep -q "nothing to bounce" <<<"$out" && grep -q "parked_count: 0" <<<"$out" && [[ -z "$(sched)" ]]; then
  ok_t "P7 an empty changed-set schedules nothing and still reports parked_count"
else
  bad_t "P7 empty changed-set" "out: $(tr '\n' '|' <<<"$out")  sched: $(sched)"
fi

# ================================================================================
# U — every UNKNOWN reading restarts (FREEZES direction). Each of these is a
# negative control: it passes only because the skip does NOT fire.
# ================================================================================
run_restart "$REG_NOFIELD" "katya" >/dev/null
bounced katya && ok_t "U1 an agent with NO desiredState field restarts (absent is not stopped)" \
  || bad_t "U1 absent field read as parked" "sched: $(sched)"
run_restart "$REG_EMPTY" "katya" >/dev/null
bounced katya && ok_t "U2 an agent absent from the registry restarts" \
  || bad_t "U2 absent agent read as parked" "sched: $(sched)"
run_restart MISSING "katya" >/dev/null
bounced katya && ok_t "U3 a MISSING registry file restarts the whole changed set" \
  || bad_t "U3 missing registry froze the fleet" "sched: $(sched)"
run_restart "$REG_CORRUPT" "katya" >/dev/null
bounced katya && ok_t "U4 a truncated/corrupt registry body restarts" \
  || bad_t "U4 corrupt registry read as parked" "sched: $(sched)"
run_restart "$REG_STOPPED" "katya" nojq >/dev/null
bounced katya && ok_t "U5 no jq on the box restarts (a missing tool is not a park)" \
  || bad_t "U5 absent jq froze the fleet" "sched: $(sched)"
run_restart '{"agents":{"katya":{"desiredState":"Stopped"}}}' "katya" >/dev/null
bounced katya && ok_t "U6 a value that is not exactly 'stopped' restarts (no fuzzy match)" \
  || bad_t "U6 fuzzy match" "sched: $(sched)"
run_restart '{"agents":{"katya":{"desiredState":null}}}' "katya" >/dev/null
bounced katya && ok_t "U7 an explicit null desiredState restarts" \
  || bad_t "U7 null read as parked" "sched: $(sched)"

# ================================================================================
# A — the AUDIT arm. DIVE-4033's sweep missed this file because its grep carried
# `-- src scripts`. This arm runs the same sweep with NO path filter and holds
# the line: every automatic (non-operator-invoked) restart path at the repo root
# must consult desiredState. It is the lesson, mechanised — see
# community/wiki/an-audit-grep-with-a-path-filter-cannot-find-the-file-outside-the-filter.md
# ================================================================================
# THE SWEEP IS WIDER THAN THE ROW ASKED FOR, and finding out why is half this
# arm's value. DIVE-4399's body named the sweep `git grep -ln 'systemctl restart
# "5dive-agent@'` — no path filter this time, and it STILL misses files, because
# src/cmd_selfupdate.sh (the DIVE-4033 file itself) and src/cmd_doctor.sh build
# the unit into a variable first and restart `"$unit"`. A pattern filter hides a
# file exactly the way a path filter does. So the sweep below keys on the two
# things a resurrection needs — a non-comment `systemctl start|restart` call, and
# the string `5dive-agent@` somewhere in the file — and message lines (warn /
# echo / printf / doctor_add) are dropped because naming the command in prose is
# not calling it.
#
# Verdicts this row reached for each survivor:
#   GUARDED           consults desiredState (asserted per file by A2)
#   OPERATOR-VERB     a person named THIS agent in THIS command; honouring the
#                     park would be refusing an explicit, reversible instruction
#   CANNOT-RESURRECT  only ever reached for an agent already observed running, so
#                     it cannot raise a stopped unit (it can still perpetuate a
#                     running-but-parked contradiction — noted, not this row)
#   RESIDUAL          the same defect as this row: the operator named a PROFILE
#                     and the fan-out reaches agents they never named, parked ones
#                     included, whose stopped units a restart WILL start. Not
#                     measured on a box, so it is recorded on DIVE-4399's body and
#                     in the changelog rather than filed as a new row.
#   AUTOMATIC-        the same defect with NO OPERATOR IN THE LOOP AT ALL. Not a
#   RESIDUAL          softer case than RESIDUAL, a harder one: the fan-out at
#                     least starts from a command a person typed, and this does
#                     not. Filed as its own row (DIVE-4409), not fixed here.
#
# THIS BUCKET EXISTS BECAUSE ONE VERDICT ABOVE WAS FALSE — in the direction that
# says a path is safe, which is the worst direction. `src/cmd_heartbeat.sh` was
# cleared CANNOT-RESURRECT on the two sites that fit that wording (spend-cap probe
# :6425, usage-limit heal :6726). It has a THIRD, `_hb_wake` at :3802-3807:
#
#     if ! systemctl is-active --quiet "5dive-agent@${name}.service"; then
#       _sc_err=$(systemctl start "5dive-agent@${name}.service" 2>&1 >/dev/null) ...
#
# which starts the unit PRECISELY BECAUSE it is not active — the exact inverse of
# the clearance. The dispatch loop that reaches it (:6310 over `.agents | keys[]`,
# calling `_hb_wake` at :6868) reads no desiredState; `grep -n desiredState
# src/cmd_heartbeat.sh` returns three hits, :5859/:5912 in the poller-liveness
# sweep and :6244 a log string, none in the dispatch path. And desiredState is
# still operator intent here: auto-sleep at :386 calls a bare `systemctl stop` and
# writes no field, only `5dive agent stop` writes it (cmd_agent_runtime.sh:51).
# So a parked agent holding a due todo is started by the TICK — every 15 minutes,
# not nightly. See DIVE-4409.
#
# DIVE-4409 HAS LANDED, so the bucket above is now empty and this file reads
# GUARDED — but A2's grep does NOT prove that, and the reason is worth keeping:
# `desiredState` was ALREADY in src/cmd_heartbeat.sh (those three hits) while it
# was resurrecting katya every fifteen minutes. A presence grep over a 7000-line
# file is a necessary condition, not a sufficient one, and here it would have
# passed on the pre-fix bytes. The behavioural proof — the shipped guard run
# against a temp registry with systemctl stubbed, nine negative controls for the
# freeze direction, and the ordering assertion that the check precedes the start
# — is tests/heartbeat_wake_parked_agent_unit.sh, which in turn asserts that THIS
# inventory carries the corrected verdict. Neither file can be relaxed alone.
#
# A FALSE CLEAR IS WORSE THAN THE MISSED FILE THIS ROW WAS FILED OVER, and worse
# once it is pinned: a filter leaves a file unseen and the tell is a suspiciously
# short list, but a wrong verdict leaves it seen, named and written down as
# harmless, so the next reader greps the inventory, finds it triaged, and stops —
# and A1 then re-asserts that in core CI on every PR, where it reads as coverage.
# The generalisable defect: A PER-FILE VERDICT IS A PER-CALL-SITE FACT WEARING A
# PER-FILE LABEL. Cheap discriminator whenever the claim is "cannot raise a
# stopped unit": grep the file for `is-active` and read EVERY hit.
#
# `src/cmd_doctor.sh` KEEPS CANNOT-RESURRECT, re-derived that way rather than
# re-trusted: its only agent-unit restart is :1588, gated on a non-empty `cpid`
# from `doctor_seat_claude_pid` (:1017-1028), which reads the unit's own
# cgroup.procs via `systemctl show -p ControlGroup` and returns empty when there
# is no cgroup — a stopped unit has none, so the restart is unreachable. Its other
# `systemctl restart` lines are `$svc` (telegram poller) and `shelld`, not agent
# units.
#
# A1 asserts the inventory is EXACT in both directions. A new restart path
# anywhere in the repo turns it red — because what DIVE-4033 shipped was not a
# wrong verdict, it was a file nobody looked at.
declare -A RESTART_PATHS=(
  [5dive-refresh-plugins.sh]=GUARDED
  [src/cmd_selfupdate.sh]=GUARDED
  [src/cmd_agent_runtime.sh]=GUARDED
  [src/cmd_heartbeat.sh]=GUARDED
  [src/cmd_doctor.sh]=CANNOT-RESURRECT
  [src/cmd_agent_lifecycle.sh]=OPERATOR-VERB
  [src/cmd_agent_config.sh]=OPERATOR-VERB
  [src/cmd_agent_teambot.sh]=OPERATOR-VERB
  [src/cmd_cos.sh]=OPERATOR-VERB
  [src/lib/agent_setup.sh]=OPERATOR-VERB
  [src/cmd_account.sh]=RESIDUAL
  [src/cmd_auth.sh]=RESIDUAL
)
# The candidate set is the TRACKED files, enumerated from git — not a filesystem
# walk. This is NOT the path filter this arm exists to warn about, and the
# difference matters: `git ls-files` enumerates the WHOLE repo with no path
# argument, so a new source file anywhere still arrives here (mutant 9 plants one
# and this arm still reds). What it excludes is the set that CANNOT carry the
# defect — untracked and gitignored files, which nothing ships.
#
# It is here because a filesystem walk read one in as a finding: `/5dive` is the
# gitignored 6.2MB CONCATENATED BUILD of everything in src/, so a tree where
# somebody had built the bundle reported an untriaged restart path that was
# really the already-triaged sources pasted together, while a fresh CI clone
# reported nothing. An arm whose verdict depends on whether a build artifact
# happens to be lying in the tree is not measuring the repo.
#
# An instrument failure must NOT read as "nothing to triage" (the `|| true`
# class): if git cannot answer, the arm fails loudly instead of sweeping an
# empty candidate set and passing.
_a1_candidates(){
  local tracked
  tracked="$(git -C "$ROOT" ls-files -- . 2>/dev/null)" || { echo "__A1_GIT_FAILED__"; return 0; }
  [[ -n "$tracked" ]] || { echo "__A1_GIT_FAILED__"; return 0; }
  printf '%s\n' "$tracked" \
    | grep -vE '^(tests/|changelog.d/|docs/|CHANGELOG\.md$|node_modules/)' \
    | while IFS= read -r f; do
        [[ -f "$ROOT/$f" ]] || continue
        grep -lE 'systemctl (start|restart) ' "$ROOT/$f" 2>/dev/null
      done \
    | sed "s|^${ROOT//|/\\|}/||" | sort -u
}

found=""
a1_instrument_ok=1
while IFS= read -r f; do
  if [[ "$f" == "__A1_GIT_FAILED__" ]]; then a1_instrument_ok=0; continue; fi
  [[ -n "$f" ]] || continue
  grep -q '5dive-agent@' "$f" || continue
  # The unit on the line must BE an agent unit: spelled out, or built into a
  # variable first (how cmd_selfupdate.sh and cmd_doctor.sh do it — the shape
  # the row's own literal-string sweep could not see). A literal non-agent unit
  # on the line (install.sh restarts systemd-journald) is not this inventory's
  # business even when the file mentions agents elsewhere.
  grep -E 'systemctl (start|restart) ("?5dive-agent@|"\$)' "$f" \
    | grep -vE '^[[:space:]]*#' \
    | grep -qvE '(warn|echo|printf|doctor_add|fail|_hc_issues)' || continue
  found="${found:+$found }$f"
done < <(_a1_candidates)
missing=""; extra=""
for f in $found; do [[ -n "${RESTART_PATHS[$f]:-}" ]] || extra="${extra:+$extra }$f"; done
for f in "${!RESTART_PATHS[@]}"; do [[ " $found " == *" $f "* ]] || missing="${missing:+$missing }$f"; done
if [[ "$a1_instrument_ok" != 1 ]]; then
  bad_t "A1 the sweep could not run — NOT a clean inventory" \
        "git ls-files returned nothing from $ROOT; the candidate set would have been empty, which must never read as 'no untriaged paths'"
elif [[ -z "$extra" && -z "$missing" ]]; then
  ok_t "A1 the UNFILTERED sweep: all ${#RESTART_PATHS[@]} agent-unit start/restart paths tracked in the repo are ones this row triaged"
else
  bad_t "A1 the restart-path inventory no longer matches the tree" \
        "UNTRIAGED (a new path that can raise an agent — decide whether it must honour a park): ${extra:-none} | GONE (drop it from the inventory): ${missing:-none}"
fi
blind=""
for f in "${!RESTART_PATHS[@]}"; do
  [[ "${RESTART_PATHS[$f]}" == GUARDED ]] || continue
  grep -q 'desiredState' "$f" 2>/dev/null || blind="${blind:+$blind }$f"
done
if [[ -z "$blind" ]]; then
  ok_t "A2 every path marked GUARDED actually reads desiredState"
else
  bad_t "A2 a GUARDED path is blind to desiredState" "$blind"
fi

if grep -q 'desiredState' "$SCRIPT"; then
  ok_t "A3 this script itself now answers the grep that returned zero hits on 2026-09-13"
else
  bad_t "A3 5dive-refresh-plugins.sh still has zero desiredState hits" "the fix is not in the shipped file"
fi

echo
echo "$PASS passed, $FAIL failed"
SUMMARY_PRINTED=1
[[ "$FAIL" == 0 ]]
