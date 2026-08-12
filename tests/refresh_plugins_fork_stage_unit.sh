#!/usr/bin/env bash
# DIVE-3269 — the FORK telegram plugins are delivered from a REF, and the delivery
# is testable without delivering.
#
# THE DEFECT. The five fork plugins (codex/grok/agy/pi/opencode) load
# /usr/local/lib/5dive/telegram-<rt>/server.ts directly. Nothing on the host wrote
# that path. Measured 2026-08-11: all five staged copies predated DIVE-3224 by an
# hour with that row AND DIVE-3267 both merged — not a slow schedule, no schedule.
# "Merged" and "running" were indistinguishable from every surface, which is why it
# went unnoticed rather than unfixed.
#
# WHAT THIS FILE GRADES, and it is the decisions rather than the plumbing. Each of
# the three has a wrong answer that looks reasonable, and two of them are only
# WRONG in a situation that does not arise on a healthy day:
#
#   W1 (arm S7) stage from a REF, never a working tree. The obvious implementation
#      reads the shared checkout — which that day sat on a feature branch. So S7
#      parks the source repo's working tree on a branch carrying poison and asserts
#      the staged bytes still come from main. A staging step tested only against a
#      tidy checkout passes while carrying this bug.
#   W2 (arm S6) never degrade to another source when the ref will not resolve. S6
#      asks for a ref that does not exist and asserts the previous staged copy is
#      left ALONE — stale-but-reviewed over fresh-but-unreviewed.
#   W3 (arm S5) overlay, do not replace. The staged dirs carry node_modules the
#      repo does not; a clean-and-copy leaves every fork agent unable to start. S5
#      plants a node_modules marker and asserts it survives a re-stage.
#
# S2 is the one whose absence would be expensive: the CLAUDE-lineage plugin lives
# in the same plugins/ dir and is delivered by an entirely different mechanism, so
# staging it here would overwrite a marketplace-managed tree with a bare checkout.
#
# Run: bash tests/refresh_plugins_fork_stage_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
STAGE_SH="$PWD/5dive-stage-fork-plugins.sh"
TMP="$(mktemp -d /tmp/fork-stage-unit.XXXXXX)"
SUMMARY_PRINTED=0
exec 8>&2
trap 'rc=$?; rm -rf "$TMP"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - refresh_plugins_fork_stage_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

[[ -x "$STAGE_SH" ]] || { bad_t "S0 the staging script exists and is executable" "$STAGE_SH"; printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; SUMMARY_PRINTED=1; exit 1; }

# ---- a fake upstream, standing in for 5dive-ai/5dive-plugins -------------------
UP="$TMP/upstream"
mkdir -p "$UP/plugins/telegram-fake1/hooks" "$UP/plugins/telegram-fake2" "$UP/plugins/telegram"
git init -q "$UP"
git -C "$UP" config user.email t@example.com; git -C "$UP" config user.name t
echo 'export const V = "v1"' > "$UP/plugins/telegram-fake1/server.ts"
echo '{"name":"fake1"}'      > "$UP/plugins/telegram-fake1/package.json"
echo 'lock-v1'               > "$UP/plugins/telegram-fake1/bun.lock"
echo 'hook-v1'               > "$UP/plugins/telegram-fake1/hooks/h.ts"
echo 'export const V = "v1"' > "$UP/plugins/telegram-fake2/server.ts"
echo 'CLAUDE-LINEAGE'        > "$UP/plugins/telegram/server.ts"
git -C "$UP" add -A; git -C "$UP" commit -qm one
git -C "$UP" branch -M main

export FORK_REPO_URL="file://$UP"
export FORK_MIRROR="$TMP/mirror.git"
export FORK_STAGE_ROOT="$TMP/stage"
mkdir -p "$FORK_STAGE_ROOT"

run_stage()  { "$STAGE_SH" 2>"$TMP/err.log"; }
run_status() { "$STAGE_SH" --status 2>"$TMP/err.log"; }
staged()     { cat "$FORK_STAGE_ROOT/$1/server.ts" 2>/dev/null; }
msha()       { grep -o '"sha":"[a-f0-9]*"' "$FORK_STAGE_ROOT/$1/$2" 2>/dev/null | cut -d'"' -f4; }

# ================================================================================
# S — staging
# ================================================================================
out="$(run_stage)"
grep -q 'changed: telegram-fake1' <<<"$out" && grep -q 'changed: telegram-fake2' <<<"$out" \
  && ok_t "S1 a first run stages every fork in the ref and says which changed" \
  || bad_t "S1 first stage" "out: $(tr '\n' '|' <<<"$out")"

