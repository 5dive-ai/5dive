
# -------- the sealed actor derivation (DIVE-2517, v0.18 "Proof of who") --------
#
# ONE derivation for "who is acting", and it fails CLOSED.
#
# Measured on origin/main 51bc5c6 (DIVE-2515, wiki:
# six-actor-derivations-strictest-has-smallest-blast-radius): this CLI derived the
# actor in SIX places and they disagreed. Exactly one of the six fails closed —
# `_gate_authenticated_actor`, uid-first, 8 references — and the widest one
# (`task_actor`, 43 references, the field the whole board later reads as ground
# truth) takes an argv string as gospel and can be redirected by a plain
# `SUDO_USER=` env var with no privilege at all.
#
# This file is the promotion of the strict one out of cmd_task.sh and into lib/,
# where every caller can reach it. The functions below are MOVED, not rewritten:
# `_gate_passwd_stream`, `_gate_uid_to_agent`, `_gate_caller_uid`, `_gate_is_root`,
# `_gate_authenticated_actor` and `_gate_agent_for_uid` keep their names and their
# semantics so all 8 existing gate call sites are byte-for-byte unaffected. What is
# NEW is the layer on top: `actor_derive`, which answers the same question but also
# reports WHICH SOURCE answered and, when nothing did, WHY.
#
# The identity axis reads exactly two things and nothing else:
#   1. `$EUID` — a bash builtin reflecting the KERNEL's view of this process. Not
#      PATH-resolved, not settable from the environment.
#   2. /etc/passwd, walked in PURE BASH (DIVE-2330: `id` and `getent` both resolve
#      through the CALLER'S PATH, and every agent sets its own PATH; a shim on PATH
#      printing `agent-lodar` made `id -un` return exactly that from a process whose
#      real uid was 1004).
# It does NOT consult argv, `--from`, `created_by`, `$USER`, `$SUDO_USER`, or
# `$FIVEDIVE_AUDIT_USER`. Those are provenance ("who does the caller SAY they are"),
# which is the right answer for an audit record and the wrong one for an
# authorization check.
#
# The AUTHORITY axis is not redefined here. `_actor_authority` (lib/audit.sh) is
# already single-sourced and correct — one function, built once by INST-4 — and
# this file WIRES it rather than growing a seventh opinion. That asymmetry is the
# finding the inventory recorded: a field built once by one ticket has an owner; a
# field that accretes has none and forks silently.

# SEAM for the passwd SOURCE (DIVE-2330 iteration 2). A harness needs to model a
# caller uid that maps to an `agent-*` name; without this it could only pick a uid
# that happens to exist ON THIS HOST — the same precondition-supplied-by-the-host
# defect DIVE-2365 named.
#
# A FUNCTION, deliberately NOT `${_GATE_PASSWD_FILE:-/etc/passwd}`. An env-settable
# source would be a new forgery vector in the one field this whole file exists to
# make unforgeable (same reasoning `_envelope_sender_fallback` records in
# cmd_agent_runtime.sh). A function cannot be injected: bash imports exported
# functions at startup, and the script's own definition executes AFTER that import
# and overwrites it.
# Pure bash — no `cat`, which would be PATH-resolved.
_gate_passwd_stream() { printf '%s\n' "$(</etc/passwd)"; }

# uid -> the unix NAME that owns it, or EMPTY when no passwd row claims that uid.
#
# NO PREFIX RULE HERE, on purpose. DIVE-2371: agent-ness decided by a username
# prefix is why the primary `claude` agent reads as a HUMAN. The name a uid owns is
# a measurement; whether that principal is an agent is the REGISTRY's answer
# (`actor_registry_agent` below), not a substring's.
actor_uid_to_name() {
  local want="${1:-}" name _x uid
  [[ "$want" =~ ^[0-9]+$ ]] || { printf ''; return; }
  while IFS=: read -r name _x uid _; do
    [[ "$uid" == "$want" ]] || continue
    printf '%s' "$name"; return
  done < <(_gate_passwd_stream)
  printf ''
}

# uid -> agent short name, or EMPTY. UNCHANGED semantics (DIVE-2330): a uid whose
# passwd name is not `agent-*` returns empty, exactly as before. The 8 gate call
# sites read that empty as "unidentified", and widening it here would widen who can
# self-authorize a delegated push. Composed over `actor_uid_to_name` so there is
# one passwd walk in the tree rather than two that can drift.
_gate_uid_to_agent() {
  local name; name=$(actor_uid_to_name "${1:-}")
  [[ "$name" == agent-* ]] || { printf ''; return; }
  printf '%s' "${name#agent-}"
}

