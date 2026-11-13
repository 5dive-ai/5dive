#!/usr/bin/env bash
# DIVE-8362 — a lead that routes its owner's ask is told how to hear that it
# finished, and a support read can see whether it armed that.
#
# Box report 941: a lead routed the owner's presentation to a teammate, the
# teammate finished, a reviewer accepted, and the owner got the file only when
# they asked again. `--tell-me` (DIVE-5852) would have woken the lead, but no
# agent's instructions named it and `task add` said nothing when it was left
# off. An opt-in nobody is taught is off in practice.
#
#   (a) team-CLAUDE.md and the Codex AGENTS.md baseline both carry the rule;
#       the team block stays under its word budget.
#   (b) `task add` by a paired seat A for seat B without --tell-me prints the
#       tip; with --tell-me, A==B, or an unpaired filer, it does not.
#   (c) `task show --json` always carries tell_me_by and told_at (null when
#       unset); the text view prints the armed and the unarmed state.
#   (d) is tests/task_tell_me_unit.sh, unchanged: no wake without the flag.
# Run: bash tests/lead_tell_me_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

SRC=src
TMP="$(mktemp -d /tmp/lead-tell-me-unit.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh \
         cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

# ── (a) the rule, in both runtimes' instructions ────────────────────────────────
TEAM=prompts/team-CLAUDE.md
TEAM_BUDGET=520   # words; the block loads every turn on every claude seat
rule_line=$(grep -F -- '--tell-me' "$TEAM" || true)
[[ -n "$rule_line" ]] && grep -qF '5dive task watch' <<<"$rule_line" && grep -qF 'file attached' <<<"$rule_line" \
  && ok_t "(a) team block names --tell-me, task watch and sending the file" \
  || bad_t "(a) team block lacks the lead rule" "$rule_line"
grep -qF 'stay on the board' <<<"$rule_line" \
  && ok_t "(a) team block keeps grades off the owner's chat" \
  || bad_t "(a) team block lacks the grades-stay-on-the-board clause" "$rule_line"
w=$(wc -w <<<"$rule_line" | tr -d ' ')
(( w <= 45 )) && ok_t "(a) the lead bullet is ${w} words (<= 45)" || bad_t "(a) the lead bullet is ${w} words" "cap 45"
tw=$(wc -w <"$TEAM" | tr -d ' ')
(( tw <= TEAM_BUDGET )) && ok_t "(a) team block is ${tw} words (<= ${TEAM_BUDGET})" \
  || bad_t "(a) team block is ${tw} words, over ${TEAM_BUDGET}" "pay for a new line with a cut"

CODEX_BASELINE_MARKER="${CODEX_BASELINE_MARKER:-5dive:codex-operating-baseline}"
doc=$(_codex_operating_baseline_doc lead)
grep -qF -- '--tell-me' <<<"$doc" && grep -qF '5dive task watch' <<<"$doc" && grep -qF 'file attached' <<<"$doc" \
  && ok_t "(a) Codex AGENTS.md baseline carries the lead rule" \
  || bad_t "(a) Codex AGENTS.md baseline lacks the lead rule"
grep -qF 'a2a return channel' <<<"$doc" \
  && ok_t "(a) Codex baseline keeps the a2a return-channel section" \
  || bad_t "(a) Codex baseline lost the a2a return-channel section"

# ── board fixture ───────────────────────────────────────────────────────────────
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR" "$TASKS_DIR"
: >"$CONNECTORS_DIR/telegram-lead.env"     # lead is paired; helper is not
fixture_box_verify_policy never || exit 1
set +e
tasks_db_init

[[ "$( ( actor_seam_as lead; task_actor ) )" == "lead" ]] \
  && ok_t "INSTRUMENT: harness impersonates an actor" \
  || bad_t "INSTRUMENT: actor impersonation broken" "arms below would be vacuous"

addtxt() { local who="$1"; shift; ( actor_seam_as "$who"; JSON_MODE=0 cmd_task_add "$@" 2>&1 ); }
addjson() { local who="$1"; shift; ( actor_seam_as "$who"; JSON_MODE=1 cmd_task_add "$@" 2>/dev/null ); }
TIP='tip: add --tell-me'

# ── (b) the tip ─────────────────────────────────────────────────────────────────
out=$(addtxt lead "make the deck" --assignee=maker --no-verify)
grep -qF "$TIP" <<<"$out" && grep -qE "task watch DIVE-[0-9]+" <<<"$out" \
  && ok_t "(b) paired lead -> other seat, no flag: tip printed with the row's ident" \
  || bad_t "(b) tip missing for a paired lead routing to another seat" "$out"
