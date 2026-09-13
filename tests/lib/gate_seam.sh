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
# Source AFTER src/cmd_task.sh, and only from a test harness — this file is not
# shipped behaviour and production must keep `exit` on a refusal.

_gate_seam_install() {
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
