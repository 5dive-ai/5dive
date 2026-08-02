#!/usr/bin/env bash
# DIVE-2054 — every audit_log call site in cmd_task.sh/cmd_heartbeat.sh must be
# CLASSIFIED, not sed-swept: routed through _task_store_audit_log (task-store
# state, fenced on STORE IDENTITY per DIVE-2010), or carrying an explicit
# "DELIBERATELY UNFENCED" in-code marker with a reason (human-delivery evidence
# a fixture store must never be able to suppress — DIVE-2054 wiki names three:
# task clear-recs' chat=$channel_proof, task answer escalate-to-human, task
# need withdraw's asserted_from=).
#
# WHY A SOURCE GREP AND NOT JUST "read the diff": DIVE-2010 measured a real
# regression-test blind spot in this exact family — a `\`-line-continuation
# split the EUID-gate pattern across two physical lines and the old
# audit_nonroot_unit.sh grep passed vacuously while the live defect sat three
# lines below it. This suite joins continuations before matching (same
# technique audit_nonroot_unit.sh was hardened with) so a future reflow of a
# raw audit_log call can't hide from it either.
#
# What is pinned here: every raw (non-wrapper) audit_log call in these two
# files is either (a) the wrapper's own internal call, (b) the one
# differently-fenced legacy site ("gate delivery", fenced via
# _task_human_send_allowed/_prod_telemetry pre-dating this wrapper, DIVE-1968),
# or (c) immediately preceded by a "DELIBERATELY UNFENCED" comment. A NEW raw
# audit_log call added later with none of these three markers fails this
# suite — the intent is to force classification, not silently default to
# either fencing or leaking.
# Run: bash tests/audit_task_store_classification_unit.sh   (no root, no network)
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
SRC=src

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

UNCLASSIFIED=""
for f in "$SRC/lib/actor.sh" "$SRC/cmd_task.sh" "$SRC/cmd_heartbeat.sh"; do
  [[ -r "$f" ]] || { bad_t "file readable: $f" "missing"; continue; }
  # Join `\`-continuations into one logical line, keeping a parallel array of
  # the FIRST physical line number each logical line started on (so a failure
  # message points somewhere useful) and the up-to-5-physical-lines-above
  # context (for the DELIBERATELY UNFENCED marker check, which is written as
  # its own preceding comment line, not on the call's own line).
  mapfile -t LINES < "$f"
  logical=""; start=0
  n=${#LINES[@]}
  for (( i=0; i<n; i++ )); do
    ln="${LINES[$i]}"
    if [[ -z "$logical" ]]; then start=$((i+1)); fi
    logical="${logical:+$logical }${ln%\\}"
    if [[ "$ln" == *\\ ]]; then continue; fi
    # logical line complete, spanning physical lines [start .. i+1]
    stripped="${logical#"${logical%%[![:space:]]*}"}"   # trim leading whitespace
    if [[ "$stripped" != \#* && "$logical" == *'audit_log "'* && "$logical" != *'_task_store_audit_log "'* ]]; then
      # Exclude the wrapper's own internal call (`audit_log "$@"`).
      if [[ "$logical" != *'audit_log "$@"'* ]]; then
        # Exclude the one legacy differently-fenced site.
        if [[ "$logical" != *'audit_log "gate delivery"'* ]]; then
          ctx_lo=$(( start-6 < 0 ? 0 : start-6 ))
          ctx=$(printf '%s\n' "${LINES[@]:$ctx_lo:$((start-ctx_lo))}")
          if [[ "$ctx" != *"DELIBERATELY UNFENCED"* ]]; then
            UNCLASSIFIED+="$f:$start: $stripped"$'\n'
          fi
        fi
      fi
    fi
    logical=""
  done
done

if [[ -z "$UNCLASSIFIED" ]]; then
  ok_t "every raw audit_log call in cmd_task.sh/cmd_heartbeat.sh is fenced, deliberately-unfenced-with-reason, or the one named legacy exception"
else
  bad_t "unclassified raw audit_log call site(s) found" "$UNCLASSIFIED"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
