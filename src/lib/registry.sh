with_registry_lock() {
  local fn="$1"; shift
  if [[ "${IN_REGISTRY_LOCK:-0}" == "1" ]]; then
    "$fn" "$@"
    return
  fi
  ensure_state
  (
    flock -x 200
    IN_REGISTRY_LOCK=1
    "$fn" "$@"
  ) 200>"$REGISTRY_LOCK"
}

registry_read() {
  [[ -f "$REGISTRY" ]] && cat "$REGISTRY" || echo '{"agents":{}}'
}

# registry_read() deliberately collapses "no registry yet" onto an empty-but-valid
# body so every read site can `jq` it without a guard. That is fine for callers
# who only want a value, and WRONG for callers who need to know whether the read
# happened at all: a permission failure, a truncated file and a genuinely empty
# fleet all come back as `{"agents":{}}`, indistinguishable.
#
# This is the checked variant. It never invents a body. Exit codes:
#   0  JSON on stdout
#   3  no registry file
#   4  file present but unreadable (perms, I/O)
#   5  file read but not parseable as JSON (truncation, partial write)
registry_read_checked() {
  [[ -e "$REGISTRY" ]] || return 3
  local body
  body="$(cat "$REGISTRY" 2>/dev/null)" || return 4
  printf '%s' "$body" | jq -e . >/dev/null 2>&1 || return 5
  printf '%s\n' "$body"
}

# DIVE-1064 stamped the sender's isolation tier into the inter-agent envelope.
# DIVE-2210 is about what that stamp does when it CANNOT be established.
#
# tier= is the one unforgeable field in `[5dive-msg ...]`: from= is caller-supplied
# and only format-validated, so tier= is the field that actually catches a
# cross-tier peer. Every site stamped it as `[[ -n "$t" ]] && header+=" tier=$t"`
# over a lookup whose stderr went to /dev/null — so a missing sudo caller, an
# unreadable registry, malformed JSON and a genuinely untiered sender ALL rendered
# as the field simply not being there. A receiver could not tell "not measured"
# from "measured, nothing to report". That is a fail-open on the only real control,
# and the same not-reached-vs-pass collapse as the v0.16 selfcheck work.
#
# So this never returns empty. A tier we could not establish is stamped
# `unknown:<reason>`, which is a value, is obviously not a tier, and says why.
# Callers append it UNCONDITIONALLY — absence of tier= now means "sent by a build
# that predates this", not "sender has no tier".
envelope_tier() {
  local caller="${1:-}"
  [[ -n "$caller" ]] || { printf 'unknown:no-caller\n'; return 0; }
  local body rc=0
  body="$(registry_read_checked)" || rc=$?
  case "$rc" in
    0) : ;;
    3) printf 'unknown:no-registry\n';          return 0 ;;
    5) printf 'unknown:registry-unparsable\n';  return 0 ;;
    *) printf 'unknown:registry-unreadable\n';  return 0 ;;
  esac
  local t=""
  t="$(printf '%s' "$body" | jq -r --arg n "$caller" '.agents[$n].isolation // empty' 2>/dev/null)" \
    || { printf 'unknown:lookup-failed\n'; return 0; }
  [[ -n "$t" ]] || { printf 'unknown:unregistered\n'; return 0; }
  # The value lands in a SPACE-DELIMITED header. A tier carrying a space would
  # forge additional envelope fields, so anything that is not a bare token is
  # reported as unusable rather than pasted through.
  [[ "$t" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { printf 'unknown:malformed-tier\n'; return 0; }
  printf '%s\n' "$t"
}

# DIVE-2552: COMPARE the claimed sender against the measured caller, and stamp the
# comparison. Both values are already in hand at every envelope site — `sender`
# (from `--from`, format-validated only) and the caller `envelope_tier` is fed —
# and until now no site put them next to each other. So `--from=marcus` run by dev
# rendered byte-for-byte identical to a send marcus actually made.
#
# tier= does NOT close this. DIVE-1064/2210 built it against a CROSS-tier peer;
# dev and marcus are both admin, so the one unforgeable field AGREES with the
# forged one. Same-tier impersonation has no tell at all today.
#
# NOT a refusal, deliberately. The obvious remedy — reject `--from=X` unless X is
# the caller — breaks the legitimate synthetic-label senders, which are not agent
# names and never derive as one: `loop`, `task-engine`, `council`, `verifier`,
# `ask`, `comment-watch`, `blocker-push`, `community-heartbeat`. Enumerating the
# acceptors before gating is the lesson of
# community/wiki/a-control-partitions-a-population-and-populations-drift.md. A
# marker keeps every one of them working and hands the receiver the fact instead.
#
# THE DIVE-2210 PROPERTY, CARRIED FORWARD. Absence must mean exactly one thing.
# Empty output here is produced by exactly ONE branch — measured, and the claim
# matched — so a missing via= is itself a measurement. Every path that did not
# measure returns an `unknown:<reason>` token instead, because a claim we could
# not check must never render the same as a claim we checked and confirmed.
#   (empty)                  measured: claimed == caller, nothing asserted
#   <caller>                 measured: claimed != caller — the real one, named
#   unknown:no-caller        no caller could be derived; the claim is UNCHECKED
#   unknown:malformed-caller caller present but not a bare header-safe token
envelope_via() {
  local claimed="${1:-}" measured="${2:-}"
  [[ -n "$measured" ]] || { printf 'unknown:no-caller\n'; return 0; }
  # Same injection surface as tier=: the value lands in a space-delimited header,
  # so a caller carrying a space would forge a second envelope field.
  [[ "$measured" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] \
    || { printf 'unknown:malformed-caller\n'; return 0; }
  [[ "$claimed" == "$measured" ]] && return 0
  printf '%s\n' "$measured"
}

# envelope_provenance <claimed> <measured> — the same question envelope_via
# answers, reduced to the VERDICT vocabulary the audit log needs (DIVE-2797).
#
# It composes over envelope_via rather than re-deciding, and that is the whole
# point of it existing. The envelope and the audit row must never be able to
# disagree about whether a send was mislabeled: two resolvers that drift apart
# give a reader a conflict with nothing in either artifact saying which one is
# right — the same defect _actor_identity was made a single function to avoid.
#
#   corroborated       the claimed sender matches what the uid measures
#   divergent          they disagree — the mislabeled/forged send
#   unclaimed          --raw or --from= : nothing was asserted to compare against
#   unknown:*          nothing could be MEASURED, so no verdict is possible;
#                      envelope_via's own reason string is passed through intact
#
# `unclaimed` is separated from `divergent` deliberately. An unasserted sender is
# not a false one, and folding them together would bury the rows that matter
# under every ordinary --raw send.
envelope_provenance() {
  local claimed="${1:-}" measured="${2:-}" via
  [[ -n "$claimed" ]] || { printf 'unclaimed\n'; return 0; }
  via="$(envelope_via "$claimed" "$measured")"
  case "$via" in
    "")        printf 'corroborated\n' ;;
    unknown:*) printf '%s\n' "$via" ;;
    *)         printf 'divergent\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# DIVE-2213: the SAME not-measured-vs-measured-absent collapse as DIVE-2210, but