[[ "$(staged telegram-fake1)" == 'export const V = "v1"' ]] \
  && ok_t "S1b …and the bytes landed" || bad_t "S1b bytes" "got: $(staged telegram-fake1)"

# S2 the CLAUDE-lineage plugin sits in the same plugins/ dir and is delivered by a
# DIFFERENT mechanism (a versioned marketplace cache). Staging it here would
# overwrite a managed tree with a bare checkout.
[[ -e "$FORK_STAGE_ROOT/telegram" ]] \
  && bad_t "S2 base plugin excluded" "the claude-lineage 'telegram' was staged — it is marketplace-managed" \
  || ok_t "S2 the claude-lineage 'telegram' is NOT staged (different mechanism, same directory)"

[[ "$(git -C "$FORK_MIRROR" rev-parse --is-bare-repository 2>/dev/null)" == "true" ]] \
  && ok_t "S3 the mirror is BARE — it has no working tree that could be parked" \
  || bad_t "S3 bare mirror" "rev-parse --is-bare-repository said $(git -C "$FORK_MIRROR" rev-parse --is-bare-repository 2>&1)"

out="$(run_stage)"
grep -q 'changed:' <<<"$out" \
  && bad_t "S4 idempotent" "a second run with no upstream change reported: $(tr '\n' '|' <<<"$out")" \
  || ok_t "S4 a second run with nothing new reports no change (idempotent, so the cron does not bounce agents nightly)"

# ---- W3: overlay, do not replace ----------------------------------------------
mkdir -p "$FORK_STAGE_ROOT/telegram-fake1/node_modules/dep"
echo 'installed' > "$FORK_STAGE_ROOT/telegram-fake1/node_modules/dep/index.js"
echo 'export const V = "v2"' > "$UP/plugins/telegram-fake1/server.ts"
git -C "$UP" commit -qam two
out="$(run_stage)"
[[ "$(staged telegram-fake1)" == 'export const V = "v2"' ]] \
  && ok_t "S5a an upstream change re-stages" || bad_t "S5a restage" "got: $(staged telegram-fake1)"
[[ -f "$FORK_STAGE_ROOT/telegram-fake1/node_modules/dep/index.js" ]] \
  && ok_t "S5 W3 node_modules SURVIVES the re-stage (overlay, not clean-and-copy)" \
  || bad_t "S5 node_modules" "a clean-and-copy deleted it — every fork agent would fail to start"
grep -q 'changed: telegram-fake2' <<<"$out" \
  && bad_t "S5b untouched fork" "telegram-fake2 was re-staged though nothing in it moved" \
  || ok_t "S5b …and a fork whose files did not move is not re-staged"

# ================================================================================
# W2 — the ref will not resolve: skip, never substitute
# ================================================================================
echo 'SENTINEL' > "$FORK_STAGE_ROOT/telegram-fake1/sentinel.txt"
before="$(staged telegram-fake1)"
out="$(FORK_REF=no-such-ref "$STAGE_SH" 2>&1)"
if [[ "$(staged telegram-fake1)" == "$before" && -f "$FORK_STAGE_ROOT/telegram-fake1/sentinel.txt" ]]; then
  ok_t "S6 W2 an unresolvable ref leaves the previous staged copy ALONE"
else
  bad_t "S6 W2 unresolvable ref" "the staged copy changed when the ref could not be resolved"
fi
grep -qiE 'skip|could not resolve' <<<"$out" \
  && ok_t "S6b …and says so out loud rather than exiting quietly" \
  || bad_t "S6b loud skip" "out: $(tr '\n' '|' <<<"$out")"

# ================================================================================
# W1 — THE DECISION THIS ROW TURNS ON: a parked working tree is not a source
# ================================================================================
# Reproduces the live condition: the shared checkout was on dive-1428-gap23-inline-
# clear at ca36c73 while main was 40+ commits ahead. A stage step reading the tree
# ships that branch to every fork agent, unreviewed, and looks perfectly healthy.
git -C "$UP" checkout -q -b parked-feature-branch
echo 'export const V = "POISON-FROM-A-PARKED-BRANCH"' > "$UP/plugins/telegram-fake1/server.ts"
git -C "$UP" commit -qam poison
# …and leave the WORKING TREE dirty too, which is the other half of the live state.
echo 'export const V = "POISON-UNCOMMITTED"' > "$UP/plugins/telegram-fake1/server.ts"
out="$(run_stage)"
if [[ "$(staged telegram-fake1)" == *POISON* ]]; then
  bad_t "S7 W1 parked tree" "staged content came from the parked branch/dirty tree: $(staged telegram-fake1)"
else
  ok_t "S7 W1 a parked branch AND a dirty working tree change nothing — staging reads the ref"
