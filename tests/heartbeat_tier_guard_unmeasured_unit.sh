#!/usr/bin/env bash
# DIVE-2213 unit: the heartbeat's privilege-escalation-by-queue guard must not
# treat a tier it COULD NOT MEASURE as a tier that is legitimately absent.
#
# THE DEFECT. DIVE-1065 refuses to AUTO-DRIVE a higher-tier agent from a
# lower-tier creator's task. It read both tiers as:
#
#     _ctier=$(jq -r --arg n "$_cby" '.agents[$n].isolation // empty' <<<"$reg" 2>/dev/null)
#     _cr=$(_hb_tier_rank "${_ctier:-}")            # "" -> 0
#     if (( _cr > 0 && _ar > 0 && _cr < _ar )); then HOLD; fi
#
# so an unmeasured tier ranked 0 and the guard SKIPPED ITSELF. `2>/dev/null`
# throws away WHY the lookup failed and `// empty` throws away THAT it failed;
# rank 0 then folds the residue in with "creator is a human". The tie went to
# running the work. Same collapse as DIVE-2210's envelope tier=, one class worse
# because this is a DECISION site, not a display one.
#
# THE FALSE BINARY. The ticket asked: hold everything unmeasured (stalls the
# fleet) or wake with a loud log (still decides on nothing)? Neither. Rank 0 was
# hiding TWO populations that want opposite policies:
#
#   MEASURED, no tier — creator is not a registered agent (a human, an external
#     filer). Majority of the board. Falling through IS the intent.
#   NOT MEASURED      — registry absent/unreadable/unparsable, jq errored, or a
#     REGISTERED agent whose isolation is missing/malformed. No basis to rank.
#
# Hold only the second and the fleet cannot stall in steady state, because a
# healthy registry never produces it. That is what agent_tier() +
# tier_unmeasured() add, and it is why they are NOT envelope_tier(): that one
# reports `unknown:unregistered` for BOTH populations on purpose (a wire format
# has no decision to make), which tests/envelope_tier_provenance_unit.sh asserts.
#
# WHAT IS ASSERTED HERE
#   A. agent_tier() splits the bucket envelope_tier() folds, and never returns
#      empty.
#   B. tier_unmeasured() keeps the polarity: unregistered is a MEASUREMENT.
#   C. The guard block, extracted VERBATIM from src/cmd_heartbeat.sh, decides
#      correctly under nine causes.
#   D. ANCHOR: the same harness driving the PRE-FIX block (extracted from a
#      PINNED commit, not reimplemented here) collapses those causes. Without
#      this the suite could pass against a guard that never had the bug. The
#      pin is load-bearing: naming a branch made the anchor compare post-fix to
#      post-fix the moment this merged. See the PRE_FIX_REF note below.
#   E. Structural: no decision site re-adds a stderr-swallowed isolation read,
#      and envelope_tier() is byte-identical to origin/main (DIVE-2210 is a
#      shipped wire format; this ticket must not move it).
#
# NOT MEASURED, declared: this does NOT run a live tick. It drives the guard's
# decision expression with stubbed db()/_hb_log(), so it proves which branch the
# guard takes, not that a tick reaches it. Reachability is measured separately
# and reported (see the REACHABILITY section) rather than asserted.
#
# Pure: fixture registries in a tmpdir, no root, no network, no tmux, no db.
#   bash tests/heartbeat_tier_guard_unmeasured_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

PASS=0; FAIL=0; SKIP=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
skip_t() { SKIP=$((SKIP+1)); printf 'SKIP - %s\n' "$1"; }
eq_t()   { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1 (expected '$2', got '$3')"; fi; }

# Source the SHIPPED resolvers out of the real source file so this test cannot
# drift from the code that runs (same technique as
# tests/envelope_tier_provenance_unit.sh).
REG_SRC=src/lib/registry.sh
for fn in registry_read registry_read_checked envelope_tier agent_tier tier_unmeasured; do
  eval "$(awk -v f="^${fn}\\\\(\\\\) \\\\{$" '$0 ~ f { on=1 } on { print } on && $0 == "}" { exit }' "$REG_SRC")"
  declare -F "$fn" >/dev/null \
    || { echo "FAIL: could not extract ${fn} from $REG_SRC (function missing?)"; exit 1; }
done
eval "$(awk '/^_hb_tier_rank\(\) \{$/ { on=1 } on { print } on && $0 == "}" { exit }' src/cmd_heartbeat.sh)"
declare -F _hb_tier_rank >/dev/null || { echo "FAIL: could not extract _hb_tier_rank"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

FIXTURE='{"agents":{
  "dev":{"isolation":"admin"},
  "boss":{"isolation":"admin"},
  "sandy":{"isolation":"sandboxed"},
  "ghost":{},
  "weird":{"isolation":"admin tier=root"}}}'

