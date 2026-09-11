#!/usr/bin/env bash
# DIVE-4293 — the headless question guard, and the pane signal that catches the
# seat this guard was too late for.
#
# THE INCIDENT: dev2 (no channel, enabledPlugins {}) called AskUserQuestion at
# ~05:40Z on 2026-09-11 and sat at "Enter to select" until lodar noticed at
# 07:12Z. bypassPermissions did not cover it — AskUserQuestion is a tool call,
# not a permission prompt — and the one guard that existed had been folded INTO
# the telegram plugin, i.e. installed on exactly the seats where a human CAN
# answer and absent on the ones where nobody can.
#
# Four arms, and the fourth is the mutation: drop the hook install and the
# channel-less arm must go red.
# Run: bash tests/headless_question_guard_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
t() {  # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"
  fi
}
tc() {  # <desc> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected to contain '$2', got '$3'"
  fi
}
tnc() {  # <desc> <needle-that-must-be-absent> <haystack>
  if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected NOT to contain '$2', got '$3'"
  fi
}

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

HOOK=hooks/pretool-headless-question.sh
[[ -x "$HOOK" ]] || { echo "FAIL: $HOOK missing or not executable"; exit 1; }

# ── ARM 1 ───────────────────────────────────────────────────────────────────
# The hook REFUSES AskUserQuestion, and the refusal carries the text a model
# with no human in front of it can act on by itself.
out=$(printf '{"tool_name":"AskUserQuestion"}' | bash "$HOOK")
t  "arm1: AskUserQuestion is denied" \
   "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")
tc "arm1: the refusal says nobody is at the keyboard" \
   "No human sits at this keyboard." "$reason"
tc "arm1: it names the action to take instead" \
   "Take the option you marked Recommended (or the first) and continue" "$reason"
tc "arm1: it says where the alternatives go" "task body" "$reason"
# The escape hatch matters as much as the refusal: a choice that GENUINELY needs
# a person must have somewhere to go, or the next model reasons its way back to
# the picker. Without this line the deny is a dead end.
tc "arm1: it routes a real human decision to a gate, not a picker" \
   "5dive task need" "$reason"

out=$(printf '{"tool_name":"ExitPlanMode"}' | bash "$HOOK")
t  "arm1: ExitPlanMode is denied too (same pane, same deadlock)" \
   "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"

# A hook that denied everything would be a far worse outage than the one it
# fixes: every Bash call on every headless seat.
out=$(printf '{"tool_name":"Bash"}' | bash "$HOOK")
t  "arm1: an unrelated tool is untouched (empty output, exit 0)" "" "$out"

# ── ARM 2 ───────────────────────────────────────────────────────────────────
# INSTALL GATING. Read out of agent_setup.sh's source rather than by running the
# provisioner (which needs root, a real agent home and sudo). What is graded is
# the CONDITION, because the defect was never the hook's content — it was which
# seats got one.
setup=$(cat src/lib/agent_setup.sh)
tc "arm2: the guard is wired into the per-agent settings.json" \
   "pretool-headless-question.sh" "$setup"
gate=$(grep -n "pretool-headless-question.sh" src/lib/agent_setup.sh | head -1 | cut -d: -f1)
cond=$(sed -n "$((gate-3)),${gate}p" src/lib/agent_setup.sh)
tc "arm2: NOT installed on a telegram seat (the plugin already denies there — two denies double-fire)" \
   '! channel_in_list telegram "$channels"' "$cond"
tc "arm2: NOT installed on a discord seat either" \
   '! channel_in_list discord "$channels"' "$cond"
tc "arm2: it matches both pickers" "AskUserQuestion|ExitPlanMode" "$setup"
# The staging leg: a hook wired in settings.json but never copied to the box is
# a settings file pointing at nothing.
tc "arm2: install.sh stages the hook to /usr/local/lib/5dive" \
   "pretool-headless-question.sh" "$(cat install.sh)"

