# DIVE-2102 — the C2 capability registry.
#
# Answers ONE question: "is <agent> a CONFIRMED holder of <capability>?"
# It deliberately cannot answer "is <agent> a confirmed NON-holder", because it
# would be wrong in the worst direction if it tried. The fleet predates this
# registry and splits by creation date, so a missing row correlates
# SYSTEMATICALLY with the older, MORE privileged agents. Absence therefore means
# "not declared", never "does not hold" — presence may refuse or route, absence
# falls through to today's behaviour. That asymmetry is the whole blast-radius
# bound (DIVE-2078 fork, answered C2 over C1 on 2026-07-26).
#
# Rows are keyed on (capability, AGENT). There is no host-scoped row and no
# host-scoped read: "this box has gh" is a TRUE sentence and is exactly the claim
# that was wrong three times in one day, because the agent asking was not the
# agent holding. A host row would encode that error as schema.

CAPABILITY_DB="${CAPABILITY_DB:-${STATE_DIR}/capabilities.json}"
CAPABILITY_LOCK="${CAPABILITY_LOCK:-${STATE_DIR}/capabilities.lock}"
# A row is evidence that a grant was verified AT A MOMENT. Past this age we stop
# believing it and fall back to absent — which degrades to today's behaviour,
# the only degradation that cannot create a NEW failure mode. Re-verification is
# the root heartbeat's job; this is the backstop for when it has not run.
CAPABILITY_TTL_SECONDS="${CAPABILITY_TTL_SECONDS:-604800}"  # 7d
# Injectable so the unit suite can drive THE REAL FUNCTION. Iteration 2 shipped a
# reverify arm that exercised a hand-written COPY of capability_reverify_from_sudoers
# defined inside the test — so the shipped function had ZERO coverage, proven by
# reintroducing a bug into it and watching the suite still pass 36/36 (olivia).
# A copy under test is the wrong universe: it agrees with the mutant.
CAPABILITY_SUDOERS_DIR="${CAPABILITY_SUDOERS_DIR:-/etc/sudoers.d}"

# Its OWN lock, deliberately not REGISTRY_LOCK. The mint happens inside
# write_standard_sudoers, and making a sudoers install depend on the agent
# registry's lock would put a new failure mode on the agent-create path — the
# one thing the read semantics above are structured to avoid.
_capability_lock() {
  local fn="$1"; shift
  if [[ "${IN_CAPABILITY_LOCK:-0}" == "1" ]]; then "$fn" "$@"; return; fi
  mkdir -p "$(dirname "$CAPABILITY_LOCK")" 2>/dev/null || true
  (
    flock -x 201
    IN_CAPABILITY_LOCK=1
    "$fn" "$@"
  ) 201>"$CAPABILITY_LOCK"
}

_capability_now() { date -u +%s; }

_capability_read() {
  [[ -s "$CAPABILITY_DB" ]] || { printf '[]'; return 0; }
  # A malformed store must read as EMPTY, not as an error and not as a partial
  # parse. Empty means "nothing confirmed", which is the safe direction here.
  jq -c '.' "$CAPABILITY_DB" 2>/dev/null || printf '[]'
}

# _capability_publish <tmp> — install the staged store with the ownership every
# other group-readable state writer in this tree uses (state.sh, registry.sh,
# audit.sh, validation.sh all chown root:claude before mv).
#
# DIVE-2102 iteration 1 shipped the chmod and DROPPED THE CHOWN, and the reason
# it was invisible is worth keeping: mktemp lands in /tmp as root:root, `mv`
# PRESERVES ownership, and $STATE_DIR's setgid bit applies only to files CREATED
# there — never to a file moved in. So the store landed root:root 640 and the
# oracle was unreadable by the only audience it exists for. The read path is
# fail-soft by design, so it absorbed EACCES into the SAME not-confirmed as
# absence: every consumer would have read "nobody holds anything", forever,
# silently. A fail-soft reader cannot distinguish "no row" from "I was not
# allowed to look", which is exactly why the WRITER has to be correct.
_capability_publish() {
  local tmp="$1"
  chown root:claude "$tmp" 2>/dev/null || true
  chmod 640 "$tmp" 2>/dev/null || true
  mv "$tmp" "$CAPABILITY_DB" || return 1
  chown root:claude "$CAPABILITY_DB" 2>/dev/null || true
  chmod 640 "$CAPABILITY_DB" 2>/dev/null || true
}

