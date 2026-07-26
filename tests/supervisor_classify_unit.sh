#!/usr/bin/env bash
# DIVE-1416 (gap#3) isolated unit harness for _sup_classify (cmd_supervisor.sh)
# — the pure classification decision factored out of _sup_agent_record so it's
# directly testable without stubbing systemctl/tmux/pgrep (mirrors how
# tests/supervisor_unit.sh already exercises _sup_act_plan). Focuses on the new
# "stalled"/idle-stranded class: an agent with NO active work but an old todo
# task still sitting assigned to it — the "idle while work is stranded" signal
# the fleet-stall dogfood incident found supervisor didn't model at all.
# Run: bash tests/supervisor_classify_unit.sh (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh cmd_supervisor.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

_SUP_CLI_LATEST="9.9.9"

PASS=0; FAIL=0
t() {  # <desc> <expected class\x1fcause> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"
  fi
}
# args: desired svc_running active sess tmux_state poller loop_stuck has_work
#       act_age cli_stale goal_drift verify_excerpt stranded
cls() { _sup_classify "$@" | cut -f1,2 -d $'\x1f'; }

# --- the new class itself ----------------------------------------------------
t "idle, no stranded todo -> healthy/(no cause)" \
  $'healthy\x1f' "$(cls "" 1 active s unknown n/a 0 0 -1 false "" "" 0)"
t "idle + a stranded todo -> stalled/idle-stranded" \
  $'stalled\x1fidle-stranded' "$(cls "" 1 active s unknown n/a 0 0 -1 false "" "" 3)"
t "idle + many stranded -> still just stalled/idle-stranded (no separate tier)" \
  $'stalled\x1fidle-stranded' "$(cls "" 1 active s unknown n/a 0 0 -1 false "" "" 99)"

# --- has_work always wins over stranded (has_work implies the agent isn't
#     idle even if some OTHER old todo happens to be sitting on it) -----------
t "has_work=1 + stranded>0 -> active, not stalled (has_work branch wins)" \
  $'healthy\x1f' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "" 5)"

# --- every dead/higher-priority signal still wins over stranded --------------
t "verify-challenge wins over stranded" \
  $'verify-challenge\x1fid-verification' "$(cls "" 1 active s unknown n/a 0 0 -1 false "" "ID check pane" 5)"
t "service-dead (has_work) wins over stranded" \
  $'stuck\x1fservice-dead' "$(cls "" 0 active s unknown n/a 0 1 -1 false "" "" 5)"
t "tmux-dead wins over stranded" \
  $'stuck\x1ftmux-dead' "$(cls "" 1 active s dead n/a 0 0 -1 false "" "" 5)"
t "poller-dead wins over stranded" \
  $'stuck\x1fpoller-dead' "$(cls "" 1 active s unknown dead 0 0 -1 false "" "" 5)"
t "loop-stuck wins over stranded" \
  $'stuck\x1floop-stuck' "$(cls "" 1 active s unknown n/a 1 0 -1 false "" "" 5)"
t "cli-stale still wins over stranded (box-level signal, unchanged precedence)" \
  $'update-pending\x1fstale-cli' "$(cls "" 1 active s unknown n/a 0 0 -1 true "" "" 5)"
t "stopped (desired) wins over stranded" \
  $'healthy\x1f' "$(cls "stopped" 0 active s unknown n/a 0 0 -1 false "" "" 5)"

# --- unaffected: existing has_work-branch classes are unchanged by the refactor
t "regression: has_work + no-progress past stuck window -> stuck/no-progress" \
  $'stuck\x1fno-progress' "$(cls "" 1 active s unknown n/a 0 1 $((_SUP_T_STUCK_MIN * 60)) false "" "" 0)"
t "regression: has_work + no-progress past slow (not stuck) window -> slow" \
  $'slow\x1f' "$(cls "" 1 active s unknown n/a 0 1 $((_SUP_T_SLOW_MIN * 60)) false "" "" 0)"
t "regression: goal-drift still fires with no stranded work" \
  $'drift\x1fgoal-drift' "$(cls "" 1 active s unknown n/a 0 0 -1 false "42" "" 0)"
t "regression: plain has_work -> healthy/(no cause)" \
  $'healthy\x1f' "$(cls "" 1 active s unknown n/a 0 1 -1 false "" "" 0)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
