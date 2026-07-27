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
  chmod 640 "$tmp" 2>/dev/null || true
  mv "$tmp" "$CAPABILITY_DB" || { rm -f "$tmp"; return 1; }
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
  chmod 640 "$tmp" 2>/dev/null || true
  mv "$tmp" "$CAPABILITY_DB" || { rm -f "$tmp"; return 1; }
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
  printf '%s\n' a2a_deliver a2a_capture audit_append self_restart
  [[ "$can_push" == "1" ]] && printf '%s\n' delegated_push
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
capability_declare_standard() {
  local user="$1" can_push="${2:-0}" source="${3:-provisioned}" cap
  while IFS= read -r cap; do
    [[ -n "$cap" ]] || continue
    capability_declare "$cap" "$user" root "$source" \
      || warn "capability registry: could not record ${cap} for ${user} (the sudoers grant IS installed; the row is absent, which reads as undeclared)"
  done < <(_capability_names_for_standard "$can_push")
  return 0
}
