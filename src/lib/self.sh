
# Resolving "which 5dive bundle am I?" — the one question every self-re-invocation
# has to get right, and the one it is easiest to get wrong.
#
# THE DEFECT THIS EXISTS TO KILL (DIVE-2061, then DIVE-2080 one call deeper):
#   self="$(command -v 5dive 2>/dev/null || echo "$0")"
# `command -v` answers "is something named 5dive on PATH" — never "which bundle am
# I part of". On every agent box 5dive IS installed, so that line silently swaps the
# INSTALLED CLI in for the artifact under test. selfcheck's probe 7 shipped that way:
# a mutated worktree bundle graded the healthy installed CLI, printed 0.42 for all
# seven metrics, and reported ok/rc 0 — grading a different artifact than the one it
# lives in, and unable to tell. Invisible in CI for the worst possible reason: CI has
# no installed 5dive, so `$0` wins there and the bug never reproduces.
#
# DIVE-2061 fixed the probe. DIVE-2080 found the same line still sitting one level
# down in `proof scorecard` / `proof badges` — so the probe faithfully shelled into a
# callee that then re-resolved itself onto the installed bundle. Hence a SHARED
# helper: the rule is only enforceable if there is exactly one implementation of it.
#
# Order is running-bundle first, PATH LAST, and every candidate must actually BE a
# 5dive bundle — a sourced `src/cmd_*.sh` under a unit harness would otherwise
# resolve `$0` to the harness itself. Returns 1 rather than guessing, because for an
# EVIDENCE path "I could not identify myself" is a real verdict and a wrong bundle is
# not: see community/wiki/not-reached-is-a-verdict-selfcheck-dive2039.md rule 5.
#
# USE IT WHEREVER THE CLI RE-INVOKES ITSELF TO PRODUCE EVIDENCE. Sites whose intent
# genuinely IS "run whatever is installed on this box" (cron drivers, sudo -u re-execs
# for another agent) are a different question and should say so in a comment at the
# site — do not blanket-replace.
five_self_bundle() {
  local c
  for c in "${BASH_SOURCE[0]:-}" "$0" "$(command -v 5dive 2>/dev/null)"; do
    [[ -n "$c" && -x "$c" && -f "$c" ]] || continue
    grep -qm1 '^readonly FIVE_VERSION=' "$c" 2>/dev/null || continue
    readlink -f "$c" 2>/dev/null || printf '%s' "$c"
    return 0
  done
  return 1
}
