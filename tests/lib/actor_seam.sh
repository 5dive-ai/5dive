# tests/lib/actor_seam.sh — impersonate a caller through the SEALED seam (DIVE-2518).
#
# WHY THIS FILE EXISTS, and it is the most useful thing DIVE-2518 turned up.
#
# Before 2518 a harness impersonated an actor by writing `USER=agent-olivia` and
# `task_actor` believed it. That was never a test seam. It was THE FORGERY —
# the same env-var path a caller with no privilege could take to act as another
# agent across all 43 `task_actor` sites — and five harnesses depended on it
# working. Closing the forgery closed those harnesses with it: `task_actor` went
# from 20/0 to 15/5 in one of them, and every failure was a precondition arm
# saying "harness can impersonate an actor" going red.
#
# That is a good failure, and it is worth saying why. Those arms exist because
# somebody understood that an impersonation harness which silently stops
# impersonating grades NOTHING while still printing green. They turned a change in
# the product into a loud red instead of a quiet vacuity. Test seams should assert
# their own preconditions exactly like that.
#
# The sealed derivation already HAS real seams — `_gate_caller_uid` and
# `_gate_passwd_stream`, added by DIVE-2330 and kept by DIVE-2517 for precisely
# this purpose. They are FUNCTIONS, and that is the difference between a seam and
# a hole: bash imports exported functions at startup, and a fresh `5dive` defines
# its own afterwards, so an EXTERNAL caller cannot inject them — while a harness
# that SOURCES the libraries can override them freely.
#
# Usage — call INSIDE the subshell that runs the code under test:
#   ( actor_seam_as olivia; cmd_task_verify "$id" )
#   ( actor_seam_as cli;    cmd_task_start  "$id" )   # the unattributable caller
#
# Names are taken as board names (`olivia` -> unix `agent-olivia`). `cli`, `root`
# and any bare non-agent name model a caller the derivation MEASURES but cannot
# attribute to an agent — which `task_actor` reports as the `cli` sentinel.

# A uid that is not this box's. The passwd stream is stubbed alongside it, so the
# pair is self-consistent regardless of who runs the suite — the
# precondition-supplied-by-the-host defect DIVE-2365 named.
_ACTOR_SEAM_UID="${_ACTOR_SEAM_UID:-4242}"

actor_seam_as() {
  local who="${1:-}" unix
  case "$who" in
    ''|cli|runner) unix="runner" ;;
    root)          unix="root" ;;
    agent-*)       unix="$who" ;;
    *)             unix="agent-${who}" ;;
  esac
  # `eval` so the stubbed values are baked in rather than read from a variable the
  # code under test could also see and be confused by.
  eval "_gate_caller_uid()    { printf '%s' '${_ACTOR_SEAM_UID}'; }"
  eval "_gate_passwd_stream() { printf '%s:x:%s:%s:::\n' '${unix}' '${_ACTOR_SEAM_UID}' '${_ACTOR_SEAM_UID}'; }"
  # The registry memo is keyed on the resolved unix name and would otherwise carry
  # the PREVIOUS impersonation's answer into this one.
  _ACTOR_REG_MEMO_KEY=""; _ACTOR_REG_MEMO_VAL=""; _ACTOR_REG_MEMO_TIER=""
  # The identity env vars no longer decide who is acting, but they are still read
  # for PROVENANCE (`_actor_identity`) and by `auto_sender_from_sudo` on the
  # envelope path. Keep them consistent with the impersonation so an arm that
  # happens to cross one of those paths sees one coherent caller, not two.
  USER="$unix"; LOGNAME="$unix"; SUDO_UID=""; SUDO_USER=""
}

# actor_seam_selftest <expected-board-name> — assert the seam actually moved the
# actor. Call this once per harness, as a real graded arm. A seam that silently
# stops working turns every arm below it green-and-meaningless.
actor_seam_selftest() {
  local want="$1" got
  got=$( actor_seam_as "$want"; task_actor )
  [[ "$got" == "$want" ]]
}