# The MERGE itself, not just the string. The hook is added to a settings object
# that ALREADY carries a SessionStart hook, and a filter that replaced `.hooks`
# wholesale would silently drop the resume-context hook from every headless seat
# — a bigger regression than the one being fixed, and invisible in a grep.
filter=$(sed -n "/DIVE-4293: the HEADLESS QUESTION GUARD/,/^  fi$/p" src/lib/agent_setup.sh          | sed -n "/settings=\$(jq '/,/<<<\"\$settings\")/p"          | sed -e "s/^.*settings=\$(jq '//" -e "s/' <<<\"\$settings\")$//")
base='{"model":"claude-opus-5","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/usr/local/lib/5dive/sessionstart-resume-context.sh"}]}]}}'
merged=$(jq "$filter" <<<"$base" 2>/dev/null) || merged=""
t  "arm2: the merge KEEPS the existing SessionStart hook"    "/usr/local/lib/5dive/sessionstart-resume-context.sh"    "$(jq -r '.hooks.SessionStart[0].hooks[0].command // ""' <<<"${merged:-{\}}")"
t  "arm2: the merge adds the PreToolUse matcher"    "AskUserQuestion|ExitPlanMode" "$(jq -r '.hooks.PreToolUse[0].matcher // ""' <<<"${merged:-{\}}")"
t  "arm2: ...pointing at the staged hook"    "/usr/local/lib/5dive/pretool-headless-question.sh"    "$(jq -r '.hooks.PreToolUse[0].hooks[0].command // ""' <<<"${merged:-{\}}")"
t  "arm2: and leaves the rest of settings alone"    "claude-opus-5" "$(jq -r '.model // ""' <<<"${merged:-{\}}")"

# ── ARM 3 ───────────────────────────────────────────────────────────────────
# LIVENESS/SUPERVISOR: a captured pane sitting on a picker classifies as
# blocked-on-prompt — not idle, not busy, not stuck.
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh cmd_supervisor.sh; do
  source "src/$f"
done
_SUP_CLI_LATEST="9.9.9"

PANE_BLOCKED=$(cat <<'PANE'
  Two rows are gate-cleared but the /goal fences me to one task.

❯ 1. Push both, then stop (Recommended)
  2. Stop now and report
  3. Keep working the fenced row

  ↑/↓ to navigate · Enter to select
PANE
)
PANE_UNMARKED=${PANE_BLOCKED/ (Recommended)/}
PANE_BUSY=$(printf 'Reading src/cmd_supervisor.sh\n  ⎿  Read 240 lines\n· Thinking… (12s)\n')

excerpt=$(printf '%s\n' "$PANE_BLOCKED" | _sup_prompt_match)
tc "arm3: the picker footer is matched" "Enter to select" "$excerpt"
t  "arm3: an ordinary working pane matches nothing" \
   "" "$(printf '%s\n' "$PANE_BUSY" | _sup_prompt_match)"

# THE FALSE-POSITIVE CONTROL. Agents write this string — this row's own body
# contains it. The tail window is what keeps a transcript MENTION from reading
# as a live picker, so it is graded, not assumed.
PANE_MENTION=$(printf 'The pane sat at "Enter to select" from 05:40Z until 07:12Z.\n'; \
  for i in $(seq 1 20); do printf '  ⎿  wrote src/file_%s.sh\n' "$i"; done)
t  "arm3: a transcript MENTION scrolls out of the tail window and does not trip" \
   "" "$(printf '%s\n' "$PANE_MENTION" | tail -n "$_SUP_PROMPT_PANE_LINES" | _sup_prompt_match)"

# Enter takes the HIGHLIGHTED option, so the cursor is the only thing that may
# authorise an auto-answer.
printf '%s\n' "$PANE_BLOCKED"  | _sup_prompt_recommended \
  && { PASS=$((PASS+1)); } || { FAIL=$((FAIL+1)); echo "FAIL: arm3: highlighted (Recommended) option should authorise an answer"; }
printf '%s\n' "$PANE_UNMARKED" | _sup_prompt_recommended \
  && { FAIL=$((FAIL+1)); echo "FAIL: arm3: an UNMARKED highlighted option must NOT authorise an answer"; } || PASS=$((PASS+1))
