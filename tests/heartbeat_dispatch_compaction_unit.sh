#!/usr/bin/env bash
# DIVE-4406 — the dispatch carries the DELTA; the contract lives in one surface.
#
# THE DEFECT THIS PINS. Every heartbeat wake re-sent the whole lifecycle contract
# (gate vs cancel, the ask's shape, single-row scope, the self-audit,
# maker/verifier separation, the knowledge clause) as prose inside the /goal
# line — byte-identical on every wake, ~1,100 wakes/day fleet-wide. It now lives
# in `projects-CLAUDE.md` (installed at /home/claude/projects/CLAUDE.md), read
# once per session.
#
# THE RISK THAT CREATES, AND WHAT THESE ARMS GRADE. "Moved" is one edit away from
# "deleted": drop the policy section and the fleet silently loses the contract,
# because the nudge no longer carries it and nothing else asserts it. So the
# invariants are graded in BOTH places — present in the policy file (part 1),
# and the row-specific half still present in the dispatch (part 2) — plus a byte
# budget (part 3) so the prose cannot creep back into the per-wake line.
# Run: bash tests/heartbeat_dispatch_compaction_unit.sh  (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/hb-dispatch-compaction.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e; tasks_db_init >/dev/null 2>&1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }

# The two enrichments that reach outside this harness (memory search, the seat's
# transcript) are stubbed empty: they are graded by their own harnesses, and the
# byte budget below must measure the deterministic core, not a seat's history.
_hb_recall_cite()      { printf ''; }
_hb_carryover_clause() { printf ''; }

POLICY=projects-CLAUDE.md

# =============================================================================
# PART 1 — the contract is IN the one surface that replaced the repetition
# =============================================================================
# Each arm names the invariant, not a sentence, so a rewording of the policy file
# passes and a DELETION reds.
pol_has() { # <label> <pattern...>  — any one pattern satisfies it
  local label="$1"; shift
  local p
  for p in "$@"; do grep -qiF -- "$p" "$POLICY" && { ok_t "policy carries: $label"; return; }; done
  bad_t "policy MUST carry: $label" "none of [$*] found in $POLICY"
}
pol_has "single-row scope"              "One row per turn"
pol_has "gate is not a cancellation"    "A human gate is not a cancellation"
pol_has "the gate verb and its shape"   "task need <ident> --type=decision|approval|secret|manual"
pol_has "the recommendation is required" "--recommend="
pol_has "cancel only when impossible"   "genuinely irrelevant or impossible"
pol_has "delivered is a maker terminal" "that IS the maker's terminal state"
pol_has "the self-audit"                "Self-audit before you close"
pol_has "maker/verifier separation"     "Maker and verifier are separate seats"
pol_has "the reject verdict is terminal" "FAIL verdict is a complete, terminal"
pol_has "no human at the keyboard"      "Never open a chooser"
pol_has "the knowledge/compile clause"  "compile it to \`community/wiki/\`"
pol_has "the result field is read"      "one or two self-contained"

# DIVE-4416 (#926) deleted the `--options=A|B` usage placeholder from all three
# surfaces that teach gate filing, on the finding that the placeholder was the
# only thing steering filers to bare letters. This policy block is a FOURTH copy
# of that text, created after #926 landed — nothing else pins it, so without
# these two arms the placeholder can be reinstated here on the most-read surface
# there is and no harness reds. Cause:
# community/wiki/compacting-a-prompt-into-a-new-surface-can-resurrect-what-another-row-just-deleted.md
pol_has "options are spelled out, not lettered" "<first choice spelled out>|<second choice spelled out>"
pol_has "WHY a bare letter is wrong"            "forwarded, quoted or screenshotted"
if grep -qF -- '--options=A|B' "$POLICY" || grep -qF -- '--options="A|B"' "$POLICY"; then
  bad_t "policy must NOT teach the A|B placeholder" "$POLICY still carries --options=A|B (DIVE-4416 deleted it everywhere else)"
else
  ok_t "policy does not teach the A|B placeholder"
fi

# =============================================================================
# PART 2 — the dispatch still carries the row-specific half
# =============================================================================
mk() { db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status)
           VALUES ($(sqlq "$1"), $(sqlq "${3:-}"), 'high', $(sqlq "$2"), 'main', 'standard', 'todo');
           SELECT last_insert_rowid();"; }