# SEAMS. `$EUID` is READONLY in bash, so a unit harness cannot exercise the root
# branch by assigning it — which is exactly how a check behind an unreachable root
# test survived a year in audit.sh, and how two of `_actor_authority`'s three
# branches shipped unexercised in its first cut. The harness overrides THESE. An
# external caller cannot: invoking `5dive` starts a fresh bash that defines the
# functions itself, so there is nothing in the environment to override. That is the
# difference between a seam and a hole.
#
# There are already two root seams in this tree (`_gate_is_root` here, `_audit_is_root`
# in lib/audit.sh). Route through the one that exists for your axis; do not add a third.
_gate_is_root()     { [[ $EUID -eq 0 ]]; }
_gate_caller_uid()  { printf '%s' "$EUID"; }

_gate_authenticated_actor() {
  local a; a=$(_gate_uid_to_agent "$(_gate_caller_uid)")
  if [[ -n "$a" ]]; then printf '%s' "$a"; return; fi
  # The SUDO_UID branch stays gated on the REAL root check (_gate_is_root, itself
  # the pre-existing seam), NOT on _gate_caller_uid. Routing it through the seam
  # would let a harness modelling "caller is root" also unlock the SUDO_UID path
  # and widen who resolves to an agent — a behaviour change, not a fix.
  if _gate_is_root && [[ -n "${SUDO_UID:-}" ]]; then
    a=$(_gate_uid_to_agent "$SUDO_UID")
    [[ -n "$a" ]] && { printf '%s' "$a"; return; }
  fi
  printf ''
}

# _gate_agent_for_uid <uid> — the agent name owning a numeric uid, or EMPTY. Used
# to re-check a STORED `need_answered_uid` (DIVE-756 stamps the real pre-sudo
# invoker) against a claimed `need_answered_by`, so a `--from` spoof is visible
# after the fact and not only at answer time.
_gate_agent_for_uid() { _gate_uid_to_agent "${1:-}"; }

# DIVE-2383: the caller's real username, for the audit log's `caller=` field. Was a
# bare `id -un` at four sites in cmd_task.sh, which resolves through the CALLER'S
# PATH — so the one field a forensic reader uses to attribute an action was writable
# by the party being attributed. None of these feeds a predicate (grepped every use),
# which is why DIVE-2330 correctly left them alone; but the audit log is our
# NON-REFUSAL sink, and a forgeable `caller=` poisons the only record of the things
# that did not refuse.
#
# Composed over `actor_uid_to_name`, NOT over `_gate_uid_to_agent`: the latter fails
# closed to EMPTY for a non-agent uid, which is right for an authorization check and
# wrong here — `claude` and `root` are real callers and the forensic record has to
# name them. DIVE-2517 moved that passwd walk here and its own comment gives the
# reason to reuse it rather than add a second one: "one passwd walk in the tree
# rather than two that can drift."
# Falls back to `?` — the same unknown marker the old `|| echo '?'` emitted — so a
# uid missing from passwd still writes a row rather than an empty field.
_gate_caller_user() {
  local u; u=$(actor_uid_to_name "$(_gate_caller_uid)")
  [[ -n "$u" ]] && { printf '%s' "$u"; return; }
  printf '?'
}

# DIVE-2383: the uid stamped into — and SIGNED over — the DIVE-756 closure payload.
# Was `${SUDO_UID:-$(id -u 2>/dev/null || echo "")}`: it trusted SUDO_UID
# unconditionally and fell back to a PATH-resolved `id -u`. Both are caller-writable
# below EUID 0, so a forged subject landed inside a tamper-EVIDENT record and the
# signature then attested the lie. That is strictly worse than an unsigned wrong
# value, because `gate-proof verify` reports the forgery as INTACT.
# SUDO_UID is honoured ONLY at EUID 0 — the same fence `_gate_authenticated_actor`
# above already documents: sudo writes it, and a non-root process that forges it
# cannot also become root. Below root the answer is $EUID, which the kernel owns.
_gate_closure_subject_uid() {
  if _gate_is_root && [[ -n "${SUDO_UID:-}" ]]; then printf '%s' "$SUDO_UID"; return; fi
  _gate_caller_uid
}