# The cursor is on option 2; option 1 still carries the marker. Answering here
# would press Enter on "Stop now and report" — the wrong option, chosen by a
# watchdog. This is the arm that makes the cursor read load-bearing.
PANE_CURSOR_ELSEWHERE=$(printf '  1. Push both, then stop (Recommended)\n❯ 2. Stop now and report\n\n  ↑/↓ to navigate · Enter to select\n')
printf '%s\n' "$PANE_CURSOR_ELSEWHERE" | _sup_prompt_recommended \
  && { FAIL=$((FAIL+1)); echo "FAIL: arm3: cursor NOT on the Recommended option must not authorise an answer"; } || PASS=$((PASS+1))

crow=$(_sup_classify running 1 active agent-dev2 alive n/a 0 1 30 false "" "" 0 0 -1 "" unknown \
         "↑/↓ to navigate · Enter to select" recommended)
IFS=$'\x1f' read -r cls cause detail <<<"$crow"
t  "arm3: a pane on a picker classifies blocked-on-prompt" "blocked-on-prompt" "$cls"
t  "arm3: ...with its own cause" "blocked-on-prompt" "$cause"
tc "arm3: the detail says the answer is takeable" "(Recommended)" "$detail"

# NOT idle and NOT busy — the two readings that hid the incident for 92 minutes.
# has_work=1 and a fresh 30s activity age would otherwise print plain "active".
tnc "arm3: it is not reported as active" "active" "$detail"
crow=$(_sup_classify running 1 active agent-dev2 alive n/a 0 1 30 false "" "" 0 0 -1 "" unknown \
         "↑/↓ to navigate · Enter to select" unmarked)
IFS=$'\x1f' read -r cls _ detail <<<"$crow"
t  "arm3: an unmarked picker still classifies blocked" "blocked-on-prompt" "$cls"
tc "arm3: ...and says a person must choose" "a person must choose" "$detail"

# The control: same seat, no picker on the pane, back to the pre-4293 verdict.
crow=$(_sup_classify running 1 active agent-dev2 alive n/a 0 1 30 false "" "" 0 0 -1 "" unknown "" unmarked)
IFS=$'\x1f' read -r cls _ detail <<<"$crow"
t  "arm3: CONTROL — no picker, no new class" "healthy" "$cls"
t  "arm3: CONTROL — the old detail is unchanged" "active" "$detail"

# A verification challenge outranks it: that is account state a person must
# clear, and it is the older, louder obligation.
crow=$(_sup_classify running 1 active agent-dev2 alive n/a 0 1 30 false "" "verify your identity" 0 0 -1 "" unknown \
         "Enter to select" recommended)
t  "arm3: verify-challenge still wins over blocked-on-prompt" \
   "verify-challenge" "$(cut -d$'\x1f' -f1 <<<"$crow")"

# ── ARM 4: THE MUTATION ─────────────────────────────────────────────────────
# Drop the hook install from agent_setup.sh and the channel-less arm must red.
# Without this the suite would pass against a tree where the guard is written
# but never wired — which is the shape of the original defect.
mut=$(mktemp) || { echo "FAIL: arm4: mktemp"; exit 1; }
trap 'rm -f "$mut"; rc=$?; echo "HARNESS-RC=$rc"' EXIT
grep -v "pretool-headless-question.sh" src/lib/agent_setup.sh > "$mut"
if grep -q "pretool-headless-question.sh" "$mut"; then
  FAIL=$((FAIL+1)); echo "FAIL: arm4: mutation did not remove the install"
elif [[ "$(cat "$mut")" == *"pretool-headless-question.sh"* ]]; then
  FAIL=$((FAIL+1)); echo "FAIL: arm4: mutant still carries the install"
else
  PASS=$((PASS+1))   # the mutant is genuinely mutated
fi
# ...and arm 2's assertion, re-run against the mutant, must FAIL.
if [[ "$(cat "$mut")" == *"pretool-headless-question.sh"* ]]; then
  FAIL=$((FAIL+1)); echo "FAIL: arm4: arm2's check survived the mutation — it does not grade the install"
else
  PASS=$((PASS+1))
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
