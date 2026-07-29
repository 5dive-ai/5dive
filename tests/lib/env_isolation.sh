# shellcheck shell=bash
# NEUTRALISE THE CALLER'S ENVIRONMENT.  (DIVE-2325.)
#
# THE DEFECT THIS CLOSES, and it is DIVE-2211 one axis over. grading_tree.sh
# pinned WHICH TREE a harness grades, because "21 passed" was a claim about
# whatever was on disk. The same sentence was still true of the ENVIRONMENT: the
# product reads 14 caller-overridable `FIVE_*` knobs, every harness inherits the
# caller's environment, and a knob set in that environment silently changes what
# the harness measures. A green log from a clean shell and a red log from a shell
# with one export are byte-identical in every respect except the number.
#
# MEASURED, and this is the incident that produced this file. `task_core_unit`
# (28/7) and `task_verifier_rail_unit` (17/6) were red on the control-plane host and
# GREEN in CI at the same commit. It read as host state — the DIVE-1919 class the
# unit-tests workflow warns about, where a harness leaks out of its isolation. It
# was not host state. `FIVE_VERIFY_DEFAULT=0` is in the caller's environment, the
# DIVE-969 verifier-by-default rail reads `${FIVE_VERIFY_DEFAULT:-1}`, and the whole
# rail goes inert — not a wrong value, no mechanism at all. Reproduced exactly:
# `FIVE_VERIFY_DEFAULT=0 bash tests/task_core_unit.sh` gives 28/7 and the rail
# harness gives 17/6, same arm names.
#
# THAT KNOB IS DELIBERATE FLEET POLICY. DO NOT DELETE IT TO MAKE A TEST PASS.
# It is set for SIXTEEN agents by lodar's backlog policy of 2026-07-29 00:49,
# delivered through the unit's `EnvironmentFile=-/var/lib/5dive/agents.d/%i.env`,
# and every one of those files carries the decision and its own revert instruction:
#
#     # DIVE backlog policy 2026-07-29 (lodar): verifier-graded is OPT-IN, not default.
#     # Explicit --verifier=<agent> still forces the rail ON. Revert: set to 1 or delete.
#     FIVE_VERIFY_DEFAULT=0
#
# THIS IS WHY THE HARNESSES ARE THE ONLY THING THAT CAN MOVE — a stronger reason
# than the one this file was first written with. The configuration is not an
# accident awaiting cleanup; it is correct, intentional and permanent. So a harness
# asserting what DIVE-969 does BY DEFAULT must not read that default from the
# environment, or it grades fleet policy instead of the code. It has to supply its
# own. Tasks filed without a rail since 00:49 are POLICY-CONFORMANT, not damage;
# there is no backlog of broken rows to go hunting for.
#
# AND BEWARE THE INSTRUMENT THAT DIAGNOSED IT. A scan of `/proc/<pid>/environ` across
# the fleet found the knob in exactly ONE agent's session, which looked like a stray
# export by one operator. That inference was wrong. A live process environ reflects
# the env file as of THAT SESSION'S LAST EXEC, so the scan measured RESTART ORDER and
# it was read as CONFIGURATION: agents that had not restarted since 00:49 still showed
# a pre-policy environ, and each picks the knob up on its next restart. **Read the
# config source, not the running processes.** grading_tree.sh pins WHICH TREE, this
# file pins WHICH ENVIRONMENT, and that scan needed WHICH MOMENT — a snapshot cannot
# see a config that has not been exec'd yet.
#
# WHY THE WHOLE NAMESPACE AND NOT THE ONE KNOB. The knob that bit us is not
# special; `FIVE_GATE_REPOS`, `FIVE_GATE_MAIN_BRANCH` and `FIVE_GATE_ANCESTRY_SCAN`
# would each silently rewrite what the merge-gate harnesses measure, and knob #15
# will be added by someone who has never read this file. A blanket unset is the
# only version that covers the knob nobody has invented yet. Verified safe: no
# harness assigns a `FIVE_*` variable before it sources grading_tree.sh, so this
# can never clobber a value a harness meant to set — anything set afterwards wins,
# which is how the harnesses that DO drive these knobs (e.g. the ancestry-scan
# bound) keep working.
#
# UNSET rather than set-to-a-default, deliberately: unsetting restores the `:-`
# default that ships in src/, which is by construction the value CI runs with. A
# hardcoded default here would be a second copy of a constant that lives in src/,
# and it would drift.
#
# THE STDERR LINE IS THE PAYLOAD, not decoration. The operator whose shell carries
# a knob needs to be told, because it is affecting their REAL `5dive` invocations
# too, not only their test run — that is the more expensive half and no test can
# fix it for them. Silent on a clean environment so CI logs stay quiet, which also
# makes the line mean something when it does appear.
#   NOTE the absence of `2>/dev/null` at the call site in grading_tree.sh. The
# obvious hardening — redirect this file's stderr so it does not litter the log —
# swallows exactly the sentence that is the point. That mistake silenced all 210
# harnesses at once when it was made to grading_tree.sh's own output.
#
# HARDENED AGAINST ITS OWN FAILURE, which a mutation run surfaced rather than
# review: `unset` on a READONLY variable fails, and this file is SOURCED into
# harnesses, some of which run under `set -e` — so a caller who had marked a knob
# readonly would not get a knob leak, they would get a suite that dies before its
# first assertion. A fix that converts a wrong number into no number is worse than
# the defect. Every step is therefore individually non-fatal, and a knob that
# cannot be cleared is REPORTED rather than passed over in silence: it is still
# in effect, so the log must say so.
_five_env_isolate() {
  # Record a knob as CLEARED only AFTER the unset actually succeeds. The first cut
  # appended to `cleared` first and tried to roll the entry back in the failure
  # branch with `${cleared% *}`, which silently does nothing when there is exactly
  # one entry (no space to strip) — so a readonly knob was announced as BOTH stuck
  # and cleared, in the same breath. A report of work that did not happen is the
  # entire defect class this file exists inside; it is not allowed to live in the
  # reporter for it. T9 pins this.
  local v val cleared="" stuck=""
  for v in $(compgen -v 2>/dev/null | grep '^FIVE_' || true); do
    val="${!v-}"
    if unset "$v" 2>/dev/null; then
      cleared="${cleared:+$cleared }${v}=${val}"
    else
      stuck="${stuck:+$stuck }$v"
    fi
  done
  [[ -n "$stuck" ]] && printf 'env isolation: COULD NOT clear %s (readonly) — it is STILL IN EFFECT for this run (DIVE-2325).\n' "$stuck" >&2
  [[ -n "$cleared" ]] && printf 'env isolation: CLEARED inherited knob(s) — %s. These are set in YOUR shell and also affect your real `5dive` invocations (DIVE-2325).\n' "$cleared" >&2
  return 0
}
_five_env_isolate