db "DELETE FROM tasks;"
P=$(mk "a plain row with no verifier" dev)
n=$(_hb_nudge_text dev "$P" "DIVE-$P")

has "$n" "DIVE-$P"                 && ok_t "dispatch names the row"                 || bad_t "dispatch names the row" "[$n]"
has "$n" "5dive task show DIVE-$P" && ok_t "dispatch names how to read the state"   || bad_t "dispatch names how to read the state" "[$n]"
has "$n" "5dive task done DIVE-$P" && ok_t "dispatch names the done verb"           || bad_t "dispatch names the done verb" "[$n]"
has "$n" "--result="               && ok_t "dispatch names the result field"        || bad_t "dispatch names the result field" "[$n]"
has "$n" "5dive task need DIVE-$P" && ok_t "dispatch names the GATE verb"           || bad_t "dispatch names the GATE verb" "[$n]"
has "$n" "5dive task cancel DIVE-$P" && ok_t "dispatch names the cancel verb"       || bad_t "dispatch names the cancel verb" "[$n]"
has "$n" "--recommend="            && ok_t "dispatch names the recommendation"      || bad_t "dispatch names the recommendation" "[$n]"
has "$n" "your only row this turn" && ok_t "dispatch states single-row scope"       || bad_t "dispatch states single-row scope" "[$n]"
has "$n" "Self-audit before you close" && ok_t "dispatch keeps the self-audit"      || bad_t "dispatch keeps the self-audit" "[$n]"
has "$n" "/home/claude/projects/CLAUDE.md" && ok_t "dispatch points at the policy surface" \
                                           || bad_t "dispatch points at the policy surface" "[$n]"
# DIVE-4406's evidence: a maker whose row is already delivered must not read a
# terminal condition it cannot reach by its own hand. The BASE line says so, not
# only the loop clause — a row with no verifier yet may acquire one.
has "$n" "delivered is terminal for you" && ok_t "base names DELIVERED as a maker terminal" \
                                         || bad_t "base names DELIVERED as a maker terminal" "[$n]"
# The gate must be offered BEFORE the cancel, in that order: the failure mode is
# an agent cancelling a row that needed a human.
[[ "${n%%CANCELLED*}" == *"GATED"* ]] && ok_t "the gate is offered ahead of the cancel" \
                                      || bad_t "the gate is offered ahead of the cancel" "[$n]"

# role variants still reach the dispatch through _hb_nudge_text
db "DELETE FROM tasks;"
M=$(mk "maker row" dev); db "UPDATE tasks SET verifier='quinn' WHERE id=${M};"
nm=$(_hb_nudge_text dev "$M" "DIVE-$M")
has "$nm" "DELIVERS" && ok_t "maker dispatch carries the deliver-is-terminal clause" \
                     || bad_t "maker dispatch carries the deliver-is-terminal clause" "[$nm]"

db "DELETE FROM tasks;"
V=$(mk "verifier row" quinn); db "UPDATE tasks SET verifier='quinn', maker_agent='dev' WHERE id=${V};"
nv=$(_hb_nudge_text quinn "$V" "DIVE-$V")
has "$nv" "5dive task reject DIVE-$V" && ok_t "verifier dispatch carries the reject terminal" \
                                      || bad_t "verifier dispatch carries the reject terminal" "[$nv]"

db "DELETE FROM tasks;"
K=$(mk "compile the wiki page" dev "write it to the team wiki as a knowledge atom")
nk=$(_hb_nudge_text dev "$K" "DIVE-$K")
has "$nk" "COMPILE it to the team wiki" && ok_t "a knowledge-shaped row still gets the compile clause" \
                                        || bad_t "a knowledge-shaped row still gets the compile clause" "[$nk]"

# =============================================================================
# PART 3 — the budget. This is the arm that reds when prose creeps back in.
# =============================================================================
# Ceilings are set just above the measured post-change sizes (base 890, typical
# 1363, knowledge 1785 bytes on 2026-09-13 — scripts/dispatch-bytes.sh prints
# them). They are a TRIPWIRE, not a target: a legitimate growth moves the number
# here deliberately, with the reason in the commit.
base_bytes=$(printf '%s' "$(_hb_nudge_text dev "$P" "DIVE-$P")" 2>/dev/null | wc -c)
db "DELETE FROM tasks;"; P2=$(mk "a plain row with no verifier" dev)
base_bytes=$(printf '%s' "$(_hb_nudge_text dev "$P2" "DIVE-$P2")" | wc -c)
(( base_bytes <= 1000 )) && ok_t "base dispatch is ${base_bytes}B (<= 1000)" \
                         || bad_t "base dispatch has re-inflated: ${base_bytes}B > 1000" \
                                  "invariant prose belongs in $POLICY, not in every wake"
