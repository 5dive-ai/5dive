# lib/durable.sh — INST-8: durable action semantics for IRREVERSIBLE actions.
#
# SEQUENCED after INST-4 (the ledger) and INST-5 (the broker), and deliberately
# the smallest thing that closes the hole those two left open. The brief says it
# outright: do NOT build a LangGraph clone. So this file is not a durable
# execution engine — no checkpointer, no resumable graph, no replay of a whole
# run. It is one predicate, asked immediately before a side effect that cannot
# be taken back:
#
#     has THIS action, identified by WHAT it does rather than by which attempt
#     is asking, already been performed?
#
# THE HOLE. INST-4 gave lifecycle_events a UNIQUE index on idem_key, which makes
# the RECORD of an action idempotent. It does not make the ACTION idempotent —
# the row is written after the fact, and a process that dies between firing the
# side effect and writing its row leaves the ledger claiming nothing happened.
# INST-5 gave every dangerous surface a gate and a root-only single-action
# executor, which bounds WHO may act and WHAT they may act on, but a cleared
# gate is a standing permission: re-run the executor and it fires again. Neither
# trail can answer the question above, so a crashed-and-retried agent
# double-deploys, and on the surfaces INST-8 names next (email / pay / publish)
# it double-sends, double-pays, double-publishes.
#
# THE INVERSION, and it is the single most important property in this file.
# ledger_emit is best-effort BY DESIGN: it swallows its own failure and returns 0
# because "a ledger write cannot fail the action it describes". A lease is the
# exact opposite. If we cannot record the claim, we do not know whether the
# action already happened, and the safe reading of "unknown" for an irreversible
# action is DO NOT ACT. So every write in this file refuses loudly on failure,
# and tests/durable_action_unit.sh grades that inversion with ledger_emit as its
# live control — the two must disagree on the same broken store, or one of them
# is not doing what its comment claims.
#
# WHAT MAKES THE CLAIM ATOMIC is `INSERT OR IGNORE` against a UNIQUE index on
# idem_key, with `SELECT changes()` read back over the SAME connection. changes()
# is 1 for exactly one racer and 0 for every other, with no advisory lock and no
# read-then-write window to lose. The harness mutation-grades this by dropping
# the index: the double-claim arm must go RED, or it was never the index holding
# the property.
#
# WHAT A LEASE CANNOT PROMISE. The lease is taken before the side effect and
# settled after it, so a crash in between leaves it `held`. A held lease that
# outlives its TTL is reclaimable — otherwise one crash wedges the surface
# forever — and that reclaim is the one place a double-fire is still reachable:
# if the original attempt was merely SLOW rather than dead, the reclaimer fires a
# second action. TTL is therefore a bet, and the only way to keep the bet safe is
# TTL > the action's own worst-case wall time. `state='done'` is the only
# unconditional guarantee this file offers. Both halves are graded.
#
# RESIDUAL, named rather than hidden: one cleared gate authorizes ONE action on
# one target. A legitimate second deploy of the same project@ref under the same
# task reads as a replay and returns the FIRST receipt instead of firing again.
# That is the conservative direction (a stale success beats a double-publish) but
# it is a real behaviour change, and the way to act twice is a second task row,
# not a bypass flag. A bypass a crashed agent could also reach would give the
# guarantee away, which is why none exists here.

# The default lease TTL, in seconds. Must exceed the worst-case wall time of the
# longest action behind it — today that is cmd_deploy_do's Vercel POST at
# --max-time 60 plus its --max-time 20 project read. 300 leaves 4x headroom, and
# the harness asserts the relationship against cmd_deploy.sh's own curl timeouts
# rather than against this literal, so shortening one without the other reds.
_DURABLE_TTL_DEFAULT=300