# at a DECISION site (the heartbeat's privilege-escalation-by-queue guard) rather
# than a display one. envelope_tier() above is deliberately left byte-for-byte
# alone -- its output is a shipped, verified WIRE FORMAT -- so the finer
# partition a decision needs lives here instead.
#
# The distinction envelope_tier() cannot make, and does not need to: it reports
# `unknown:unregistered` for BOTH
#   (a) the name is not a key under .agents at all -- a human, or an external
#       filer. That is a MEASUREMENT: this creator correctly has no tier, and
#       every task lodar files takes this path.
#   (b) the agent IS registered but its .isolation is missing/null -- NOT
#       measured. A hole.
# tests/envelope_tier_provenance_unit.sh asserts (a) and (b) collide, on purpose.
# A guard deciding whether to trust a creator must not treat them the same: hold
# on (a) and the fleet stops running human-filed work; fall through on (b) and an
# untiered agent is permanently exempt from the guard.
#
# Reasons (never empty, and a failure is never a bare tier):
#   unknown:no-caller            no name supplied
#   unknown:no-registry          registry file absent
#   unknown:registry-unreadable  present, could not be read
#   unknown:registry-unparsable  present, read, not JSON
#   unknown:no-agents-map        parsed, but .agents is not an object
#   unknown:lookup-failed        jq errored on a body that parsed
#   unknown:unregistered         name is NOT under .agents        (MEASURED)
#   unknown:no-tier              key present, isolation absent    (not measured)
#   unknown:malformed-tier       isolation present, not a bare token
agent_tier() {
  local who="${1:-}"
  [[ -n "$who" ]] || { printf 'unknown:no-caller\n'; return 0; }
  local body rc=0
  body="$(registry_read_checked)" || rc=$?
  case "$rc" in
    0) : ;;
    3) printf 'unknown:no-registry\n';          return 0 ;;
    5) printf 'unknown:registry-unparsable\n';  return 0 ;;
    *) printf 'unknown:registry-unreadable\n';  return 0 ;;
  esac
  local present
  present="$(printf '%s' "$body" | jq -r --arg n "$who" \
    'if (.agents|type) != "object" then "no-map" elif (.agents|has($n)) then "y" else "n" end' 2>/dev/null)" \
    || { printf 'unknown:lookup-failed\n'; return 0; }
  case "$present" in
    y)      : ;;
    n)      printf 'unknown:unregistered\n';  return 0 ;;
    no-map) printf 'unknown:no-agents-map\n'; return 0 ;;
    *)      printf 'unknown:lookup-failed\n'; return 0 ;;
  esac
  local t
  t="$(printf '%s' "$body" | jq -r --arg n "$who" '.agents[$n].isolation // empty' 2>/dev/null)" \
    || { printf 'unknown:lookup-failed\n'; return 0; }
  [[ -n "$t" ]] || { printf 'unknown:no-tier\n'; return 0; }
  # Same injection rule as envelope_tier(): a tier is a bare token or it is
  # unusable. A decision site must never rank a value it could not validate.
  [[ "$t" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { printf 'unknown:malformed-tier\n'; return 0; }
  printf '%s\n' "$t"
}

# True when a tier string means "we could not measure it". Every unknown:* EXCEPT
# unregistered, which IS a measurement (this name is not an agent). This is the
# one predicate that separates the two halves of the old rank-0 bucket -- keep the
# polarity here and callers cannot re-collapse them by writing `unknown:*`.
tier_unmeasured() {
  case "$1" in
    unknown:unregistered) return 1 ;;
    unknown:*)            return 0 ;;
    *)                    return 1 ;;
  esac
}

