#!/usr/bin/env bash
# DIVE-4462 — THE GATE REFUSAL SEAM.
#
# `fail()` (src/lib/output.sh) ends with `exit "$code"`. A harness that sources
# src/ and calls `cmd_task_need` in its own shell therefore DIES on any refusal
# inside that function — not with a failed arm, but at rc=3 before its summary.
# Every assertion after the call is SKIPPED, not passed. Measured on DIVE-4431:
# one new refusal aborted ten harnesses across all three core-pristine shards,
# and `gate_verifier_route_unit` died after 3 of its 22 arms.
#
# That is a property of the SEAM, not of any one rule: the next refusal anyone
# adds to `cmd_task_need` inherits it. CEO direction on DIVE-4462 (2026-09-13):
# "a refusal in that function must fail its own arm, never abort the process".
#
# THE FIX IS ONE SOURCE LINE PER HARNESS, NOT A CALL-SITE SWEEP. Sourcing this
# file re-binds `cmd_task_need` to a wrapper that runs the real function in a
# SUBSHELL, so `fail`'s `exit` ends the subshell and returns its code to the
# caller. Call sites are untouched: 37 harnesses under tests/ pass the bare-letter
# `--options` idiom and none of them has to change shape. The refusal still
# refuses, still prints its message, still returns 3 — it just no longer takes
# the harness with it.
#
# WHAT A SUBSHELL DOES NOT CARRY BACK: shell variables set by cmd_task_need. Its
# real effects are sqlite writes and audit-log lines, which are separate
# processes and persist. Nothing under tests/ reads a variable back out of it.
#
# THE OPT-OUT, and why it is declared rather than inferred. A subshell discards
# shell state, so a harness whose SUBJECT is in-process state that cmd_task_need
# sets — `_TASK_STORE_AUDIT_FENCED` (audit_task_store_fence_unit: "the notice is
# one-shot per PROCESS"), or a stubbed `task_need_notify` recording into a
# variable the arms read back (gate_precedent_unit, DIVE-4346) — must not be
# wrapped: wrapping it does not red the arm, it makes the arm grade a different
# program. Set `GATE_SEAM_INPROCESS=1` before sourcing, WITH A WRITTEN REASON.
# Those harnesses keep the ABORT marker instead: a refused fixture still ends
# them, but it ends with a verdict rather than with silence, and silence is the
# half that misleads a reader.
#
# Source AFTER src/cmd_task.sh, and only from a test harness — this file is not
# shipped behaviour and production must keep `exit` on a refusal.

_gate_seam_install() {
  if [[ "${GATE_SEAM_INPROCESS:-0}" == "1" ]]; then
    printf 'gate seam: DECLINED by GATE_SEAM_INPROCESS=1 — this harness grades in-process state, so a refusal inside cmd_task_need still ends it (the ABORT marker is what names that)\n' >&2
    return 0
  fi
  if ! declare -F cmd_task_need >/dev/null 2>&1; then
    printf 'gate seam: cmd_task_need not defined — source src/cmd_task.sh FIRST; refusals will still abort this harness\n' >&2
    return 1
  fi
  # Already installed (a harness that sources this twice, or a nested bootstrap).
  declare -F _gate_seam_real_task_need >/dev/null 2>&1 && return 0
  local _body
  _body=$(declare -f cmd_task_need) || return 1
  eval "_gate_seam_real_task_need() ${_body#*$'\n'}" || return 1
  cmd_task_need() { ( _gate_seam_real_task_need "$@" ); }
  return 0
}

_gate_seam_install || true