# durable_key <surface> <ident> <target> [payload] — the ACTION IDENTITY.
#
# Derived only from what the action DOES, never from which attempt is asking: no
# pid, no timestamp, no nonce. That is the whole point — retry #4 must compute
# the same key as attempt #1 or the lease cannot recognize its own action.
#
# Refuses on an empty digest instead of returning one. An empty key would be
# shared by every action on the host, so the first success would make all of them
# read as replays — silent, total, and indistinguishable from "it worked".
durable_key() {
  local surface="${1:-}" ident="${2:-}" target="${3:-}" payload="${4:-}"
  [[ -n "$surface" && -n "$target" ]] \
    || fail "$E_USAGE" "durable_key needs <surface> and <target> (INST-8)"
  local k
  k=$(ledger_hash "durable|v1|${surface}|${ident}|${target}|${payload}")
  [[ ${#k} -ge 16 ]] \
    || fail "$E_GENERIC" "durable: refusing to act on an empty idempotency key — every action would collide (INST-8)"
  printf '%s' "$k"
}

# durable_claim <surface> <ident> <target> [payload] [ttl] — take the lease.
#
# Sets DURABLE_KEY, DURABLE_STATE, DURABLE_OUTCOME_REF, DURABLE_HOLDER.
# Returns, and the caller MUST branch on all three:
#   0  claimed   — nobody has done this. Perform the action, then durable_settle.
#   3  replay    — it is already done. DURABLE_OUTCOME_REF is the original
#                  receipt. Report success with that receipt; do NOT act.
#   4  in flight — another live attempt holds the lease. Refuse; do not act.
# Any store-level failure exits through fail() rather than returning — see the
# inversion note in the file header.
durable_claim() {
  local surface="${1:-}" ident="${2:-}" target="${3:-}" payload="${4:-}"
  local ttl="${5:-$_DURABLE_TTL_DEFAULT}"
  [[ "$ttl" =~ ^[0-9]+$ && "$ttl" -gt 0 ]] \
    || fail "$E_USAGE" "durable_claim: ttl must be a positive integer (got '${ttl}')"
  DURABLE_KEY=$(durable_key "$surface" "$ident" "$target" "$payload") || return $?
  DURABLE_STATE=""; DURABLE_OUTCOME_REF=""; DURABLE_HOLDER=""

  # The table must be THERE. A claim against a store missing action_leases would
  # otherwise read as "no prior action" — the one wrong answer that permits a
  # double-fire — so its absence refuses instead of degrading.
  local have
  have=$(db "SELECT 1 FROM sqlite_master WHERE type='table' AND name='action_leases' LIMIT 1;" 2>/dev/null)
  [[ "$have" == "1" ]] \
    || fail "$E_GENERIC" "durable: action_leases is missing from $(durable_store) — cannot tell a first attempt from a retry, refusing (INST-8)"

  local holder actor
  holder="$$@${HOSTNAME:-unknown}"
  actor=$(_actor_identity)

  # THE ATOMIC CLAIM. INSERT OR IGNORE against UNIQUE(idem_key), changes() read
  # back over the same connection: exactly one racer sees 1.
  local won
  won=$(db "INSERT OR IGNORE INTO action_leases
              (idem_key, surface, ident, target, state, holder, actor, expires_at)
            VALUES ($(sqlq "$DURABLE_KEY"), $(sqlq "$surface"), $(sqlq_or_null "$ident"),
                    $(sqlq "$target"), 'held', $(sqlq "$holder"), $(sqlq "$actor"),
                    datetime('now', '+${ttl} seconds'));
           SELECT changes();") \
    || fail "$E_GENERIC" "durable: could not write the action lease — refusing to act (INST-8)"

  if [[ "$won" == "1" ]]; then
    DURABLE_STATE=claimed; DURABLE_HOLDER="$holder"
    ledger_emit action.claimed ident="$ident" \
      idem="action.claimed:${DURABLE_KEY}" in="${surface}|${target}|${payload}" \
      detail="surface=${surface} target=${target} lease=fresh ttl=${ttl}"
    return 0
  fi

  # We lost, or this action ran before. The existing row is authoritative.
  local row state ref expired
  row=$(db "SELECT state || '|' || COALESCE(outcome_ref,'') || '|' || holder || '|' ||
                   CASE WHEN expires_at <= datetime('now') THEN 1 ELSE 0 END
            FROM action_leases WHERE idem_key=$(sqlq "$DURABLE_KEY");")
  state="${row%%|*}"; row="${row#*|}"
  ref="${row%%|*}";   row="${row#*|}"
  DURABLE_HOLDER="${row%%|*}"; expired="${row##*|}"
  DURABLE_OUTCOME_REF="$ref"

  case "$state" in
    done)
      DURABLE_STATE=replay
      ledger_emit action.replayed ident="$ident" \
        idem="action.replayed:${DURABLE_KEY}:$$" \
        detail="surface=${surface} target=${target} receipt=${ref:-none}"
      return 3 ;;
    failed)
      # A failed attempt is retryable — that is the whole difference between
      # "we tried and it did not happen" and "it happened". Guarded on the state
      # we read, so a racer that settled it done in the meantime loses here.
      _durable_reclaim "$DURABLE_KEY" failed "$ttl" "$holder" "$ident" "$surface" "$target" && return 0
      return 4 ;;
    held)
      if [[ "$expired" == "1" ]]; then
        _durable_reclaim "$DURABLE_KEY" held "$ttl" "$holder" "$ident" "$surface" "$target" && return 0
        return 4
      fi
      DURABLE_STATE=inflight
      return 4 ;;
    *)
      fail "$E_GENERIC" "durable: action_leases row for this action has an unreadable state '${state}' — refusing to act (INST-8)" ;;
  esac
}

# _durable_reclaim — take over a lease in a known prior state. The prior state
# rides in the WHERE clause, so losing the race changes 0 rows and reclaims
# nothing; only the winner sees changes()=1. attempts is bumped here because the
# reclaim IS the new attempt, and it is the number that tells a reader afterwards
# whether a double-fire window was ever entered.
_durable_reclaim() {
  local key="$1" from="$2" ttl="$3" holder="$4" ident="$5" surface="$6" target="$7"
  local got
  got=$(db "UPDATE action_leases
               SET state='held', holder=$(sqlq "$holder"), attempts=attempts+1,
                   acquired_at=datetime('now'),
                   expires_at=datetime('now', '+${ttl} seconds'), settled_at=NULL
             WHERE idem_key=$(sqlq "$key") AND state=$(sqlq "$from")
               $( [[ "$from" == held ]] && printf "AND expires_at <= datetime('now')" );
             SELECT changes();") \
    || fail "$E_GENERIC" "durable: could not reclaim the action lease — refusing to act (INST-8)"
  [[ "$got" == "1" ]] || return 1
  DURABLE_STATE=claimed; DURABLE_HOLDER="$holder"
  # An expired-lease steal is the one path where a double-fire is reachable at
  # all, so it is recorded as its own kind rather than folded into a fresh claim.
  ledger_emit action.claimed ident="$ident" \
    idem="action.claimed:${key}:$$" \
    detail="surface=${surface} target=${target} lease=reclaimed_from=${from} ttl=${ttl}"
  return 0
}

# durable_settle <key> done|failed [outcome_ref] — the terminal write.
#
# `done` is the only state that makes a later attempt a replay, and outcome_ref
# is what that replay RETURNS instead of acting, so a done without its receipt is
# a lease that can only say "already happened" and never "here is what happened".
# Settling a key that does not exist is a hard failure: silently updating zero
# rows is how "we recorded it" turns into a claim nobody can check.
durable_settle() {
  local key="${1:-}" state="${2:-}" ref="${3:-}"
  [[ -n "$key" ]] || fail "$E_USAGE" "durable_settle needs <key>"
  case "$state" in done|failed) ;; *) fail "$E_USAGE" "durable_settle: state must be done|failed (got '${state}')" ;; esac
  local got
  got=$(db "UPDATE action_leases
               SET state=$(sqlq "$state"), settled_at=datetime('now'),
                   outcome_ref=COALESCE($(sqlq_or_null "$ref"), outcome_ref)
             WHERE idem_key=$(sqlq "$key");
            SELECT changes();") \
    || fail "$E_GENERIC" "durable: could not settle the action lease for ${key} (INST-8)"
  [[ "$got" == "1" ]] \
    || fail "$E_GENERIC" "durable: no action lease to settle for ${key} — the action ran without a claim (INST-8)"
  ledger_emit "action.${state}" idem="action.${state}:${key}" out="${ref}" \
    detail="lease=${key} receipt=${ref:-none}"
  return 0
}

# durable_compensation <key> <text> — record HOW to undo an action, next to the
# action. Recorded, never executed: nothing in this file evals it, and the
# harness greps for that. An automatic compensation is a second irreversible
# action fired by the same crashed process that could not finish the first one,
# and choosing to run it is exactly the judgment a gate exists to route to a
# human. What we owe is that the undo instruction is not lost.
durable_compensation() {
  local key="${1:-}" text="${2:-}"
  [[ -n "$key" && -n "$text" ]] || fail "$E_USAGE" "durable_compensation needs <key> <text>"
  local got
  got=$(db "UPDATE action_leases SET compensation=$(sqlq "$text") WHERE idem_key=$(sqlq "$key");
            SELECT changes();") \
    || fail "$E_GENERIC" "durable: could not record the compensation for ${key} (INST-8)"
  [[ "$got" == "1" ]] \
    || fail "$E_GENERIC" "durable: no action lease to attach a compensation to for ${key} (INST-8)"
  return 0
}

# durable_store — the store the leases live in, named so a refusal can say WHERE
# it looked. Same store as the ledger on purpose: an action's claim and its
# lifecycle row must not be able to disagree about whether it happened.
durable_store() { printf '%s' "${TASKS_DB:-<unset>}"; }