# envelope_peer_forgery <claimed> <measured> — DIVE-2183. The REFUSAL that
# DIVE-2552 declined to make, narrowed to the one shape where refusing breaks
# nothing that works today.
#
# 2552 stamped `via=` and wrote down why it stopped there: "reject --from=X unless
# X is the caller" breaks the legitimate synthetic-label senders (`comment-watch`,
# `blocker-push`, `community-heartbeat`, `host-updates`, `loop`, `task-engine`,
# `council`, `verifier`, `ask`), none of which are agent names. That argument rules
# out the BROAD guard and says nothing about the narrow one: a claim on a name the
# REGISTRY knows is an agent has no legitimate caller but that agent itself.
#
# So the refusal turns on registration, and registration only. A label that is not
# a registered agent stays as free as it is today.
#
# WHY THIS IS A REFUSAL WHERE `via=` IS A MARKER. via= hands the fact to a
# receiver, and every receiver here is an LLM reading a pane — the field is advice
# that a model may or may not act on. Impersonating a REGISTERED PEER is the one
# case where there is nothing to weigh, so it is decided by the sender's own
# process instead of being delegated to the recipient's judgment.
#
# VERDICTS. Never empty, and every non-refusal names WHY it is not one — the
# DIVE-2210 property: "we could not check" must never be spelled like "we checked
# and it was fine".
#   ok:unclaimed            nothing was asserted (--raw, or --from=)
#   ok:corroborated         the claim matches the measured caller
#   ok:synthetic-label      MEASURED: the claim is not a registered agent name
#   ok:unmeasured:<reason>  the caller or the registry could not be measured
#   refuse:<measured>       a REGISTERED agent's name, claimed by someone else
#
# THE UNMEASURED BRANCH FAILS OPEN, DELIBERATELY, and that is defensible only
# because of what it degrades TO. A guard that refused whenever the registry was
# unreadable would take out every divergent-but-legitimate send on a box with one
# bad file mode — and it would buy nothing, because reaching the unmeasured branch
# already requires the powers this guard cannot defend against anyway. What is left
# when the refusal declines to fire is DIVE-2552's `via=`, stamped by the same two
# values: the send still carries the divergence to its receiver. Fail-open here is
# a downgrade to the marker, not a hole.
#
# NOT tier_unmeasured(). That predicate partitions on whether a TIER was measured,
# and this guard asks whether a NAME is registered. They disagree on exactly the
# rows that matter: `unknown:no-tier` and `unknown:malformed-tier` are registry
# HITS — the agent is registered, its isolation field is just missing or malformed
# — so tier_unmeasured() would wave through a claim on a real peer's name because
# that peer had no tier. Registration is answered by the presence of the key.
envelope_peer_forgery() {
  local claimed="${1:-}" measured="${2:-}"
  [[ -n "$claimed" ]] || { printf 'ok:unclaimed\n'; return 0; }
  # Compose over envelope_via rather than re-comparing, for the reason
  # envelope_provenance does: the refusal and the `via=` a receiver reads must not
  # be able to disagree about whether a send was mislabeled. It also inherits the
  # header-safety check on the measured name for free.
  local via; via="$(envelope_via "$claimed" "$measured")"
  case "$via" in
    "")        printf 'ok:corroborated\n';              return 0 ;;
    unknown:*) printf 'ok:unmeasured:%s\n' "${via#unknown:}"; return 0 ;;
  esac
  # Diverged, and both names are in hand. One question left.
  local t; t="$(agent_tier "$claimed")"
  case "$t" in
    unknown:unregistered)                    printf 'ok:synthetic-label\n' ;;
    unknown:no-tier|unknown:malformed-tier)  printf 'refuse:%s\n' "$via" ;;
    unknown:*)                               printf 'ok:unmeasured:%s\n' "${t#unknown:}" ;;
    *)                                       printf 'refuse:%s\n' "$via" ;;
  esac
}

registry_write() {
  # stdin -> registry, atomic
  local tmp
  tmp=$(mktemp "${REGISTRY}.XXXXXX")
  cat > "$tmp"
  chown root:claude "$tmp"
  chmod 640 "$tmp"
  mv "$tmp" "$REGISTRY"
}