# ---------------------------------------------------------------------------
# A. agent_tier(): never empty, and it SPLITS what envelope_tier() folds.
# ---------------------------------------------------------------------------
REGISTRY="$TMP/agents.json"; printf '%s' "$FIXTURE" > "$REGISTRY"

eq_t "registered admin resolves to its tier"        "admin"     "$(agent_tier dev)"
eq_t "registered sandboxed resolves to its tier"    "sandboxed" "$(agent_tier sandy)"
eq_t "name absent from .agents is UNREGISTERED"     "unknown:unregistered" "$(agent_tier lodar)"
eq_t "registered but no isolation is NO-TIER"       "unknown:no-tier"      "$(agent_tier ghost)"
eq_t "no name supplied is its own reason"           "unknown:no-caller"    "$(agent_tier "")"
eq_t "space-bearing tier is refused, not ranked"    "unknown:malformed-tier" "$(agent_tier weird)"

# THE SPLIT, stated directly: envelope_tier() gives these two the SAME answer.
# That is correct for a wire format and wrong for a guard, which is the whole
# reason agent_tier() exists rather than a rename of envelope_tier().
eq_t "envelope_tier folds unregistered+untiered (unchanged, DIVE-2210)" \
     "unknown:unregistered|unknown:unregistered" \
     "$(envelope_tier lodar)|$(envelope_tier ghost)"
if [[ "$(agent_tier lodar)" != "$(agent_tier ghost)" ]]; then
  ok_t "agent_tier SPLITS them (this is the fix)"
else
  bad_t "agent_tier still folds unregistered and untiered together"
fi

REGISTRY="$TMP/missing.json"
eq_t "absent registry is a REASON"      "unknown:no-registry"         "$(agent_tier dev)"
printf '%s' '{"agents":{"dev":{"isolat' > "$TMP/trunc.json"; REGISTRY="$TMP/trunc.json"
eq_t "truncated registry is a REASON"   "unknown:registry-unparsable" "$(agent_tier dev)"
printf '%s' '{"fleet":{}}' > "$TMP/nomap.json"; REGISTRY="$TMP/nomap.json"
eq_t "no .agents map is a REASON"       "unknown:no-agents-map"       "$(agent_tier dev)"
# A directory is `-e` but cannot be cat'd — denies ROOT too, unlike chmod 000
# (which is inert against root and would make this probe pass vacuously).
mkdir -p "$TMP/adir"; REGISTRY="$TMP/adir"
eq_t "unreadable registry is a REASON"  "unknown:registry-unreadable" "$(agent_tier dev)"

REGISTRY="$TMP/agents.json"
_empty=0
for c in dev sandy lodar ghost weird "" nosuch; do
  [[ -n "$(agent_tier "$c")" ]] || _empty=$((_empty+1))
done
eq_t "agent_tier NEVER returns empty (the property, not the cases)" "0" "$_empty"

# ---------------------------------------------------------------------------
# B. tier_unmeasured(): polarity. unregistered is a MEASUREMENT, not a hole.
# ---------------------------------------------------------------------------
for m in admin standard sandboxed unknown:unregistered; do
  if tier_unmeasured "$m"; then bad_t "tier_unmeasured wrongly true for '$m'"; else ok_t "measured: $m"; fi
done
for u in unknown:no-caller unknown:no-registry unknown:registry-unreadable \
         unknown:registry-unparsable unknown:no-agents-map unknown:lookup-failed \
         unknown:no-tier unknown:malformed-tier; do
  if tier_unmeasured "$u"; then ok_t "NOT measured: $u"; else bad_t "tier_unmeasured missed '$u'"; fi
done

# ---------------------------------------------------------------------------
# C/D. Drive the guard block itself, extracted VERBATIM, under nine causes.
# ---------------------------------------------------------------------------
# Extract the block between its two banner comments from an arbitrary source
# TEXT, so the same harness can run the current tree and origin/main's pre-fix
# copy without either being retyped here.
_extract_guard() {  # stdin = a cmd_heartbeat.sh body
  awk '/# --- DIVE-1065 tier guard/ { on=1 } /# --- Same-account spread/ { on=0 } on { print }'
}

# Build a decider function from a guard block. `continue` inside the block ends
# the one-shot loop, so WAKE is printed only when no branch held.
_mk_decider() {  # $1 = fn name, stdin = guard block
  local fn="$1" block; block="$(cat)"
  [[ -n "$block" ]] || return 1
  eval "${fn}() {
    local task_id=1 task_ident='DIVE-9999'
    for _once in 1; do
${block}
      printf 'WAKE\n'
    done
  }"
}