_capability_declare_locked() {
  local name="$1" holder="$2" declared_by="$3" source="$4" now cur tmp
  now=$(_capability_now)
  cur=$(_capability_read)
  tmp=$(mktemp) || return 1
  printf '%s' "$cur" | jq \
    --arg n "$name" --arg h "$holder" --arg d "$declared_by" \
    --arg s "$source" --argjson t "$now" \
    'map(select(.name != $n or .holder_agent != $h))
     + [{name:$n, holder_agent:$h, declared_by:$d, verified_at:$t, source:$s}]' \
    >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mkdir -p "$(dirname "$CAPABILITY_DB")" 2>/dev/null || true
  _capability_publish "$tmp" || { rm -f "$tmp"; return 1; }
}

# capability_declare <name> <holder_agent> <declared_by> <source>
# source: 'provisioned' (written by the grant-installing path) or 'backfilled'
# (a root measurement of a pre-registry agent). They differ in staleness
# semantics, so the reader can tell a fact from a reconstruction.
capability_declare() {
  [[ $# -eq 4 ]] || return 2
  [[ -n "$1" && -n "$2" ]] || return 2
  _capability_lock _capability_declare_locked "$@"
}

# capability_confirmed_holder <name> <agent>
# 0 = CONFIRMED holder (row present AND fresh). Non-zero = NOT CONFIRMED, which
# covers "no row", "stale row" and "unreadable store" and must never be read as
# "confirmed non-holder". There is deliberately no capability_is_not_holder():
# the negative claim this registry cannot support should be impossible to spell.
capability_confirmed_holder() {
  local name="$1" agent="$2" now
  [[ -n "$name" && -n "$agent" ]] || return 2
  now=$(_capability_now)
  _capability_read | jq -e \
    --arg n "$name" --arg a "$agent" --argjson now "$now" \
    --argjson ttl "$CAPABILITY_TTL_SECONDS" \
    'any(.[]; .name == $n and .holder_agent == $a
              and (($now - (.verified_at // 0)) <= $ttl))' >/dev/null 2>&1
}

# capability_holders <name> — confirmed, fresh holders only, one per line.
capability_holders() {
  local name="$1" now; now=$(_capability_now)
  _capability_read | jq -r \
    --arg n "$name" --argjson now "$now" --argjson ttl "$CAPABILITY_TTL_SECONDS" \
    '.[] | select(.name == $n and (($now - (.verified_at // 0)) <= $ttl))
         | .holder_agent' 2>/dev/null
}

_capability_forget_locked() {
  local agent="$1" cur tmp
  cur=$(_capability_read)
  tmp=$(mktemp) || return 1
  printf '%s' "$cur" | jq --arg a "$agent" 'map(select(.holder_agent != $a))' \
    >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  _capability_publish "$tmp" || { rm -f "$tmp"; return 1; }
}

# capability_forget_agent <agent> — drop every row for a torn-down agent.
# Without this a reaped agent stays a CONFIRMED holder forever, and confirmed-
# holder is the only claim this registry makes, so a stale one is the only kind
# of wrong answer it can give. Teardown is the moment the fact stops being true.
capability_forget_agent() {
  [[ -n "$1" ]] || return 2
  _capability_lock _capability_forget_locked "$1"
}

# _capability_names_for_standard <can_push> — the capabilities a standard-agent
# sudoers policy grants, derived from the SAME argument render_standard_sudoers
# branches on. Kept next to nothing else so the two cannot drift apart silently:
# if render_ grows a conditional grant, this is the function that must grow with
# it, and the unit test asserts they agree.
_capability_names_for_standard() {
  local can_push="${1:-0}"
  # INST-5: the broker's second surface. Its own axis, not a rider on can_push —
  # shipping a branch for review and shipping to PRODUCTION are different
  # authorities, so they are different rows a router can ask about separately.
  local can_deploy="${2:-0}"
  # DIVE-3573: buzz_inbound is UNCONDITIONAL for the same reason a2a_deliver is —
  # the grant confers no authority of its own. `agent buzz inbound` has no target
  # argument, drives only the calling seat's own pane, and re-derives the sender
  # from the registry rather than from anything the caller says.
  printf '%s\n' a2a_deliver a2a_capture audit_append self_restart buzz_inbound
  [[ "$can_push" == "1" ]] && printf '%s\n' delegated_push
  [[ "$can_deploy" == "1" ]] && printf '%s\n' delegated_deploy
  return 0
}

# capability_declare_standard <user> <can_push> <source> — mint every row a
# standard sudoers policy justifies. Called from write_standard_sudoers' SUCCESS
# path, on the same file that just passed `visudo -c`, so the row records the
# verified write rather than being a second copy minted at a different moment
# (the drift shape AGENT_CAN_PUSH already warns about in-tree).
#
# BEST-EFFORT BY CONSTRUCTION: the sudoers grant is authoritative, this is its
# record. A failed mint warns and returns 0, because failing the install would
# turn a bookkeeping error into a provisioning outage. A missing row reads as
# absent, which is today's behaviour.
_capability_reconcile_locked() {
  local agent="$1" declared_by="$2" source="$3" caps="$4" now cur tmp
  now=$(_capability_now)
  cur=$(_capability_read)
  tmp=$(mktemp) || return 1
  printf '%s' "$cur" | jq \
    --arg a "$agent" --arg d "$declared_by" --arg s "$source" \
    --argjson t "$now" --arg caps "$caps" \
    'map(select(.holder_agent != $a))
     + ([$caps | split("\n") | .[] | select(length > 0)]
        | map({name:., holder_agent:$a, declared_by:$d, verified_at:$t, source:$s}))' \
    >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mkdir -p "$(dirname "$CAPABILITY_DB")" 2>/dev/null || true
  _capability_publish "$tmp" || { rm -f "$tmp"; return 1; }
}

# capability_declare_standard <user> <can_push> <source> — record EXACTLY the
# capabilities a standard sudoers policy grants. Called from
# write_standard_sudoers' SUCCESS path, on the same file that just passed
# `visudo -c`, so the row records the verified write rather than being a second
# copy minted at a different moment (the drift shape AGENT_CAN_PUSH already
# warns about in-tree).
#
# RECONCILES rather than appends, and that is load-bearing in both directions.
# Appending confirms a capability the policy has STOPPED granting: re-provision
# an agent without --can-push, or re-verify after the grant is pulled, and a
# stale delegated_push row would stay CONFIRMED until its TTL expired. That is
# the one direction this registry must never be wrong in — it would hand a
# revoked capability to a router as a live fact. The policy file is total for
# this agent, so the row set is replaced from it, atomically, under one lock.
#
# BEST-EFFORT BY CONSTRUCTION: the sudoers grant is authoritative, this is its
# record. A failure warns and returns 0, because failing the install would turn
# a bookkeeping error into a provisioning outage. Absent reads as undeclared.
capability_declare_standard() {
  local user="$1" can_push="${2:-0}" source="${3:-provisioned}"
  local can_deploy="${4:-0}" caps
  caps=$(_capability_names_for_standard "$can_push" "$can_deploy")
  _capability_lock _capability_reconcile_locked "$user" root "$source" "$caps" \
    || warn "capability registry: could not record capabilities for ${user} (the sudoers grant IS installed; the rows are absent, which reads as undeclared)"
  return 0
}

# capability_reverify_from_sudoers <user> — the other half of the spec's drift
# control. Iteration 1 landed only "a stale row reads as absent", which alone
# converges the registry on permanently-empty: with a TTL and nothing renewing,
# every row expires and the oracle silently becomes "nobody holds anything" —
# a third independent path to the same nothing (olivia, DIVE-2102 iteration 1).
#
# This re-verifies against the INSTALLED sudoers file, the same artifact the
# mint recorded. It never merely refreshes verified_at: a timestamp bumped
# without a measurement is precisely the drift this ticket exists to prevent,
# and would convert an expired-and-therefore-safe row into a confidently wrong
# one. If the file is gone, the grant is gone, so the rows go too.
capability_reverify_from_sudoers() {
  local user="$1" can_push=0
  local can_deploy=0
  local f
  [[ -n "$user" ]] || return 2
  # NOT one `local` line. `local a="$1" b="...${a}"` expands every word before it
  # assigns any, so ${a} resolves to whatever `a` meant in the CALLER's scope
  # under bash dynamic scoping — NOT to "$1".
  #
  # The failure is a SILENTLY WRONG VALUE, not a crash, and getting that wrong is
  # what lets sibling instances survive review. The identical pattern is on
  # origin/main in write_standard_sudoers today and provisioning works, because
  # the caller happens to have `user` set to the same thing. Orphaned under
  # `set -u` it dies unbound; under `set -eo` alone it silently builds a path
  # from the wrong value. See [[multi-assign-local-takes-the-callers-value]].
  f="${CAPABILITY_SUDOERS_DIR}/${user}"
  if [[ ! -r "$f" ]]; then
    # Absent OR unreadable. Both mean "cannot confirm from the artifact", and
    # forgetting degrades to absent = today's behaviour. Never the other way.
    capability_forget_agent "$user"
    return 0
  fi
  grep -q '5dive _push_do' "$f" && can_push=1
  grep -q '5dive _deploy_do' "$f" && can_deploy=1
  # Only a STANDARD policy is modelled here; an admin policy is a different
  # shape and claiming standard capabilities from it would be a false record.
  grep -q '5dive agent _deliver' "$f" || { capability_forget_agent "$user"; return 0; }
  capability_declare_standard "$user" "$can_push" reverified "$can_deploy"
}