db "DELETE FROM tasks;"; M2=$(mk "maker row" dev); db "UPDATE tasks SET verifier='quinn' WHERE id=${M2};"
typ_bytes=$(printf '%s' "$(_hb_nudge_text dev "$M2" "DIVE-$M2")" | wc -c)
(( typ_bytes <= 1500 )) && ok_t "typical maker dispatch is ${typ_bytes}B (<= 1500)" \
                        || bad_t "typical maker dispatch has re-inflated: ${typ_bytes}B > 1500" ""
db "DELETE FROM tasks;"; K2=$(mk "compile the wiki page" dev "write it to the team wiki as a knowledge atom")
kn_bytes=$(printf '%s' "$(_hb_nudge_text dev "$K2" "DIVE-$K2")" | wc -c)
(( kn_bytes <= 2000 )) && ok_t "knowledge-shaped dispatch is ${kn_bytes}B (<= 2000)" \
                       || bad_t "knowledge-shaped dispatch has re-inflated: ${kn_bytes}B > 2000" ""

# =============================================================================
# PART 4 — the policy actually REACHES a host that already has a CLAUDE.md
# =============================================================================
# install.sh writes projects/CLAUDE.md on FIRST INSTALL ONLY and deliberately
# never clobbers a customised one. Left there, every existing host would keep a
# CLAUDE.md with no lifecycle section while the dispatch cites it — the contract
# deleted rather than moved. `sync_managed_block` reconciles the marked block on
# every install. The function is read OUT OF THE SHIPPED install.sh, so these
# arms grade the product, not a copy of it.
eval "$(sed -n '/^sync_managed_block()/,/^}$/p' install.sh)" 2>/dev/null
if declare -F sync_managed_block >/dev/null; then
  F="$TMP/blk"; mkdir -p "$F"
  printf '# a host CLAUDE.md\ncustom line A\n' > "$F/live.md"
  cp projects-CLAUDE.md "$F/src.md"
  sync_managed_block "$F/live.md" "$F/src.md" 5dive:task-lifecycle
  grep -qF "Task lifecycle" "$F/live.md" && grep -qF "custom line A" "$F/live.md" \
    && ok_t "install sync APPENDS the block to an existing CLAUDE.md, keeping its content" \
    || bad_t "install sync must append the block without clobbering" "$(cat "$F/live.md")"
  printf 'TRAILING CUSTOM\n' >> "$F/live.md"
  sed -i 's/One row per turn/MUTATED BY A HOST/' "$F/live.md"
  sync_managed_block "$F/live.md" "$F/src.md" 5dive:task-lifecycle
  [[ "$(grep -c '5dive:task-lifecycle:begin' "$F/live.md")" == 1 ]] \
    && ok_t "a second install REPLACES the block (no duplicate)" \
    || bad_t "a second install must not duplicate the block" "$(grep -c '5dive:task-lifecycle:begin' "$F/live.md") copies"
  grep -qF "One row per turn" "$F/live.md" && ! grep -qF "MUTATED BY A HOST" "$F/live.md" \
    && ok_t "a drifted block is restored from the published file" \
    || bad_t "the managed block must be restored on install" "$(cat "$F/live.md")"
  grep -qF "custom line A" "$F/live.md" && grep -qF "TRAILING CUSTOM" "$F/live.md" \
    && ok_t "text on BOTH sides of the block survives the replace" \
    || bad_t "content outside the markers must be byte-preserved" "$(cat "$F/live.md")"
  before=$(wc -c < "$F/live.md")
  sync_managed_block "$F/live.md" "$F/nope.md" 5dive:task-lifecycle
  [[ "$(wc -c < "$F/live.md")" == "$before" ]] \
    && ok_t "an unreadable source writes NOTHING (no truncation)" \
    || bad_t "a failed fetch must never truncate the live file" "size $before -> $(wc -c < "$F/live.md")"
else
  bad_t "install.sh must define sync_managed_block" "the policy would never reach an existing host"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