# Stubs. db() answers only the created_by query the block issues; _hb_log()
# renders the hold so a HOLD's REASON is part of the observed outcome, not just
# the fact of it.
db()      { printf '%s\n' "$CREATOR"; }
sqlq()    { printf "'%s'" "$1"; }
_hb_log() { printf 'HOLD :: %s\n' "$1"; }

# outcome() collapses a run to WAKE, HOLD:unmeasured, or HOLD:escalation — the
# three decisions the guard can reach — so OLD and NEW are compared on the same
# alphabet rather than on log wording.
outcome() {
  local out; out="$("$@" 2>&1)"
  case "$out" in
    *WAKE*)               printf 'WAKE\n' ;;
    *"NOT MEASURED"*)     printf 'HOLD:unmeasured\n' ;;
    *"created by lower-tier"*) printf 'HOLD:escalation\n' ;;
    *)                    printf 'HOLD:other\n' ;;
  esac
}

# Nine causes. reg= is the in-memory blob the PRE-FIX block read; regfile= is
# what the fixed resolver re-reads from disk. They are set to the SAME condition
# so neither build is handed a friendlier world than the other.
#   label | creator | registry-condition | expected-NEW
CAUSES=(
  "human-creator|lodar|ok|WAKE"
  "registered-untiered-creator|ghost|ok|HOLD:unmeasured"
  "malformed-tier-creator|weird|ok|HOLD:unmeasured"
  "registry-absent|boss|missing|HOLD:unmeasured"
  "registry-truncated|boss|trunc|HOLD:unmeasured"
  "registry-unreadable|boss|dir|HOLD:unmeasured"
  "registry-no-agents-map|boss|nomap|HOLD:unmeasured"
  "lower-tier-creator|sandy|ok|HOLD:escalation"
  "equal-tier-creator|boss|ok|WAKE"
)

_set_world() {  # $1 = condition
  case "$1" in
    ok)      REGISTRY="$TMP/agents.json"; reg="$FIXTURE" ;;
    missing) REGISTRY="$TMP/missing.json"; reg='{"agents":{}}' ;;
    trunc)   REGISTRY="$TMP/trunc.json";   reg='{"agents":{}}' ;;
    dir)     REGISTRY="$TMP/adir";         reg='{"agents":{}}' ;;
    nomap)   REGISTRY="$TMP/nomap.json";   reg='{"agents":{}}' ;;
  esac
}

name=dev   # the assignee under test: admin, i.e. the escalation target

_mk_decider decide_new < <(_extract_guard < src/cmd_heartbeat.sh) \
  || { echo "FAIL: could not extract the guard block from src/cmd_heartbeat.sh"; exit 1; }

declare -a NEW_OUT=()
for row in "${CAUSES[@]}"; do
  IFS='|' read -r label CREATOR cond want <<<"$row"
  _set_world "$cond"
  got="$(outcome decide_new)"
  NEW_OUT+=("$got")
  eq_t "guard/$label" "$want" "$got"
done