# ---------------------------------------------------------------------------
# actor_derive — the same uid-first derivation, but it REPORTS its work.
#
# Sets, and never leaves stale:
#   ACTOR_UNIX     the unforgeable unix name owning the acting uid ("agent-dev",
#                  "claude", "root"), or EMPTY when unmeasurable
#   ACTOR_UID      the uid the identity was read from
#   ACTOR_SOURCE   euid | sudo_uid   — WHICH of the two trusted sources answered
#   ACTOR_REASON   populated ONLY on failure, and it names the failure
#
# Returns 0 when the actor was MEASURED, non-zero when it was not. That return is
# the whole point of the epoch: "unmeasurable" must be a refusal, never the string
# `unknown` handed back with a success status. This codebase has paid for that
# collapse repeatedly — DIVE-2210's envelope tier, DIVE-2213's heartbeat guard,
# DIVE-1927's paired probe — every time because a reader could not tell "measured,
# nothing to report" from "we could not look".
#
# NOTE the partition, and it is deliberate: a caller who is a real unix user but
# NOT an agent (`claude`, `root`) is MEASURED, not unmeasurable. "This uid is not an
# agent" is an answer. Unmeasurable means the uid resolves to nothing at all — no
# passwd row (an NSS-only or deleted account), an unreadable passwd, a non-numeric
# uid. Same absent-vs-not-measured line `tier_unmeasured` already draws for tiers.
actor_derive() {
  ACTOR_UNIX=""; ACTOR_UID=""; ACTOR_SOURCE="euid"; ACTOR_REASON=""
  local uid; uid=$(_gate_caller_uid)
  ACTOR_UID="$uid"
  # sudo's record of the pre-elevation invoker, trusted ONLY behind the REAL root
  # check (DIVE-1413): sudo writes SUDO_UID, and a non-root process forging it
  # cannot also become root. Below EUID 0 it is a plain env var, which is why
  # DIVE-950 dropped the agent-forgeable `--proof` form.
  if _gate_is_root && [[ -n "${SUDO_UID:-}" ]]; then
    [[ "$SUDO_UID" =~ ^[0-9]+$ ]] || { ACTOR_REASON="sudo-uid-not-numeric"; return 1; }
    ACTOR_UID="$SUDO_UID"; ACTOR_SOURCE="sudo_uid"
  fi
  [[ "$ACTOR_UID" =~ ^[0-9]+$ ]] || { ACTOR_REASON="uid-not-numeric"; return 1; }
  # `$(</etc/passwd)` on an unreadable file expands to empty and still leaves
  # printf's status 0, so emptiness — not the exit code — is the signal here.
  local body; body=$(_gate_passwd_stream)
  [[ -n "$body" ]] || { ACTOR_REASON="passwd-unreadable"; return 1; }
  ACTOR_UNIX=$(actor_uid_to_name "$ACTOR_UID")
  [[ -n "$ACTOR_UNIX" ]] || { ACTOR_REASON="uid-not-in-passwd"; return 1; }
  return 0
}

# actor_registry_agent <unix-name> — the BOARD name for a unix principal, decided
# by the registry, plus the tier that decided it.
#
# Sets ACTOR_AGENT (board name, or empty) and ACTOR_TIER (agent_tier's vocabulary,
# never empty). Candidates are tried `agent-dev` -> `dev` -> `dev` as-is: the
# `agent-` strip is a LOOKUP CANDIDATE, not the decision. The registry answers.
#
# agent_tier's three-way split is load-bearing here:
#   a real tier                     registered, tier usable
#   unknown:no-tier                 the key IS under .agents, isolation absent
#   unknown:malformed-tier          the key IS under .agents, isolation unusable
#   unknown:unregistered            the key is NOT            -> a MEASUREMENT, try next
#   any other unknown:*             we could not look at all  -> report it, claim nothing
#
# no-tier and malformed-tier both NAME THE AGENT and flag the tier as not measured.
# Both mean the registry answered "yes, this is an agent" and then failed only on the
# tier value; dropping the agent name because its tier was unusable would throw away
# the half that WAS measured — the same two-things-in-one-bucket collapse agent_tier
# itself exists to undo.
#
# The residual `unknown:*` branch RETURNS rather than trying the next candidate, and
# that is load-bearing. A registry we could not read is not an invitation to guess
# again with a different name: `continue` there would let a second candidate's
# success paper over the first candidate's failed lookup and report a confident
# agent identity built on a read that did not happen. Graded by T17.
actor_registry_agent() {
  local unix="${1:-}" cand t
  ACTOR_AGENT=""; ACTOR_TIER="unknown:no-caller"
  [[ -n "$unix" ]] || return 0
  for cand in "${unix#agent-}" "$unix"; do
    [[ -n "$cand" ]] || continue
    t=$(agent_tier "$cand")
    case "$t" in
      unknown:unregistered)                 ACTOR_TIER="$t"; continue ;;
      unknown:no-tier|unknown:malformed-tier) ACTOR_AGENT="$cand"; ACTOR_TIER="$t"; return 0 ;;
      unknown:*)                            ACTOR_TIER="$t"; return 0 ;;   # could not look — claim nothing
      *)                                    ACTOR_AGENT="$cand"; ACTOR_TIER="$t"; return 0 ;;
    esac
  done
  return 0
}

# The env vars this derivation deliberately IGNORES for identity. Printed by
# `5dive whoami` so the refusal is visible rather than merely documented — a reader
# holding a forged SUDO_USER should be able to see that it was read and discarded.
actor_ignored_identity_env() {
  local n v out=""
  for n in SUDO_USER USER LOGNAME FIVEDIVE_AUDIT_USER; do
    v="${!n:-}"
    [[ -n "$v" ]] && out+="${out:+, }${n}=${v}"
  done
  printf '%s' "$out"
}