grep -q "^ok\|created" <<<"$out" && [[ $(grep -c "$TIP" <<<"$out") == 1 ]] \
  && ok_t "(b) the tip is one line, on the created line" \
  || bad_t "(b) tip not exactly once" "$out"

j=$(addjson lead "make the deck 2" --assignee=maker --no-verify)
[[ "$(jq -r '.data.tellMeTip // empty' <<<"$j")" == "$TIP"* ]] \
  && ok_t "(b) --json carries tellMeTip" || bad_t "(b) --json lacks tellMeTip" "$j"

out=$(addtxt lead "make the deck 3" --assignee=maker --no-verify --tell-me)
! grep -qF "$TIP" <<<"$out" && grep -qF "lead is woken once" <<<"$out" \
  && ok_t "(b) with --tell-me: no tip, the armed note instead" \
  || bad_t "(b) tip printed although --tell-me was passed" "$out"

out=$(addtxt lead "my own row" --assignee=lead --no-verify)
! grep -qF "$TIP" <<<"$out" && grep -q "created" <<<"$out" \
  && ok_t "(b) filer == assignee: no tip" || bad_t "(b) tip on a row filed to oneself" "$out"

out=$(addtxt helper "sub-step" --assignee=maker --no-verify)
! grep -qF "$TIP" <<<"$out" && grep -q "created" <<<"$out" \
  && ok_t "(b) unpaired filer (no owner to report to): no tip" || bad_t "(b) tip for an unpaired filer" "$out"

j=$(addjson lead "make the deck 4" --assignee=maker --no-verify --tell-me)
[[ "$(jq -r '.data.tellMeTip' <<<"$j")" == "null" ]] \
  && ok_t "(b) --json tellMeTip is null when armed" || bad_t "(b) --json tellMeTip set although armed" "$j"

# ── (c) task show carries the wake state ────────────────────────────────────────
T_ARMED=$(jq -r '.data.ident' <<<"$j")
T_BARE=$(jq -r '.data.ident' <<<"$(addjson lead "bare" --assignee=maker --no-verify)")
showj() { ( JSON_MODE=1 cmd_task_show "$@" 2>/dev/null ); }

sj=$(showj "$T_BARE")
[[ "$(jq -r '.data.task | has("tell_me_by") and has("told_at")' <<<"$sj")" == true \
   && "$(jq -r '.data.task.tell_me_by' <<<"$sj")" == null ]] \
  && ok_t "(c) show --json: unarmed row carries tell_me_by:null and told_at:null" \
  || bad_t "(c) show --json drops the keys on an unarmed row" "$(jq -c '.data.task | {tell_me_by, told_at}' <<<"$sj")"
sj=$(showj "$T_ARMED")
[[ "$(jq -r '.data.task.tell_me_by' <<<"$sj")" == lead ]] \
  && ok_t "(c) show --json: armed row names the seat" \
  || bad_t "(c) show --json lost tell_me_by" "$(jq -c '.data.task | {tell_me_by, told_at}' <<<"$sj")"
sj=$(showj "$T_ARMED" --no-body)
[[ "$(jq -r '.data.task | has("told_at") and (has("body")|not)' <<<"$sj")" == true ]] \
  && ok_t "(c) show --json --no-body keeps the keys" || bad_t "(c) --no-body dropped the keys" "$sj"

db "UPDATE tasks SET told_at='2026-11-13 08:00:00' WHERE ident=$(sqlq "$T_ARMED");"
sj=$(showj "$T_ARMED")
[[ "$(jq -r '.data.task.told_at' <<<"$sj")" == "2026-11-13 08:00:00" ]] \
  && ok_t "(c) show --json carries told_at once the wake went" || bad_t "(c) told_at not carried" "$sj"

st=$( ( JSON_MODE=0 cmd_task_show "$T_ARMED" 2>/dev/null ) )
grep -qE '^ +tell_me_by = lead is woken once when it closes \(told 2026-11-13 08:00:00\)' <<<"$st" \
  && ok_t "(c) show text: armed state and when it was told" \
  || bad_t "(c) show text lacks the armed line" "$(grep tell_me <<<"$st")"
st=$( ( JSON_MODE=0 cmd_task_show "$T_BARE" 2>/dev/null ) )
grep -qE "^ +tell_me_by = nobody is woken when it closes \(arm: 5dive task watch ${T_BARE}\)" <<<"$st" \
  && ok_t "(c) show text: unarmed state with the command that arms it" \
  || bad_t "(c) show text lacks the unarmed line" "$(grep tell_me <<<"$st")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