# D. ANCHOR. Same harness, PRE-FIX block taken from a PINNED COMMIT — not
# retyped here, so this cannot silently agree with my reading of the old code.
# If the baseline is unavailable, SKIP loudly: an anchor that cannot run must
# not read as a pass.
#
# IT USED TO SAY `origin/main`, AND THAT WAS SELF-INVALIDATING. The moment this
# fix merged, origin/main BECAME the post-fix tree, so the anchor compared post
# to post: it reported "pre-fix block only auto-ran on 0/6 unmeasured causes"
# and "fix did not increase distinguishable decisions (3 -> 3)" — red for a
# reason that has nothing to do with the code under test, on main, inherited by
# whoever merged next. A baseline named by a BRANCH moves out from under the
# claim it anchors; name the COMMIT. (It also explains a count that looked like
# a disagreement: on a checkout with no reachable baseline these two SKIP, so
# the same harness honestly reports 36+2 there and 41 here.)
PRE_FIX_REF="9258ee1"   # main immediately before DIVE-2213 merged (PR #268)
OLD_SRC="$TMP/old_heartbeat.sh"
if git rev-parse --verify -q "${PRE_FIX_REF}^{commit}" >/dev/null 2>&1 \
   && git show "${PRE_FIX_REF}:src/cmd_heartbeat.sh" > "$OLD_SRC" 2>/dev/null; then
  if _mk_decider decide_old < <(_extract_guard < "$OLD_SRC"); then
    declare -a OLD_OUT=()
    for row in "${CAUSES[@]}"; do
      IFS='|' read -r label CREATOR cond want <<<"$row"
      _set_world "$cond"
      OLD_OUT+=("$(outcome decide_old)")
    done
    n_old=$(printf '%s\n' "${OLD_OUT[@]}" | sort -u | wc -l)
    n_new=$(printf '%s\n' "${NEW_OUT[@]}" | sort -u | wc -l)
    printf '#    distinct decisions across %d causes: OLD=%d NEW=%d\n' "${#CAUSES[@]}" "$n_old" "$n_new"
    printf '#    OLD: %s\n' "${OLD_OUT[*]}"
    printf '#    NEW: %s\n' "${NEW_OUT[*]}"

    # The defect, as one number: every not-measured cause used to decide WAKE.
    old_wakes_on_unmeasured=0
    for i in "${!CAUSES[@]}"; do
      IFS='|' read -r label CREATOR cond want <<<"${CAUSES[$i]}"
      [[ "$want" == "HOLD:unmeasured" && "${OLD_OUT[$i]}" == "WAKE" ]] \
        && old_wakes_on_unmeasured=$((old_wakes_on_unmeasured+1))
    done
    if (( old_wakes_on_unmeasured >= 6 )); then
      ok_t "ANCHOR: pre-fix block auto-ran on ${old_wakes_on_unmeasured}/6 unmeasured causes"
    else
      bad_t "ANCHOR is vacuous: pre-fix block only auto-ran on ${old_wakes_on_unmeasured}/6 unmeasured causes — the RED does not reproduce, so the greens above prove nothing"
    fi
    # And it must still be RIGHT about the two it always got right, or the fix
    # is being graded against a baseline that was broken for another reason.
    eq_t "ANCHOR: pre-fix held the real escalation" "HOLD:escalation" "${OLD_OUT[7]}"
    eq_t "ANCHOR: pre-fix woke on a human creator"  "WAKE"            "${OLD_OUT[0]}"
    if (( n_new > n_old )); then
      ok_t "fix strictly increases distinguishable decisions ($n_old -> $n_new)"
    else
      bad_t "fix did not increase distinguishable decisions ($n_old -> $n_new)"
    fi
  else
    skip_t "ANCHOR: ${PRE_FIX_REF}'s cmd_heartbeat.sh has no extractable guard block"
  fi
else
  skip_t "ANCHOR: pinned baseline ${PRE_FIX_REF} unavailable (shallow clone?) — pre-fix collapse NOT re-measured here"
fi

# ---------------------------------------------------------------------------
# E. Structural — the shape must not come back, and DIVE-2210 must not move.
# ---------------------------------------------------------------------------
# No decision site may read isolation with its stderr swallowed again.
bad_reads="$(grep -n "agents\[\$n\]\.isolation" src/cmd_heartbeat.sh src/cmd_task.sh 2>/dev/null || true)"
eq_t "no raw isolation lookup left at the guard/show sites" "" "$bad_reads"

# The guard must route through the predicate, not re-derive the polarity inline.
if grep -q 'tier_unmeasured' src/cmd_heartbeat.sh; then
  ok_t "guard uses tier_unmeasured()"
else
  bad_t "guard no longer routes through tier_unmeasured()"
fi

# DIVE-2210's envelope_tier() is a shipped wire format that olivia verified.
# This ticket adds a sibling; it must not edit it.
if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
  old_et="$(git show origin/main:src/lib/registry.sh 2>/dev/null | awk '/^envelope_tier\(\) \{$/ { on=1 } on { print } on && $0 == "}" { exit }')"
  new_et="$(awk '/^envelope_tier\(\) \{$/ { on=1 } on { print } on && $0 == "}" { exit }' src/lib/registry.sh)"
  eq_t "envelope_tier() is byte-identical to origin/main (DIVE-2210 untouched)" "$old_et" "$new_et"
else
  skip_t "envelope_tier() drift check (origin/main unavailable)"
fi

# ---------------------------------------------------------------------------
# REACHABILITY — reported, not asserted, because it is a claim about a live tick.
# ---------------------------------------------------------------------------
# The pre-fix block read `$reg`, and the wake loop enumerates agents from that
# SAME blob. A whole-registry failure therefore yielded zero agents and the guard
# was NOT REACHED — so of the six unmeasured causes above, only the three that
# leave the registry loadable (untiered creator, malformed tier, jq failure) were
# reachable in production before this fix. The other three are reachable AFTER
# it, because agent_tier() re-reads the registry at decision time and so also
# catches a registry that dies mid-tick. Stating this so the OLD=WAKE column is
# not over-read as six live incidents.
printf '#    REACHABILITY: pre-fix, whole-registry failures could not reach this\n'
printf '#    guard (the wake loop enumerates from the same $reg). Reachable pre-fix:\n'
printf '#    registered-untiered creator, malformed tier, jq failure.\n'

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
