#!/usr/bin/env bash
# TIER: nightly — 62.4s measured on the agent-dev seat, this host, 2026-09-22, at 3 mutants: it re-runs tests/gate_urgent_row_routes_now_unit.sh (21.1s there, and that box runs these ~2.5x slower than the ubuntu-latest core runner) once per mutant plus a source-tree copy each time. Demoted under the mutation-harness rule (DIVE-2867): the cost is arms x tree-copy by construction and does not shrink with tuning. Re-stamp this number from a CI report, not from a seat, and quote the environment when you do.
# DIVE-4809 mutation grader for tests/gate_urgent_row_routes_now_unit.sh.
#
# WHY THIS FILE EXISTS. The change it grades can only ever turn urgency ON, so a
# suite made of "it turned on" arms passes on source that routes EVERY gate
# immediately — which would silently delete DIVE-3474 arm 2's measured result. M2 is
# that exact wrong implementation, and it exists to prove the CONTROL arm is live.
# M3 is the other cheap wrong one: keep the behaviour, launder the provenance into
# the filer's own declaration. Every behavioural arm stays green under M3; only the
# record notices, which is the whole reason the record is separate.
#
# Every mutant asserts its own application (exactly ONE occurrence across
# src/cmd_task.sh + src/task/*.sh, or the run fails loudly) and asserts the copy
# differs on disk — a mutation that silently no-opped after a refactor, or an
# unwritable copy, would otherwise run as a CONTROL and read as a passing grade.
#
# BLAST RADIUS. Both anchors are single lines in src/task/need.sh and each is unique
# across the whole task source set. The uniqueness check is what enforces that: if a
# second derivation site is ever added, these mutants FAIL rather than grade half of
# the change from one of the two sites (the failure measured on DIVE-4779).
# Run: bash tests/gate_urgent_row_routes_now_mutation.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/gate-urgent-row-mut.XXXXXX)"

MPASS=0; MFAIL=0
ok_t()  { MPASS=$((MPASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { MFAIL=$((MFAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

grade() {
  local name="$1" want="$2" old="$3" new="$4"
  local dir="$TMP/mut-$name"; rm -rf "$dir"; mkdir -p "$dir"
  cp -r src "$dir/src"
  if ! OLD="$old" NEW="$new" D="$dir/src" python3 - <<'PY'
import os, sys, glob
d, old, new = os.environ["D"], os.environ["OLD"], os.environ["NEW"]
files = [os.path.join(d, "cmd_task.sh")] + sorted(glob.glob(os.path.join(d, "task", "*.sh")))
hits = [(p, open(p).read()) for p in files]
n = sum(s.count(old) for _, s in hits)
if n != 1:
    sys.stderr.write("mutation did not apply cleanly: %d occurrences of %r across %d files\n"
                     % (n, old[:120], len(files)))
    sys.exit(1)
for p, s in hits:
    if old in s:
        open(p, "w").write(s.replace(old, new))
PY
  then
    bad_t "$name — mutation applies to the current source" "the anchor is gone or duplicated; this mutant graded NOTHING"
    return
  fi
  if diff -qr src/task "$dir/src/task" >/dev/null 2>&1; then
    bad_t "$name — mutant differs from the baseline on disk" "the copy is byte-identical to src: this mutant graded NOTHING"
    return
  fi
  local out rc
  out=$(GU_SRC_DIR="$dir/src" bash tests/gate_urgent_row_routes_now_unit.sh 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then
    bad_t "$name — the arms must go RED" "the arms stayed GREEN with the property removed: the '$want' arm grades nothing"
    return
  fi
  if grep -q "FAIL - .*${want}" <<<"$out"; then
    ok_t "$name — kills the '$want' arm"
  else
    bad_t "$name — kills the '$want' arm" "the arms failed, but NOT on that one: $(grep '^FAIL' <<<"$out" | head -3)"
  fi
}

# M1: the pre-DIVE-4809 source. The derivation is gone; the urgent row queues again.
grade "M1-derivation-removed" "GU2 urgent row wakes reviewer" \
  '    if [[ "$_row_prio" == "urgent" ]]; then urgent=1; urgent_src="priority=urgent"; fi' \
  '    :' \
  || true

# M2: the derivation fires for EVERY priority. This is the failure the control arm
# exists for, and it is the cheap wrong implementation — it passes GU2/GU3/GU4.
grade "M2-derivation-unconditional" "GU1 control queues" \
  'if [[ "$_row_prio" == "urgent" ]]; then urgent=1; urgent_src="priority=urgent"; fi' \
  'urgent=1; urgent_src="priority=urgent"' \
  || true

# M3: the effect is kept but the PROVENANCE is laundered into the filer's own
# declaration. Every behavioural arm stays green; only the record notices.
grade "M3-provenance-laundered" "GU2d audit provenance" \
  'if [[ "$_row_prio" == "urgent" ]]; then urgent=1; urgent_src="priority=urgent"; fi' \
  'if [[ "$_row_prio" == "urgent" ]]; then urgent=1; urgent_src="--urgent"; fi' \
  || true

printf '\n%d mutants killed, %d mutants survived-or-void\n' "$MPASS" "$MFAIL"
(( MFAIL == 0 ))