fi
[[ "$(staged telegram-fake1)" == 'export const V = "v2"' ]] \
  && ok_t "S7b …the staged bytes are still main's" || bad_t "S7b" "got: $(staged telegram-fake1)"
git -C "$UP" checkout -q -- . ; git -C "$UP" checkout -q main

# ================================================================================
# R — the readout, which is half of "done" for this row
# ================================================================================
st="$(run_status)"
grep -qE 'telegram-fake1 .*CURRENT' <<<"$st" \
  && ok_t "R1 --status reports a staged fork as CURRENT" || bad_t "R1 status current" "st: $(tr '\n' '|' <<<"$st")"

echo 'export const V = "v3"' > "$UP/plugins/telegram-fake1/server.ts"
git -C "$UP" commit -qam three
st="$(run_status)"
grep -qE 'telegram-fake1 .*BEHIND' <<<"$st" \
  && ok_t "R2 …and BEHIND once upstream moves — the question nobody could ask before" \
  || bad_t "R2 status behind" "st: $(tr '\n' '|' <<<"$st")"

# R3 a dir staged by hand (or before this mechanism existed) is NOT 'current'. It is
# unattributable, and saying so is the point — that state is exactly what was on the
# box for five forks, reading as fine from every surface.
mkdir -p "$FORK_STAGE_ROOT/telegram-handmade"; echo x > "$FORK_STAGE_ROOT/telegram-handmade/server.ts"
st="$(run_status)"
grep -qE 'telegram-handmade .*MODIFIED' <<<"$st" \
  && ok_t "R3 a hand-staged fork reads MODIFIED (matches no ref), never CURRENT" \
  || bad_t "R3 handmade" "st: $(tr '\n' '|' <<<"$st")"

# R5 THE ARM FOR THE WHOLE ROW, one layer up. A --status that reads the version from
# a file the stage step itself wrote can only ever confirm THE STAGER RAN, not that
# the plugin on disk is that version — which is "merged and running are
# indistinguishable" reproduced inside the fix for it. So: stage cleanly (manifest
# says CURRENT), then hand-edit server.ts the way someone patching a live box does,
# and assert the verdict moves. The real box carries a server.ts.bak-dive3179-* right
# now, so this is a state that HAPPENS, not a hypothetical.
git -C "$UP" checkout -q main 2>/dev/null
run_stage >/dev/null 2>&1
st="$(run_status)"
grep -qE 'telegram-fake2 .*CURRENT' <<<"$st" || bad_t "R5 precondition" "fake2 was not CURRENT before the edit: $(tr '\n' '|' <<<"$st")"
echo 'export const V = "HAND-PATCHED ON THE BOX"' > "$FORK_STAGE_ROOT/telegram-fake2/server.ts"
st="$(run_status)"
if grep -qE 'telegram-fake2 .*CURRENT' <<<"$st"; then
  bad_t "R5 manifest cannot be the verdict" "a hand-edited server.ts still reads CURRENT — status is agreeing with the writer, not measuring the disk"
else
  ok_t "R5 a hand-edited staged file stops reading CURRENT — the verdict is hashed from disk, not taken from the manifest"
fi
[[ -r "$FORK_STAGE_ROOT/telegram-fake2/$(basename .5dive-stage.json)" ]] 2>/dev/null || true
grep -qE 'telegram-fake2 .*MODIFIED' <<<"$st" \
  && ok_t "R5b …and it is named MODIFIED, distinct from BEHIND (a refresh will overwrite it)" \
  || bad_t "R5b" "st: $(tr '\n' '|' <<<"$st")"

# A1 the install is per-file rename-into-place, so a crashed run cannot leave a
# truncated server.ts for five live agents. The observable is that no scratch file
# survives a successful run.
run_stage >/dev/null 2>&1
if find "$FORK_STAGE_ROOT" -name '*.stage-tmp' | grep -q .; then
  bad_t "A1 atomic install" "a .stage-tmp scratch file survived a successful run"
else
  ok_t "A1 no .stage-tmp scratch files survive a run (per-file rename-into-place)"
fi

# R4 with no upstream reachable the verdict is UNKNOWN, never CURRENT — same posture
# as ops/in-my-binary.sh: never claim live off a measurement that could not be taken.
st="$(FORK_REPO_URL="file://$TMP/nope" FORK_MIRROR="$TMP/nomirror.git" "$STAGE_SH" --status 2>/dev/null)"
grep -q 'UPSTREAM UNKNOWN' <<<"$st" \
  && ok_t "R4 an unreachable upstream reports UNKNOWN rather than a comparison it cannot make" \
  || bad_t "R4 unknown upstream" "st: $(tr '\n' '|' <<<"$st")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
SUMMARY_PRINTED=1
[[ "$FAIL" == 0 ]]
